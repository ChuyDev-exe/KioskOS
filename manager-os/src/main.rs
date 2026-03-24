use actix_web::{web, App, HttpResponse, HttpServer, Responder};
use actix_files as fs_serve;
use serde::Deserialize;
use std::env;
use std::fs;
use std::fs::File;
use std::io::Write;
use std::process::Command;
use std::collections::BTreeSet;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Deserialize)]
struct WifiForm {
    ssid: String,
    password: String,
}

async fn index() -> impl Responder {
    // Verificar si hay conexión WiFi
    let has_wifi = web::block(|| check_wifi_connection()).await;

    match has_wifi {
        Ok(true) => {
            // Si hay WiFi, servir HTML que fuerza fullscreen y redirige
            let redirect_url = env::var("KIOSK_HOMEPAGE_URL")
                .unwrap_or_else(|_| "https://self-order-kiosk-front.vercel.app/".to_string());
            
            let html = format!(r#"<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Redirecting...</title>
    <style>
        body {{
            margin: 0;
            background: #000;
            color: #fff;
            font-family: sans-serif;
            display: flex;
            align-items: center;
            justify-content: center;
            height: 100vh;
        }}
    </style>
</head>
<body>
    <div>Loading kiosk...</div>
    <script>
        // Request fullscreen
        document.documentElement.requestFullscreen().catch(e => console.log(e));
        // Redirect to kiosk URL
        setTimeout(() => {{
            window.location.href = "{}";
        }}, 500);
    </script>
</body>
</html>"#, redirect_url);
            
            HttpResponse::Ok()
                .content_type("text/html; charset=utf-8")
                .body(html)
        }
        _ => {
            // Si no hay WiFi, mostrar la interfaz de configuración
            let static_path = env::var("STATIC_PATH")
                .unwrap_or_else(|_| "/static".to_string());
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

async fn start_kiosk() -> impl Responder {
    // Reiniciar el servicio kiosk para que Firefox se lance en modo --kiosk
    let result = web::block(|| {
        let restart_output = Command::new("systemctl")
            .args(&["restart", "kiosk.service"])
            .output()
            .map_err(|e| {
                std::io::Error::new(
                    std::io::ErrorKind::Other,
                    format!("Failed to restart kiosk service: {}", e),
                )
            })?;

        if !restart_output.status.success() {
            let error = String::from_utf8_lossy(&restart_output.stderr);
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("Kiosk service restart failed: {}", error),
            ));
        }

        Ok(())
    })
    .await;

    match result {
        Ok(Ok(())) => {
            let redirect_url = env::var("KIOSK_HOMEPAGE_URL")
                .unwrap_or_else(|_| "https://self-order-kiosk-front.vercel.app/".to_string());
            
            let html = format!(r#"<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Starting Kiosk...</title>
    <style>
        body {{
            margin: 0;
            background: #000;
            color: #fff;
            font-family: sans-serif;
            display: flex;
            align-items: center;
            justify-content: center;
            height: 100vh;
        }}
    </style>
</head>
<body>
    <div>Starting kiosk mode...</div>
    <script>
        setTimeout(() => {{
            window.location.href = "{}";
        }}, 2000);
    </script>
</body>
</html>"#, redirect_url);
            
            HttpResponse::Ok()
                .content_type("text/html; charset=utf-8")
                .body(html)
        }
        Ok(Err(e)) => HttpResponse::InternalServerError().json(serde_json::json!({"success": false, "error": format!("{}", e)})),
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"success": false, "error": format!("Blocking error: {}", e)})),
    }
}

fn check_wifi_connection() -> bool {
    let interface = "wlan0";
    
    // First check if interface is up
    if !is_interface_connected(interface) {
        return false;
    }
    
    // Check if it has an IP address
    let output = Command::new("ip")
        .args(&["addr", "show", interface])
        .output();
    
    let has_ip = match output {
        Ok(output) => {
            let output_str = String::from_utf8_lossy(&output.stdout);
            output_str.lines().any(|line| {
                line.trim().starts_with("inet ") && !line.contains("127.0.0.1")
            })
        }
        Err(_) => false,
    };
    
    if !has_ip {
        return false;
    }
    
    // Verify actual internet connectivity with a quick ping
    let ping_output = Command::new("ping")
        .args(&["-c", "1", "-W", "5", "8.8.8.8"])
        .output();
    
    match ping_output {
        Ok(output) => {
            let success = output.status.success();
            if !success {
                eprintln!("Ping failed - no internet connectivity");
            }
            success
        }
        Err(e) => {
            eprintln!("Ping command failed: {}", e);
            false
        }
    }
}

async fn check_wifi() -> impl Responder {
    let has_wifi = web::block(|| check_wifi_connection()).await;
    
    match has_wifi {
        Ok(true) => HttpResponse::Ok().json(serde_json::json!({"connected": true})),
        _ => HttpResponse::Ok().json(serde_json::json!({"connected": false})),
    }
}

fn scan_wifi_networks() -> Vec<String> {
    let mut ssids: BTreeSet<String> = BTreeSet::new();

    // Preferred: `iw` (provided by package `iw`)
    if let Ok(output) = Command::new("iw")
        .args(&["dev", "wlan0", "scan"])
        .output()
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            for line in stdout.lines() {
                let trimmed = line.trim_start();
                if let Some(ssid) = trimmed.strip_prefix("SSID: ") {
                    let ssid = ssid.trim();
                    if !ssid.is_empty() {
                        ssids.insert(ssid.to_string());
                    }
                }
            }
        }
    }

    // Fallback: `iwlist` (provided by package `wireless-tools`)
    if ssids.is_empty() {
        if let Ok(output) = Command::new("iwlist")
            .args(&["wlan0", "scan"])
            .output()
        {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                for line in stdout.lines() {
                    let trimmed = line.trim();
                    if let Some(pos) = trimmed.find("ESSID:\"") {
                        let value = &trimmed[(pos + 7)..];
                        if let Some(end) = value.find('"') {
                            let ssid = value[..end].trim();
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
    let result = web::block(scan_wifi_networks).await;

    match result {
        Ok(networks) => HttpResponse::Ok().json(serde_json::json!({
            "success": true,
            "networks": networks
        })),
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({
            "success": false,
            "error": format!("Failed to scan WiFi networks: {}", e)
        })),
    }
}

async fn set_wifi(form: web::Form<WifiForm>) -> impl Responder {
    let ssid = form.ssid.clone();
    let password = form.password.clone();
    let interface = "wlan0";

    println!("Received WiFi config request - SSID: {}", ssid);

    let result = web::block(move || {
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
            ssid, password
        );

        println!("Creating wpa_supplicant config...");

        // Create directory if it doesn't exist
        let _ = Command::new("mkdir")
            .args(&["-p", "/etc/wpa_supplicant"])
            .output();

        // Write to persistent location
        let file_path = "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf";
        File::create(file_path)
            .and_then(|mut file| file.write_all(config.as_bytes()))
            .map_err(|e| {
                eprintln!("Failed to write config file: {}", e);
                std::io::Error::new(
                    std::io::ErrorKind::Other,
                    format!("Failed to write config: {}", e),
                )
            })?;

        println!("Config file written successfully");

        // Set proper permissions
        let _ = Command::new("chmod")
            .args(&["600", file_path])
            .output();

        // Sync to ensure file is written
        let _ = Command::new("sync").output();

        // Stop systemd service if running
        let _ = Command::new("systemctl")
            .args(&["stop", "wpa_supplicant@wlan0"])
            .output();

        thread::sleep(Duration::from_secs(1));

        // Enable and start the service
        let enable_output = Command::new("systemctl")
            .args(&["enable", "wpa_supplicant@wlan0"])
            .output()
            .map_err(|e| {
                std::io::Error::new(
                    std::io::ErrorKind::Other,
                    format!("Failed to enable service: {}", e),
                )
            })?;

        if !enable_output.status.success() {
            let error = String::from_utf8_lossy(&enable_output.stderr);
            eprintln!("Warning: Failed to enable wpa_supplicant@wlan0: {}", error);
        }

        let start_output = Command::new("systemctl")
            .args(&["start", "wpa_supplicant@wlan0"])
            .output()
            .map_err(|e| {
                std::io::Error::new(
                    std::io::ErrorKind::Other,
                    format!("Failed to start service: {}", e),
                )
            })?;

        if !start_output.status.success() {
            let error = String::from_utf8_lossy(&start_output.stderr);
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("wpa_supplicant service start failed: {}", error),
            ));
        }

        thread::sleep(Duration::from_secs(3));

        // Request IP with dhclient
        let dhclient_output = Command::new("/usr/sbin/dhclient")
            .arg(interface)
            .output()
            .map_err(|e| {
                std::io::Error::new(
                    std::io::ErrorKind::Other,
                    format!("dhclient execution failed: {}", e),
                )
            })?;

        if !dhclient_output.status.success() {
            let error = String::from_utf8_lossy(&dhclient_output.stderr);
            eprintln!("Warning: dhclient failed: {}", error);
        }

        // Wait for network
        if !wait_for_network_with_interface(30, interface) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Network not available after 30 seconds",
            ));
        }

        // Final sync
        let _ = Command::new("sync").output();

        trigger_timesyncd()?;

        Ok(())
    })
    .await;

    // Handle the result and return an HTTP response
    match result {
        Ok(Ok(())) => HttpResponse::Ok().json(serde_json::json!({"success": true, "message": "WiFi configured successfully"})),
        Ok(Err(e)) => HttpResponse::Ok().json(serde_json::json!({"success": false, "error": format!("{}", e)})),
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"success": false, "error": format!("Blocking error: {}", e)})),
    }
}

fn is_interface_connected(interface: &str) -> bool {
    if let Ok(state) = fs::read_to_string(format!("/sys/class/net/{}/operstate", interface)) {
        return state.trim() == "up";
    }
    false
}

fn trigger_timesyncd() -> std::io::Result<()> {
    let output = Command::new("systemctl")
        .arg("restart")
        .arg("systemd-timesyncd")
        .output()?;
    if !output.status.success() {
        eprintln!("Failed to restart systemd-timesyncd: {:?}", output);
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "systemd-timesyncd restart failed",
        ));
    }
    Ok(())
}

fn wait_for_network_with_interface(timeout_secs: u64, interface: &str) -> bool {
    let start = Instant::now();
    loop {
        if is_interface_connected(interface) {
            // Check for IP address assignment
            let output = Command::new("ip")
                .args(&["addr", "show", interface])
                .output();
            if let Ok(output) = output {
                let output_str = String::from_utf8_lossy(&output.stdout);
                if output_str.contains("inet ") {
                    return true; // Interface has an IP address
                }
            }
        }
        if start.elapsed().as_secs() > timeout_secs {
            return false;
        }
        thread::sleep(Duration::from_secs(1));
    }
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let static_path = env::var("STATIC_PATH")
        .unwrap_or_else(|_| "/static".to_string());
    
    println!("Starting WiFi setup service on 0.0.0.0:8080");
    println!("Serving static files from: {}", static_path);
    
    HttpServer::new(move || {
        let static_path_clone = static_path.clone();
        App::new()
            .route("/", web::get().to(index))
            .route("/set_wifi", web::post().to(set_wifi))
            .route("/start_kiosk", web::get().to(start_kiosk))
            .route("/check_wifi", web::get().to(check_wifi))
            .route("/scan_wifi", web::get().to(scan_wifi))
            .service(fs_serve::Files::new("/static", static_path_clone).show_files_listing())
    })
    .bind("0.0.0.0:8080")?
    .run()
    .await
}