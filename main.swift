import Cocoa
import ApplicationServices

// MARK: - Settings model

enum Effect: Int, CaseIterable {
    case off, single, series, fade
    var title: String {
        switch self {
        case .off: return "Нет"
        case .single: return "Одиночный клик"
        case .series: return "Серия быстрых"
        case .fade: return "Длинная затухающая"
        }
    }
}

final class Profile {
    let key: String
    var effect: Effect { didSet { save() } }
    var level: Int { didSet { save() } }      // 1...4
    var count: Int { didSet { save() } }      // pulses in a series
    var gapMs: Int { didSet { save() } }      // pause between pulses of a series
    var fadeMs: Int { didSet { save() } }     // length of the fading effect
    var light: Bool { didSet { save() } }     // keyboard backlight effect

    init(key: String, effect: Effect, level: Int, count: Int, gapMs: Int, fadeMs: Int, light: Bool) {
        let d = UserDefaults.standard
        self.key = key
        self.effect = Effect(rawValue: d.object(forKey: key + ".effect") as? Int ?? effect.rawValue) ?? effect
        self.level = d.object(forKey: key + ".level") as? Int ?? level
        self.count = d.object(forKey: key + ".count") as? Int ?? count
        self.gapMs = d.object(forKey: key + ".gapMs") as? Int ?? gapMs
        self.fadeMs = d.object(forKey: key + ".fadeMs") as? Int ?? fadeMs
        self.light = d.object(forKey: key + ".light") as? Bool ?? light
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(effect.rawValue, forKey: key + ".effect")
        d.set(level, forKey: key + ".level")
        d.set(count, forKey: key + ".count")
        d.set(gapMs, forKey: key + ".gapMs")
        d.set(fadeMs, forKey: key + ".fadeMs")
        d.set(light, forKey: key + ".light")
    }
}

let enterP = Profile(key: "enter", effect: .fade,   level: 4, count: 3, gapMs: 55, fadeMs: 800, light: true)
let spaceP = Profile(key: "space", effect: .series, level: 3, count: 3, gapMs: 55, fadeMs: 500, light: true)
let otherP = Profile(key: "other", effect: .single, level: 1, count: 1, gapMs: 55, fadeMs: 300, light: false)

var lightFadeMs: Int = UserDefaults.standard.object(forKey: "lightFadeMs") as? Int ?? 700 {
    didSet { UserDefaults.standard.set(lightFadeMs, forKey: "lightFadeMs") }
}
var appEnabled: Bool = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
    didSet { UserDefaults.standard.set(appEnabled, forKey: "enabled") }
}

// MARK: - Trackpad haptics (private MultitouchSupport + public fallback)

final class Haptics {
    private typealias ListFn    = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias GetIDFn   = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateFn  = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenFn    = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuateFn = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32

    private var actuator: UnsafeMutableRawPointer?
    private var actuateFn: ActuateFn?
    private let queue = DispatchQueue(label: "keyhaptics.haptics")
    private var gen = 0
    private static let ids: [Int32] = [3, 4, 5, 6]   // light ... strong
    var hasPrivateActuator: Bool { actuator != nil }

    init() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let h = dlopen(path, RTLD_NOW),
              let l = dlsym(h, "MTDeviceCreateList"),
              let g = dlsym(h, "MTDeviceGetDeviceID"),
              let c = dlsym(h, "MTActuatorCreateFromDeviceID"),
              let o = dlsym(h, "MTActuatorOpen"),
              let a = dlsym(h, "MTActuatorActuate") else { return }

        let list   = unsafeBitCast(l, to: ListFn.self)
        let getID  = unsafeBitCast(g, to: GetIDFn.self)
        let create = unsafeBitCast(c, to: CreateFn.self)
        let open   = unsafeBitCast(o, to: OpenFn.self)

        guard let rawArr = list() else { return }
        let arr = Unmanaged<CFArray>.fromOpaque(rawArr).takeRetainedValue()

        for i in 0..<CFArrayGetCount(arr) {
            guard let dev = CFArrayGetValueAtIndex(arr, i) else { continue }
            var id: UInt64 = 0
            guard getID(dev, &id) == 0, let act = create(id) else { continue }
            if open(act) == 0 {
                actuator = act
                actuateFn = unsafeBitCast(a, to: ActuateFn.self)
                break
            }
        }
    }

    func id(_ level: Int) -> Int32 { Haptics.ids[min(max(level, 1), 4) - 1] }

    func fireNow(_ id: Int32) {
        if let act = actuator, let fn = actuateFn {
            _ = fn(act, id, 0, 0, 0)
        } else {
            DispatchQueue.main.async {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }

    /// List of (delay in seconds, strength) for the chosen effect
    private func steps(_ p: Profile) -> [(Double, Int32)] {
        var out: [(Double, Int32)] = []
        switch p.effect {
        case .off:
            break
        case .single:
            out.append((0, id(p.level)))
        case .series:
            for i in 0..<max(p.count, 1) {
                out.append((Double(i * p.gapMs) / 1000.0, id(p.level)))
            }
        case .fade:
            let total = Double(max(p.fadeMs, 100)) / 1000.0
            var t = 0.0
            while t < total {
                let prog = t / total
                let idx = Int((Double(p.level - 1) * (1.0 - prog)).rounded())
                out.append((t, Haptics.ids[max(0, min(3, idx))]))
                t += 0.018 + 0.07 * prog      // pulses get weaker and sparser
            }
        }
        return out
    }

    func play(_ p: Profile) {
        let s = steps(p)
        queue.async {
            self.gen += 1
            let g = self.gen
            for step in s {
                self.queue.asyncAfter(deadline: .now() + step.0) {
                    if g == self.gen { self.fireNow(step.1) }
                }
            }
        }
    }
}

// MARK: - Keyboard backlight (private CoreBrightness)

final class Backlight {
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float

    private var client: NSObject?
    private var setFn: SetFn?
    private var getFn: GetFn?
    private let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
    private let getSel = NSSelectorFromString("brightnessForKeyboard:")
    private var kbID: UInt64 = 1
    private let queue = DispatchQueue(label: "keyhaptics.backlight")
    private var gen = 0
    private var base: Float?
    var isAvailable: Bool { client != nil && setFn != nil && getFn != nil }

    init() {
        _ = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load()
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return }
        let c = cls.init()
        guard c.responds(to: setSel), c.responds(to: getSel) else { return }
        setFn = unsafeBitCast(class_getMethodImplementation(cls, setSel), to: SetFn.self)
        getFn = unsafeBitCast(class_getMethodImplementation(cls, getSel), to: GetFn.self)
        let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
        if c.responds(to: idsSel),
           let ids = c.perform(idsSel)?.takeUnretainedValue() as? [NSNumber],
           let first = ids.first {
            kbID = first.uint64Value
        }
        client = c
    }

    /// Turns the backlight off instantly and fades it back in over fadeMs milliseconds
    func flash(fadeMs: Int) {
        guard isAvailable, let client = client, let setFn = setFn, let getFn = getFn else { return }
        queue.async {
            self.gen += 1
            let g = self.gen
            if self.base == nil { self.base = getFn(client, self.getSel, self.kbID) }
            guard let base = self.base, base > 0.01 else { self.base = nil; return }
            _ = setFn(client, self.setSel, 0, self.kbID)
            let total = Double(max(fadeMs, 50)) / 1000.0
            let steps = max(Int(total / 0.016), 3)
            for i in 1...steps {
                self.queue.asyncAfter(deadline: .now() + Double(i) * 0.016) {
                    guard g == self.gen else { return }
                    let p = Float(i) / Float(steps)
                    _ = setFn(client, self.setSel, base * p, self.kbID)
                    if i == steps { self.base = nil }
                }
            }
        }
    }

    /// On quit, restore the original brightness if we are in the middle of a fade
    func restore() {
        guard isAvailable, let client = client, let setFn = setFn else { return }
        queue.sync {
            self.gen += 1
            if let b = self.base {
                _ = setFn(client, self.setSel, b, self.kbID)
                self.base = nil
            }
        }
    }
}

// MARK: - Globals and key event tap

let haptics = Haptics()
let backlight = Backlight()
var tapRef: CFMachPort?

func trigger(_ p: Profile) {
    if p.effect != .off { haptics.play(p) }
    if p.light { backlight.flash(fadeMs: lightFadeMs) }
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let t = tapRef { CGEvent.tapEnable(tap: t, enable: true) }
    case .keyDown:
        guard appEnabled, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { break }
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 36, 76: trigger(enterP)           // Return and keypad Enter
        case 49: trigger(spaceP)               // Space
        default:
            if otherP.effect == .single { haptics.fireNow(haptics.id(otherP.level)) }
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Settings window

final class ClosureTarget: NSObject {
    let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func run() { fn() }
}

final class SettingsWindow {
    let window: NSWindow
    private var targets: [ClosureTarget] = []

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "KeyHaptics — Настройки"
        window.isReleasedWhenClosed = false
        build()
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    private func bind<T: NSControl>(_ c: T, _ fn: @escaping () -> Void) -> T {
        let t = ClosureTarget(fn)
        targets.append(t)
        c.target = t
        c.action = #selector(ClosureTarget.run)
        return c
    }

    private func labelRow(_ title: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: title)
        l.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let s = NSStackView(views: [l, control])
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 8
        return s
    }

    private func slider(_ lo: Int, _ hi: Int, _ value: Int, unit: String, ticks: Bool = false,
                        _ set: @escaping (Int) -> Void) -> NSView {
        let s = NSSlider(value: Double(value), minValue: Double(lo), maxValue: Double(hi), target: nil, action: nil)
        if ticks {
            s.numberOfTickMarks = hi - lo + 1
            s.allowsTickMarkValuesOnly = true
        }
        s.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let v = NSTextField(labelWithString: "\(value)\(unit)")
        v.widthAnchor.constraint(equalToConstant: 70).isActive = true
        bind(s) {
            let x = Int(s.doubleValue.rounded())
            v.stringValue = "\(x)\(unit)"
            set(x)
        }
        let row = NSStackView(views: [s, v])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 424).isActive = true
        return b
    }

    private func vstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 8
        return s
    }

    private func section(_ title: String, _ p: Profile) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = NSFont.boldSystemFont(ofSize: 14)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Effect.allCases.map { $0.title })
        popup.selectItem(at: p.effect.rawValue)
        bind(popup) { p.effect = Effect(rawValue: popup.indexOfSelectedItem) ?? .off }

        let cb = NSButton(checkboxWithTitle: "Подсветка: гаснет и плавно загорается", target: nil, action: nil)
        cb.state = p.light ? .on : .off
        bind(cb) { p.light = (cb.state == .on) }

        let test = NSButton(title: "Проверить", target: nil, action: nil)
        bind(test) { trigger(p) }

        return vstack([
            header,
            labelRow("Эффект", popup),
            labelRow("Сила", slider(1, 4, p.level, unit: " / 4", ticks: true) { p.level = $0 }),
            labelRow("Серия: число вибраций", slider(1, 8, p.count, unit: "", ticks: true) { p.count = $0 }),
            labelRow("Серия: пауза", slider(20, 200, p.gapMs, unit: " мс") { p.gapMs = $0 }),
            labelRow("Затухающая: длительность", slider(200, 2000, p.fadeMs, unit: " мс") { p.fadeMs = $0 }),
            cb,
            test
        ])
    }

    private func build() {
        let header = NSTextField(labelWithString: "Остальные клавиши")
        header.font = NSFont.boldSystemFont(ofSize: 14)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Нет", "Одиночный клик"])
        popup.selectItem(at: otherP.effect == .single ? 1 : 0)
        bind(popup) { otherP.effect = popup.indexOfSelectedItem == 1 ? .single : .off }

        let other = vstack([
            header,
            labelRow("Эффект", popup),
            labelRow("Сила", slider(1, 4, otherP.level, unit: " / 4", ticks: true) { otherP.level = $0 })
        ])

        let gh = NSTextField(labelWithString: "Подсветка")
        gh.font = NSFont.boldSystemFont(ofSize: 14)
        let glob = vstack([
            gh,
            labelRow("Время плавного возврата", slider(100, 2000, lightFadeMs, unit: " мс") { lightFadeMs = $0 })
        ])

        let root = vstack([
            section("Enter", enterP), separator(),
            section("Пробел", spaceP), separator(),
            other, separator(),
            glob
        ])
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)

        window.contentView = root
        window.setContentSize(root.fittingSize)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var retryTimer: Timer?
    private var settings: SettingsWindow?
    private var enabledItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.title = "⌨︎"

        let menu = NSMenu()
        enabledItem = NSMenuItem(title: "Вибрация включена", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = appEnabled ? .on : .off
        menu.addItem(enabledItem)

        let s = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        menu.addItem(s)

        menu.addItem(.separator())
        let info = [
            haptics.hasPrivateActuator ? "Вибрация: прямой доступ к трекпаду"
                                       : "Вибрация: fallback (только при касании трекпада)",
            backlight.isAvailable ? "Подсветка: доступна" : "Подсветка: недоступна"
        ]
        for t in info {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        startTap()
        if tapRef == nil {
            CGRequestListenEventAccess()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                self?.startTap()
                if tapRef != nil { t.invalidate() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backlight.restore()
    }

    @objc private func toggleEnabled() {
        appEnabled.toggle()
        enabledItem.state = appEnabled ? .on : .off
    }

    @objc private func openSettings() {
        if settings == nil { settings = SettingsWindow() }
        settings?.show()
    }

    private func startTap() {
        guard tapRef == nil, CGPreflightListenEventAccess() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: tapCallback,
                                          userInfo: nil) else { return }
        tapRef = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
