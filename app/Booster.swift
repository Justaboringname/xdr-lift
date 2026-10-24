// One display's boost: a full-screen multiply overlay plus a 1×1 EDR trigger window.
//
// How it works: while any EDR content is on screen macOS raises the panel's backlight and renders
// SDR white at 1.0 inside a larger range (headroom H = maximumExtendedDynamicRangeColorComponentValue).
// The trigger keeps that mode on; the overlay multiplies everything below it by k, pushing SDR white
// to k × (native brightness). The native slider (Control Center, keys) keeps working: lowering it
// raises H, which only loosens the k ≤ 0.95·H cap.
import AppKit

private let shieldingLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)

private func makeOverlayWindow(frame: NSRect, view: NSView) -> NSWindow {
    let w = NSWindow(contentRect: frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
    w.level = shieldingLevel
    w.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .canJoinAllApplications, .fullScreenAuxiliary]
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.hidesOnDeactivate = false
    w.canHide = false
    w.animationBehavior = .none
    w.isReleasedWhenClosed = false
    w.contentView = view
    w.setFrame(frame, display: false)
    return w
}

func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

func displayUUID(_ id: CGDirectDisplayID) -> String {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
    return CFUUIDCreateString(nil, uuid) as String
}

@MainActor
final class Booster {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    /// The multiplier the user asked for; the applied one is capped by headroom (see `target`).
    var userK: Double

    private let overlayView: ClearView
    private let overlay: NSWindow
    private let triggerView: ClearView
    private let trigger: NSWindow
    private(set) var applied = 1.0          // what the overlay currently multiplies by
    private var fade: (from: Double, to: Double, start: CFTimeInterval)?
    private var upSince: CFTimeInterval?     // when a system-caused increase was first proposed
    private(set) var shown = false
    private var shownAt: CFTimeInterval = 0
    private var revealed = false             // overlay alpha raised after its first fresh frame
    private var lowSince: CFTimeInterval?    // headroom has been missing since
    private var lastKick: CFTimeInterval = 0
    private(set) var fadeFrames = 0          // frames drawn mid-fade (self-test diagnostics)

    static let fadeDuration = 0.4
    static let upwardDelay = 1.5
    static let hdrReady = 1.05
    static let idleFPS = 5
    static let fadeFPS = 60

    init(screen: NSScreen, id: CGDirectDisplayID, userK: Double) {
        self.id = id
        uuid = displayUUID(id)
        name = screen.localizedName
        self.userK = userK
        overlayView = ClearView(frame: NSRect(origin: .zero, size: screen.frame.size), multiply: true)
        overlay = makeOverlayWindow(frame: screen.frame, view: overlayView)
        overlay.alphaValue = 0
        triggerView = ClearView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), multiply: false)
        // A near-invisible pixel is enough to make macOS open up headroom (H 1.0 → 3.33 here).
        triggerView.setColor(0.016, alpha: 0.01)
        trigger = makeOverlayWindow(frame: Self.triggerFrame(screen), view: triggerView)
        trigger.sharingType = .none
        overlayView.onFrame = { [weak self] in MainActor.assumeIsolated { self?.revealIfFresh() } }
        overlayView.beforeDraw = { [weak self] in MainActor.assumeIsolated { self?.step() } }
    }

    private static func triggerFrame(_ screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 1, height: 1)
    }

    var screen: NSScreen? { NSScreen.screens.first { displayID(of: $0) == id } }
    var headroom: Double { Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1) }

    func show() {
        guard !shown else { return }
        shown = true
        shownAt = CACurrentMediaTime()
        revealed = false
        lowSince = nil
        refit()
        overlayView.isPaused = false
        triggerView.isPaused = false
        trigger.orderFrontRegardless()
        overlay.orderFrontRegardless()
        // Present right away instead of waiting up to 200 ms for the 5 fps loop.
        triggerView.draw()
        overlayView.draw()
    }

    /// Takes both windows off screen (not closed: closing and recreating flashes and has crashed
    /// other tools). An identity frame is presented first, so the layer can never come back
    /// holding a boosted frame.
    func hide() {
        defer {
            overlayView.isPaused = true
            triggerView.isPaused = true
            overlayView.preferredFramesPerSecond = Self.idleFPS
        }
        guard shown else { return }
        shown = false
        fade = nil
        upSince = nil
        lowSince = nil
        applied = 1
        overlay.alphaValue = 0
        revealed = false
        overlayView.setColor(1)
        overlayView.draw()
        overlay.orderOut(nil)
        trigger.orderOut(nil)
    }

    func close() {
        hide()
        overlay.close()
        trigger.close()
    }

    func refit() {
        guard let s = screen else { return }
        if overlay.frame != s.frame { overlay.setFrame(s.frame, display: false) }
        let t = Self.triggerFrame(s)
        if trigger.frame != t { trigger.setFrame(t, display: false) }
    }

    /// Makes the overlay visible only once a frame encoded after show() has completed. If frames
    /// never come it stays at alpha 0, which is identity: no boost, but never a bad screen.
    private func revealIfFresh() {
        guard shown, !revealed, overlayView.lastFrame > shownAt else { return }
        revealed = true
        overlay.alphaValue = 1
    }

    /// The multiplier to apply now: the user's k, capped below the headroom, 1 without EDR.
    func target(off: Bool) -> Double {
        let h = headroom
        guard !off, shown, h > Self.hdrReady else { return 1 }
        return max(1, min(userK, 0.95 * h))
    }

    /// Moves toward the target. Decreases (EDR lost, slider moved, suspend) start at once; a
    /// system-caused increase must hold for `upwardDelay` first so a headroom blip can't flash.
    /// `immediate` is for the user's own changes.
    func update(off: Bool, immediate: Bool = false, now: CFTimeInterval = CACurrentMediaTime()) {
        let t = target(off: off)
        let goal = fade?.to ?? applied
        if abs(t - goal) < 0.002 { upSince = nil; return }
        if t > goal && !immediate {
            if upSince == nil { upSince = now }
            if now - upSince! < Self.upwardDelay { return }
        }
        upSince = nil
        fade = (from: applied, to: t, start: now)
        overlayView.preferredFramesPerSecond = Self.fadeFPS
    }

    var fading: Bool { fade != nil }

    /// Advances a fade (smoothstep over `fadeDuration`); runs at the start of each overlay frame,
    /// at 60 fps while fading and back at 5 fps once the final value has been drawn.
    private func step(now: CFTimeInterval = CACurrentMediaTime()) {
        guard let f = fade else { return }
        fadeFrames += 1
        let x = min(1, max(0, (now - f.start) / Self.fadeDuration))
        let s = x * x * (3 - 2 * x)
        applied = f.from + (f.to - f.from) * s
        if x >= 1 {
            applied = f.to
            fade = nil
            overlayView.preferredFramesPerSecond = Self.idleFPS
        }
        overlayView.setColor(applied)
    }

    /// Re-raises the windows if something (a game, a shield window) covered them.
    func keepOnTop() {
        guard shown else { return }
        if !overlay.occlusionState.contains(.visible) { overlay.orderFrontRegardless() }
        if !trigger.occlusionState.contains(.visible) { trigger.orderFrontRegardless() }
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

    struct Health { var overlayVisible: Bool; var triggerVisible: Bool; var overlayAge: Double; var triggerAge: Double }
    func health(now: CFTimeInterval = CACurrentMediaTime()) -> Health {
        Health(overlayVisible: overlay.occlusionState.contains(.visible),
               triggerVisible: trigger.occlusionState.contains(.visible),
               overlayAge: overlayView.lastFrame == 0 ? .infinity : now - overlayView.lastFrame,
               triggerAge: triggerView.lastFrame == 0 ? .infinity : now - triggerView.lastFrame)
    }
}
