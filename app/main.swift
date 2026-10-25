// XDRLift — keeps an XDR display's SDR brightness above Apple's indoor cap with a fixed multiplier,
// while the native brightness slider (Control Center, keyboard) keeps controlling it.
//
//   XDRLift                      menu bar app
//   XDRLift --login on|off       registers this copy as a login item, then exits
//   XDRLift --selftest [secs]    boosts the XDR screen, pulses 1.0× ↔ 1.4× every 2 s, logs
//                                headroom / table, then exits (hard-capped at 60 s); refuses to
//                                run next to the menu bar instance (both would write the table)
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import os

let conflictingApps = [
    "com.goodsnooze.vivid": "Vivid", "com.getvivid.vivid": "Vivid",
    "pro.betterdisplay.BetterDisplay": "BetterDisplay", "fyi.lunar.Lunar": "Lunar",
    "org.herf.Flux": "f.lux", "com.bright.BrightIntosh": "BrightIntosh",
]

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var boosters: [CGDirectDisplayID: Booster] = [:]
    private var statusItem: NSStatusItem!
    private var poll: Timer?
    private var suspendReasons = Set<String>()
    private var suspendedAt: [String: CFTimeInterval] = [:]
    private var staleReasons = Set<String>()  // live state said "over" at the previous repair check
    private var lastRepair: CFTimeInterval = 0
    private var fadeTimer: Timer?
    private var quitting = false
    private var profileWork: DispatchWorkItem?
    private var ignoreProfileUntil: CFTimeInterval = 0
    private var shownSymbol = ""
    private var resumeWork: [String: DispatchWorkItem] = [:]
    private var signalSources: [DispatchSourceSignal] = []
    private let selftest: Double?
    private var hotKey: EventHotKeyRef?

    // Menu pieces updated live.
    private let enableItem = NSMenuItem(title: "启用提亮", action: #selector(toggleEnabled), keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let warningLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sliderLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 1.25, minValue: 1.0, maxValue: 1.6, target: nil, action: nil)
    private let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")

    static let defaultK = 1.25

    init(selftest: Double?) {
        self.selftest = selftest
        super.init()
    }

    var enabled: Bool {
        get { selftest != nil || (defaults.object(forKey: "enabled") as? Bool ?? true) }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    func userK(for uuid: String) -> Double {
        let k = defaults.double(forKey: "k.\(uuid)")
        return k >= 1 ? min(k, 1.6) : Self.defaultK
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if selftest == nil { buildMenu() }
        observe()
        installSignalHandlers()
        if selftest == nil { registerHotKey() }
        syncBoosters()
        // .common so it keeps running while the menu is open or an alert is up.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        if let secs = selftest { runSelftest(seconds: secs) }
        if defaults.bool(forKey: "trace") { startTrace() }
    }

    /// Quit fades the boost out first instead of dropping it in one frame.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        fadeOutThenTeardown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ note: Notification) { teardown() }

    private func fadeOutThenTeardown(_ done: @escaping () -> Void) {
        guard !quitting else { return }
        quitting = true
        let boosted = boosters.values.contains { $0.applied > 1.0001 || $0.fading }
        applyNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + (boosted ? Booster.fadeDuration + 0.05 : 0)) { [weak self] in
            MainActor.assumeIsolated { self?.teardown() }
            done()
        }
    }

    private func teardown() {
        for b in boosters.values { b.close() }
        boosters.removeAll()
    }

    // MARK: Displays

    /// Boosts every display that can show EDR (the Studio Display XDR here); built-in panels too,
    /// since the same trick works there.
    private func syncBoosters() {
        var seen = Set<CGDirectDisplayID>()
        for s in NSScreen.screens {
            guard let id = displayID(of: s), s.maximumPotentialExtendedDynamicRangeColorComponentValue > Booster.hdrReady else { continue }
            seen.insert(id)
            if let b = boosters[id] { b.refit(); continue }
            let b = Booster(screen: s, id: id, userK: userK(for: displayUUID(id)))
            boosters[id] = b
            log("display \(id) \(s.localizedName) uuid \(b.uuid) k \(b.userK)")
        }
        for (id, b) in boosters where !seen.contains(id) {
            b.close()
            boosters[id] = nil
        }
        applyShown()
    }

    /// Shows every booster when enabled. When disabled, a booster still fading out is left for
    /// tick() to hide once the fade has finished, so nothing cuts a fade short.
    private func applyShown() {
        for b in boosters.values {
            if enabled { b.show() } else if !b.fading { b.hide() }
        }
        refreshMenu()
    }

    private var suspended: Bool { !suspendReasons.isEmpty }
    /// Boost held at 1: quitting, suspended, or switched off and still fading out.
    private var off: Bool { quitting || suspended || !enabled }

    private func tick() {
        let now = CACurrentMediaTime()
        for (id, b) in boosters {
            b.verify(now: now)
            guard b.shown else { continue }
            b.setTriggerRunning(!suspended)
            if !off { b.keepOnTop() }
            if b.watchHeadroom(off: off, now: now) { log("display \(id): no EDR headroom for 5 s, re-raised the trigger") }
            b.update(off: off, now: now)
            if !enabled && !quitting && !b.fading && b.applied <= 1.0001 { b.hide() }
        }
        startFadeTimerIfNeeded()
        if suspended { repairSuspension(now: now) }
        refreshStatusLine()
    }

    /// Re-evaluates at once (user changed k / toggled): increases need no stabilisation delay.
    private func applyNow() {
        for b in boosters.values { b.update(off: off, immediate: true) }
        startFadeTimerIfNeeded()
        refreshStatusLine()
    }

    /// Writes fade steps at 60 Hz while any display is fading. In .common mode so dragging the
    /// menu slider previews live.
    private func startFadeTimerIfNeeded() {
        guard fadeTimer == nil, boosters.values.contains(where: { $0.fading }) else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let now = CACurrentMediaTime()
                for b in self.boosters.values { b.step(now: now) }
                if !self.boosters.values.contains(where: { $0.fading }) {
                    t.invalidate()
                    self.fadeTimer = nil
                    self.refreshStatusLine()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    // MARK: Suspend / resume

    private func suspend(_ reason: String) {
        resumeWork[reason]?.cancel()
        resumeWork[reason] = nil
        guard suspendReasons.insert(reason).inserted else { return }
        suspendedAt[reason] = CACurrentMediaTime()
        staleReasons.remove(reason)
        log("suspend: \(reason)")
        applyNow()
    }

    private func resume(_ reason: String, after delay: Double = 0) {
        resumeWork[reason]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.suspendReasons.remove(reason) != nil else { return }
                self.resumeWork[reason] = nil
                self.suspendedAt[reason] = nil
                self.staleReasons.remove(reason)
                log("resume: \(reason)")
                self.syncBoosters()
                self.tick()
            }
        }
        resumeWork[reason] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Every suspend reason is normally cleared by its paired notification. If one never arrives
    /// (a screen saver that dies without "didstop", say), the boost would stay off until relaunch,
    /// so every 2 s compare held reasons with the live state; a reason held for 10 s+ that two
    /// checks in a row find over is resumed. This only ever clears reasons, never adds them.
    private func repairSuspension(now: CFTimeInterval) {
        guard now - lastRepair >= 2 else { return }
        lastRepair = now
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let onConsole = session?["kCGSSessionOnConsoleKey"] as? Bool ?? true
        let asleep = boosters.keys.contains { CGDisplayIsAsleep($0) != 0 }
        let saver = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" }
        for reason in suspendReasons where resumeWork[reason] == nil && now - (suspendedAt[reason] ?? now) > 10 {
            let over: Bool
            switch reason {
            case "locked": over = !locked && onConsole
            case "session": over = onConsole
            case "sleep", "screens-sleep": over = !asleep && onConsole
            case "screensaver": over = !saver
            case "reconfigure": over = now - (suspendedAt[reason] ?? now) > 20
            default: over = false
            }
            if !over { staleReasons.remove(reason); continue }
            if staleReasons.insert(reason).inserted { continue }  // need a second agreeing check
            log("repair: \(reason) never got its resume notification")
            resume(reason)
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            log("active space changed")
        }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncBoosters(); self?.tick() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.willSleepNotification, "sleep", true), (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.screensDidSleepNotification, "screens-sleep", true), (NSWorkspace.screensDidWakeNotification, "screens-sleep", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true), (NSWorkspace.sessionDidBecomeActiveNotification, "session", false),
        ]
        for (name, reason, isSuspend) in pairs {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if isSuspend { self?.suspend(reason) } else { self?.resume(reason, after: reason == "session" ? 1 : 5) }
                }
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMenu() }
            }
        }
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.ColorSync.DisplayProfileNotification", "com.apple.ColorSync.DeviceProfilesNotification"] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.profileChanged() }
            }
        }
        let dpairs: [(String, String, Bool)] = [
            ("com.apple.screenIsLocked", "locked", true), ("com.apple.screenIsUnlocked", "locked", false),
            ("com.apple.screensaver.didstart", "screensaver", true), ("com.apple.screensaver.didstop", "screensaver", false),
        ]
        for (name, reason, isSuspend) in dpairs {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if isSuspend { self?.suspend(reason) } else { self?.resume(reason, after: 1) }
                }
            }
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let d = NSApp.delegate as? AppDelegate else { return }
                    if flags.contains(.beginConfigurationFlag) { d.suspend("reconfigure") } else { d.resume("reconfigure", after: 5) }
                }
            }
        }, nil)
    }

    /// A colour profile change (both notifications may fire): if the table still holds what this
    /// app wrote, nothing has loaded the new profile's table yet, so restore it once; verify()
    /// then adopts it as the base and fades the boost back up on top.
    private func profileChanged() {
        guard CACurrentMediaTime() > ignoreProfileUntil else { return }
        profileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                log("colour profile changed")
                if self.boosters.values.contains(where: { !$0.conflict && $0.holdsOwnTable }) {
                    self.ignoreProfileUntil = CACurrentMediaTime() + 1
                    CGDisplayRestoreColorSyncSettings()
                }
                for b in self.boosters.values { b.verify() }
                self.tick()
            }
        }
        profileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { exit(0) }
                    if self.quitting { exit(0) }  // a second signal: stop waiting for the fade
                    self.fadeOutThenTeardown { exit(0) }
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Hot key ⌃⌥⌘B toggles the boost from anywhere.

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.toggleEnabled() }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5844_524C), id: 1)  // 'XDRL'
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        warningLine.isEnabled = false
        enableItem.target = self
        enableItem.keyEquivalent = "b"
        enableItem.keyEquivalentModifierMask = [.command, .option, .control]
        menu.addItem(enableItem)
        menu.addItem(statusLine)
        menu.addItem(warningLine)
        menu.addItem(.separator())

        let row = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        sliderLabel.frame = NSRect(x: 20, y: 28, width: 230, height: 18)
        sliderLabel.font = .menuFont(ofSize: 13)
        slider.frame = NSRect(x: 18, y: 4, width: 226, height: 22)
        slider.numberOfTickMarks = 13          // 1.00 … 1.60 in 0.05 steps
        slider.allowsTickMarkValuesOnly = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.isContinuous = true
        row.addSubview(sliderLabel)
        row.addSubview(slider)
        let sliderItem = NSMenuItem()
        sliderItem.view = row
        menu.addItem(sliderItem)
        menu.addItem(.separator())

        loginItem.target = self
        menu.addItem(loginItem)
        let quit = NSMenuItem(title: "退出 XDRLift", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private var primary: Booster? { boosters.values.sorted { $0.id < $1.id }.first }

    private func refreshMenu() {
        guard selftest == nil, statusItem != nil else { return }
        enableItem.state = enabled ? .on : .off
        let k = primary?.userK ?? Self.defaultK
        slider.doubleValue = k
        slider.isEnabled = enabled && primary != nil
        sliderLabel.stringValue = String(format: "提亮倍数  %.2f×", k)
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.flatMap { conflictingApps[$0] } }
        var warnings: [String] = []
        if !running.isEmpty { warnings.append("⚠️ \(Set(running).sorted().joined(separator: "、")) 在运行，可能互相抢 gamma 表") }
        if boosters.values.contains(where: { $0.conflict }) { warnings.append("⚠️ 别的程序在改 gamma 表，已暂停提亮") }
        warningLine.title = warnings.joined(separator: "  ")
        warningLine.isHidden = warnings.isEmpty
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.state = .on
            loginItem.title = "开机自动启动"
        case .requiresApproval:
            loginItem.state = .off
            loginItem.title = "开机自动启动（需在系统设置里允许…）"
        default:
            loginItem.state = .off
            loginItem.title = installed ? "开机自动启动" : "开机自动启动（先 make install）"
        }
        loginItem.isEnabled = installed || SMAppService.mainApp.status == .enabled
        refreshStatusLine()
    }

    private func refreshStatusLine() {
        guard selftest == nil, statusItem != nil else { return }
        // Only touch the status item when the symbol changes: every set redraws it and its copies.
        let symbol = enabled && (primary?.applied ?? 1) > 1.001 ? "sun.max.fill" : "sun.max"
        if symbol != shownSymbol {
            shownSymbol = symbol
            statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "XDRLift")
        }
        let title: String
        if let b = primary {
            let h = b.headroom
            if !enabled { title = "已关闭（⌃⌥⌘B 开关）" }
            else if suspended { title = "暂停中（\(suspendReasons.sorted().joined(separator: ", "))）" }
            else if b.conflict { title = "已让出（别的程序在改 gamma 表）" }
            else if h > Booster.hdrReady { title = String(format: "当前约 %.2f×  ·  EDR 余量 %.2f×", b.applied, h) }
            else { title = "等待 EDR 启动…" }
        } else {
            title = "没有找到支持 EDR 的显示器"
        }
        if statusLine.title != title { statusLine.title = title }
    }

    @objc func toggleEnabled() {
        enabled.toggle()
        if enabled {
            // EDR opens ~0.25 s after the trigger appears; re-check a few times instead of waiting
            // for the next tick, and skip the stabilisation delay since the user asked.
            for b in boosters.values { b.noteUserIntent() }
            applyShown()
            applyNow()
            for delay in [0.3, 0.6, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.enabled else { return }
                        self.applyNow()
                    }
                }
            }
        } else {
            // Fade to 1 first; tick() takes the trigger down once the fade has finished.
            applyNow()
            refreshMenu()
        }
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let k = (sender.doubleValue * 20).rounded() / 20
        for b in boosters.values {
            b.userK = k
            defaults.set(k, forKey: "k.\(b.uuid)")
        }
        sliderLabel.stringValue = String(format: "提亮倍数  %.2f×", k)
        applyNow()
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "设置开机启动失败"
            a.informativeText = error.localizedDescription + "\n可在 系统设置 › 通用 › 登录项 中检查。"
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        refreshMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Trace (`defaults write com.justaboringname.xdrlift trace -bool true`, then relaunch)

    /// Logs headroom, applied k, window visibility and frame health every 50 ms, whenever any of
    /// them changes, for chasing short glitches such as Space switches.
    private func startTrace() {
        var last = ""
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                let line = self.boosters.values.map { b -> String in
                    let h = b.health(now: now)
                    return String(format: "id=%u H=%.3f applied=%.3f table=%.4f trVis=%d trStale=%d",
                                  b.id, b.headroom, b.applied, b.tableLast, h.triggerVisible ? 1 : 0, h.triggerAge > 0.5 ? 1 : 0)
                }.joined(separator: " | ")
                if line != last { log("trace " + line); last = line }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        log("trace on")
    }

    // MARK: Self-test

    private func runSelftest(seconds: Double) {
        let start = CACurrentMediaTime()
        var high = false
        log("selftest: \(boosters.count) EDR display(s); pulsing 1.00× ↔ 1.40× every 2 s for \(Int(seconds)) s")
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                high.toggle()
                for b in self.boosters.values { b.userK = high ? 1.4 : 1.0 }
                self.applyNow()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                for b in self.boosters.values {
                    let h = b.health(now: now)
                    log(String(format: "t=%4.1f id=%u H=%.3f applied=%.3f table=%.4f trigVis=%d trigAge=%.2f",
                               now - start, b.id, b.headroom, b.applied, b.tableLast, h.triggerVisible ? 1 : 0, h.triggerAge))
                }
                if now - start >= seconds {
                    log("selftest: done")
                    self.teardown()
                    exit(0)
                }
            }
        }
    }
}

private let logger = Logger(subsystem: "com.justaboringname.xdrlift", category: "main")

/// stderr plus the unified log: `log stream --predicate 'subsystem == "com.justaboringname.xdrlift"'`.
func log(_ s: String) {
    FileHandle.standardError.write(("[XDRLift] " + s + "\n").data(using: .utf8)!)
    logger.notice("\(s, privacy: .public)")
}

// MARK: Entry

let args = CommandLine.arguments
// `--login on|off`: register this copy as a login item (same as the menu toggle) and exit.
if let i = args.firstIndex(of: "--login") {
    let on = i + 1 < args.count && args[i + 1] == "on"
    do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        print("login item: \(SMAppService.mainApp.status == .enabled ? "on" : SMAppService.mainApp.status == .requiresApproval ? "needs approval in System Settings › General › Login Items" : "off")")
        exit(0)
    } catch {
        print("login item: \(error.localizedDescription)")
        exit(1)
    }
}
var selftest: Double? = nil
if let i = args.firstIndex(of: "--selftest") {
    selftest = min(60, i + 1 < args.count ? Double(args[i + 1]) ?? 12 : 12)
}
// One instance at a time: two would fight over the gamma table.
if let me = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0 != .current && !$0.isTerminated }) {
    if selftest != nil {
        FileHandle.standardError.write("XDRLift is already running; quit it first (both would write the gamma table)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate(selftest: selftest) }
app.delegate = delegate
app.run()
