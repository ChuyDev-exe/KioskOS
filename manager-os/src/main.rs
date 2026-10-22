//! KioskOS manager service.
//!
//! Serves the local setup wizard, reports the device state and joins Wi-Fi
//! networks through `wpa_supplicant`. The kiosk browser always opens this
//! service first: it shows the wizard while the device is offline and
//! redirects to the configured homepage once it is online.
//!
//! Security model: the service runs as root and is bound to 127.0.0.1 on the
//! device. Binding to loopback is not enough on its own, because the remote
//! homepage runs in the same browser and could send requests to localhost
//! (CSRF) or reach it through DNS rebinding. Every request must therefore
//! carry a local `Host`, and mutating requests must be POSTs whose `Origin`
//! (when present) is this service.

use actix_files as fs_serve;
use actix_web::body::MessageBody;
use actix_web::dev::{ServiceRequest, ServiceResponse};
use actix_web::http::header;
use actix_web::middleware::{from_fn, Next};
use actix_web::{web, App, Error, HttpRequest, HttpResponse, HttpServer, Responder};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::net::{IpAddr, TcpStream, ToSocketAddrs};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixDatagram;
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const INTERFACE: &str = "wlan0";
const WPA_UNIT: &str = "wpa_supplicant@wlan0";
const DEFAULT_HOMEPAGE: &str = "https://self-order-kiosk-front.vercel.app/";
const HOMEPAGE_PLACEHOLDER: &str = "{{KIOSK_HOMEPAGE_URL}}";
/// How long a connectivity result is reused (avoids one probe per request).
const CONNECTIVITY_TTL: Duration = Duration::from_secs(10);
/// TCP connect timeout of each connectivity probe.
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a Wi-Fi connection attempt may take before it is rolled back.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

// ── Settings ────────────────────────────────────────────────────────────────

struct Settings {
    static_path: String,
    bind_addr: String,
    bind_port: String,
    homepage_url: String,
    api_token: Option<String>,
    wifi_country: String,
    wpa_conf_path: String,
    /// True when the service is bound to loopback (the device default):
    /// only local `Host` headers are accepted.
    enforce_local: bool,
}

static SETTINGS: OnceLock<Settings> = OnceLock::new();

fn settings() -> &'static Settings {
    SETTINGS.get_or_init(Settings::from_env)
}

fn env_or(key: &str, default: &str) -> String {
    env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| default.to_string())
}

fn is_loopback(addr: &str) -> bool {
    addr.eq_ignore_ascii_case("localhost")
        || addr
            .parse::<IpAddr>()
            .map(|ip| ip.is_loopback())
            .unwrap_or(false)
}

impl Settings {
    fn from_env() -> Self {
        let bind_addr = env_or("BIND_ADDRESS", "127.0.0.1");
        let country = env_or("WIFI_COUNTRY", "US").to_ascii_uppercase();
        let wifi_country = if country.len() == 2 && country.chars().all(|c| c.is_ascii_uppercase())
        {
            country
        } else {
            eprintln!("Invalid WIFI_COUNTRY '{country}', using US");
            "US".to_string()
        };

        Settings {
            static_path: env_or("STATIC_PATH", "/static"),
            enforce_local: is_loopback(&bind_addr),
            bind_addr,
            bind_port: env_or("BIND_PORT", "8080"),
            homepage_url: env_or("KIOSK_HOMEPAGE_URL", DEFAULT_HOMEPAGE),
            api_token: env::var("API_TOKEN").ok().filter(|t| !t.is_empty()),
            wifi_country,
            wpa_conf_path: env_or(
                "WPA_CONF_PATH",
                "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf",
            ),
        }
    }
}

// ── Request guards (Host / Origin / token) ──────────────────────────────────

fn local_authorities(port: &str) -> Vec<String> {
    let mut list = vec![
        format!("localhost:{port}"),
        format!("127.0.0.1:{port}"),
        format!("[::1]:{port}"),
    ];
    if port == "80" {
        list.extend(["localhost", "127.0.0.1", "[::1]"].map(String::from));
    }
    list
}

/// DNS-rebinding guard: when bound to loopback, only local hosts are valid.
fn host_allowed(host: Option<&str>, enforce_local: bool, port: &str) -> bool {
    if !enforce_local {
        return true;
    }
    match host {
        // HTTP/1.0 clients may omit it; a browser never does.
        None => true,
        Some(h) => local_authorities(port)
            .iter()
            .any(|a| a.eq_ignore_ascii_case(h)),
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum OriginKind {
    /// No Origin header: a non-browser client (curl, a script on the device).
    Absent,
    /// Same origin as the service (the setup wizard itself).
    SameOrigin,
    /// Any other page, e.g. the remote homepage loaded in the kiosk.
    Foreign,
}

fn classify_origin(origin: Option<&str>, host: Option<&str>) -> OriginKind {
    match (origin, host) {
        (None, _) => OriginKind::Absent,
        (Some(o), Some(h)) if o.eq_ignore_ascii_case(&format!("http://{h}")) => {
            OriginKind::SameOrigin
        }
        _ => OriginKind::Foreign,
    }
}

fn header_str<'a>(req: &'a HttpRequest, name: &str) -> Option<&'a str> {
    req.headers().get(name).and_then(|v| v.to_str().ok())
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Authorization of state-changing requests.
///
/// * A foreign `Origin` is always rejected (CSRF from the kiosk homepage).
/// * With `API_TOKEN` set, the token is required, except for the wizard
///   itself when the service is bound to loopback (only local processes can
///   reach it, and a remote page cannot forge a same-origin request).
fn authorize_mutation(req: &HttpRequest) -> Result<(), HttpResponse> {
    let s = settings();
    let kind = classify_origin(header_str(req, "origin"), header_str(req, "host"));

    if kind == OriginKind::Foreign {
        return Err(HttpResponse::Forbidden()
            .json(serde_json::json!({"success": false, "error": "Origen no permitido"})));
    }

    let Some(expected) = &s.api_token else {
        return Ok(());
    };
    if kind == OriginKind::SameOrigin && s.enforce_local {
        return Ok(());
    }
    let given = header_str(req, "x-api-token").unwrap_or("");
    if constant_time_eq(given.as_bytes(), expected.as_bytes()) {
        Ok(())
    } else {
        Err(HttpResponse::Unauthorized()
            .json(serde_json::json!({"success": false, "error": "No autorizado"})))
    }
}

async fn host_guard(
    req: ServiceRequest,
    next: Next<impl MessageBody + 'static>,
) -> Result<ServiceResponse<impl MessageBody>, Error> {
    let s = settings();
    let host = req
        .headers()
        .get(header::HOST)
        .and_then(|v| v.to_str().ok());
    if host_allowed(host, s.enforce_local, &s.bind_port) {
        next.call(req).await.map(|res| res.map_into_left_body())
    } else {
        Ok(req
            .into_response(HttpResponse::Forbidden().body("Forbidden host"))
            .map_into_right_body())
    }
}

// ── Templates ───────────────────────────────────────────────────────────────

/// Escapes a value for a JavaScript string literal (without the quotes).
fn js_string_inner(value: &str) -> String {
    let quoted = serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string());
    quoted[1..quoted.len() - 1].replace("</", "<\\/")
}

fn render_template(name: &str) -> String {
    let s = settings();
    let url = js_string_inner(&s.homepage_url);
    let path = format!("{}/{}", s.static_path, name);
    match fs::read_to_string(&path) {
        Ok(content) => content.replace(HOMEPAGE_PLACEHOLDER, &url),
        Err(e) => {
            eprintln!("Error reading {path}: {e}");
            format!(
                r#"<!DOCTYPE html><html><body><script>window.location.href="{url}";</script></body></html>"#
            )
        }
    }
}

fn html(body: String) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/html; charset=utf-8")
        .insert_header((header::CACHE_CONTROL, "no-store"))
        .body(body)
}

// ── Pages ───────────────────────────────────────────────────────────────────

async fn index() -> impl Responder {
    let online = web::block(check_connectivity).await.unwrap_or(false);
    if online {
        return html(render_template("redirect.html"));
    }

    let index_path = format!("{}/index.html", settings().static_path);
    match fs::read_to_string(&index_path) {
        Ok(content) => html(content),
        Err(e) => {
            eprintln!("Error reading index.html from {index_path}: {e}");
            HttpResponse::InternalServerError().body("Error loading page")
        }
    }
}

async fn restarting() -> impl Responder {
    html(render_template("start_kiosk.html"))
}

async fn start_kiosk(req: HttpRequest) -> impl Responder {
    if let Err(resp) = authorize_mutation(&req) {
        return resp;
    }

    // --no-block only queues the job, so the response reaches the browser
    // before systemd tears the kiosk session (and the browser) down.
    let result = web::block(|| {
        Command::new("systemctl")
            .args(["--no-block", "restart", "kiosk.service"])
            .output()
    })
    .await;

    match result {
        Ok(Ok(o)) if o.status.success() => {
            HttpResponse::Accepted().json(serde_json::json!({"success": true}))
        }
        Ok(Ok(o)) => HttpResponse::InternalServerError().json(serde_json::json!({
            "success": false,
            "error": format!("No se pudo reiniciar el kiosco: {}", String::from_utf8_lossy(&o.stderr).trim()),
        })),
        Ok(Err(e)) => HttpResponse::InternalServerError().json(serde_json::json!({
            "success": false,
            "error": format!("No se pudo ejecutar systemctl: {e}"),
        })),
        Err(e) => HttpResponse::InternalServerError()
            .json(serde_json::json!({"success": false, "error": e.to_string()})),
    }
}

// ── Connectivity ────────────────────────────────────────────────────────────

struct ConnectivityCache {
    online: bool,
    at: Instant,
}

static CONNECTIVITY: Mutex<Option<ConnectivityCache>> = Mutex::new(None);
/// Serialises the probes: concurrent requests wait for one result instead of
/// all probing at once.
static PROBE_LOCK: Mutex<()> = Mutex::new(());

fn cached_connectivity() -> Option<bool> {
    let cache = CONNECTIVITY.lock().ok()?;
    cache
        .as_ref()
        .filter(|c| c.at.elapsed() < CONNECTIVITY_TTL)
        .map(|c| c.online)
}

fn invalidate_connectivity() {
    if let Ok(mut cache) = CONNECTIVITY.lock() {
        *cache = None;
    }
}

/// Whether the device is online, cached for `CONNECTIVITY_TTL`.
fn check_connectivity() -> bool {
    if let Some(online) = cached_connectivity() {
        return online;
    }
    let _guard = PROBE_LOCK.lock();
    if let Some(online) = cached_connectivity() {
        return online;
    }

    let online = is_interface_up(INTERFACE) && has_global_ipv4(INTERFACE) && has_internet();

    if let Ok(mut cache) = CONNECTIVITY.lock() {
        *cache = Some(ConnectivityCache {
            online,
            at: Instant::now(),
        });
    }
    online
}

/// Host and port of an http(s) URL, e.g. `https://a.com:8443/x` → `a.com:8443`.
fn url_authority(url: &str) -> Option<String> {
    let (default_port, rest) = match url.split_once("://")? {
        ("https", r) => (443, r),
        ("http", r) => (80, r),
        _ => return None,
    };
    let authority = rest.split(['/', '?', '#']).next()?;
    let authority = authority.rsplit('@').next()?;
    if authority.is_empty() {
        return None;
    }
    let has_port = if authority.starts_with('[') {
        authority.contains("]:")
    } else {
        authority.contains(':')
    };
    Some(if has_port {
        authority.to_string()
    } else {
        format!("{authority}:{default_port}")
    })
}

fn tcp_reachable(target: &str) -> bool {
    target
        .to_socket_addrs()
        .ok()
        .into_iter()
        .flatten()
        .take(2)
        .any(|addr| TcpStream::connect_timeout(&addr, PROBE_TIMEOUT).is_ok())
}

/// A TCP connection instead of ICMP: many networks (hotels, offices) block
/// ping but allow HTTPS. The homepage host is tried first because it is what
/// the kiosk actually needs.
fn has_internet() -> bool {
    let mut targets = Vec::new();
    if let Some(home) = url_authority(&settings().homepage_url) {
        targets.push(home);
    }
    targets.push("1.1.1.1:443".to_string());
    targets.push("8.8.8.8:53".to_string());
    targets.iter().any(|t| tcp_reachable(t))
}

fn is_interface_up(interface: &str) -> bool {
    fs::read_to_string(format!("/sys/class/net/{interface}/operstate"))
        .map(|s| s.trim() == "up")
        .unwrap_or(false)
}

fn has_global_ipv4(interface: &str) -> bool {
    Command::new("ip")
        .args(["-4", "addr", "show", "dev", interface, "scope", "global"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("inet "))
        .unwrap_or(false)
}

// ── Wi-Fi connection ────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct WifiForm {
    ssid: String,
    #[serde(default)]
    password: String,
}

#[derive(Clone, Copy, Serialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
enum ConnectPhase {
    Idle,
    Connecting,
    Connected,
    Failed,
}

#[derive(Clone, Serialize)]
struct ConnectStatus {
    phase: ConnectPhase,
    ssid: Option<String>,
    error: Option<String>,
}

static CONNECT_STATUS: Mutex<ConnectStatus> = Mutex::new(ConnectStatus {
    phase: ConnectPhase::Idle,
    ssid: None,
    error: None,
});
static CONNECT_BUSY: AtomicBool = AtomicBool::new(false);

fn set_status(phase: ConnectPhase, ssid: &str, error: Option<String>) {
    if let Ok(mut s) = CONNECT_STATUS.lock() {
        *s = ConnectStatus {
            phase,
            ssid: Some(ssid.to_string()),
            error,
        };
    }
}

fn connect_status() -> ConnectStatus {
    CONNECT_STATUS
        .lock()
        .map(|s| s.clone())
        .unwrap_or(ConnectStatus {
            phase: ConnectPhase::Idle,
            ssid: None,
            error: None,
        })
}

fn is_hex_psk(psk: &str) -> bool {
    psk.len() == 64 && psk.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Validates the credentials the same way wpa_supplicant would.
fn validate_credentials(ssid: &str, psk: &str) -> Result<(), String> {
    if ssid.is_empty() {
        return Err("El nombre de la red (SSID) está vacío".to_string());
    }
    if ssid.len() > 32 {
        return Err("El nombre de la red no puede superar 32 bytes".to_string());
    }
    if psk.is_empty() || is_hex_psk(psk) {
        return Ok(());
    }
    let printable = psk.bytes().all(|b| (0x20..=0x7e).contains(&b));
    let len = psk.len();
    if !printable || !(8..=63).contains(&len) {
        return Err(
            "La contraseña debe tener entre 8 y 63 caracteres ASCII imprimibles".to_string(),
        );
    }
    Ok(())
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Builds the wpa_supplicant configuration for the given credentials.
///
/// wpa_supplicant does not process escape sequences inside `ssid="..."` or
/// `psk="..."`: it takes everything up to the LAST double quote literally.
/// So the SSID is written hex-encoded (valid for any byte sequence) and the
/// passphrase, already validated as printable ASCII, is written verbatim.
/// An empty password means an open network.
fn wpa_supplicant_config(ssid: &str, psk: &str, country: &str) -> String {
    let security = if psk.is_empty() {
        "    key_mgmt=NONE\n".to_string()
    } else if is_hex_psk(psk) {
        format!("    psk={}\n", psk.to_ascii_lowercase())
    } else {
        format!("    psk=\"{psk}\"\n")
    };

    format!(
        "ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev\nupdate_config=1\ncountry={country}\n\nnetwork={{\n    ssid={}\n    scan_ssid=1\n{security}}}\n",
        hex_encode(ssid.as_bytes())
    )
}

/// Writes a file atomically with mode 0600 (it holds the Wi-Fi password):
/// temp file + fsync + rename, so a power cut never leaves it half written
/// and the password is never readable by other users, not even briefly.
fn write_secure(path: &Path, contents: &[u8]) -> io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(dir)?;
    let tmp = path.with_extension("tmp");
    let _ = fs::remove_file(&tmp);
    {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(contents)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    if let Ok(d) = fs::File::open(dir) {
        let _ = d.sync_all();
    }
    Ok(())
}

fn systemctl(args: &[&str]) -> Result<(), String> {
    let out = Command::new("systemctl")
        .args(args)
        .output()
        .map_err(|e| format!("systemctl: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!(
            "systemctl {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

/// SSID the interface is currently associated with, if any.
fn associated_ssid(interface: &str) -> Option<String> {
    let out = Command::new("iw")
        .args(["dev", interface, "link"])
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .find_map(|l| l.trim_start().strip_prefix("SSID: "))
        .map(unescape_iw)
}

/// systemd-networkd (systemd-net-min layer) runs DHCP on wlan0. Only fall
/// back to dhclient on images without it, so two DHCP clients never fight.
fn ensure_dhcp(interface: &str) {
    let networkd_active = Command::new("systemctl")
        .args(["is-active", "--quiet", "systemd-networkd"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !networkd_active {
        let _ = Command::new("/usr/sbin/dhclient")
            .args(["-nw", interface])
            .status();
    }
}

fn wait_for_association(ssid: &str, timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if associated_ssid(INTERFACE).as_deref() == Some(ssid) && has_global_ipv4(INTERFACE) {
            return true;
        }
        thread::sleep(Duration::from_secs(1));
    }
    false
}

/// Joins `ssid`. On failure the previous configuration is restored, so a
/// mistyped password never disconnects a device that was already working.
fn connect_wifi(ssid: &str, psk: &str) -> Result<(), String> {
    let s = settings();
    let path = Path::new(&s.wpa_conf_path);
    let previous = fs::read(path).ok();

    write_secure(
        path,
        wpa_supplicant_config(ssid, psk, &s.wifi_country).as_bytes(),
    )
    .map_err(|e| format!("No se pudo guardar la configuración: {e}"))?;

    let attempt = systemctl(&["restart", WPA_UNIT]).and_then(|_| {
        ensure_dhcp(INTERFACE);
        if wait_for_association(ssid, CONNECT_TIMEOUT) {
            Ok(())
        } else {
            Err(format!(
                "No se pudo conectar a «{ssid}» en {} s. Revisa la contraseña.",
                CONNECT_TIMEOUT.as_secs()
            ))
        }
    });

    if let Err(e) = attempt {
        eprintln!(
            "Wi-Fi connection to '{ssid}' failed ({e}), restoring the previous configuration"
        );
        let restored = match &previous {
            Some(bytes) => write_secure(path, bytes),
            None => fs::remove_file(path).or_else(|err| {
                if err.kind() == io::ErrorKind::NotFound {
                    Ok(())
                } else {
                    Err(err)
                }
            }),
        };
        if let Err(re) = restored {
            eprintln!("Could not restore the previous Wi-Fi configuration: {re}");
        }
        let _ = systemctl(&["restart", WPA_UNIT]);
        return Err(e);
    }

    // The clock is usually wrong on a Pi without RTC; resync it now that the
    // network is up. Not fatal: the connection itself already worked.
    if let Err(e) = systemctl(&["restart", "systemd-timesyncd"]) {
        eprintln!("Warning: {e}");
    }
    Ok(())
}

async fn set_wifi(form: web::Form<WifiForm>, req: HttpRequest) -> impl Responder {
    if let Err(resp) = authorize_mutation(&req) {
        return resp;
    }

    let WifiForm { ssid, password } = form.into_inner();
    if let Err(e) = validate_credentials(&ssid, &password) {
        return HttpResponse::BadRequest().json(serde_json::json!({"success": false, "error": e}));
    }

    if CONNECT_BUSY.swap(true, Ordering::SeqCst) {
        return HttpResponse::Conflict().json(serde_json::json!({
            "success": false,
            "error": "Ya hay una conexión en curso",
        }));
    }

    println!("Received Wi-Fi configuration request - SSID: {ssid}");
    set_status(ConnectPhase::Connecting, &ssid, None);

    thread::spawn(move || {
        let result = connect_wifi(&ssid, &password);
        invalidate_connectivity();
        match result {
            Ok(()) => {
                println!("Wi-Fi configured successfully for SSID: {ssid}");
                set_status(ConnectPhase::Connected, &ssid, None);
            }
            Err(e) => {
                eprintln!("Wi-Fi configuration failed: {e}");
                set_status(ConnectPhase::Failed, &ssid, Some(e));
            }
        }
        CONNECT_BUSY.store(false, Ordering::SeqCst);
    });

    HttpResponse::Accepted().json(serde_json::json!({
        "success": true,
        "message": "Conexión en curso",
    }))
}

async fn check_wifi() -> impl Responder {
    let online = web::block(check_connectivity).await.unwrap_or(false);
    let status = connect_status();
    HttpResponse::Ok().json(serde_json::json!({
        "connected": online,
        "phase": status.phase,
        "ssid": status.ssid,
        "error": status.error,
    }))
}

// ── Wi-Fi scan ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize)]
struct Network {
    ssid: String,
    signal_dbm: Option<i32>,
    secure: bool,
}

/// Decodes the `\xNN` escapes `iw` uses for non-printable SSID bytes.
fn unescape_iw(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 4 <= bytes.len() && bytes[i + 1] == b'x' {
            let decoded = std::str::from_utf8(&bytes[i + 2..i + 4])
                .ok()
                .and_then(|h| u8::from_str_radix(h, 16).ok());
            if let Some(b) = decoded {
                out.push(b);
                i += 4;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn parse_dbm(value: &str) -> Option<i32> {
    value
        .split_whitespace()
        .next()?
        .parse::<f32>()
        .ok()
        .map(|v| v.round() as i32)
}

fn parse_iw_scan(output: &str) -> Vec<Network> {
    let mut networks = Vec::new();
    let mut current: Option<Network> = None;

    for line in output.lines() {
        let trimmed = line.trim();
        if line.starts_with("BSS ") {
            networks.extend(current.take());
            current = Some(Network {
                ssid: String::new(),
                signal_dbm: None,
                secure: false,
            });
            continue;
        }
        let Some(net) = current.as_mut() else {
            continue;
        };
        if let Some(v) = trimmed.strip_prefix("signal:") {
            net.signal_dbm = parse_dbm(v);
        } else if let Some(v) = trimmed.strip_prefix("SSID:") {
            net.ssid = unescape_iw(v.trim());
        } else if let Some(v) = trimmed.strip_prefix("capability:") {
            if v.split_whitespace().any(|f| f == "Privacy") {
                net.secure = true;
            }
        } else if trimmed.starts_with("RSN:") || trimmed.starts_with("WPA:") {
            net.secure = true;
        }
    }
    networks.extend(current);
    networks
}

fn parse_iwlist_scan(output: &str) -> Vec<Network> {
    let mut networks = Vec::new();
    let mut current: Option<Network> = None;

    for line in output.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("Cell ") {
            networks.extend(current.take());
            current = Some(Network {
                ssid: String::new(),
                signal_dbm: None,
                secure: false,
            });
            continue;
        }
        let Some(net) = current.as_mut() else {
            continue;
        };
        if let Some(pos) = trimmed.find("Signal level=") {
            net.signal_dbm = parse_dbm(&trimmed[pos + "Signal level=".len()..]);
        }
        if trimmed == "Encryption key:on" {
            net.secure = true;
        }
        if let Some(rest) = trimmed.strip_prefix("ESSID:\"") {
            if let Some(end) = rest.rfind('"') {
                net.ssid = unescape_iw(&rest[..end]);
            }
        }
    }
    networks.extend(current);
    networks
}

/// Drops hidden networks, keeps the strongest BSS per SSID and sorts by
/// signal (strongest first).
fn dedupe_networks(list: Vec<Network>) -> Vec<Network> {
    let mut best: HashMap<String, Network> = HashMap::new();
    for net in list.into_iter().filter(|n| !n.ssid.trim().is_empty()) {
        match best.get_mut(&net.ssid) {
            Some(existing) => {
                let secure = existing.secure || net.secure;
                if net.signal_dbm.unwrap_or(i32::MIN) > existing.signal_dbm.unwrap_or(i32::MIN) {
                    *existing = net;
                }
                existing.secure = secure;
            }
            None => {
                best.insert(net.ssid.clone(), net);
            }
        }
    }
    let mut result: Vec<Network> = best.into_values().collect();
    result.sort_by(|a, b| {
        b.signal_dbm
            .unwrap_or(i32::MIN)
            .cmp(&a.signal_dbm.unwrap_or(i32::MIN))
            .then_with(|| a.ssid.cmp(&b.ssid))
    });
    result
}

fn run_iw_scan() -> Option<String> {
    let out = Command::new("iw")
        .args(["dev", INTERFACE, "scan"])
        .output()
        .ok()?;
    if out.status.success() {
        return Some(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    if err.contains("Network is down") {
        // A link without configuration can be administratively down.
        let _ = Command::new("ip")
            .args(["link", "set", INTERFACE, "up"])
            .status();
    }
    None
}

fn scan_wifi_networks() -> Vec<Network> {
    // wpa_supplicant scans on its own and makes `iw scan` fail with EBUSY
    // now and then: retry a couple of times before giving up.
    for attempt in 0..3 {
        if let Some(out) = run_iw_scan() {
            let list = dedupe_networks(parse_iw_scan(&out));
            if !list.is_empty() {
                return list;
            }
        }
        if attempt < 2 {
            thread::sleep(Duration::from_millis(800));
        }
    }

    if let Ok(out) = Command::new("iwlist").args([INTERFACE, "scan"]).output() {
        if out.status.success() {
            return dedupe_networks(parse_iwlist_scan(&String::from_utf8_lossy(&out.stdout)));
        }
    }
    Vec::new()
}

async fn scan_wifi() -> impl Responder {
    match web::block(scan_wifi_networks).await {
        Ok(networks) => HttpResponse::Ok().json(serde_json::json!({
            "success": true,
            "networks": networks,
        })),
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({
            "success": false,
            "error": format!("No se pudo escanear: {e}"),
        })),
    }
}

// ── Health ──────────────────────────────────────────────────────────────────

fn uptime_secs() -> Option<u64> {
    fs::read_to_string("/proc/uptime")
        .ok()?
        .split_whitespace()
        .next()?
        .parse::<f64>()
        .ok()
        .map(|v| v as u64)
}

fn collect_health() -> serde_json::Value {
    let kiosk_active = Command::new("systemctl")
        .args(["is-active", "--quiet", "kiosk.service"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    serde_json::json!({
        "uptime_secs": uptime_secs(),
        "wlan_connected": is_interface_up(INTERFACE),
        "internet": check_connectivity(),
        "kiosk_service_active": kiosk_active,
        "wifi": connect_status(),
        "version": env!("CARGO_PKG_VERSION"),
    })
}

/// Process commands are blocking: run them on the blocking pool so a slow
/// `systemctl` never stalls an actix worker.
async fn health() -> impl Responder {
    match web::block(collect_health).await {
        Ok(v) => HttpResponse::Ok()
            .insert_header((header::CACHE_CONTROL, "no-store"))
            .json(v),
        Err(e) => HttpResponse::InternalServerError().body(e.to_string()),
    }
}

/// Cheap liveness endpoint used by the systemd watchdog probe.
async fn livez() -> impl Responder {
    HttpResponse::Ok().body("ok")
}

// ── systemd watchdog ────────────────────────────────────────────────────────

fn sd_notify(sock: &UnixDatagram, path: &str, msg: &[u8]) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    if let Some(name) = path.strip_prefix('@') {
        use std::os::linux::net::SocketAddrExt;
        let addr = std::os::unix::net::SocketAddr::from_abstract_name(name.as_bytes())?;
        return sock.send_to_addr(msg, &addr).map(|_| ());
    }
    sock.send_to(msg, path).map(|_| ())
}

/// Sends an HTTP request to the service itself; true when it answers 200.
fn probe_http(addr: &str) -> bool {
    let Some(target) = addr.to_socket_addrs().ok().and_then(|mut a| a.next()) else {
        return false;
    };
    let Ok(mut stream) = TcpStream::connect_timeout(&target, Duration::from_secs(3)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let request = format!("GET /livez HTTP/1.0\r\nHost: {addr}\r\n\r\n");
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut buf = [0u8; 16];
    let n = stream.read(&mut buf).unwrap_or(0);
    let head = String::from_utf8_lossy(&buf[..n]);
    head.starts_with("HTTP/1.") && head.contains(" 200")
}

/// Pings the systemd watchdog only while the HTTP server really answers, so
/// a hung server gets restarted (a blind timer would only detect a crash,
/// which `Restart=` already covers).
fn spawn_watchdog() {
    let Ok(socket_path) = env::var("NOTIFY_SOCKET") else {
        return;
    };
    if socket_path.is_empty() {
        return;
    }
    let interval = env::var("WATCHDOG_USEC")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(|us| Duration::from_micros(us / 3))
        .unwrap_or(Duration::from_secs(10));

    let s = settings();
    let host = match s.bind_addr.as_str() {
        "0.0.0.0" | "::" | "[::]" => "127.0.0.1",
        other => other,
    };
    let probe_addr = format!("{host}:{}", s.bind_port);

    thread::spawn(move || {
        let Ok(sock) = UnixDatagram::unbound() else {
            eprintln!("Watchdog disabled: cannot create the notify socket");
            return;
        };
        loop {
            if probe_http(&probe_addr) {
                if let Err(e) = sd_notify(&sock, &socket_path, b"WATCHDOG=1") {
                    eprintln!("Watchdog notify failed: {e}");
                }
            } else {
                eprintln!("Watchdog probe failed: the HTTP server is not answering");
            }
            thread::sleep(interval);
        }
    });
}

// ── Main ────────────────────────────────────────────────────────────────────

#[actix_web::main]
async fn main() -> io::Result<()> {
    let s = settings();
    let bind = format!("{}:{}", s.bind_addr, s.bind_port);

    println!("Starting KioskOS manager on {bind}");
    println!("Serving static files from: {}", s.static_path);
    if s.api_token.is_some() {
        println!("API authentication enabled (X-API-Token)");
    }
    if !s.enforce_local {
        println!("Warning: not bound to loopback, the Host check is disabled");
    }

    spawn_watchdog();

    HttpServer::new(move || {
        App::new()
            .wrap(from_fn(host_guard))
            .route("/", web::get().to(index))
            .route("/restarting", web::get().to(restarting))
            .route("/set_wifi", web::post().to(set_wifi))
            .route("/start_kiosk", web::post().to(start_kiosk))
            .route("/check_wifi", web::get().to(check_wifi))
            .route("/scan_wifi", web::get().to(scan_wifi))
            .route("/health", web::get().to(health))
            .route("/livez", web::get().to(livez))
            .service(fs_serve::Files::new("/static", s.static_path.clone()))
    })
    // Two workers are plenty for a single local browser and keep the memory
    // footprint low on a Pi 3 (the default is one worker per core).
    .workers(2)
    .bind(&bind)
    .map_err(|e| match e.kind() {
        io::ErrorKind::AddrInUse => io::Error::new(
            e.kind(),
            format!("{bind} is already in use: stop the other instance or set BIND_PORT"),
        ),
        _ => e,
    })?
    .run()
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssid_is_hex_encoded_so_quotes_and_backslashes_survive() {
        let conf = wpa_supplicant_config("My \"Net\"\\", "secret12", "MX");
        assert!(conf.contains(&format!("ssid={}", hex_encode(b"My \"Net\"\\"))));
        assert!(!conf.contains("ssid=\""));
        assert!(conf.contains("scan_ssid=1"));
        assert!(conf.contains("country=MX"));
    }

    #[test]
    fn passphrase_is_written_verbatim() {
        // wpa_supplicant reads up to the LAST quote: no escaping must happen.
        let conf = wpa_supplicant_config("net", "p@ss\"w\\rd", "US");
        assert!(conf.contains("psk=\"p@ss\"w\\rd\""), "{conf}");
        assert!(!conf.contains("key_mgmt=NONE"));
    }

    #[test]
    fn hex_psk_is_written_unquoted() {
        let hex = "A".repeat(64);
        let conf = wpa_supplicant_config("net", &hex, "US");
        assert!(conf.contains(&format!("psk={}", "a".repeat(64))));
    }

    #[test]
    fn open_networks_use_key_mgmt_none() {
        let conf = wpa_supplicant_config("FreeWifi", "", "US");
        assert!(conf.contains("key_mgmt=NONE"));
        assert!(!conf.contains("psk="));
    }

    #[test]
    fn credentials_are_validated() {
        assert!(validate_credentials("", "secret12").is_err());
        assert!(validate_credentials(&"x".repeat(33), "").is_err());
        assert!(validate_credentials("net", "short").is_err());
        assert!(validate_credentials("net", &"x".repeat(64)).is_err());
        assert!(validate_credentials("net", "line\nbreak1").is_err());
        assert!(validate_credentials("net", "").is_ok());
        assert!(validate_credentials("net", "secret12").is_ok());
        assert!(validate_credentials("net", &"ab".repeat(32)).is_ok());
    }

    #[test]
    fn foreign_origins_are_rejected() {
        let host = Some("localhost:8080");
        assert_eq!(classify_origin(None, host), OriginKind::Absent);
        assert_eq!(
            classify_origin(Some("http://localhost:8080"), host),
            OriginKind::SameOrigin
        );
        assert_eq!(
            classify_origin(Some("https://www.berel.com"), host),
            OriginKind::Foreign
        );
        assert_eq!(classify_origin(Some("null"), host), OriginKind::Foreign);
    }

    #[test]
    fn only_local_hosts_pass_when_bound_to_loopback() {
        assert!(host_allowed(Some("localhost:8080"), true, "8080"));
        assert!(host_allowed(Some("127.0.0.1:8080"), true, "8080"));
        assert!(!host_allowed(Some("evil.example:8080"), true, "8080"));
        assert!(!host_allowed(Some("localhost:9999"), true, "8080"));
        assert!(host_allowed(Some("evil.example:8080"), false, "8080"));
    }

    #[test]
    fn url_authority_adds_default_ports() {
        assert_eq!(
            url_authority("https://berel.com/"),
            Some("berel.com:443".into())
        );
        assert_eq!(
            url_authority("http://a.b:8080/x?y#z"),
            Some("a.b:8080".into())
        );
        assert_eq!(url_authority("https://a.com?x=1"), Some("a.com:443".into()));
        assert_eq!(url_authority("ftp://a.com"), None);
    }

    #[test]
    fn js_strings_are_escaped() {
        assert_eq!(js_string_inner("a\"b</script>"), "a\\\"b<\\/script>");
        assert_eq!(
            js_string_inner("https://a.com/?a=1&b=2"),
            "https://a.com/?a=1&b=2"
        );
    }

    #[test]
    fn iw_escapes_are_decoded() {
        assert_eq!(unescape_iw("Caf\\xc3\\xa9 Net"), "Café Net");
        assert_eq!(unescape_iw("plain"), "plain");
        assert_eq!(unescape_iw("trailing\\x"), "trailing\\x");
    }

    const IW_SAMPLE: &str = "BSS aa:bb:cc:dd:ee:01(on wlan0)\n\
\tfreq: 2437\n\
\tcapability: ESS Privacy ShortSlotTime (0x0411)\n\
\tsignal: -61.00 dBm\n\
\tSSID: Oficina\n\
\tRSN:\t * Version: 1\n\
BSS aa:bb:cc:dd:ee:02(on wlan0)\n\
\tcapability: ESS ShortSlotTime (0x0401)\n\
\tsignal: -40.00 dBm\n\
\tSSID: Invitados\n\
BSS aa:bb:cc:dd:ee:03(on wlan0)\n\
\tcapability: ESS Privacy (0x0011)\n\
\tsignal: -50.00 dBm\n\
\tSSID: Oficina\n\
BSS aa:bb:cc:dd:ee:04(on wlan0)\n\
\tsignal: -30.00 dBm\n\
\tSSID: \n";

    #[test]
    fn iw_scan_is_parsed_deduplicated_and_sorted() {
        let list = dedupe_networks(parse_iw_scan(IW_SAMPLE));
        assert_eq!(
            list,
            vec![
                Network {
                    ssid: "Invitados".into(),
                    signal_dbm: Some(-40),
                    secure: false
                },
                Network {
                    ssid: "Oficina".into(),
                    signal_dbm: Some(-50),
                    secure: true
                },
            ]
        );
    }

    #[test]
    fn iwlist_scan_is_parsed() {
        let out = "wlan0     Scan completed :\n\
          Cell 01 - Address: AA:BB:CC:DD:EE:01\n\
                    Quality=70/70  Signal level=-38 dBm\n\
                    Encryption key:on\n\
                    ESSID:\"Casa \"Norte\"\"\n\
          Cell 02 - Address: AA:BB:CC:DD:EE:02\n\
                    Quality=40/70  Signal level=-70 dBm\n\
                    Encryption key:off\n\
                    ESSID:\"Libre\"\n";
        let list = dedupe_networks(parse_iwlist_scan(out));
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].ssid, "Casa \"Norte\"");
        assert!(list[0].secure);
        assert_eq!(list[1].signal_dbm, Some(-70));
        assert!(!list[1].secure);
    }

    #[test]
    fn secure_write_uses_mode_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = env::temp_dir().join(format!("kioskos-test-{}", std::process::id()));
        let path = dir.join("wpa.conf");
        write_secure(&path, b"one").unwrap();
        write_secure(&path, b"two").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"two");
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let _ = fs::remove_dir_all(&dir);
    }
}
