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

    private func post(_ type: CGEventType, _ btn: CGMouseButton, _ p: CGPoint, _ e: PenEvent, pressure: Float) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: btn) else { return }
        ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        ev.setDoubleValueField(.mouseEventPressure, value: Double(pressure))
        if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp {
            ev.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        let b = CGDisplayBounds(targetDisplay)
        ev.setIntegerValueField(.tabletEventPointX, value: Int64((p.x - b.minX) / max(b.width, 1) * 65535))
        ev.setIntegerValueField(.tabletEventPointY, value: Int64((p.y - b.minY) / max(b.height, 1) * 65535))
        ev.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
        ev.setDoubleValueField(.tabletEventTiltX, value: Double(e.tiltX))
        ev.setDoubleValueField(.tabletEventTiltY, value: Double(e.tiltY))
        ev.setIntegerValueField(.tabletEventDeviceID, value: 1)
        ev.setIntegerValueField(.tabletEventPointButtons, value: buttonDown == nil ? 0 : 1)
        ev.post(tap: .cghidEventTap)
    }

    private func proximity(_ enter: Bool, eraser: Bool) {
        guard let ev = CGEvent(source: source) else { return }
        ev.type = .tabletProximity
        ev.location = lastPoint
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: 0x056A)
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: eraser ? 0x080A : 0x0802)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        // device id | abs x | abs y | buttons | tilt x | tilt y | pressure
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x05C7)
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
