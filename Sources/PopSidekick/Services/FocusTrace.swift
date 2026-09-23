import AppKit
import SwiftUI
import Combine
import Observation

/// One sampled point of a trace, in global Cocoa screen coordinates.
struct FocusTracePoint {
    var location: CGPoint
    var time: TimeInterval
}

/// A drawn stroke. Strokes sharing a `group` (e.g. an arrow's shaft and head)
/// are undone together. Pinned strokes (a circled selection) don't fade.
struct TraceStroke {
    var id: Int
    var group: Int
    var points: [FocusTracePoint]
    /// Every sampled location, kept even after old points fade, for shape snapping.
    var raw: [CGPoint] = []
    var pinned = false
    /// Drawn with ⌥ held: stays on screen like persistent ink.
    var permanent = false
    var isArrow = false
    /// ⇧⌥-drag: a rectangle from the press point to the pointer.
    var isBox = false
    /// When set, the stroke is being removed with a short fade.
    var fadingFrom: TimeInterval?
}

/// Expanding ring shown on a mouse click.
struct ClickRipple {
    var location: CGPoint
    var time: TimeInterval
    var secondary: Bool
}

/// Rendering options derived from `AppSettings`.
struct FocusTraceConfig {
    var cursorScale: CGFloat = 2.5
    var showHalo = true
    var cursorShape: FocusTraceCursorShape = .system
    var cursorColor: NSColor = .systemPink
    var color: NSColor = .systemPink
    var multicolor = true
    var lineWidth: CGFloat = 10
    var fade: TimeInterval = 1.6
    var mode: FocusTraceDrawMode = .passThrough
    var snapShapes = true
    var persistentInk = false
    var ripples = false
    var rippleSize: CGFloat = 10
    var spotlight = false
    var spotlightRadius: CGFloat = 150
    var spotlightDim: Double = 0.55
    var magnifier = true
    var magnifierSize: CGFloat = 240

    init() {}

    init(_ s: AppSettings) {
        cursorScale = CGFloat(max(1, s.focusTraceCursorScale))
        showHalo = s.focusTraceShowHalo
        cursorShape = s.focusTraceCursorShape
        cursorColor = NSColor(hex: s.focusTraceCursorColorHex) ?? .systemPink
        color = NSColor(hex: s.focusTraceColorHex) ?? .systemPink
        multicolor = s.focusTraceMulticolor
        lineWidth = CGFloat(max(2, s.focusTraceLineWidth))
        fade = max(0.2, s.focusTraceFadeSeconds)
        mode = s.focusTraceDrawMode
        snapShapes = s.focusTraceSnapShapes
        persistentInk = s.focusTracePersistentInk
        ripples = s.focusTraceRipples
        rippleSize = CGFloat(min(200, max(6, s.focusTraceRippleSize)))
        spotlight = s.focusTraceSpotlight
        spotlightRadius = CGFloat(max(40, s.focusTraceSpotlightRadius))
        spotlightDim = min(1, max(0, s.focusTraceSpotlightDim))
        magnifier = s.focusTraceMagnifier
        magnifierSize = CGFloat(max(100, s.focusTraceMagnifierSize))
    }
}

/// Shared render state. Observable so the overlays redraw only when something
/// changes; `animating` un-pauses the per-frame timeline while ink fades,
/// ripples expand, or a stroke is being drawn.
@Observable
final class FocusTraceModel {
    var strokes: [TraceStroke] = []
    var animating = false
    var ripples: [ClickRipple] = []
    var cursor: CGPoint = .zero
    var drawing = false
    /// True while the magnifier lens is on screen (the halo steps aside).
    var lensVisible = false
    var config = FocusTraceConfig()

    static let removeFade: TimeInterval = 0.35
    static let rippleDuration: TimeInterval = 0.55

    func alpha(_ p: FocusTracePoint, in s: TraceStroke, now: TimeInterval) -> Double {
        var a = (s.pinned || s.permanent || config.persistentInk) ? 1 : 1 - (now - p.time) / config.fade
        if let f = s.fadingFrom { a *= 1 - (now - f) / Self.removeFade }
        return max(0, min(1, a))
    }
}

enum FocusTraceBlank { case black, white }

/// Presentation aid: magnifies the cursor and draws a fading, colorful trace
/// wherever the user drags. Extras: click ripples, spotlight, pinch-to-zoom
/// magnifier, smart shapes (lines, arrows, circled selections explained by
/// Copilot), persistent ink, and black/white screen blanking.
@MainActor
final class FocusTrace: ObservableObject {
    static let shared = FocusTrace()

    @Published private(set) var isEnabled = false
    @Published private(set) var blank: FocusTraceBlank?

    private let model = FocusTraceModel()
    private var panels: [NSPanel] = []
    private var blankPanels: [NSPanel] = []
    private var timer: Timer?
    private var settingsSub: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var escMonitors: [Any] = []
    private var wasDrawing = false
    private var wasLeftDown = false
    private var wasRightDown = false
    private var pendingOrigin: FocusTracePoint?
    private var activeStrokeID: Int?
    private var nextStrokeID = 1
    private var nextGroup = 1
    private var selectionGroup: Int?
    private var capturing = false
    private var hadInk = false

    // Hotkeys that only exist while FocusTrace is on.
    private let hotkeys = HotkeyManager(signature: 0x50534654 /* 'PSFT' */)
    private var hotkeySignature = ""
    private static let blackID = "black", whiteID = "white", undoID = "undo", clearID = "clear"

    // Magnifier.
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var zoom: CGFloat = 1
    private let mirror = ScreenMirror()
    private var mirrorSurface: IOSurface?
    private var mirrorFrame: CGRect = .zero
    private var lens: MagnifierLens?
    private var askedCapturePermission = false

    private lazy var selectionUI: FocusTraceSelectionUI = {
        let ui = FocusTraceSelectionUI(level: NSWindow.Level(rawValue: Self.overlayLevel.rawValue + 1))
        ui.onDismiss = { [weak self] in self?.dismissSelection() }
        return ui
    }()

    /// Just below the menu bar so the status item stays clickable, but above
    /// the Dock and every regular / full-screen window.
    static let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
    private static let maxRawPoints = 4000

    private init() {
        hotkeys.onTrigger = { [weak self] id in self?.handleHotkey(id) }
        mirror.onFrame = { [weak self] surface in
            MainActor.assumeIsolated { self?.mirrorSurface = surface }
        }
    }

    func toggle() { setEnabled(!isEnabled) }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        if on { start() } else { stop() }
    }

    // MARK: Lifecycle

    private func start() {
        model.config = FocusTraceConfig(SettingsStore.shared.settings)
        model.strokes.removeAll()
        model.ripples.removeAll()
        model.cursor = NSEvent.mouseLocation
        wasDrawing = false
        wasLeftDown = NSEvent.pressedMouseButtons & 1 != 0
        wasRightDown = NSEvent.pressedMouseButtons & 2 != 0
        buildPanels()

        settingsSub = SettingsStore.shared.$settings
            .sink { [weak self] s in
                guard let self else { return }
                self.model.config = FocusTraceConfig(s)
                self.applyCapture(self.shouldCapture(option: NSEvent.modifierFlags.contains(.option)), force: true)
                self.updateHotkeys(settings: s)
                self.updateTap()
                if !self.model.config.magnifier { self.resetZoom() }
            }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.buildPanels()
                if let b = self.blank { self.blank = nil; self.setBlank(b) }
            }
        }
        installEscapeMonitors()

        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        settingsSub = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        setBlank(nil)
        selectionUI.hide()
        selectionGroup = nil
        resetZoom()
        removeTap()
        hotkeys.unregisterAllHotkeys()
        hotkeySignature = ""
        model.strokes.removeAll()
        model.ripples.removeAll()
        model.drawing = false
        wasDrawing = false
        pendingOrigin = nil
        activeStrokeID = nil
        capturing = false
        hadInk = false
    }

    /// Esc steps back one layer at a time: blank screen, zoom, circled
    /// selection, and finally (in Capture mode, so it can never trap the user)
    /// FocusTrace itself.
    private func installEscapeMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.handleEscape() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) {
            escMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) {
            escMonitors.append(l)
        }
    }

    private func handleEscape() {
        if blank != nil { setBlank(nil) }
        else if zoom > 1 { resetZoom() }
        else if selectionGroup != nil || selectionUI.isVisible { selectionUI.hide(); dismissSelection() }
        else if capturing { setEnabled(false) }
    }

    private func buildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = Self.overlayLevel
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            let host = NSHostingView(rootView: FocusTraceOverlay(model: model, screenFrame: screen.frame))
            host.frame = CGRect(origin: .zero, size: screen.frame.size)
            panel.contentView = host
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            return panel
        }
        applyCapture(shouldCapture(option: NSEvent.modifierFlags.contains(.option)), force: true)
    }

    // MARK: Hotkeys

    private func handleHotkey(_ id: String) {
        switch id {
        case Self.blackID: setBlank(blank == .black ? nil : .black)
        case Self.whiteID: setBlank(blank == .white ? nil : .white)
        case Self.undoID: undo()
        case Self.clearID: clearInk()
        default: break
        }
    }

    /// Blank shortcuts are live while FocusTrace is on. Undo (⌘Z, ⌃Z, ⌫) and
    /// clear (⌘⌫) only while persistent ink is actually on screen, so those
    /// keys aren't stolen from other apps otherwise.
    private func updateHotkeys(settings s: AppSettings) {
        var actions: [(id: String, hotkey: Hotkey)] = []
        if let b = s.focusTraceBlackHotkey { actions.append((Self.blackID, b)) }
        if let w = s.focusTraceWhiteHotkey { actions.append((Self.whiteID, w)) }
        if hasInk {
            let cmd = UInt32(Hotkey.cmdKeyMask), ctrl = UInt32(Hotkey.controlKeyMask)
            actions.append((Self.undoID, Hotkey(keyCode: 6, modifiers: cmd)))
            actions.append((Self.undoID, Hotkey(keyCode: 6, modifiers: ctrl)))
            actions.append((Self.undoID, Hotkey(keyCode: 51, modifiers: 0)))
            actions.append((Self.clearID, Hotkey(keyCode: 51, modifiers: cmd)))
        }
        let signature = actions.map { "\($0.id):\($0.hotkey.keyCode):\($0.hotkey.modifiers)" }.joined(separator: ",")
        guard signature != hotkeySignature else { return }
        hotkeySignature = signature
        hotkeys.registerActions(actions)
    }

    /// Whether anything that doesn't fade by itself is on screen.
    private var hasInk: Bool { model.strokes.contains(where: isInk) }

    private func isInk(_ s: TraceStroke) -> Bool {
        s.fadingFrom == nil && (s.pinned || s.permanent || model.config.persistentInk)
    }

    // MARK: Ink

    private func undo() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let group = model.strokes.last(where: isInk)?.group else { return }
        for i in model.strokes.indices where model.strokes[i].group == group {
            model.strokes[i].fadingFrom = now
        }
        if group == selectionGroup { selectionGroup = nil; selectionUI.hide() }
    }

    private func clearInk() {
        let now = ProcessInfo.processInfo.systemUptime
        for i in model.strokes.indices where model.strokes[i].fadingFrom == nil {
            model.strokes[i].fadingFrom = now
        }
        selectionGroup = nil
        selectionUI.hide()
    }

    fileprivate func replaceSelection(now: TimeInterval) {
        guard let old = selectionGroup else { return }
        selectionGroup = nil
        // With persistent ink, earlier shapes stay; only the ✕ / ✨ buttons move.
        guard !model.config.persistentInk else { return }
        for j in model.strokes.indices where model.strokes[j].group == old && !model.strokes[j].permanent {
            model.strokes[j].fadingFrom = now
        }
        selectionGroup = nil
    }

    private func dismissSelection() {
        guard let group = selectionGroup else { return }
        selectionGroup = nil
        let now = ProcessInfo.processInfo.systemUptime
        for i in model.strokes.indices where model.strokes[i].group == group {
            model.strokes[i].fadingFrom = now
        }
    }

    // MARK: Blank screen

    /// Covers every screen in black or white. Sits just below the trace, so it
    /// doubles as a blackboard / whiteboard.
    private func setBlank(_ mode: FocusTraceBlank?) {
        let old = blankPanels
        blankPanels = []
        for p in old {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        blank = mode
        guard let mode else { return }
        blankPanels = Self.blankScreens(SettingsStore.shared.settings.focusTraceBlankTarget).map { screen in
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = mode == .black ? .black : .white
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Self.overlayLevel.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            // Swallow clicks so nothing hidden underneath gets activated.
            panel.ignoresMouseEvents = false
            panel.alphaValue = 0
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 1
            }
            return panel
        }
    }

    private static func blankScreens(_ target: String) -> [NSScreen] {
        let all = NSScreen.screens
        switch target {
        case "all":
            return all
        case "pointer":
            let p = NSEvent.mouseLocation
            return [all.first { $0.frame.contains(p) } ?? NSScreen.main ?? all[0]]
        default:
            // A display that's no longer connected falls back to all screens.
            let named = all.filter { $0.localizedName == target }
            return named.isEmpty ? all : named
        }
    }

    // MARK: Magnifier

    private func updateTap() {
        if model.config.magnifier { installTap() } else { removeTap() }
    }

    private func installTap() {
        guard tap == nil else { return }
        // NSEventTypeGesture (29) and NSEventTypeMagnify (30).
        let mask: CGEventMask = (1 << 29) | (1 << 30)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: focusTraceTapCallback, userInfo: info) else {
            Diag.log("FocusTrace: couldn't create the pinch event tap (Accessibility permission?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true if the pinch was used for the magnifier (and should be
    /// hidden from the app under the cursor).
    fileprivate func handleMagnify(_ magnification: CGFloat) -> Bool {
        guard isEnabled, model.config.magnifier else { return false }
        guard ScreenCapture.hasPermission else {
            if !askedCapturePermission {
                askedCapturePermission = true
                ScreenCapture.requestPermission()
            }
            return false
        }
        zoom = min(8, max(1, zoom * (1 + magnification)))
        if zoom < 1.03 { zoom = 1 }
        return true
    }

    private func resetZoom() {
        zoom = 1
        updateLens()
    }

    private func updateLens() {
        guard zoom > 1,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(model.cursor) }),
              let id = ScreenCapture.displayID(of: screen) else {
            if mirror.displayID != nil { mirror.stop() }
            mirrorSurface = nil
            lens?.hide()
            if model.lensVisible { model.lensVisible = false }
            return
        }
        if mirror.displayID != id {
            mirrorSurface = nil
            mirrorFrame = screen.frame
            mirror.start(displayID: id)
        }
        guard let surface = mirrorSurface else { return }
        let lens = self.lens ?? MagnifierLens(level: NSWindow.Level(rawValue: Self.overlayLevel.rawValue + 1))
        self.lens = lens
        lens.update(cursor: model.cursor, zoom: zoom, size: model.config.magnifierSize,
                    surface: surface, displayFrame: mirrorFrame,
                    tint: NSColor(hex: SettingsStore.shared.settings.focusTraceColorHex) ?? .systemPink)
        if !model.lensVisible { model.lensVisible = true }
    }

    // MARK: Sampling

    private func shouldCapture(option: Bool) -> Bool {
        switch model.config.mode {
        case .passThrough: return false
        case .capture: return true
        case .modifier: return option
        }
    }

    private func applyCapture(_ capture: Bool, force: Bool = false) {
        guard force || capture != capturing else { return }
        capturing = capture
        panels.forEach { $0.ignoresMouseEvents = !capture }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let location = NSEvent.mouseLocation
        let flags = NSEvent.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let buttons = NSEvent.pressedMouseButtons
        let leftDown = buttons & 1 != 0
        let rightDown = buttons & 2 != 0
        let cfg = model.config
        if model.cursor != location { model.cursor = location }
        applyCapture(shouldCapture(option: option))

        if cfg.ripples {
            if leftDown && !wasLeftDown { model.ripples.append(ClickRipple(location: location, time: now, secondary: false)) }
            if rightDown && !wasRightDown { model.ripples.append(ClickRipple(location: location, time: now, secondary: true)) }
        }
        wasLeftDown = leftDown
        wasRightDown = rightDown
        if !model.ripples.isEmpty {
            if model.ripples.contains(where: { now - $0.time > FocusTraceModel.rippleDuration }) {
                model.ripples.removeAll { now - $0.time > FocusTraceModel.rippleDuration }
            }
        }

        let draw = leftDown && (cfg.mode != .modifier || option)
        if draw && !wasDrawing {
            // Defer the stroke until the pointer actually moves, so a plain
            // click doesn't leave a dot.
            pendingOrigin = FocusTracePoint(location: location, time: now)
            activeStrokeID = nil
        }
        if draw, let origin = pendingOrigin {
            if hypot(origin.location.x - location.x, origin.location.y - location.y) >= 4 {
                let stroke = TraceStroke(
                    id: nextStrokeID, group: nextGroup,
                    points: [FocusTracePoint(location: origin.location, time: now),
                             FocusTracePoint(location: location, time: now)],
                    raw: [origin.location, location])
                nextStrokeID += 1
                nextGroup += 1
                model.strokes.append(stroke)
                activeStrokeID = stroke.id
                pendingOrigin = nil
            }
        } else if draw, let i = activeIndex {
            var s = model.strokes[i]
            // ⌥ while drawing makes the stroke permanent (except in Hold-⌥
            // mode, where ⌥ is what draws, and ⇧⌥, which draws a box).
            if option && !shift && cfg.mode != .modifier && !s.permanent {
                s.permanent = true
            }
            if cfg.snapShapes && ((shift && option && !s.isArrow) || s.isBox) {
                let start = s.raw.first ?? location
                s.isBox = true
                let rect = CGRect(x: min(start.x, location.x), y: min(start.y, location.y),
                                  width: abs(location.x - start.x), height: abs(location.y - start.y))
                s.points = ShapeSnapper.rectangle(rect).map { FocusTracePoint(location: $0, time: now) }
                s.raw = [start, location]
            } else if cfg.snapShapes && (shift || s.isArrow) {
                // ⇧-drag: a straight arrow from the press point.
                let start = s.raw.first ?? location
                s.isArrow = true
                s.points = [FocusTracePoint(location: start, time: now), FocusTracePoint(location: location, time: now)]
                s.raw = [start, location]
            } else if let last = s.points.last,
                      hypot(last.location.x - location.x, last.location.y - location.y) < 1.5 {
                // Holding still keeps the head of the trace alive.
                s.points[s.points.count - 1].time = now
            } else {
                s.points.append(FocusTracePoint(location: location, time: now))
                // Only needed for shape snapping; a very long scribble won't be
                // a circle anyway, so stop growing it.
                if s.raw.count < Self.maxRawPoints { s.raw.append(location) }
            }
            model.strokes[i] = s
        }
        if !draw && wasDrawing, let i = activeIndex {
            finishStroke(at: i, now: now)
            // The raw path is only used for snapping; drop it once finished.
            if i < model.strokes.count { model.strokes[i].raw = [] }
        }
        if !draw {
            pendingOrigin = nil
            activeStrokeID = nil
        }
        if model.drawing != draw { model.drawing = draw }
        wasDrawing = draw

        prune(now: now)
        let persistent = cfg.persistentInk
        let animating = draw || !model.ripples.isEmpty || model.strokes.contains {
            $0.fadingFrom != nil || !($0.pinned || $0.permanent || persistent)
        }
        if model.animating != animating { model.animating = animating }
        let ink = hasInk
        if ink != hadInk {
            hadInk = ink
            updateHotkeys(settings: SettingsStore.shared.settings)
        }
        updateLens()
    }

    private var activeIndex: Int? {
        guard let id = activeStrokeID else { return nil }
        return model.strokes.lastIndex { $0.id == id }
    }

    private func prune(now: TimeInterval) {
        let cutoff = now - model.config.fade
        let persistent = model.config.persistentInk
        let needs = model.strokes.contains { s in
            if let f = s.fadingFrom { return now - f > FocusTraceModel.removeFade }
            return !s.pinned && !s.permanent && !persistent && (s.points.first?.time ?? now) < cutoff
        }
        guard needs else { return }
        model.strokes = model.strokes.compactMap { s in
            if let f = s.fadingFrom { return now - f > FocusTraceModel.removeFade ? nil : s }
            if s.pinned || s.permanent || persistent { return s }
            var kept = s
            kept.points = Array(s.points.drop { $0.time < cutoff })
            // Keep the active stroke alive so its raw path can still snap.
            return kept.points.isEmpty && s.id != activeStrokeID ? nil : kept
        }
    }

    // MARK: Shapes

    private func finishStroke(at i: Int, now: TimeInterval) {
        guard model.config.snapShapes else { return }
        var s = model.strokes[i]
        let w = model.config.lineWidth
        if s.isBox {
            guard let a = s.raw.first, let b = s.raw.last, abs(b.x - a.x) > 20, abs(b.y - a.y) > 20 else { return }
            let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            pinSelection(at: i, points: ShapeSnapper.rectangle(box), bounds: box, now: now)
            return
        }
        if s.isArrow {
            guard let a = s.raw.first, let b = s.raw.last, hypot(b.x - a.x, b.y - a.y) > 12 else { return }
            let angle = atan2(b.y - a.y, b.x - a.x)
            let len = max(20, w * 2.8)
            let spread = CGFloat.pi * 30 / 180
            let left = CGPoint(x: b.x - len * cos(angle + spread), y: b.y - len * sin(angle + spread))
            let right = CGPoint(x: b.x - len * cos(angle - spread), y: b.y - len * sin(angle - spread))
            // One chevron stroke, so the tip gets a smooth round join.
            let head = [left, b, right]
            model.strokes.append(TraceStroke(
                id: nextStrokeID, group: s.group,
                points: head.map { FocusTracePoint(location: $0, time: now) }, raw: head,
                permanent: s.permanent))
            nextStrokeID += 1
            return
        }
        if let (shape, bounds) = ShapeSnapper.closedShape(s.raw) {
            pinSelection(at: i, points: shape, bounds: bounds, now: now)
        }
    }
}

extension FocusTrace {
    /// Pins a finished shape as the current selection (replacing any previous
    /// one) and shows its ✕ / ✨ buttons.
    fileprivate func pinSelection(at i: Int, points: [CGPoint], bounds: CGRect, now: TimeInterval) {
        replaceSelection(now: now)
        model.strokes[i].points = points.map { FocusTracePoint(location: $0, time: now) }
        model.strokes[i].pinned = true
        selectionGroup = model.strokes[i].group
        selectionUI.show(for: bounds)
    }
}

/// Recognizes hand-drawn circles and rectangles.
enum ShapeSnapper {
    /// A closed loop becomes a clean ellipse or rectangle. Returns its points
    /// and bounding box.
    static func closedShape(_ pts: [CGPoint]) -> ([CGPoint], CGRect)? {
        guard pts.count >= 8, let first = pts.first else { return nil }
        let length = pathLength(pts)
        let box = robustBounds(pts)
        guard box.width > 30, box.height > 30, length > 2.2 * max(box.width, box.height) else { return nil }
        // The loop is closed if the tail comes back near the start (overshoot is fine).
        let tail = pts[(pts.count * 6 / 10)...]
        let gap = tail.map { hypot($0.x - first.x, $0.y - first.y) }.min() ?? .infinity
        guard gap < max(28, 0.25 * min(box.width, box.height)) else { return nil }

        // Pick whichever ideal shape the stroke hugs more closely. Boxes get a
        // slight edge, since hand-drawn corners are always a bit rounded.
        let (rectErr, ellipseErr) = fitErrors(pts, box)
        return (rectErr < ellipseErr * 1.15 ? rectangle(box) : ellipse(box), box)
    }

    /// Mean distance from the points to the box's edges and to its inscribed ellipse.
    private static func fitErrors(_ pts: [CGPoint], _ box: CGRect) -> (CGFloat, CGFloat) {
        let cx = box.midX, cy = box.midY, a = box.width / 2, b = box.height / 2
        var rect: CGFloat = 0, ell: CGFloat = 0
        for p in pts {
            let dx = abs(p.x - cx), dy = abs(p.y - cy)
            if dx <= a && dy <= b {
                rect += min(a - dx, b - dy)
            } else {
                rect += hypot(max(dx - a, 0), max(dy - b, 0))
            }
            let nx = dx / a, ny = dy / b
            let r = (nx * nx + ny * ny).squareRoot()
            let d = hypot(dx, dy)
            ell += r > 0 ? abs(r - 1) * d / r : min(a, b)
        }
        let n = CGFloat(pts.count)
        return (rect / n, ell / n)
    }

    /// Bounding box ignoring the outermost few percent of points, so an
    /// overshooting tail doesn't inflate the shape.
    private static func robustBounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x).sorted(), ys = pts.map(\.y).sorted()
        let k = Int(Double(pts.count) * 0.02)
        let lo = k, hi = pts.count - 1 - k
        return CGRect(x: xs[lo], y: ys[lo], width: xs[hi] - xs[lo], height: ys[hi] - ys[lo])
    }


    private static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    private static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private static func ellipse(_ r: CGRect) -> [CGPoint] {
        (0...96).map { k in
            let t = CGFloat(k) / 96 * 2 * .pi + .pi / 2
            return CGPoint(x: r.midX + r.width / 2 * cos(t), y: r.midY + r.height / 2 * sin(t))
        }
    }

    /// Densified so the chunked renderer never splits exactly at a corner.
    static func rectangle(_ r: CGRect) -> [CGPoint] {
        let corners = [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                       CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.minY),
                       CGPoint(x: r.minX, y: r.maxY)]
        var out: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            for k in 0..<24 {
                let t = CGFloat(k) / 24
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        out.append(corners[4])
        return out
    }
}

/// Event-tap callback for trackpad pinches. Runs on the main run loop.
private func focusTraceTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let trace = Unmanaged<FocusTrace>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { trace.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    guard let ns = NSEvent(cgEvent: event), ns.type == .magnify else { return Unmanaged.passUnretained(event) }
    let consumed = MainActor.assumeIsolated { trace.handleMagnify(ns.magnification) }
    return consumed ? nil : Unmanaged.passUnretained(event)
}

/// A round, glass-rimmed lens showing the live screen magnified around the
/// cursor. The crop happens on the GPU via `contentsRect`.
@MainActor
final class MagnifierLens {
    private let panel: NSPanel
    private let content = CALayer()
    private let rim = CALayer()

    init(level: NSWindow.Level) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let view = NSView()
        view.wantsLayer = true
        let root = view.layer!
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = 0.35
        root.shadowRadius = 14
        root.shadowOffset = CGSize(width: 0, height: -4)
        content.masksToBounds = true
        content.contentsGravity = .resize
        content.backgroundColor = NSColor.windowBackgroundColor.cgColor
        rim.borderWidth = 3
        root.addSublayer(content)
        root.addSublayer(rim)
        panel.contentView = view
    }

    func update(cursor: CGPoint, zoom: CGFloat, size: CGFloat, surface: IOSurface,
                displayFrame: CGRect, tint: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = CGRect(x: cursor.x - size / 2, y: cursor.y - size / 2, width: size, height: size)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        content.frame = bounds
        rim.frame = bounds
        content.cornerRadius = size / 2
        rim.cornerRadius = size / 2
        rim.borderColor = tint.withAlphaComponent(0.85).cgColor
        panel.contentView?.layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        content.contents = surface
        let region = size / zoom
        content.contentsRect = CGRect(
            x: (cursor.x - displayFrame.minX - region / 2) / displayFrame.width,
            y: (displayFrame.maxY - cursor.y - region / 2) / displayFrame.height,
            width: region / displayFrame.width,
            height: region / displayFrame.height)
        CATransaction.commit()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }
}

// MARK: - Overlay

private struct FocusTraceOverlay: View {
    let model: FocusTraceModel
    let screenFrame: CGRect

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !model.animating)) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let cfg = model.config
            let cursor = local(model.cursor)
            let onScreen = screenFrame.insetBy(dx: -160, dy: -160).contains(model.cursor)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    if cfg.spotlight { drawSpotlight(&ctx, size: size, cursor: cursor, onScreen: onScreen, cfg: cfg) }
                    drawTrace(&ctx, now: now, cfg: cfg)
                    drawRipples(&ctx, now: now, cfg: cfg)
                }
                if onScreen && !model.lensVisible {
                    if cfg.showHalo {
                        FocusHalo(config: cfg, pressed: model.drawing).position(cursor)
                    }
                    if cfg.cursorScale > 1.05 || cfg.cursorShape != .system {
                        BigCursor(config: cfg, at: cursor)
                    }
                }
            }
            .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Global Cocoa (bottom-left origin) → this screen's top-left view space.
    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - screenFrame.minX, y: screenFrame.maxY - p.y)
    }

    // MARK: Spotlight & ripples

    /// Dims the screen except for a soft-edged circle around the cursor.
    private func drawSpotlight(_ ctx: inout GraphicsContext, size: CGSize, cursor: CGPoint,
                               onScreen: Bool, cfg: FocusTraceConfig) {
        ctx.drawLayer { g in
            g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(cfg.spotlightDim)))
            guard onScreen else { return }
            let r = cfg.spotlightRadius
            g.blendMode = .destinationOut
            g.fill(Path(ellipseIn: CGRect(x: cursor.x - r, y: cursor.y - r, width: 2 * r, height: 2 * r)),
                   with: .radialGradient(Gradient(stops: [.init(color: .black, location: 0),
                                                          .init(color: .black, location: 0.8),
                                                          .init(color: .clear, location: 1)]),
                                         center: cursor, startRadius: 0, endRadius: r))
        }
    }

    private func drawRipples(_ ctx: inout GraphicsContext, now: TimeInterval, cfg: FocusTraceConfig) {
        for ripple in model.ripples {
            let t = min(1, max(0, (now - ripple.time) / FocusTraceModel.rippleDuration))
            let ease = 1 - pow(1 - t, 3)
            let r = cfg.rippleSize * (0.17 + 0.83 * ease)
            let c = local(ripple.location)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            let tint = ripple.secondary ? Color.orange : (cfg.multicolor ? Color(hue: (ripple.time * 0.35).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 1) : Color(nsColor: cfg.color))
            ctx.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.18 * (1 - t))))
            ctx.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(0.9 * (1 - t))), lineWidth: 1 + 3 * (1 - t))
            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 2, dy: 2)), with: .color(.white.opacity(0.5 * (1 - t))), lineWidth: 1)
        }
    }

    // MARK: Trace

    /// Draws each stroke as a translucent glass tube: a soft tinted glow, a
    /// translucent body, and a bright specular core. The tail tapers and fades.
    private func drawTrace(_ ctx: inout GraphicsContext, now: TimeInterval, cfg: FocusTraceConfig) {
        let w = cfg.lineWidth
        for stroke in model.strokes where !stroke.points.isEmpty {
            let pts = stroke.points.map { local($0.location) }
            let alphas = stroke.points.map { model.alpha($0, in: stroke, now: now) }
            let colors = stroke.points.map { color(for: $0.time, cfg: cfg) }
            let chunks = chunked(pts.count)

            // 1. Tinted glow, blurred once for the whole stroke.
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: w * 0.9))
                for r in chunks {
                    let a = alphas[r.upperBound]
                    g.stroke(path(pts, r), with: .color(colors[r.upperBound].opacity(0.55 * a)),
                             style: StrokeStyle(lineWidth: w * 2.1 * taper(a), lineCap: .round, lineJoin: .round))
                }
            }
            // 2. Frosted rim + translucent body.
            for r in chunks {
                let a = alphas[r.upperBound]
                let p = path(pts, r)
                let width = w * taper(a)
                ctx.stroke(p, with: .color(.white.opacity(0.28 * a)),
                           style: StrokeStyle(lineWidth: width + 2, lineCap: .butt, lineJoin: .round))
                ctx.stroke(p, with: .color(colors[r.upperBound].opacity(0.72 * a)),
                           style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .round))
            }
            // 3. Specular highlight, offset up-left like light on glass.
            var hl = ctx
            hl.translateBy(x: -w * 0.1, y: -w * 0.16)
            for r in chunks {
                let a = alphas[r.upperBound]
                hl.stroke(path(pts, r), with: .color(.white.opacity(0.7 * a)),
                          style: StrokeStyle(lineWidth: max(1, w * 0.28 * taper(a)), lineCap: .butt, lineJoin: .round))
            }
            // Rounded head and tail caps.
            for idx in Set([0, pts.count - 1]) {
                let a = alphas[idx]
                let d = w * taper(a)
                let rect = CGRect(x: pts[idx].x - d / 2, y: pts[idx].y - d / 2, width: d, height: d)
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(.white.opacity(0.28 * a)))
                ctx.fill(Path(ellipseIn: rect), with: .color(colors[idx].opacity(0.72 * a)))
            }
        }
    }

    /// Splits a stroke into ~24 contiguous index ranges (sharing endpoints), so
    /// each range can be stroked once with its own opacity without the
    /// overlapping-cap "beads" per-segment strokes would produce.
    private func chunked(_ count: Int) -> [ClosedRange<Int>] {
        guard count > 1 else { return [] }
        let step = max(2, (count - 1) / 24)
        var out: [ClosedRange<Int>] = []
        var start = 0
        while start < count - 1 {
            let end = min(count - 1, start + step)
            out.append(start...end)
            start = end
        }
        return out
    }

    private func path(_ pts: [CGPoint], _ r: ClosedRange<Int>) -> Path {
        var p = Path()
        p.move(to: pts[r.lowerBound])
        for i in (r.lowerBound + 1)...r.upperBound { p.addLine(to: pts[i]) }
        return p
    }

    private func taper(_ alpha: Double) -> CGFloat { CGFloat(0.35 + 0.65 * alpha) }

    private func color(for time: TimeInterval, cfg: FocusTraceConfig) -> Color {
        guard cfg.multicolor else { return Color(nsColor: cfg.color) }
        let hue = (time * 0.35).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.75, brightness: 1)
    }
}

/// A liquid-glass lens that follows the cursor. Shrinks slightly while drawing.
private struct FocusHalo: View {
    let config: FocusTraceConfig
    let pressed: Bool

    var body: some View {
        let d = 22 * config.cursorScale + 18
        let tint = Color(nsColor: config.color)
        let rim = config.multicolor
            ? AngularGradient(colors: [.pink, .purple, .blue, .cyan, .green, .yellow, .orange, .pink], center: .center)
            : AngularGradient(colors: [tint, tint.opacity(0.5), tint], center: .center)
        glass(Circle().fill(Color.clear), tint: tint)
            .frame(width: d, height: d)
            .overlay(Circle().strokeBorder(rim, lineWidth: 2).opacity(0.85))
            .overlay(
                Circle()
                    .trim(from: 0.55, to: 0.8)
                    .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(4)
            )
            .shadow(color: tint.opacity(0.35), radius: 10)
            .scaleEffect(pressed ? 0.82 : 1)
    }

    @ViewBuilder private func glass<V: View>(_ v: V, tint: Color) -> some View {
        if #available(macOS 26.0, *) {
            v.glassEffect(.clear.tint(tint.opacity(0.14)), in: Circle())
        } else {
            v.background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().fill(tint.opacity(0.1)))
        }
    }
}

/// The system arrow, magnified with its hotspot pinned to the pointer.
private struct BigCursor: View {
    let config: FocusTraceConfig
    let at: CGPoint

    var body: some View {
        let k = config.cursorScale
        let fill = Color(nsColor: config.cursorColor)
        let edge = Self.outline(for: config.cursorColor)
        let glow = Color(nsColor: config.cursorColor).opacity(0.45)
        switch config.cursorShape {
        case .system:
            systemArrow(k: k)
        case .arrow:
            // Classic arrow outline, tip at (0, 0), in 1× cursor points.
            let w: CGFloat = 13 * k, h: CGFloat = 21 * k
            ArrowShape()
                .fill(fill)
                .overlay(ArrowShape().stroke(edge, style: StrokeStyle(lineWidth: max(1.2, 0.9 * k), lineJoin: .round)))
                .frame(width: w, height: h)
                .shadow(color: glow, radius: 6)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .position(x: at.x + w / 2, y: at.y + h / 2)
        case .hand:
            let d = 24 * k
            ZStack {
                Image(systemName: "hand.point.up.left.fill").resizable().scaledToFit()
                    .foregroundStyle(edge).blur(radius: 0.5).scaleEffect(1.1)
                Image(systemName: "hand.point.up.left.fill").resizable().scaledToFit()
                    .foregroundStyle(fill)
            }
            .frame(width: d, height: d)
            .shadow(color: glow, radius: 6)
            // The fingertip sits near the symbol's top-left corner.
            .position(x: at.x + d * 0.36, y: at.y + d * 0.42)
        case .dot:
            let d = 10 * k
            Circle().fill(fill)
                .overlay(Circle().stroke(edge, lineWidth: max(1.2, 0.6 * k)))
                .frame(width: d, height: d)
                .shadow(color: glow, radius: 8)
                .position(at)
        case .ring:
            let d = 16 * k
            Circle().stroke(fill, lineWidth: max(2, 1.4 * k))
                .overlay(Circle().stroke(edge.opacity(0.7), lineWidth: 1).padding(-max(1, 0.7 * k)))
                .frame(width: d, height: d)
                .shadow(color: glow, radius: 8)
                .position(at)
        case .crosshair:
            let d = 22 * k
            ZStack {
                CrosshairShape().stroke(edge, style: StrokeStyle(lineWidth: max(3, 1.6 * k), lineCap: .round))
                CrosshairShape().stroke(fill, style: StrokeStyle(lineWidth: max(1.6, 0.9 * k), lineCap: .round))
            }
            .frame(width: d, height: d)
            .shadow(color: glow, radius: 6)
            .position(at)
        }
    }

    /// The macOS arrow image, with its hotspot pinned to the pointer.
    private func systemArrow(k: CGFloat) -> some View {
        let cursor = NSCursor.arrow
        let img = cursor.image
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        let hot = cursor.hotSpot
        let center = CGPoint(x: at.x + (img.size.width / 2 - hot.x) * k,
                             y: at.y + (img.size.height / 2 - hot.y) * k)
        return Image(nsImage: img)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .shadow(color: Color(nsColor: config.color).opacity(0.45), radius: 6)
            .position(center)
    }

    /// White edge on dark fills, dark edge on light ones.
    private static func outline(for color: NSColor) -> Color {
        let c = color.usingColorSpace(.sRGB) ?? color
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.65 ? Color.black.opacity(0.8) : .white
    }
}

private struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        // Normalized from a 13 × 21 arrow.
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4, 13.2), (6.8, 20), (9.4, 18.9), (6.7, 12.3), (12, 12.3)]
        var p = Path()
        for (n, (x, y)) in pts.enumerated() {
            let q = CGPoint(x: r.minX + x / 13 * r.width, y: r.minY + y / 21 * r.height)
            if n == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }
}

private struct CrosshairShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), gap = r.width * 0.16
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: c.y)); p.addLine(to: CGPoint(x: c.x - gap, y: c.y))
        p.move(to: CGPoint(x: c.x + gap, y: c.y)); p.addLine(to: CGPoint(x: r.maxX, y: c.y))
        p.move(to: CGPoint(x: c.x, y: r.minY)); p.addLine(to: CGPoint(x: c.x, y: c.y - gap))
        p.move(to: CGPoint(x: c.x, y: c.y + gap)); p.addLine(to: CGPoint(x: c.x, y: r.maxY))
        return p
    }
}

// MARK: - Hex colors

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
