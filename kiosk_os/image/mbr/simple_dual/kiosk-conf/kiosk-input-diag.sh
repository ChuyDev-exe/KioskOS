#!/bin/bash
#
# kiosk-input-diag — how every input device is detected (touch vs mouse).
#
#   sudo kiosk-input-diag
#
# Send the output when a touch foil / IR frame does not behave as touch.
set -u

echo "== USB devices"
if command -v lsusb >/dev/null 2>&1; then
    lsusb
else
    echo "(lsusb not installed)"
fi
echo

echo "== Input devices"
for node in /sys/class/input/event*; do
    [ -e "$node" ] || continue
    ev=$(basename "$node")
    dev="$node/device"
    name=$(cat "$dev/name" 2>/dev/null)
    phys=$(cat "$dev/phys" 2>/dev/null)
    vid=$(cat "$dev/id/vendor" 2>/dev/null)
    pid=$(cat "$dev/id/product" 2>/dev/null)
    props=$(udevadm info -q property -n "/dev/input/$ev" 2>/dev/null |
        grep -E '^ID_INPUT_(MOUSE|TOUCHSCREEN|TABLET|TOUCHPAD|KEYBOARD|JOYSTICK)=1' |
        sed 's/^ID_INPUT_//; s/=1$//' | tr '\n' ' ')
    driver=""
    hid=$(readlink -f "$dev/device" 2>/dev/null)
    if [ -n "$hid" ] && [ -e "$hid/driver" ]; then
        driver=$(basename "$(readlink -f "$hid/driver")")
    fi
    echo "$ev: \"$name\""
    echo "    usb id: ${vid}:${pid}   phys: ${phys:-?}   hid driver: ${driver:-?}"
    echo "    detected as: ${props:-(nothing)}"
    echo "    caps: abs=$(cat "$dev/capabilities/abs" 2>/dev/null) rel=$(cat "$dev/capabilities/rel" 2>/dev/null) key=$(cat "$dev/capabilities/key" 2>/dev/null | awk '{print $NF}' ) props=$(cat "$dev/properties" 2>/dev/null)"
    unit="kiosk-touch-bridge@${ev}.service"
    if systemctl is-active --quiet "$unit"; then
        echo "    touch bridge: ACTIVE ($unit)"
    elif systemctl list-units --all --no-legend "$unit" 2>/dev/null | grep -q .; then
        echo "    touch bridge: not used ($(journalctl -u "$unit" -n 1 -o cat 2>/dev/null))"
    fi
done
echo

echo "== Kernel command line (usbhid quirks)"
tr ' ' '\n' </proc/cmdline | grep -i 'usbhid' || echo "(no usbhid.quirks)"
echo
cat <<'TXT'
Hints:
  * "detected as: MOUSE" with abs=3... and rel=0 is a touch device in mouse
    mode: the touch bridge turns it into a touchscreen automatically.
  * Several event nodes with the same phys prefix (usb-...-1.3/input0,
    input1, ...) are interfaces of one device. If none is a TOUCHSCREEN,
    try the HID_QUIRK_MULTI_INPUT quirk in the build options:
        kiosk_usbhid_quirks=0xVVVV:0xPPPP:0x40
  * Many IR frames / foil controllers can be switched from "mouse mode" to
    "HID multitouch" with the vendor configuration tool: that is the best
    fix when it is available.
  * Live events: sudo evtest /dev/input/eventN
TXT
