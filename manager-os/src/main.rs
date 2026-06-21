use actix_files as fs_serve;
use actix_web::{web, App, HttpRequest, HttpResponse, HttpServer, Responder};
use serde::Deserialize;
use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::io::Write;
use std::os::unix::net::UnixDatagram;
use std::process::Command;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Deserialize)]
struct WifiForm {
    ssid: String,
    password: String,
}

fn escape_wpa(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace(['\n', '\r'], "")
}

fn load_template(path: &str, url: &str) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|c| c.replace("{{KIOSK_HOMEPAGE_URL}}", url))
}

fn kiosk_url() -> String {
    env::var("KIOSK_HOMEPAGE_URL")
        .unwrap_or_else(|_| "https://self-order-kiosk-front.vercel.app/".to_string())
}

fn api_token() -> Option<String> {
    let t = env::var("API_TOKEN").unwrap_or_default();
    if t.is_empty() {
        None
    } else {
        Some(t)
    }
}

fn check_auth(req: &HttpRequest) -> bool {
    let Some(expected) = api_token() else {
        return true;
    };
    let header = req
        .headers()
        .get("X-API-Token")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    header == expected
}

async fn index() -> impl Responder {
    let has_wifi = web::block(check_wifi_connection).await;
    let static_path = env::var("STATIC_PATH").unwrap_or_else(|_| "/static".to_string());

    match has_wifi {
        Ok(true) => {
            let tpl_path = format!("{}/redirect.html", static_path);
            match load_template(&tpl_path, &kiosk_url()) {
                Some(html) => HttpResponse::Ok()
                    .content_type("text/html; charset=utf-8")
                    .body(html),
                None => HttpResponse::Ok()
                    .content_type("text/html; charset=utf-8")
                    .body(format!(
                        r#"<!DOCTYPE html><html><body><script>window.location.href='{}';</script></body></html>"#,
                        kiosk_url()
                    )),
            }
        }
        _ => {
            let index_path = format!("{}/index.html", static_path);
            match fs::read_to_string(&index_path) {
                Ok(content) => HttpResponse::Ok()
                    .content_type("text/html; charset=utf-8")
                    .body(content),
                Err(e) => {
                    eprintln!("Error reading index.html from {}: {}", index_path, e);
                    HttpResponse::InternalServerError().body(format!("Error loading page: {}", e))
                }
            }
        }
    }
}

async fn start_kiosk(req: HttpRequest) -> impl Responder {
    if !check_auth(&req) {
        return HttpResponse::Unauthorized().body("Unauthorized");
    }

    let result = web::block(|| {
        Command::new("systemctl")
            .args(["restart", "kiosk.service"])
            .output()
            .map_err(|e| format!("Failed to restart kiosk service: {}", e))
            .and_then(|o| {
                if o.status.success() {
                    Ok(())
                } else {
                    Err(format!(
                        "Kiosk service restart failed: {}",
                        String::from_utf8_lossy(&o.stderr)
                    ))
                }
            })
    })
    .await;

    match result {
        Ok(Ok(())) => {
            let tpl_path = format!(
                "{}/start_kiosk.html",
                env::var("STATIC_PATH").unwrap_or_else(|_| "/static".to_string())
            );
            match load_template(&tpl_path, &kiosk_url()) {
                Some(html) => HttpResponse::Ok()
                    .content_type("text/html; charset=utf-8")
                    .body(html),
                None => HttpResponse::Ok()
                    .content_type("text/html; charset=utf-8")
                    .body(format!(
                        r#"<!DOCTYPE html><html><body><script>window.location.href='{}';</script></body></html>"#,
                        kiosk_url()
                    )),
            }
        }
        Ok(Err(e)) => HttpResponse::InternalServerError()
            .json(serde_json::json!({"success": false, "error": e})),
        Err(e) => HttpResponse::InternalServerError()
            .json(serde_json::json!({"success": false, "error": format!("Blocking error: {}", e)})),
    }
}

struct WifiCache {
    connected: bool,
    cached_at: Instant,
}

static WIFI_CACHE: Mutex<Option<WifiCache>> = Mutex::new(None);
static WIFI_ERROR: Mutex<Option<String>> = Mutex::new(None);

fn check_wifi_connection() -> bool {
    let now = Instant::now();

    if let Ok(cache) = WIFI_CACHE.lock() {
        if let Some(ref entry) = *cache {
            if now.duration_since(entry.cached_at).as_secs() < 10 {
                return entry.connected;
            }
        }
    }

    let connected = check_wifi_connection_inner();

    if let Ok(mut cache) = WIFI_CACHE.lock() {
        *cache = Some(WifiCache {
            connected,
            cached_at: now,
        });
    }

    connected
}

fn check_wifi_connection_inner() -> bool {
    let interface = "wlan0";

    if !is_interface_connected(interface) {
        return false;
    }

    let output = Command::new("ip")
        .args(["addr", "show", interface])
        .output();

    let has_ip = match output {
        Ok(output) => String::from_utf8_lossy(&output.stdout)
            .lines()
            .any(|line| line.trim().starts_with("inet ") && !line.contains("127.0.0.1")),
        Err(_) => false,
    };

    if !has_ip {
        return false;
    }

    Command::new("ping")
        .args(["-c", "1", "-W", "2", "8.8.8.8"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

async fn check_wifi() -> impl Responder {
    let has_wifi = web::block(check_wifi_connection).await;
    let error_msg = WIFI_ERROR.lock().ok().and_then(|e| e.clone());

    HttpResponse::Ok().json(serde_json::json!({
        "connected": has_wifi.unwrap_or(false),
        "error": error_msg,
    }))
}

fn scan_wifi_networks() -> Vec<String> {
    let mut ssids: BTreeSet<String> = BTreeSet::new();

    if let Ok(output) = Command::new("iw").args(["dev", "wlan0", "scan"]).output() {
        if output.status.success() {
            for line in String::from_utf8_lossy(&output.stdout).lines() {
                if let Some(ssid) = line.trim_start().strip_prefix("SSID: ") {
                    let ssid = ssid.trim();
                    if !ssid.is_empty() {
                        ssids.insert(ssid.to_string());
                    }
                }
            }
        }
    }

    if ssids.is_empty() {
        if let Ok(output) = Command::new("iwlist").args(["wlan0", "scan"]).output() {
            if output.status.success() {
                for line in String::from_utf8_lossy(&output.stdout).lines() {
                    let trimmed = line.trim();
                    if let Some(pos) = trimmed.find("ESSID:\"") {
                        if let Some(end) = trimmed[(pos + 7)..].find('"') {
                            let ssid = trimmed[(pos + 7)..(pos + 7 + end)].trim();
                            if !ssid.is_empty() {
                                ssids.insert(ssid.to_string());
                            }
                        }
                    }
                }
            }
        }
    }

    ssids.into_iter().collect()
}

async fn scan_wifi() -> impl Responder {
    match web::block(scan_wifi_networks).await {
        Ok(networks) => HttpResponse::Ok().json(serde_json::json!({
            "success": true,
            "networks": networks,
        })),
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({
            "success": false,
            "error": format!("Failed to scan WiFi networks: {}", e),
        })),
    }
}

async fn set_wifi(form: web::Form<WifiForm>, req: HttpRequest) -> impl Responder {
    if !check_auth(&req) {
        return HttpResponse::Unauthorized().body("Unauthorized");
    }

    let ssid = form.ssid.clone();
    let password = form.password.clone();

    println!("Received WiFi config request - SSID: {}", ssid);

    thread::spawn(move || {
        let escaped_ssid = escape_wpa(&ssid);
        let escaped_psk = escape_wpa(&password);
        let interface = "wlan0";

        let result = match Command::new("nmcli")
            .args([
                "dev",
                "wifi",
                "connect",
                &escaped_ssid,
                "password",
                &escaped_psk,
            ])
            .output()
        {
            Ok(o) if o.status.success() => {
                println!("nmcli connected successfully");
                Ok(())
            }
            Ok(o) => {
                let msg = String::from_utf8_lossy(&o.stderr).trim().to_string();
                eprintln!("nmcli failed ({}), falling back to wpa_supplicant", msg);
                configure_wpa_supplicant(&escaped_ssid, &escaped_psk, interface)
            }
            Err(e) => {
                eprintln!(
                    "nmcli not available ({}), falling back to wpa_supplicant",
                    e
                );
                configure_wpa_supplicant(&escaped_ssid, &escaped_psk, interface)
            }
        };

        if let Ok(mut err) = WIFI_ERROR.lock() {
            *err = result.as_ref().err().map(|e| e.to_string());
        }
        if result.is_ok() {
            println!("WiFi configured successfully for SSID: {}", ssid);
        }
    });

    HttpResponse::Accepted().json(serde_json::json!({
        "success": true,
        "message": "WiFi configuration in progress",
    }))
}

fn configure_wpa_supplicant(ssid: &str, psk: &str, interface: &str) -> Result<(), String> {
    let config = format!(
        r#"ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={{
    ssid="{}"
    psk="{}"
    key_mgmt=WPA-PSK
}}
"#,
        ssid, psk
    );

    println!("Creating wpa_supplicant config...");

    let _ = Command::new("mkdir")
        .args(["-p", "/etc/wpa_supplicant"])
        .output();

    let file_path = "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf";
    {
        let mut file =
            fs::File::create(file_path).map_err(|e| format!("Failed to write config: {}", e))?;
        file.write_all(config.as_bytes())
            .map_err(|e| format!("Failed to write config: {}", e))?;
    }

    let _ = Command::new("chmod").args(["600", file_path]).output();
    let _ = Command::new("sync").output();

    let _ = Command::new("systemctl")
        .args(["stop", "wpa_supplicant@wlan0"])
        .output();
    thread::sleep(Duration::from_secs(1));

    let out = Command::new("systemctl")
        .args(["enable", "wpa_supplicant@wlan0"])
        .output()
        .map_err(|e| format!("Failed to enable service: {}", e))?;
    if !out.status.success() {
        eprintln!(
            "Warning: enable wpa_supplicant@wlan0: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    let out = Command::new("systemctl")
        .args(["start", "wpa_supplicant@wlan0"])
        .output()
        .map_err(|e| format!("Failed to start service: {}", e))?;
    if !out.status.success() {
        return Err(format!(
            "wpa_supplicant start failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }

    thread::sleep(Duration::from_secs(3));

    let _ = Command::new("/usr/sbin/dhclient").arg(interface).output();

    if !wait_for_network_with_interface(30, interface) {
        return Err("Network not available after 30 seconds".to_string());
    }

    let _ = Command::new("sync").output();
    trigger_timesyncd().map_err(|e| e.to_string())?;

    Ok(())
}

fn is_interface_connected(interface: &str) -> bool {
    fs::read_to_string(format!("/sys/class/net/{}/operstate", interface))
        .ok()
        .map(|s| s.trim() == "up")
        .unwrap_or(false)
}

fn trigger_timesyncd() -> std::io::Result<()> {
    let out = Command::new("systemctl")
        .args(["restart", "systemd-timesyncd"])
        .output()?;
    if !out.status.success() {
        return Err(std::io::Error::other("systemd-timesyncd restart failed"));
    }
    Ok(())
}

fn wait_for_network_with_interface(timeout_secs: u64, interface: &str) -> bool {
    let start = Instant::now();
    loop {
        if is_interface_connected(interface) {
            if let Ok(output) = Command::new("ip")
                .args(["addr", "show", interface])
                .output()
            {
                if String::from_utf8_lossy(&output.stdout).contains("inet ") {
                    return true;
                }
            }
        }
        if start.elapsed().as_secs() > timeout_secs {
            return false;
        }
        thread::sleep(Duration::from_secs(1));
    }
}

async fn health() -> impl Responder {
    let uptime = fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split('.').next().map(|s| s.to_string()))
        .unwrap_or_default();

    let wlan_connected = is_interface_connected("wlan0");

    let kiosk_active = Command::new("systemctl")
        .args(["is-active", "kiosk.service"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "active")
        .unwrap_or(false);

    HttpResponse::Ok().json(serde_json::json!({
        "uptime_secs": uptime,
        "wlan_connected": wlan_connected,
        "kiosk_service_active": kiosk_active,
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let static_path = env::var("STATIC_PATH").unwrap_or_else(|_| "/static".to_string());
    let bind_addr = env::var("BIND_ADDRESS").unwrap_or_else(|_| "127.0.0.1".to_string());
    let bind_port = env::var("BIND_PORT").unwrap_or_else(|_| "8080".to_string());
    let bind = format!("{}:{}", bind_addr, bind_port);

    if let Ok(socket_path) = env::var("NOTIFY_SOCKET") {
        if !socket_path.is_empty() {
            let sock_path = socket_path.clone();
            thread::spawn(move || {
                if let Ok(ref s) = UnixDatagram::unbound() {
                    loop {
                        let _ = s.send_to(b"WATCHDOG=1", &sock_path);
                        thread::sleep(Duration::from_secs(10));
                    }
                }
            });
        }
    }

    println!("Starting WiFi setup service on {}", bind);
    println!("Serving static files from: {}", static_path);
    if api_token().is_some() {
        println!("API authentication enabled (X-API-Token)");
    }

    HttpServer::new(move || {
        App::new()
            .route("/", web::get().to(index))
            .route("/set_wifi", web::post().to(set_wifi))
            .route("/start_kiosk", web::get().to(start_kiosk))
            .route("/check_wifi", web::get().to(check_wifi))
            .route("/scan_wifi", web::get().to(scan_wifi))
            .route("/health", web::get().to(health))
            .service(fs_serve::Files::new("/static", static_path.clone()))
    })
    .bind(&bind)?
    .run()
    .await
}
