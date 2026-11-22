import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AppKit

/// Turns pad pen/gesture/button messages into real macOS tablet events.
/// Pen events are posted as *tablet* events (proximity + tablet-point subtype with pressure and tilt),
/// which is what Photoshop reads for pressure-sensitive brushes.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var targetDisplay: CGDirectDisplayID = CGMainDisplayID()
    private var inProximity = false
    private var currentEraser = false
    private var buttonDown: CGMouseButton?
    private var lastPoint = CGPoint.zero
    /// Which end of the pen was last near the screen, and whether *we* switched the app to its eraser.
    private var lastEndWasEraser = false
    private var switchedToEraser = false

    /// The "virtual tablet" identity, built the way Wacom's own MovinkPad "Instant Pen Display" does it on the
    /// Mac: a vendor that is *not* Wacom (with Wacom's ID, Photoshop goes looking for a real Wacom driver and
    /// tablet behind it and then ignores pressure / misplaces points), one device ID shared by proximity and
    /// every pen event, and fixed serial/unique IDs for the pen.
    private enum Tablet {
        static let deviceID: Int64 = 0x1A6F
        static let vendorID: Int64 = 0x1A70
        static let tabletID: Int64 = 0x1A71
        static let serial: Int64 = 0x50AD_4D5E
        static let uniqueID: Int64 = 0x50_AD1D_0862_98
        static let capsNative: Int64 = 0x37C7   // id, x, y, buttons, tilt, z, pressure, orientation, rotation
        static let capsWeb: Int64 = 0x17C7
    }

    func setDisplay(_ id: CGDirectDisplayID) { targetDisplay = id }

    // MARK: Pen

    func handle(_ e: PenEvent) {
        let b = CGDisplayBounds(targetDisplay)
        let x = CGFloat(min(max(e.x, 0), 1)), y = CGFloat(min(max(e.y, 0), 1))
        let p = CGPoint(x: b.minX + x * (b.width - 1), y: b.minY + y * (b.height - 1))
        lastPoint = p

        if e.action == .hoverExit {
            if let btn = buttonDown { post(btn == .left ? .leftMouseUp : .rightMouseUp, btn, p, e, pressure: 0) }
            buttonDown = nil
            proximity(false, eraser: currentEraser)
            return
        }
        if !inProximity || e.eraser != currentEraser {
            if inProximity { proximity(false, eraser: currentEraser) }
            proximity(true, eraser: e.eraser)
            penFlipped(toEraser: e.eraser)
        }

        switch e.action {
        case .hoverEnter, .hoverMove:
            if let btn = buttonDown { // lost an "up" somewhere — release
                post(btn == .left ? .leftMouseUp : .rightMouseUp, btn, p, e, pressure: 0)
                buttonDown = nil
            }
            post(.mouseMoved, .left, p, e, pressure: 0)
        case .down:
            let btn: CGMouseButton = e.sideButton ? .right : .left
            buttonDown = btn
            post(btn == .left ? .leftMouseDown : .rightMouseDown, btn, p, e, pressure: max(e.pressure, 0.01))
        case .move:
            guard let btn = buttonDown else {
                // The "down" got lost on the way (Wi‑Fi) — start the stroke here instead of dropping it.
                let b: CGMouseButton = e.sideButton ? .right : .left
                buttonDown = b
                post(b == .left ? .leftMouseDown : .rightMouseDown, b, p, e, pressure: max(e.pressure, 0.01))
                return
            }
            post(btn == .left ? .leftMouseDragged : .rightMouseDragged, btn, p, e, pressure: max(e.pressure, 0.01))
        case .up:
            let btn = buttonDown ?? .left
            buttonDown = nil
            post(btn == .left ? .leftMouseUp : .rightMouseUp, btn, p, e, pressure: 0)
        case .hoverExit: break
        }
    }

    func releaseAll() {
        if let btn = buttonDown {
            if let ev = CGEvent(mouseEventSource: source, mouseType: btn == .left ? .leftMouseUp : .rightMouseUp,
                                mouseCursorPosition: lastPoint, mouseButton: btn) { ev.post(tap: .cghidEventTap) }
        }
        buttonDown = nil
        if inProximity { proximity(false, eraser: currentEraser) }
        keyUp(kVK_Space)
    }

    /// Pen turned around. Photoshop switches to its eraser by itself when the tablet reports the eraser end;
    /// Photopea (browser) doesn't, so there we press E — and B again when the tip comes back, but only if it
    /// was us who switched (so a tool chosen on purpose stays).
    private func penFlipped(toEraser: Bool) {
        guard toEraser != lastEndWasEraser else { return }
        lastEndWasEraser = toEraser
        guard FrontApp.shared.isBrowser else { return }
        if toEraser {
            shortcut("e", [])
            switchedToEraser = true
        } else if switchedToEraser {
            shortcut("b", [])
            switchedToEraser = false
        }
    }

    /// One pen sample as a mouse event carrying the tablet data (the "tablet point" subtype). Pen position
    /// goes into the tablet fields in screen points, like Wacom's virtual pen display does.
    private func post(_ type: CGEventType, _ btn: CGMouseButton, _ p: CGPoint, _ e: PenEvent, pressure: Float) {
        guard let ev = CGEvent(source: nil) else { return }
        ev.type = type
        ev.location = p
        ev.flags = CGEventSource.flagsState(.combinedSessionState)
        ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        ev.setIntegerValueField(.mouseEventNumber, value: 0)
        let isButtonEvent = type != .mouseMoved
        ev.setIntegerValueField(.mouseEventClickState, value: isButtonEvent ? 1 : 0)
        ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(btn.rawValue))
        ev.setDoubleValueField(.mouseEventPressure, value: Double(pressure))
        ev.setIntegerValueField(.tabletEventDeviceID, value: Tablet.deviceID)
        ev.setIntegerValueField(.tabletEventPointX, value: Int64(p.x.rounded()))
        ev.setIntegerValueField(.tabletEventPointY, value: Int64(p.y.rounded()))
        ev.setIntegerValueField(.tabletEventPointZ, value: 0)
        ev.setIntegerValueField(.tabletEventPointButtons, value: buttonDown == nil ? 0 : (btn == .right ? 2 : 1))
        ev.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
        ev.setDoubleValueField(.tabletEventTiltX, value: Double(e.tiltX))
        ev.setDoubleValueField(.tabletEventTiltY, value: Double(e.tiltY))
        ev.setDoubleValueField(.tabletEventRotation, value: 0)
        ev.setDoubleValueField(.tabletEventTangentialPressure, value: 0)
        ev.post(tap: .cghidEventTap)
    }

    /// The pen entering/leaving the tablet — this is what tells apps "this is a pen with pressure".
    /// Native apps (Photoshop …) get a proximity event of its own; browsers (Photopea) listen for the
    /// proximity *subtype* on a mouse event instead. Same split as Wacom's own software makes.
    private func proximity(_ enter: Bool, eraser: Bool) {
        let web = FrontApp.shared.isBrowser
        let ev: CGEvent?
        if web {
            ev = CGEvent(source: nil)
            ev?.type = .mouseMoved
            ev?.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletProximity.rawValue))
        } else {
            ev = CGEvent(source: nil)
            ev?.type = .tabletProximity
        }
        guard let ev else { return }
        ev.location = lastPoint
        ev.flags = CGEventSource.flagsState(.combinedSessionState)
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: Tablet.deviceID)
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: Tablet.vendorID)
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: Tablet.tabletID)
        ev.setIntegerValueField(.tabletProximityEventPointerID, value: 0)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 0)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: Tablet.serial)
        ev.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: Tablet.uniqueID)
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: web ? Tablet.capsWeb : Tablet.capsNative)
        ev.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1)
        ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        ev.post(tap: .cghidEventTap)
        inProximity = enter
        currentEraser = eraser
    }

    // MARK: Gestures

    func scroll(dx: Float, dy: Float, zoom: Bool) {
        // Natural direction: fingers move the canvas.
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        if zoom { ev.flags = .maskAlternate } // Option + scroll = zoom in Photoshop
        ev.location = lastPoint
        ev.post(tap: .cghidEventTap)
    }

    // MARK: Shortcut buttons

    func command(_ c: PadCommand) {
        // Photoshop and Photopea (in a browser) use slightly different keys — pick by the app in front.
        let web = FrontApp.shared.isBrowser
        if c == .brush || c == .eraser { switchedToEraser = false } // chosen on purpose — don't undo it on flip
        switch c {
        case .undo:     if web { shortcut("z", [.maskCommand, .maskAlternate]) } else { shortcut("z", [.maskCommand]) } // Photopea: Step Backward
        case .redo:     shortcut("z", [.maskCommand, .maskShift])
        case .brush:    shortcut("b", [])
        case .eraser:   shortcut("e", [])
        case .zoomIn:   if web { zoomStep(+1) } else if !shortcut("+", [.maskCommand]) { shortcut("=", [.maskCommand]) }
        case .zoomOut:  if web { zoomStep(-1) } else { shortcut("-", [.maskCommand]) }
        case .fit:      shortcut("0", [.maskCommand])
        case .smaller:  if web { typeChar("[") } else { shortcut("[", []) }
        case .bigger:   if web { typeChar("]") } else { shortcut("]", []) }
        case .handDown: keyDown(kVK_Space)
        case .handUp:   keyUp(kVK_Space)
        }
    }

    /// Option + mouse wheel at the pen position — zooms in Photopea (and Photoshop) without
    /// touching the browser's own Cmd +/- page zoom.
    private func zoomStep(_ dir: Int32) {
        for _ in 0..<2 {
            guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                                   wheel1: dir, wheel2: 0, wheel3: 0) else { return }
            ev.flags = .maskAlternate
            ev.location = lastPoint
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Sends a character with no modifiers, even if the keyboard needs Option for it (e.g. "[" on Swiss/German
    /// layouts). Browsers read the character, so Photopea sees a plain "[" instead of "Option+5".
    @discardableResult
    private func typeChar(_ char: Character) -> Bool {
        guard let (code, _, _) = KeyMap.shared.key(for: char) else { return false }
        let utf16 = Array(String(char).utf16)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            ev.flags = []
            ev.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            ev.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Types a shortcut by *character*, so it works on Swiss/German/US keyboards alike.
    @discardableResult
    private func shortcut(_ char: Character, _ flags: CGEventFlags) -> Bool {
        guard let (code, needsShift, needsOption) = KeyMap.shared.key(for: char) else { return false }
        var f = flags
        if needsShift { f.insert(.maskShift) }
        if needsOption { f.insert(.maskAlternate) }
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            ev.flags = f
            ev.post(tap: .cghidEventTap)
        }
        return true
    }

    private func keyDown(_ code: Int) {
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)?.post(tap: .cghidEventTap)
    }
    private func keyUp(_ code: Int) {
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)?.post(tap: .cghidEventTap)
    }
}

/// Character → (key code, shift?, option?) for the *current* keyboard layout.
/// The Text Input Sources API must run on the main thread (macOS 26 traps otherwise), so the table is
/// built there — at launch and whenever the user switches keyboard layout — and only *read* elsewhere.
final class KeyMap {
    static let shared = KeyMap()
    private let lock = NSLock()
    private var map: [Character: (CGKeyCode, Bool, Bool)] = [:]
    private var observer: NSObjectProtocol?

    /// Call once from the main thread (app launch).
    func prepare() {
        dispatchPrecondition(condition: .onQueue(.main))
        rebuild()
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    func key(for c: Character) -> (CGKeyCode, Bool, Bool)? {
        lock.lock(); let empty = map.isEmpty; lock.unlock()
        if empty {
            // Not prepared yet: build on main. Main never waits on the network queue, so this can't deadlock.
            if Thread.isMainThread { rebuild() } else { DispatchQueue.main.sync { rebuild() } }
        }
        lock.lock(); defer { lock.unlock() }
        return map[c]
    }

    private func rebuild() {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        let kbdType = UInt32(LMGetKbdType())
        var m: [Character: (CGKeyCode, Bool, Bool)] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            // Prefer plain, then shift, then option, then shift+option.
            let combos: [(UInt32, Bool, Bool)] = [(0, false, false), (UInt32(shiftKey >> 8), true, false),
                                                  (UInt32(optionKey >> 8), false, true),
                                                  (UInt32((shiftKey | optionKey) >> 8), true, true)]
            for (mods, sh, opt) in combos {
                for code in 0..<128 {
                    var dead: UInt32 = 0
                    var len = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods,
                                            kbdType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, 4, &len, &chars)
                    guard st == noErr, len == 1, let scalar = Unicode.Scalar(chars[0]) else { continue }
                    let ch = Character(String(scalar).lowercased())
                    if m[ch] == nil { m[ch] = (CGKeyCode(code), sh, opt) }
                }
            }
        }
        lock.lock(); map = m; lock.unlock()
    }
}

/// Which app is in front (kept up to date on the main thread, read from the network thread).
final class FrontApp {
    static let shared = FrontApp()
    private let lock = NSLock()
    private var bundleID = ""
    private var observer: NSObjectProtocol?

    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    /// Photopea runs in a browser (or as an installed web app, whose bundle IDs start like the browser's).
    var isBrowser: Bool {
        lock.lock(); defer { lock.unlock() }
        return Self.browsers.contains(bundleID) || bundleID.hasPrefix("com.google.Chrome.app.")
            || bundleID.lowercased().contains("photopea")
    }

    func prepare() {
        dispatchPrecondition(condition: .onQueue(.main))
        set(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.set(app?.bundleIdentifier)
        }
    }

    private func set(_ id: String?) {
        guard let id, id != Bundle.main.bundleIdentifier else { return } // ignore PadLink itself
        lock.lock(); bundleID = id; lock.unlock()
    }
}
