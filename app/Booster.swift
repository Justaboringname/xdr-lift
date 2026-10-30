// One display's boost: a 1×1 EDR trigger window plus a scaled gamma (transfer) table.
//
// How it works: while any EDR content is on screen macOS raises the panel's backlight and renders
// SDR white at 1.0 inside a larger range (headroom H = maximumExtendedDynamicRangeColorComponentValue).
// The trigger keeps that mode on; scaling the display's transfer table above 1.0 then pushes SDR
// white into the headroom, to k × (native brightness). The native slider (Control Center, keys)
// keeps working: lowering it raises H, which only loosens the k ≤ 0.95·H cap.
//
// The table sits after window compositing, so the boost holds through Space switches and Mission
// Control (a full-screen multiply overlay drops out for ~1 s there), covers the cursor, and stays
// out of screenshots. WindowServer restores the table when this process exits, even on kill -9.
import AppKit

func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

func displayUUID(_ id: CGDirectDisplayID) -> String {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
    return CFUUIDCreateString(nil, uuid) as String
}

struct GammaTable {
    static let size: UInt32 = 256
    var r, g, b: [CGGammaValue]

    static func read(_ id: CGDirectDisplayID) -> GammaTable? {
        var t = GammaTable(r: .init(repeating: 0, count: Int(size)), g: .init(repeating: 0, count: Int(size)), b: .init(repeating: 0, count: Int(size)))
        var n: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, size, &t.r, &t.g, &t.b, &n) == .success, n > 1 else { return nil }
        t.r.removeLast(t.r.count - Int(n)); t.g.removeLast(t.g.count - Int(n)); t.b.removeLast(t.b.count - Int(n))
        return t
    }

    static func identity(_ n: Int = Int(size)) -> GammaTable {
        let ramp = (0..<n).map { CGGammaValue($0) / CGGammaValue(n - 1) }
        return GammaTable(r: ramp, g: ramp, b: ramp)
    }

    var peak: CGGammaValue { max(r.max() ?? 0, g.max() ?? 0, b.max() ?? 0) }
    /// Not boosted by anyone: what the profile, the system or a tint/dimming app put there.
    var plain: Bool { peak <= 1.003 }

    func scaled(by f: CGGammaValue) -> GammaTable {
        GammaTable(r: r.map { $0 * f }, g: g.map { $0 * f }, b: b.map { $0 * f })
    }

    func matches(_ o: GammaTable, tolerance: CGGammaValue = 0.003) -> Bool {
        guard r.count == o.r.count else { return false }
        for i in r.indices where abs(r[i] - o.r[i]) > tolerance || abs(g[i] - o.g[i]) > tolerance || abs(b[i] - o.b[i]) > tolerance {
            return false
        }
        return true
    }

    @discardableResult
    func write(_ id: CGDirectDisplayID) -> CGError {
        var r = r, g = g, b = b
        return CGSetDisplayTransferByTable(id, UInt32(r.count), &r, &g, &b)
    }
}

@MainActor
final class Booster {
    private static var all = NSHashTable<Booster>.weakObjects()

    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    /// The multiplier the user asked for (linear light, ≈ nits ratio); the applied one is capped
    /// by headroom (see `target`).
    var userK: Double

    private let triggerView: ClearView
    private var trigger: NSWindow
    private var triggerTimer: Timer?
    private var base: GammaTable             // the plain table the boost is applied on top of
    private var lastWritten: GammaTable?     // exactly what this process last put in the table
    private(set) var applied = 1.0           // linear multiplier currently in the table
    private var fade: (from: Double, to: Double, start: CFTimeInterval)?
    private var upSince: CFTimeInterval?      // when a system-caused increase was first proposed
    private var fastUntil: CFTimeInterval = 0 // increases skip the stabilisation delay until then
    private(set) var shown = false
    private var lowSince: CFTimeInterval?     // headroom has been missing since
    private var offSpaceSince: CFTimeInterval? // the trigger has been off the active Space since
    private var lastKick: CFTimeInterval = 0
    private var changes: [CFTimeInterval] = []  // times someone else changed the table
    /// Another app owns the table (it boosted it, or keeps changing it): stay at 1 and write
    /// nothing until it has been left alone for 30 s.
    private(set) var conflict = false

    /// Headroom the trigger asks for. Enough for the 1.6× slider maximum (0.95 · 2.0), and the
    /// yardstick for HDR detection: macOS grants exactly this, so a higher H means HDR content.
    static let triggerHeadroom = 2.0
    static let fadeDuration = 0.4
    static let upwardDelay = 1.5
    static let hdrReady = 1.05
    /// The table holds gamma-encoded values: scaling it by f scales light by f^2.2, so a linear
    /// multiplier k is written as k^(1/2.2). (Checked against an EDR 1.4× reference on this
    /// display: the encoded factor matched, the linear one flickered more.)
    static let encodingGamma = 2.2

    init(screen: NSScreen, id: CGDirectDisplayID, userK: Double) {
        self.id = id
        uuid = displayUUID(id)
        name = screen.localizedName
        self.userK = userK
        base = Self.cleanBase(id)
        triggerView = ClearView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), headroom: Self.triggerHeadroom)
        // A near-invisible pixel is enough to make macOS open up headroom (H 1.0 → 2.0 in 0.25 s).
        triggerView.setColor(0.016, alpha: 0.01)
        trigger = Self.makeTrigger(screen, view: triggerView)
        Self.all.add(self)
    }

    private static func makeTrigger(_ screen: NSScreen, view: NSView) -> NSWindow {
        let w = NSWindow(contentRect: triggerFrame(screen), styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        w.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .canJoinAllApplications, .fullScreenAuxiliary]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false
        w.canHide = false
        w.animationBehavior = .none
        w.isReleasedWhenClosed = false
        w.sharingType = .none
        w.contentView = view
        return w
    }

    /// The current table, unless it already looks boosted (left by another tool), in which case
    /// the ColorSync profile's table is restored and used — or identity if even that looks boosted.
    private static func cleanBase(_ id: CGDirectDisplayID) -> GammaTable {
        if let t = GammaTable.read(id), t.plain { return t }
        CGDisplayRestoreColorSyncSettings()
        if let t = GammaTable.read(id), t.plain { return t }
        return .identity()
    }

    private static func triggerFrame(_ screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 1, height: 1)
    }

    var screen: NSScreen? { NSScreen.screens.first { displayID(of: $0) == id } }
    var headroom: Double { Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1) }

    private func encoded(_ k: Double) -> CGGammaValue { CGGammaValue(pow(k, 1 / Self.encodingGamma)) }

    /// Writes base × k. At k = 1 the table is handed back to the system instead of written: any
    /// table this process holds, even an identity one, caps EDR content at SDR white, so HDR video
    /// would look like SDR (seen with Bilibili HDR in Safari until XDRLift was quit).
    private func writeTable(_ k: Double) {
        guard !conflict else { return }
        if k <= 1.0001 {
            releaseTable()
            return
        }
        let t = base.scaled(by: encoded(k))
        let e = t.write(id)
        if e == .success { lastWritten = t } else { log("display \(id): CGSetDisplayTransferByTable failed (\(e.rawValue))") }
    }

    /// Restores this process's tables to the ColorSync profile, which drops its override. The call
    /// covers every display, so it waits until no display of this app is boosted; until then the
    /// plain base is written instead.
    private func releaseTable() {
        if Self.all.allObjects.contains(where: { $0 !== self && ($0.applied > 1.0001 || $0.fading) }) {
            if base.write(id) == .success { lastWritten = base }
            return
        }
        CGDisplayRestoreColorSyncSettings()
        for b in Self.all.allObjects {
            if let live = GammaTable.read(b.id) {
                b.lastWritten = live
                if live.plain { b.base = live }
            }
        }
    }

    /// Other content on this display asked for more headroom than the trigger: HDR video or
    /// photos. The gamma boost would clip it, so the boost steps aside while it is on screen.
    var hdrOnScreen: Bool { shown && headroom > Self.triggerHeadroom + 0.05 }

    func show() {
        guard !shown else { return }
        shown = true
        lowSince = nil
        offSpaceSince = nil
        refit()
        trigger.orderFrontRegardless()
        setTriggerRunning(true)
    }

    /// Writes the plain table back and takes the trigger off screen (not closed: closing and
    /// recreating windows like this has crashed other tools).
    func hide() {
        guard shown else { return }
        shown = false
        fade = nil
        upSince = nil
        lowSince = nil
        offSpaceSince = nil
        applied = 1
        writeTable(1)
        setTriggerRunning(false)
        trigger.orderOut(nil)
    }

    func close() {
        hide()
        trigger.close()
    }

    /// Presents a trigger frame every 0.2 s while EDR is wanted. A timer instead of MTKView's own
    /// loop, whose display link wakes the process at the full refresh rate even at 5 fps.
    func setTriggerRunning(_ on: Bool) {
        if on, triggerTimer == nil {
            let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.triggerView.draw() }
            }
            t.tolerance = 0.03
            RunLoop.main.add(t, forMode: .common)
            triggerTimer = t
            triggerView.draw()
        } else if !on, let t = triggerTimer {
            t.invalidate()
            triggerTimer = nil
        }
    }

    func refit() {
        guard let s = screen else { return }
        let t = Self.triggerFrame(s)
        if trigger.frame != t { trigger.setFrame(t, display: false) }
    }

    /// The user just asked for the boost: let increases through without the stabilisation delay
    /// for the next 2 s (EDR takes ~0.25 s to open after the trigger appears).
    func noteUserIntent(now: CFTimeInterval = CACurrentMediaTime()) { fastUntil = now + 2 }

    /// The multiplier to apply now: the user's k, capped below the headroom, 1 without EDR.
    func target(off: Bool) -> Double {
        let h = headroom
        guard !off, shown, !conflict, h > Self.hdrReady, !hdrOnScreen else { return 1 }
        return max(1, min(userK, 0.95 * h))
    }

    /// Moves toward the target. Decreases (EDR lost, slider moved, suspend) start at once; a
    /// system-caused increase must hold for `upwardDelay` first so a headroom blip can't flash.
    /// `immediate` is for the user's own changes.
    func update(off: Bool, immediate: Bool = false, now: CFTimeInterval = CACurrentMediaTime()) {
        let immediate = immediate || now < fastUntil
        let t = target(off: off)
        let goal = fade?.to ?? applied
        if abs(t - goal) < 0.002 { upSince = nil; return }
        if t > goal && !immediate {
            if upSince == nil { upSince = now }
            if now - upSince! < Self.upwardDelay { return }
        }
        upSince = nil
        log(String(format: "display %u: fade %.3f → %.3f (H %.3f%@)", id, applied, t, headroom, immediate ? ", fast" : ""))
        fade = (from: applied, to: t, start: now)
    }

    var fading: Bool { fade != nil }

    /// Advances a fade (smoothstep over `fadeDuration`), one table write per call.
    func step(now: CFTimeInterval = CACurrentMediaTime()) {
        guard let f = fade else { return }
        let x = min(1, max(0, (now - f.start) / Self.fadeDuration))
        let s = x * x * (3 - 2 * x)
        applied = f.from + (f.to - f.from) * s
        if x >= 1 { applied = f.to; fade = nil }
        writeTable(applied)
    }

    /// Compares the live table with what this process last wrote. If someone else changed it:
    /// - a plain table (ColorSync reload after wake or a profile change, f.lux, a dimmer) becomes
    ///   the new base, and the boost fades back up on top of it from 1, which is what is on screen;
    /// - a boosted table, or a third change within 10 s, means another app owns the table: stay at
    ///   1 and write nothing (`conflict`) until it has been left alone for 30 s.
    func verify(now: CFTimeInterval = CACurrentMediaTime()) {
        guard let live = GammaTable.read(id) else { return }
        guard let mine = lastWritten else { lastWritten = live; return }
        if live.matches(mine) {
            if conflict, let last = changes.last, now - last > 30, live.plain {
                conflict = false
                base = live
                log("display \(id): gamma table left alone for 30 s, boosting again")
            }
            return
        }
        changes = changes.filter { now - $0 < 10 } + [now]
        lastWritten = live
        fade = nil
        applied = 1
        if !live.plain || changes.count >= 3 {
            if !conflict { log(String(format: "display %u: another app is writing the gamma table (peak %.3f); standing aside", id, live.peak)) }
            conflict = true
            return
        }
        if conflict { return }
        log(String(format: "display %u: gamma table replaced by a plain one (peak %.3f); using it as the base", id, live.peak))
        base = live
        fastUntil = now + 2
    }

    /// Whether the live table is still exactly what this process wrote (nobody replaced it).
    var holdsOwnTable: Bool {
        guard let mine = lastWritten, let live = GammaTable.read(id) else { return false }
        return live.matches(mine)
    }

    /// Re-raises the trigger if something (a game, a shield window) covered it.
    func keepOnTop() {
        guard shown, !trigger.occlusionState.contains(.visible) else { return }
        trigger.orderFrontRegardless()
    }

    /// WindowServer can drop the trigger from a Space despite .canJoinAllSpaces (seen on a full-screen
    /// Space, cause unknown). EDR then lapses 15 s after that Space opens, and neither ordering the
    /// window in nor resetting its collectionBehavior puts it back; a new window joins every Space.
    /// So after 1.5 s off the active Space the view moves to a new window, at most every 30 s.
    /// Returns true when it did.
    func watchSpace(off: Bool, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard shown, !off, !trigger.isOnActiveSpace, let s = screen else {
            offSpaceSince = nil
            return false
        }
        let since = offSpaceSince ?? now
        offSpaceSince = since
        guard now - since > 1.5, now - lastKick > 30 else { return false }
        lastKick = now
        offSpaceSince = nil
        let old = trigger
        trigger = Self.makeTrigger(s, view: triggerView)
        trigger.orderFrontRegardless()
        triggerView.draw()
        old.orderOut(nil)
        // Closed a beat later, not in the pass that built the new one (see hide()).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { old.close() } }
        return true
    }

    /// If headroom has been missing for 5 s while the trigger is up and drawing, asks for EDR
    /// again by re-ordering the trigger, at most every 30 s. Returns true when it did.
    func watchHeadroom(off: Bool, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        let h = health(now: now)
        guard shown, !off, headroom <= Self.hdrReady, h.triggerVisible, h.triggerAge < 1 else {
            lowSince = nil
            return false
        }
        let since = lowSince ?? now
        lowSince = since
        guard now - since > 5, now - lastKick > 30 else { return false }
        lastKick = now
        trigger.orderOut(nil)
        trigger.orderFrontRegardless()
        triggerView.draw()
        return true
    }

    struct Health { var triggerVisible: Bool; var triggerAge: Double }
    func health(now: CFTimeInterval = CACurrentMediaTime()) -> Health {
        Health(triggerVisible: trigger.occlusionState.contains(.visible),
               triggerAge: triggerView.lastFrame == 0 ? .infinity : now - triggerView.lastFrame)
    }

    /// Last entry of the red channel as macOS reports it now (diagnostics).
    var tableLast: Double { Double(GammaTable.read(id)?.r.last ?? -1) }
}
