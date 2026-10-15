import AppKit
import SwiftUI

/// A borderless, always-on-top, non-activating panel that sits in a screen
/// corner. It never steals focus from whatever you are working in; the
/// question field asks for key focus only when it is open.
final class FacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onDoubleClick: (() -> Void)?
    var onClick: (() -> Void)?
    /// Height of the speech bubble above the face (0 when hidden), plus its gap.
    var bubbleTop: CGFloat = 0
    /// Square at the top-left (in points from the content's top-left corner)
    /// where the menu button lives; clicks there go to the button, not the drag.
    var cornerButtonInset: CGFloat = 0
    /// Shows the robot's menu at a point in content-view coordinates.
    var onMenu: ((NSPoint) -> Void)?

    /// Press anywhere on the face and drag to move the panel; double-click opens
    /// the question box. Done here, under SwiftUI, so the drag always wins and
    /// works whether the robot is awake or asleep.
    override func sendEvent(_ event: NSEvent) {
        if let cv = contentView, event.type == .leftMouseDown || event.type == .rightMouseDown {
            let p = cv.convert(event.locationInWindow, from: nil)
            // NSHostingView is flipped (y grows downward); measure from the top either way.
            let yFromTop = cv.isFlipped ? p.y : cv.bounds.height - p.y
            let inBubble = bubbleTop > 0 && yFromTop < bubbleTop + 8
            let faceTop = yFromTop - bubbleTop
            let inButton = !inBubble && p.x < cornerButtonInset + 24 && faceTop < cornerButtonInset + 24
            if event.type == .rightMouseDown && !inBubble { onMenu?(p); return }
            if inButton {
                let below = bubbleTop + cornerButtonInset + 24
                onMenu?(NSPoint(x: cornerButtonInset, y: cv.isFlipped ? below : cv.bounds.height - below))
                return
            }
            if event.type == .leftMouseDown && !inBubble {
                if event.clickCount == 2 { onDoubleClick?(); return }
                onClick?()   // a click while he talks stops him
                performDrag(with: event)
                return
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class FacePanelController {
    static var shared: FacePanelController?
    static let posKey = "facePosition"
    static let scaleKey = "faceScale"
    /// Measured height of the speech bubble; the panel grows upward to fit it.
    var bubbleHeight: CGFloat = 0 {
        didSet { if bubbleHeight != oldValue { refit() } }
    }

    let panel: FacePanel
    private let robot: Robot
    private var observers: [Any] = []
    private var positioning = false

    var scale: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: Self.scaleKey) as? Double ?? 2.0) }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.scaleKey); panel.cornerButtonInset = PanelContent.buttonInset(scale: newValue); rebuild(keepCorner: true) }
    }

    /// The panel's size is computed, not measured: face + bezel + padding, plus
    /// the question row when it is open. Measuring a SwiftUI hosting view before
    /// layout gave a zero size and put the panel off-screen.
    var contentSize: NSSize {
        let w = CGFloat(FaceEngine.screenW) * scale + 4 * scale + 16
        var h = CGFloat(FaceEngine.screenH) * scale + 4 * scale + 16
        if bubbleHeight > 0 { h += bubbleHeight + PanelContent.bubbleGap }
        return NSSize(width: w, height: h)
    }

    init(robot: Robot) {
        self.robot = robot
        panel = FacePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 170),
                          styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                          backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false  // sendEvent handles dragging
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.onDoubleClick = { [weak robot] in robot?.askShown.toggle() }
        panel.onClick = { [weak robot] in if robot?.status?.speaking == true { robot?.stopTalking() } }
        panel.cornerButtonInset = PanelContent.buttonInset(scale: scale)
        panel.onMenu = { [weak self] point in
            guard let self, let cv = self.panel.contentView else { return }
            let menu = RobotMenu.shared.make()
            // Near the bottom of the screen there is no room below the face, so
            // anchor the last item at the click and let the menu grow upward.
            let screenMidY = (self.panel.screen ?? NSScreen.main)?.visibleFrame.midY ?? 0
            let anchor = self.panel.frame.midY < screenMidY ? menu.items.last : nil
            menu.popUp(positioning: anchor, at: point, in: cv)
        }
        rebuild(keepCorner: false)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, !self.positioning else { return }
            self.savePosition()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keepOnScreen()
        })
        Self.shared = self
    }

    private func rebuild(keepCorner: Bool) {
        let size = contentSize
        let host = NSHostingView(rootView: PanelContent(robot: robot, scale: scale))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let corner = NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
        panel.contentView = host
        positioning = true
        panel.setContentSize(size)
        if keepCorner {
            panel.setFrameOrigin(NSPoint(x: corner.x - size.width, y: corner.y))
            keepOnScreen()
        } else {
            restorePosition()
        }
        positioning = false
    }

    /// The bubble grows upward above the face: re-fit keeping the bottom-right corner.
    func refit() {
        panel.bubbleTop = bubbleHeight > 0 ? bubbleHeight + PanelContent.bubbleGap : 0
        let size = contentSize
        let old = panel.frame
        guard old.size != size else { return }
        positioning = true
        panel.setFrame(NSRect(x: old.maxX - size.width, y: old.minY, width: size.width, height: size.height), display: true, animate: false)
        keepOnScreen()
        positioning = false
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func focus() { panel.makeKeyAndOrderFront(nil) }

    private func savePosition() {
        let f = panel.frame
        UserDefaults.standard.set([Double(f.maxX), Double(f.minY)], forKey: Self.posKey)
    }

    /// Default home: bottom-right of the main screen, just above the Dock.
    private func restorePosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = contentSize
        let vis = screen.visibleFrame
        var origin = NSPoint(x: vis.maxX - size.width - 12, y: vis.minY + 12)
        if let saved = UserDefaults.standard.array(forKey: Self.posKey) as? [Double], saved.count == 2 {
            let candidate = NSPoint(x: saved[0] - Double(size.width), y: saved[1])
            let rect = NSRect(origin: candidate, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { origin = candidate }
        }
        panel.setFrameOrigin(origin)
        keepOnScreen()
    }

    private func keepOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        var f = panel.frame
        let vis = screen.visibleFrame
        f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
        if f.origin != panel.frame.origin { panel.setFrameOrigin(f.origin) }
    }
}
