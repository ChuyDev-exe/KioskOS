## Plan actualizado: desarrollo rápido + release controlado

Objetivo: desarrollar y validar en Raspberry Pi sin reconstruir/flashear imagen en cada cambio, y generar imagen solo al cierre de iteración.

## Estado actual

Implementado:
1. Flujo rápido con scripts de desarrollo para build + sync a Pi.
2. Flujo de logs/reinicio de servicios para validación inmediata.
3. Flujo rápido para kernel modules sobre hardware real (sin nueva imagen).
4. Sincronización automática de configuración desde `kiosk_os/adagi_os.options` a `kiosk_os/config/adagi_os.yaml` durante `./build.sh`.
5. Soporte de imagen preconfigurada con WiFi y SSH en primer arranque.
6. Script de verificación de entorno (`dev-doctor.sh`).
7. Script de smoke tests HTTP (`dev-smoke-http.sh`).
8. Script de ejecución local (`dev-run-local.sh`).

Pendiente recomendado:
1. Automatizar smoke tests HTTP para `/set_wifi` en un modo seguro/mock.
2. Agregar checklist QA formal PASS/FAIL para release.
3. Opcional: rollback rápido del último binario bueno en la Pi.

## Plan por fases

### Fase 1 — Configuración base y fuentes de verdad
1. Definir `kiosk_os/adagi_os.options` como fuente principal de configuración.
2. Mantener sincronización automática hacia `kiosk_os/config/adagi_os.yaml` en `build.sh`.
3. Definir valores por defecto seguros para WiFi/SSH.

### Fase 2 — Ciclo de desarrollo rápido (sin reflashear)
1. Compilar servicio con `scripts/dev-build-service.sh`.
2. Sincronizar binario + estáticos a la Pi con `scripts/dev-sync-app.sh`.
3. Ejecutar flujo completo con `scripts/dev-sync-all.sh`.
4. Observar logs con `scripts/dev-logs.sh` y reiniciar kiosk con `scripts/dev-restart-kiosk.sh` cuando aplique.

### Fase 3 — Validación de kernel modules en hardware
1. Build e instalación directa en Pi con `scripts/dev-kmod-build-on-pi.sh`.
2. Validación funcional con `scripts/dev-kmod-validate.sh`.
3. Mantener evidencia de `modinfo`, `lsmod` y `dmesg` por iteración.

### Fase 4 — Release
1. Configurar opciones finales en `kiosk_os/adagi_os.options` (homepage, rotation, WiFi, SSH).
2. Generar imagen con `./build.sh`.
3. Flashear SD y ejecutar pruebas de aceptación final.

## Criterios de aprobación

1. Tiempo de iteración para cambios app < 5 minutos (build+sync+validación).
2. Kernel module validado en hardware sin regenerar imagen.
3. Imagen final arranca con WiFi y SSH según configuración.
4. Manual operativo actualizado y usable por otro desarrollador.

## Checklist operativo mínimo

1. `scripts/dev.env` configurado (host/user/port).
2. `scripts/dev-sync-all.sh` exitoso.
3. `scripts/dev-logs.sh` mostrando servicios sin errores críticos.
4. `scripts/dev-kmod-build-on-pi.sh` y `scripts/dev-kmod-validate.sh` exitosos (si aplica).
5. `./build.sh` genera `deploy/adagi_os.img` para release.
