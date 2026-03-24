---
description: KioskOS — referencia rápida de tareas comunes (build, debug WiFi, agregar features, deploy)
---

# KioskOS — Skill de Proyecto

Eres un experto en el proyecto **KioskOS**: una imagen Linux personalizada para Raspberry Pi que arranca directamente en un kiosco de pantalla completa con Firefox ESR.

## Contexto del Proyecto

- **Backend**: Rust + actix-web 4 en `manager-os/src/main.rs`, puerto 8080
- **Frontend**: HTML/JS/CSS en `manager-os/static/` (servido desde `/static/` en el dispositivo)
- **Imagen RPi**: generada con `rpi-image-gen` + `bdebstrap` Debian Bookworm en `kiosk_os/`
- **Build**: `./build.sh` (cross-compila para `aarch64-unknown-linux-gnu` en Docker)
- **Target principal**: Raspberry Pi 3

### Reglas críticas
1. NO modificar la lógica en `kiosk-launch.sh.tpl` — toda la lógica va en Rust o `script.js`
2. Los archivos estáticos van en `/static` en el dispositivo (NO en `/usr/local/share/...`)
3. WiFi config persiste en `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`
4. Los endpoints siempre devuelven JSON, nunca redireccionan el form
5. `wpa_supplicant@wlan0.service` debe estar habilitado en `customize-kiosk`

---

## Cómo usar este skill

Invoca con `#kioskos` seguido de la tarea:

```
#kioskos build la imagen completa
#kioskos debug: el botón no cambia a verde
#kioskos agrega un endpoint para reiniciar el dispositivo
#kioskos el WiFi no persiste después de reiniciar
#kioskos muéstrame los logs del dispositivo
```

---

## Tareas Disponibles

### 1. BUILD — Compilar y generar imagen

Para compilar el binario Rust y generar la imagen completa:

```bash
cd /Users/chuy/Desktop/KioskOS
./build.sh
```

Para solo compilar el binario Rust (sin generar imagen):
```bash
cd /Users/chuy/Desktop/KioskOS
docker compose build manager-os
docker compose run --rm manager-os cargo build --release --target aarch64-unknown-linux-gnu
```

Para correr el servidor localmente (sin dispositivo):
```bash
cd /Users/chuy/Desktop/KioskOS/manager-os
STATIC_PATH=$(pwd)/static cargo run
# Abre http://localhost:8080
```

---

### 2. DEBUG WiFi — Diagnosticar problemas de conectividad

**Síntoma**: Botón no cambia a verde / Start Kiosk no aparece
- Causa probable: La red tarda 5-15 segundos en establecerse
- El retry progresivo en `script.js` hace 20 intentos cada 2s (40s total)
- Verificar en `manager-os/static/script.js` que el bloque `quickCheck` esté activo

**Síntoma**: WiFi no persiste al reiniciar
- Causa: `wpa_supplicant@wlan0.service` no está habilitado
- Verificar en `kiosk_os/image/mbr/simple_dual/bdebstrap/customize-kiosk`:
  ```sh
  $BDEBSTRAP_HOOKS/enable-units "$1" wpa_supplicant@wlan0
  ```
- El archivo de config debe estar en `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`

**Síntoma**: Conectado a WiFi pero sin internet (botón rojo)
- El servidor hace ping a `8.8.8.8` con timeout de 5s
- Verificar routing: `ip route show` y `ip addr show wlan0`

**Logs en el dispositivo**:
```bash
journalctl -u wifi_setup.service -f
journalctl -u wpa_supplicant@wlan0.service -f
journalctl -u kiosk.service -f
```

---

### 3. AGREGAR ENDPOINT — Nuevo endpoint Rust

Al agregar un endpoint en `manager-os/src/main.rs`:

1. Definir la función `async fn`:
```rust
async fn mi_endpoint() -> impl Responder {
    // lógica
    HttpResponse::Ok().json(serde_json::json!({"success": true}))
}
```

2. Registrar en `main()`:
```rust
.route("/mi_ruta", web::get().to(mi_endpoint))
```

3. Si necesita comandos del sistema, usar `web::block()`:
```rust
let result = web::block(|| {
    Command::new("systemctl").args(&["restart", "mi.service"]).output()
}).await;
```

---

### 4. MODIFICAR FRONTEND — Cambios en el wizard

Estructura del wizard en `manager-os/static/index.html`:
- Sección 1 (`.Sec-form`): Pantalla de bienvenida
- Sección 2 (`.Sec-form`): Formulario WiFi (form `#wifi-form`)
- Sección 3 (`.Sec-form`): Configuración de contenido

IDs importantes:
- `#connect-btn`: Botón Connect (rojo=sin WiFi, verde=conectado)
- `#start-kiosk-btn`: Aparece solo cuando `check_wifi → connected: true`
- `#status-message`: Mensajes de estado del proceso
- `#pwd`: Campo contraseña
- `#network-select`: Select con redes WiFi disponibles
- `#Load_network`: Botón para escanear redes

---

### 5. ROTACIÓN DE PANTALLA

La rotación se configura en `kiosk_os/adagi_os.options`:
```ini
kiosk_rotation=90   # valores: normal, 90, 180, 270
```

En el dispositivo, `kiosk-launch.sh` aplica `wlr-randr --transform` al compositor Wayland (cage).

---

### 6. CAMBIAR URL DEL KIOSCO

En `kiosk_os/adagi_os.options`:
```ini
kiosk_homepage_url=https://tu-url.com/
```

Esta variable se inyecta en `wifi_setup.service.tpl` como variable de entorno `KIOSK_HOMEPAGE_URL` y el servidor Rust la lee con `env::var("KIOSK_HOMEPAGE_URL")`.

---

### 7. FLASHEAR IMAGEN

```bash
# macOS
diskutil list                          # identificar /dev/diskN
diskutil unmountDisk /dev/diskN
sudo dd if=deploy/adagi_os.img of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

---

### 8. VERIFICAR ERRORES DE COMPILACIÓN

```bash
cd /Users/chuy/Desktop/KioskOS/manager-os
cargo check
# o para el target real:
cargo build --target aarch64-unknown-linux-gnu
```

---

## Archivos Clave — Referencia Rápida

| Archivo | Propósito |
|---------|-----------|
| `manager-os/src/main.rs` | Servidor HTTP Rust |
| `manager-os/static/index.html` | UI del wizard |
| `manager-os/static/script.js` | Lógica AJAX + polling WiFi |
| `manager-os/static/style.css` | Estilos + animaciones |
| `kiosk_os/adagi_os.options` | Variables de configuración del kiosco |
| `kiosk_os/image/mbr/simple_dual/bdebstrap/customize-kiosk` | Hook principal de imagen |
| `kiosk_os/image/mbr/simple_dual/kiosk-conf/kiosk-launch.sh.tpl` | Lanzador de Firefox |
| `kiosk_os/image/mbr/simple_dual/kiosk-conf/wifi_setup.service.tpl` | Servicio systemd del servidor |
| `kiosk_os/image/mbr/simple_dual/device/rootfs-overlay/etc/systemd/system/wpa_supplicant@wlan0.service` | Servicio wpa_supplicant |
| `build.sh` | Pipeline de build completo |
