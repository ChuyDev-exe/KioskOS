# Rotación de pantalla (kiosk_os/device)

Este archivo documenta cómo se aplica la rotación de pantalla en los overlays de dispositivo incluidos en este repositorio.

Qué se cambió
- Se añadió el parámetro de kernel `fbcon=rotate:3` en `cmdline.txt` de los overlays de `pi4` y `pi5` para rotar la consola framebuffer en el arranque.
- Se añadió `display_hdmi_rotate=3` en `kiosk_os/device/pi5/device/rootfs-overlay/boot/firmware/config.txt` para que la salida HDMI del firmware quede rotada, igual que en el overlay de `pi4` (que ya tenía `display_hdmi_rotate=3`).

Dónde cambiar la rotación
- Edite los archivos:
  - `kiosk_os/device/pi4/device/rootfs-overlay/boot/firmware/cmdline.txt`
  - `kiosk_os/device/pi5/device/rootfs-overlay/boot/firmware/cmdline.txt`
  - `kiosk_os/device/pi5/device/rootfs-overlay/boot/firmware/config.txt`

Valores válidos
- Para `display_hdmi_rotate` y `fbcon=rotate:N`, `N` puede ser:
  - `0` = 0° (sin rotación)
  - `1` = 90°
  - `2` = 180°
  - `3` = 270°

Recomendaciones
- Mantenga `display_hdmi_rotate` y `fbcon=rotate:N` con el mismo valor para que la consola y el framebuffer queden coherentes.
- Si su kiosk usa un compositor (por ejemplo, X11 o Wayland) o una aplicación que gestiona la pantalla, podría ser preferible rotar desde el compositor (p. ej. `xrandr` o la configuración de Westonia/Wayland), en lugar del firmware/kernel.

Plymouth (splash) y sesión gráfica
- Algunas versiones de `plymouth` y de la pila gráfica pueden no respetar la rotación aplicada por `fbcon` o `display_hdmi_rotate`. Si el splash de `plymouth` aparece sin rotar, verás que la consola (tty1) sí está rotada, pero al entrar al entorno gráfico la orientación puede volver a la normal.

Soluciones aplicadas en este repositorio
- He deshabilitado el splash en el overlay de `pi5` (se usará la configuración `disable_splash=1`) para evitar que un splash sin rotar aparezca. El overlay de `pi4` ya tenía `disable_splash=1`.
- Añadí un script de arranque de sesión X en `/etc/X11/Xsession.d/99-rotate` (tanto en `pi4` como `pi5`) que ejecuta `xrandr` durante el inicio de la sesión X para forzar la rotación. El script ahora intenta varias veces hasta que la salida X esté disponible y usa `left` para aplicar 270° (coherente con `display_hdmi_rotate=3`). Esto asegura que tras hacer login el entorno X rotará al valor esperado.

Si prefieres mantener el splash de `plymouth` en vez de desactivarlo, hay dos opciones:
1. Crear/ajustar un tema de `plymouth` con imágenes ya rotadas (más trabajo y depende del theme).  
2. Forzar plymouth a usar modo framebuffer o a aplicar transformaciones — esto es frágil y depende de la versión de plymouth y del driver de pantalla.

Pruebas recomendadas (actualizado)
1. Reconstruye la imagen con tu flujo normal:
```bash
./build.sh
```
2. Flashea y arranca en el dispositivo.
3. Verifica:
  - La consola del sistema (tty1) debe aparecer rotada (esto se logra con `fbcon=rotate:3`).
  - No debería aparecer el splash de plymouth sin rotar (pi5 ahora tiene `disable_splash=1`).
  - Al iniciar sesión X, el script en `/etc/X11/Xsession.d/99-rotate` ejecutará `xrandr` para rotar la pantalla a 270°.

Si tras esto todavía ves la pantalla sin rotación al entrar en el entorno gráfico, dime cómo se inicia la GUI (systemd service, startx, autologin->.xsession, `cage`, etc.) y ajustaré la solución (por ejemplo creando un servicio systemd que ejecute `xrandr` en el contexto del usuario o añadiendo el comando al autostart del navegador/compositor).

Prueba rápida
1. Reconstruya su imagen tal como lo hace normalmente (por ejemplo, ejecutar su script de build).  
2. Flashee la imagen en la tarjeta SD y arranque en el dispositivo.  
3. Verifique que la consola y el escritorio estén rotados: la salida de consola (tty1) debería estar orientada según el valor elegido.

Si prefiere que ponga un valor distinto por defecto (por ejemplo `1` para 90°), indíquelo y lo actualizo.
