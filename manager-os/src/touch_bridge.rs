//! Touch bridge: turns an "absolute mouse" into a real touchscreen.
//!
//! Many touch foils and IR touch frames enumerate as a USB HID *mouse* with
//! absolute coordinates (their factory "mouse mode"). libinput then handles
//! them as a pointer: no touch events, so dragging selects text instead of
//! scrolling, the touch calibration/rotation rule does not apply and
//! touch-only behaviour never triggers.
//!
//! The bridge grabs such a device (so the compositor stops seeing the mouse)
//! and re-emits its events through a uinput single-touch touchscreen:
//! `ABS_X/ABS_Y` are copied and `BTN_LEFT` becomes `BTN_TOUCH`. udev then
//! classifies the virtual device as a touchscreen like any other one.
//!
//! Started per device by udev (`kiosk-touch-bridge@eventN.service`), see
//! `kiosk-conf/99-kiosk-touch-bridge.rules`.
//!
//!   wifi_setup_service touch-bridge /dev/input/eventN
//!
//! `KIOSK_TOUCH_BRIDGE=force` bridges the device even when the same USB
//! device already exposes a touchscreen interface (auto mode skips it, to
//! never produce double touches).

use evdev::uinput::VirtualDevice;
use evdev::{
    AbsInfo, AbsoluteAxisCode, AttributeSet, BusType, EventType, InputEvent, InputId, KeyCode,
    PropType, RelativeAxisCode, SynchronizationCode, UinputAbsSetup,
};
use std::env;
use std::io;
use std::path::Path;

/// Prefix of the virtual devices: never bridge our own output.
pub const BRIDGE_NAME_PREFIX: &str = "KioskOS touch";

/// Capabilities of an input device, reduced to what the bridge needs.
#[derive(Debug, Default, Clone)]
pub struct Caps {
    pub name: String,
    pub btn_left: bool,
    pub btn_touch: bool,
    pub pen: bool,
    pub abs_x: bool,
    pub abs_y: bool,
    pub abs_mt: bool,
    pub rel_xy: bool,
    pub direct: bool,
}

impl Caps {
    fn of(dev: &evdev::raw_stream::RawDevice) -> Self {
        let keys = dev.supported_keys();
        let has_key = |k: KeyCode| keys.map(|s| s.contains(k)).unwrap_or(false);
        let abs = dev.supported_absolute_axes();
        let has_abs = |a: AbsoluteAxisCode| abs.map(|s| s.contains(a)).unwrap_or(false);
        let rel = dev.supported_relative_axes();
        let has_rel = |r: RelativeAxisCode| rel.map(|s| s.contains(r)).unwrap_or(false);

        Caps {
            name: dev.name().unwrap_or("").to_string(),
            btn_left: has_key(KeyCode::BTN_LEFT),
            btn_touch: has_key(KeyCode::BTN_TOUCH),
            pen: has_key(KeyCode::BTN_TOOL_PEN) || has_key(KeyCode::BTN_STYLUS),
            abs_x: has_abs(AbsoluteAxisCode::ABS_X),
            abs_y: has_abs(AbsoluteAxisCode::ABS_Y),
            abs_mt: has_abs(AbsoluteAxisCode::ABS_MT_POSITION_X),
            rel_xy: has_rel(RelativeAxisCode::REL_X) || has_rel(RelativeAxisCode::REL_Y),
            direct: dev.properties().contains(PropType::DIRECT),
        }
    }

    fn is_bridge(&self) -> bool {
        self.name.starts_with(BRIDGE_NAME_PREFIX)
    }

    /// An absolute pointer with a button and no relative axes: what touch
    /// foils and IR frames look like in "mouse mode". Regular mice are
    /// relative, so they are never matched.
    pub fn is_absolute_mouse(&self) -> bool {
        !self.is_bridge()
            && self.abs_x
            && self.abs_y
            && self.btn_left
            && !self.rel_xy
            && !self.btn_touch
            && !self.pen
    }

    /// Something libinput already handles as a touchscreen.
    pub fn is_touchscreen(&self) -> bool {
        // Touchpads also have BTN_TOUCH: they lack INPUT_PROP_DIRECT and
        // have physical buttons.
        !self.is_bridge()
            && self.btn_touch
            && (self.abs_mt || (self.abs_x && self.abs_y))
            && (self.direct || !self.btn_left)
    }
}

/// USB device part of an evdev physical path: `usb-3f980000.usb-1.3/input0`
/// → `usb-3f980000.usb-1.3`. Interfaces of the same USB device share it.
pub fn usb_device_of(phys: &str) -> Option<&str> {
    let (device, _interface) = phys.rsplit_once('/')?;
    if device.is_empty() {
        None
    } else {
        Some(device)
    }
}

/// Translates the event stream of the absolute mouse into touchscreen
/// events, one frame (up to `SYN_REPORT`) at a time.
#[derive(Default)]
pub struct Translator {
    pending: Vec<(EventType, u16, i32)>,
    touching: bool,
}

impl Translator {
    /// Feeds one source event. Returns a complete output frame when the
    /// source frame ends (the uinput emit adds the `SYN_REPORT` itself).
    pub fn feed(
        &mut self,
        kind: EventType,
        code: u16,
        value: i32,
    ) -> Option<Vec<(EventType, u16, i32)>> {
        match kind {
            EventType::ABSOLUTE
                if code == AbsoluteAxisCode::ABS_X.0 || code == AbsoluteAxisCode::ABS_Y.0 =>
            {
                self.pending.push((kind, code, value));
            }
            EventType::KEY if code == KeyCode::BTN_LEFT.0 => {
                // 2 = autorepeat: not a state change.
                if value == 0 || value == 1 {
                    let down = value == 1;
                    if down != self.touching {
                        self.touching = down;
                        self.pending
                            .push((EventType::KEY, KeyCode::BTN_TOUCH.0, value));
                    }
                }
            }
            EventType::SYNCHRONIZATION if code == SynchronizationCode::SYN_REPORT.0 => {
                if !self.pending.is_empty() {
                    return Some(std::mem::take(&mut self.pending));
                }
            }
            EventType::SYNCHRONIZATION if code == SynchronizationCode::SYN_DROPPED.0 => {
                // Events were lost: drop the partial frame and lift the
                // finger, so a touch can never get stuck "down".
                self.pending.clear();
                if self.touching {
                    self.touching = false;
                    return Some(vec![(EventType::KEY, KeyCode::BTN_TOUCH.0, 0)]);
                }
            }
            // Other buttons (right/middle click), wheels, MSC_SCAN...: a
            // touchscreen has no equivalent.
            _ => {}
        }
        None
    }

    /// Frame that lifts the finger, used when the source goes away.
    pub fn release(&mut self) -> Option<Vec<(EventType, u16, i32)>> {
        if self.touching {
            self.touching = false;
            Some(vec![(EventType::KEY, KeyCode::BTN_TOUCH.0, 0)])
        } else {
            None
        }
    }
}

fn sibling_touchscreen(own_path: &Path, own_usb: &str) -> Option<String> {
    evdev::raw_stream::enumerate()
        .filter(|(path, _)| path != own_path)
        .find_map(|(_, dev)| {
            let same_usb = dev.physical_path().and_then(usb_device_of) == Some(own_usb);
            let caps = Caps::of(&dev);
            (same_usb && caps.is_touchscreen()).then_some(caps.name)
        })
}

fn copy_axis(
    dev: &evdev::raw_stream::RawDevice,
    code: AbsoluteAxisCode,
) -> io::Result<UinputAbsSetup> {
    let info = dev
        .get_absinfo()?
        .find(|(c, _)| *c == code)
        .map(|(_, i)| i)
        .ok_or_else(|| io::Error::other(format!("missing {code:?}")))?;
    Ok(UinputAbsSetup::new(
        code,
        AbsInfo::new(
            info.value(),
            info.minimum(),
            info.maximum(),
            info.fuzz(),
            info.flat(),
            info.resolution(),
        ),
    ))
}

fn emit(out: &mut VirtualDevice, frame: &[(EventType, u16, i32)]) -> io::Result<()> {
    let events: Vec<InputEvent> = frame
        .iter()
        .map(|&(kind, code, value)| InputEvent::new(kind.0, code, value))
        .collect();
    out.emit(&events)
}

/// Entry point of `touch-bridge <device>`. Exits 0 (without doing anything)
/// when the device is not an absolute mouse, so udev can start it for every
/// candidate and let this function decide.
pub fn run(device_path: &str) -> io::Result<()> {
    let mode = env::var("KIOSK_TOUCH_BRIDGE").unwrap_or_else(|_| "auto".to_string());
    if mode == "off" {
        println!("touch-bridge: disabled (KIOSK_TOUCH_BRIDGE=off)");
        return Ok(());
    }

    let path = Path::new(device_path);
    let mut source = evdev::raw_stream::RawDevice::open(path)?;
    let caps = Caps::of(&source);

    if !caps.is_absolute_mouse() {
        println!(
            "touch-bridge: {} ({device_path}) is not an absolute mouse, nothing to do",
            caps.name
        );
        return Ok(());
    }

    if mode != "force" {
        if let Some(usb) = source.physical_path().and_then(usb_device_of) {
            if let Some(name) = sibling_touchscreen(path, usb) {
                println!(
                    "touch-bridge: {} already exposes a touchscreen ({name}), skipping \
                     (set KIOSK_TOUCH_BRIDGE=force to bridge it anyway)",
                    caps.name
                );
                return Ok(());
            }
        }
    }

    let id = source.input_id();
    let mut keys = AttributeSet::<KeyCode>::new();
    keys.insert(KeyCode::BTN_TOUCH);
    let mut props = AttributeSet::<PropType>::new();
    props.insert(PropType::DIRECT);
    let name = format!("{BRIDGE_NAME_PREFIX} ({})", caps.name);

    let mut out = VirtualDevice::builder()?
        .name(&name)
        .input_id(InputId::new(
            BusType::BUS_VIRTUAL,
            id.vendor(),
            id.product(),
            id.version(),
        ))
        .with_keys(&keys)?
        .with_absolute_axis(&copy_axis(&source, AbsoluteAxisCode::ABS_X)?)?
        .with_absolute_axis(&copy_axis(&source, AbsoluteAxisCode::ABS_Y)?)?
        .with_properties(&props)?
        .build()?;

    // From here on the compositor only sees the virtual touchscreen.
    source.grab()?;
    println!(
        "touch-bridge: {} ({device_path}, {:04x}:{:04x}) → \"{name}\"",
        caps.name,
        id.vendor(),
        id.product()
    );

    let mut translator = Translator::default();
    loop {
        let events = match source.fetch_events() {
            Ok(events) => events,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => {
                // ENODEV: the device was unplugged. Lift a pressed finger
                // and stop; udev starts a new bridge on the next plug.
                if let Some(frame) = translator.release() {
                    let _ = emit(&mut out, &frame);
                }
                println!("touch-bridge: {device_path} is gone ({e}), stopping");
                return Ok(());
            }
        };
        let frames: Vec<_> = events
            .filter_map(|ev| translator.feed(ev.event_type(), ev.code(), ev.value()))
            .collect();
        for frame in frames {
            emit(&mut out, &frame)?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ABS: EventType = EventType::ABSOLUTE;
    const KEY: EventType = EventType::KEY;
    const SYN: EventType = EventType::SYNCHRONIZATION;

    fn ir_frame_caps() -> Caps {
        Caps {
            name: "USB Touch IR".into(),
            btn_left: true,
            abs_x: true,
            abs_y: true,
            ..Caps::default()
        }
    }

    #[test]
    fn absolute_mice_are_bridged_and_real_mice_are_not() {
        assert!(ir_frame_caps().is_absolute_mouse());

        let mut mouse = ir_frame_caps();
        mouse.abs_x = false;
        mouse.abs_y = false;
        mouse.rel_xy = true;
        assert!(!mouse.is_absolute_mouse(), "relative mouse");

        let mut touch = ir_frame_caps();
        touch.btn_touch = true;
        touch.direct = true;
        assert!(!touch.is_absolute_mouse(), "already a touchscreen");
        assert!(touch.is_touchscreen());

        let mut touchpad = touch.clone();
        touchpad.direct = false;
        assert!(!touchpad.is_touchscreen(), "touchpad");

        let mut pen = ir_frame_caps();
        pen.pen = true;
        assert!(!pen.is_absolute_mouse(), "graphics tablet");

        let mut ours = ir_frame_caps();
        ours.name = format!("{BRIDGE_NAME_PREFIX} (x)");
        assert!(!ours.is_absolute_mouse(), "our own virtual device");
    }

    #[test]
    fn usb_device_is_extracted_from_phys() {
        assert_eq!(
            usb_device_of("usb-3f980000.usb-1.3/input0"),
            Some("usb-3f980000.usb-1.3")
        );
        assert_eq!(usb_device_of("input0"), None);
        assert_eq!(usb_device_of("/input0"), None);
    }

    #[test]
    fn a_tap_becomes_a_touch() {
        let mut t = Translator::default();
        assert_eq!(t.feed(ABS, AbsoluteAxisCode::ABS_X.0, 100), None);
        assert_eq!(t.feed(ABS, AbsoluteAxisCode::ABS_Y.0, 200), None);
        assert_eq!(t.feed(KEY, KeyCode::BTN_LEFT.0, 1), None);
        assert_eq!(
            t.feed(SYN, SynchronizationCode::SYN_REPORT.0, 0),
            Some(vec![
                (ABS, AbsoluteAxisCode::ABS_X.0, 100),
                (ABS, AbsoluteAxisCode::ABS_Y.0, 200),
                (KEY, KeyCode::BTN_TOUCH.0, 1),
            ])
        );
        // Drag while touching: coordinates only.
        t.feed(ABS, AbsoluteAxisCode::ABS_Y.0, 260);
        assert_eq!(
            t.feed(SYN, SynchronizationCode::SYN_REPORT.0, 0),
            Some(vec![(ABS, AbsoluteAxisCode::ABS_Y.0, 260)])
        );
        t.feed(KEY, KeyCode::BTN_LEFT.0, 0);
        assert_eq!(
            t.feed(SYN, SynchronizationCode::SYN_REPORT.0, 0),
            Some(vec![(KEY, KeyCode::BTN_TOUCH.0, 0)])
        );
    }

    #[test]
    fn other_buttons_and_empty_frames_are_dropped() {
        let mut t = Translator::default();
        t.feed(KEY, KeyCode::BTN_RIGHT.0, 1);
        t.feed(EventType::MISC, 4, 0x90001);
        assert_eq!(t.feed(SYN, SynchronizationCode::SYN_REPORT.0, 0), None);
        // Autorepeat / duplicate presses do not toggle the touch.
        t.feed(KEY, KeyCode::BTN_LEFT.0, 1);
        t.feed(SYN, SynchronizationCode::SYN_REPORT.0, 0);
        t.feed(KEY, KeyCode::BTN_LEFT.0, 2);
        t.feed(KEY, KeyCode::BTN_LEFT.0, 1);
        assert_eq!(t.feed(SYN, SynchronizationCode::SYN_REPORT.0, 0), None);
    }

    #[test]
    fn dropped_events_and_unplug_lift_the_finger() {
        let mut t = Translator::default();
        t.feed(KEY, KeyCode::BTN_LEFT.0, 1);
        t.feed(SYN, SynchronizationCode::SYN_REPORT.0, 0);
        t.feed(ABS, AbsoluteAxisCode::ABS_X.0, 5);
        assert_eq!(
            t.feed(SYN, SynchronizationCode::SYN_DROPPED.0, 0),
            Some(vec![(KEY, KeyCode::BTN_TOUCH.0, 0)])
        );
        assert_eq!(t.release(), None);

        t.feed(KEY, KeyCode::BTN_LEFT.0, 1);
        t.feed(SYN, SynchronizationCode::SYN_REPORT.0, 0);
        assert_eq!(t.release(), Some(vec![(KEY, KeyCode::BTN_TOUCH.0, 0)]));
    }
}
