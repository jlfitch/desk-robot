import AppKit
import SwiftUI
import ServiceManagement

/// The robot's menu as an AppKit NSMenu, so it can pop up from the small
/// button on the face and from a right-click, inside a non-activating panel.
/// The menu bar item shows the same choices through MenuContent.
@MainActor
final class RobotMenu: NSObject {
    static let shared = RobotMenu()
    private var robot: Robot { Robot.shared }

    func make() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        m.addItem(.separator())
        m.addItem(item(robot.askShown ? "Hide question box" : "Ask by typing…", #selector(toggleAsk)))
        m.addItem(item("Stop talking", #selector(stopTalking), enabled: robot.status?.speaking == true))
        m.addItem(item(robot.isAsleep ? "Wake up" : "Go to sleep", #selector(toggleSleep), enabled: robot.connected))
        m.addItem(item(robot.listening ? "Stop listening" : "Start listening", #selector(toggleListening), enabled: robot.connected && robot.brain.isRunning))

        let style = NSMenu()
        for s in FaceStyle.allCases {
            let i = item(s.rawValue, #selector(pickStyle(_:))); i.representedObject = s.rawValue; i.state = s == robot.faceStyle ? .on : .off; style.addItem(i)
        }
        m.addItem(submenu("Face style", style))
        let color = NSMenu()
        for c in EyeColor.allCases {
            let i = item(c.rawValue, #selector(pickColor(_:))); i.representedObject = c.rawValue; i.state = c == robot.eyeColor ? .on : .off; color.addItem(i)
        }
        m.addItem(submenu("Eye color", color))
        let size = NSMenu()
        for (name, s) in [("Small", 15), ("Medium", 20), ("Large", 30)] {
            let i = item(name, #selector(pickSize(_:))); i.tag = s
            i.state = Int((FacePanelController.shared?.scale ?? 2) * 10) == s ? .on : .off
            size.addItem(i)
        }
        m.addItem(submenu("Face size", size))
        m.addItem(item(robot.faceVisible ? "Hide face" : "Show face", #selector(toggleFace)))
        let ct = item("Ignore clicks while asleep", #selector(toggleClickThrough)); ct.state = robot.clickThroughAsleep ? .on : .off
        m.addItem(ct)
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(showSettings)))
        m.addItem(item("Restart brain", #selector(restartBrain)))
        m.addItem(item("Open brain console in browser", #selector(openConsole)))
        m.addItem(item("Show log", #selector(showLog)))
        let li = item("Start at login", #selector(toggleLogin)); li.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(li)
        m.addItem(.separator())
        m.addItem(item("Quit Desk Robot", #selector(quit)))
        return m
    }

    var statusLine: String {
        guard robot.connected else { return robot.brain.isRunning ? "Brain is starting…" : "Brain is off" }
        if robot.status?.speaking == true { return "Talking" }
        if robot.status?.thinking == true { return "Thinking" }
        if !robot.listening { return "Not listening" }
        return robot.isAsleep ? "Asleep — say “hey \(RobotName.value)”" : "Awake and listening"
    }

    private func item(_ title: String, _ sel: Selector, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.isEnabled = enabled
        return i
    }
    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    @objc func toggleAsk() { robot.askShown.toggle() }
    @objc func toggleSleep() { robot.sleep(!robot.isAsleep) }
    @objc func stopTalking() { robot.stopTalking() }
    @objc func toggleListening() { robot.toggleListening() }
    @objc func pickStyle(_ sender: NSMenuItem) { if let r = sender.representedObject as? String, let s = FaceStyle(rawValue: r) { robot.faceStyle = s } }
    @objc func pickColor(_ sender: NSMenuItem) { if let r = sender.representedObject as? String, let c = EyeColor(rawValue: r) { robot.eyeColor = c } }
    @objc func pickSize(_ sender: NSMenuItem) { FacePanelController.shared?.scale = CGFloat(sender.tag) / 10 }
    @objc func toggleFace() { robot.faceVisible.toggle() }
    @objc func toggleClickThrough() { robot.clickThroughAsleep.toggle() }
    @objc func restartBrain() { robot.brain.restart() }
    @objc func openConsole() { NSWorkspace.shared.open(URL(string: "http://localhost:8766/")!) }
    @objc func showLog() { LogWindow.show() }
    @objc func showSettings() { SettingsWindow.show() }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { NSLog("login item: \(error)") }
        robot.objectWillChange.send()
    }
    @objc func quit() { NSApp.terminate(nil) }
}

/// The log in a plain window, openable from AppKit and SwiftUI alike.
@MainActor
enum LogWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Desk Robot Log"
            w.contentView = NSHostingView(rootView: LogView(robot: Robot.shared))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
