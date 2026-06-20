# KioskOS
Flujo recomendado para desarrollar rápido sin tener que generar imagen + flashear SD en cada cambio.

## Objetivo
Tener dos carriles:

1. **Carril rápido (diario)**: compilar/sincronizar cambios hacia una Raspberry Pi de desarrollo.
2. **Carril release (final)**: construir imagen completa cuando ya validaste funcionalmente.

### Plan actualizado (resumen)

1. Cambios diarios: `dev-sync-all` sobre Pi de desarrollo.
2. Cambios de kiosk/sesión: `dev-restart-kiosk` + validación de logs.
3. Cambios de kernel module: build/instalación/validación directa en Pi.
4. Release: `./build.sh` solo cuando el comportamiento ya esté validado.

---

## Requisitos
- macOS/Linux con Docker y Docker Compose
- acceso SSH a una Raspberry Pi de desarrollo
- en la Pi: `rsync`, `sudo`, `systemd`
- para kernel modules en la Pi: `raspberrypi-kernel-headers`, `build-essential`, `make`

---

## Estructura relevante
- Backend: [manager-os/src/main.rs](manager-os/src/main.rs)
- Frontend estático: [manager-os/static/index.html](manager-os/static/index.html)
- Build de imagen final: [build.sh](build.sh)
- Capa de imagen/kiosk: [kiosk_os/layer/adagi-kiosk.yaml](kiosk_os/layer/adagi-kiosk.yaml)
- Config principal del build: [kiosk_os/config/adagi_os.yaml](kiosk_os/config/adagi_os.yaml)
- Variables de configuración: [kiosk_os/adagi_os.options](kiosk_os/adagi_os.options)
- Scripts de desarrollo rápido: [scripts](scripts)

---

## 1) Configurar una Pi de desarrollo (una sola vez)
1. Arranca una imagen funcional en la Pi (base estable).
2. Habilita SSH.
3. Verifica servicios:

```bash
sudo systemctl status wifi_setup.service
sudo systemctl status kiosk.service
```

4. Instala utilidades requeridas:

```bash
sudo apt update
sudo apt install -y rsync
```

5. Si vas a validar kernel modules en caliente:

```bash
sudo apt install -y raspberrypi-kernel-headers build-essential make
```

---

## 2) Configurar entorno local de desarrollo rápido
1. Copia archivo de entorno:

```bash
cp scripts/dev.env.example scripts/dev.env
```

2. Edita `scripts/dev.env` con IP/usuario real de tu Pi.

Variables importantes:
- `PI_HOST`
- `PI_USER`
- `PI_PORT`

3. Valida tu entorno local y la conectividad con la Pi:

```bash
./scripts/dev-doctor.sh
```

---

## 2.1) Preparar imagen preconfigurada (WiFi + SSH)

Edita [kiosk_os/adagi_os.options](kiosk_os/adagi_os.options):

```ini
DEVICE_USER1=adagio
DEVICE_USER1PASS=adagio

kiosk_homepage_url=https://tu-homepage.com/
kiosk_rotation=0

kiosk_wifi_ssid=TU_SSID
kiosk_wifi_psk=TU_PASSWORD_WIFI

kiosk_ssh_enable=1
kiosk_ssh_authorized_key=ssh-ed25519 AAAA... tu_usuario@equipo
```

Notas:
- `kiosk_ssh_authorized_key` es opcional pero recomendado.
- Si no defines clave SSH, podrás usar usuario/password.
- Estos valores se sincronizan automáticamente a [kiosk_os/config/adagi_os.yaml](kiosk_os/config/adagi_os.yaml) cuando ejecutas [build.sh](build.sh).

---

## 3) Flujo rápido para cambios de app (sin reflashear)
### Opción A: build + deploy en un paso

```bash
./scripts/dev-sync-all.sh
```

Esto hace:
- compila `wifi_setup_service` a `aarch64`
- sube binario y carpeta static a la Pi
- instala en rutas reales del sistema (`/usr/local/bin/wifi_setup_service`, `/static`)
- reinicia `wifi_setup.service`

### Opción B: paso a paso

_(El flujo paso a paso fue eliminado para máxima simplicidad. Usa siempre `dev-sync-all.sh`)_

### Ver logs en vivo

```bash
./scripts/dev-logs.sh
```

### Reiniciar kiosk manualmente (si cambias lógica de sesión)

```bash
./scripts/dev-restart-kiosk.sh
```

---

## 4) Desarrollo local (sin Pi)
_(El flujo local fue eliminado para máxima simplicidad. Valida siempre en la Pi real)_

---

## 5) Validación rápida de kernel modules
_(El flujo de kernel modules fue eliminado del repo base. Si lo necesitas, agrega scripts específicos en tu fork)_

---

## 6) Flujo release (imagen final)
Cuando ya validaste en Pi de desarrollo:

```bash
./build.sh
```

Salida esperada:
- `deploy/adagi_os.img`
- `deploy/adagi_os.sbom` (si aplica)

Luego haces pruebas finales de release en SD flasheada.

### Proceso recomendado para tu caso (arranque y trabajo solo por SSH)

1. Configura [kiosk_os/adagi_os.options](kiosk_os/adagi_os.options) con tu `SSID/PSK` y `kiosk_ssh_enable=1`.
2. Construye imagen con `./build.sh`.
3. Flashea la SD e inicia la Raspberry Pi.
4. Espera 30–90 segundos para que suba red + SSH.
5. Conéctate por SSH:

```bash
ssh adagio@<IP_DE_LA_PI>
```

6. Desde ahí trabajas directamente en la Pi y validas servicios/módulos.

---

## 7) Configuración y rotación

La configuración del kiosko se controla en [kiosk_os/adagi_os.options](kiosk_os/adagi_os.options).

Durante build de imagen, [build.sh](build.sh) sincroniza automáticamente valores a [kiosk_os/config/adagi_os.yaml](kiosk_os/config/adagi_os.yaml), incluyendo:

- `kiosk_homepage_url` → `kiosk.homepage_url`
- `kiosk_rotation` → `kiosk.rotation`
- `kiosk_wifi_ssid` → `kiosk.wifi_ssid`
- `kiosk_wifi_psk` → `kiosk.wifi_psk`
- `kiosk_ssh_enable` → `kiosk.ssh_enable`
- `kiosk_ssh_authorized_key` → `kiosk.ssh_authorized_key`

Recomendación: tomar [kiosk_os/adagi_os.options](kiosk_os/adagi_os.options) como fuente de verdad.

---

## 7.1) Manual de prueba rápida (Servidor, UI, Kernel Modules)

### A) Servidor (`wifi_setup.service`)

1. Deploy rápido:

```bash
./scripts/dev-sync-all.sh
```

2. Verifica estado del servicio en la Pi:

```bash
ssh <usuario>@<ip_pi> 'sudo systemctl --no-pager --full status wifi_setup.service | head -n 30'
```

3. Pruebas API mínimas:

```bash
curl -s http://<ip_pi>:8080/check_wifi
curl -s http://<ip_pi>:8080/scan_wifi
```

O usando el smoke test:

_(El smoke test fue eliminado para máxima simplicidad. Usa curl o navegador para validar)_

### B) UI (wizard)

1. Abre `http://<ip_pi>:8080` en navegador.
2. Valida:
	- carga de pasos del wizard
	- botón `Load_network`
	- selección SSID + envío de contraseña
	- botón de estado conectado/no conectado

3. Si cambias UI/JS:

_(No es necesario, usa siempre `dev-sync-all.sh`)_

### C) Kernel Modules (sin generar imagen)

_(El flujo de kernel modules fue eliminado para máxima simplicidad)_

---

## 8) Troubleshooting rápido

- `Permission denied` por SSH: valida llave/usuario en `scripts/dev.env`.
- `wifi_setup.service` no inicia: usar `./scripts/dev-logs.sh`.
- `módulo no compila`: revisar headers con `ls /lib/modules/$(uname -r)/build` en la Pi.
- `módulo no carga`: revisar `dmesg` y dependencias del módulo.

---

## 9) Comandos de referencia

```bash
# Build rápido + deploy a Pi
./scripts/dev-sync-all.sh

# Logs en vivo
./scripts/dev-logs.sh

# Reiniciar kiosk
./scripts/dev-restart-kiosk.sh

# Build de imagen final
./build.sh
```