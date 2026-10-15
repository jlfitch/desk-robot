import SwiftUI
import AppKit
import ServiceManagement

@main
struct DeskRobotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var robot = Robot.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(robot: robot)
        } label: {
            Image(systemName: robot.connected ? (robot.isAsleep ? "face.dashed" : "face.smiling") : "face.dashed.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panelController: FacePanelController?
    private var askObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let robot = Robot.shared
        panelController = FacePanelController(robot: robot)
        panelController?.show()
        robot.start()
        // An always-on helper should come back after a reboot: register once;
        // the menu's "Start at login" toggle owns it from then on.
        if !UserDefaults.standard.bool(forKey: "loginRegistered") {
            UserDefaults.standard.set(true, forKey: "loginRegistered")
            try? SMAppService.mainApp.register()
        }
        askObserver = robot.$askShown.combineLatest(robot.$faceVisible).sink { [weak self] shown, visible in
            DispatchQueue.main.async {
                guard let pc = self?.panelController else { return }
                if visible { pc.show() } else { pc.hide() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { pc.refit() }
                if shown { pc.focus() }
                Robot.shared.updateClickThrough()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Robot.shared.shutdown()
    }
}

import Combine

struct MenuContent: View {
    @ObservedObject var robot: Robot

    var body: some View {
        Text(statusLine).font(.caption)
        Divider()
        Button(robot.askShown ? "Hide question box" : "Ask by typing…") { robot.askShown.toggle() }
            .keyboardShortcut("k", modifiers: [.command, .option])
        Button(robot.isAsleep ? "Wake up" : "Go to sleep") { robot.sleep(!robot.isAsleep) }
            .disabled(!robot.connected)
        Button(robot.listening ? "Stop listening" : "Start listening") { robot.toggleListening() }
            .disabled(!robot.connected || !robot.brain.isRunning)
        Button(robot.faceVisible ? "Hide face" : "Show face") { robot.faceVisible.toggle() }
        Picker("Face style", selection: Binding(get: { robot.faceStyle }, set: { robot.faceStyle = $0 })) {
            ForEach(FaceStyle.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Eye color", selection: Binding(get: { robot.eyeColor }, set: { robot.eyeColor = $0 })) {
            ForEach(EyeColor.allCases) { Text($0.rawValue).tag($0) }
        }
        Menu("Face size") {
            ForEach([("Small", 1.5), ("Medium", 2.0), ("Large", 3.0)], id: \.1) { name, s in
                Button(name) { FacePanelController.shared?.scale = CGFloat(s) }
            }
        }
        Toggle("Ignore clicks while asleep", isOn: Binding(get: { robot.clickThroughAsleep }, set: { robot.clickThroughAsleep = $0 }))
        Divider()
        Button("Settings…") { SettingsWindow.show() }.keyboardShortcut(",")
        Button("Restart brain") { robot.brain.restart() }
        Button("Open brain console in browser") { NSWorkspace.shared.open(URL(string: "http://localhost:8766/")!) }
        Button("Show log") { LogWindow.show() }
        Toggle("Start at login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { NSLog("login item: \(error)") }
                robot.objectWillChange.send()
            }))
        Divider()
        Button("Quit Desk Robot") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusLine: String {
        guard robot.connected else { return robot.brain.isRunning ? "Brain is starting…" : "Brain is off" }
        if robot.status?.speaking == true { return "Talking" }
        if robot.status?.thinking == true { return "Thinking" }
        if !robot.listening { return "Not listening" }
        return robot.isAsleep ? "Asleep — say “hey \(RobotName.value)”" : "Awake and listening"
    }
}

struct LogView: View {
    @ObservedObject var robot: Robot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Heard: \(robot.lastHeard)").lineLimit(1)
                Spacer()
                Text("Said: \(robot.lastSaid)").lineLimit(1)
            }.font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(robot.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: robot.logLines.count) { _, n in proxy.scrollTo(max(0, n - 1)) }
            }
        }
        .padding(12)
    }
}
