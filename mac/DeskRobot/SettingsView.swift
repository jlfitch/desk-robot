import SwiftUI
import AppKit

/// Settings for the brain (listening, voice, model, character) and the face.
/// Listening and voice sliders apply live; the rest is saved and applies on
/// Restart brain. Values come from the brain's /status (settings + ranges).
struct SettingsView: View {
    @ObservedObject var robot: Robot
    @State private var values: [String: Double] = [:]
    @State private var strings: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var ranges: [String: [Double]] = [:]
    @State private var loaded = false
    @State private var needsRestart = false
    @State private var note = ""

    private let liveKeys: Set<String> = ["VAD_THRESHOLD", "TURN_THRESHOLD", "TURN_MAX_SILENCE", "AWAKE_SECONDS", "TTS_LEVEL", "TTS_HIGHPASS_HZ", "TTS_PRESENCE_DB"]
    private let instantKeys: Set<String> = ["BARGE_IN", "BARGE_IN_MIN_SPEECH", "ADDRESSED_CHECK", "ADDRESSED_THRESHOLD"]
    private let voiceKeys: Set<String> = ["TTS_LEVEL", "TTS_HIGHPASS_HZ", "TTS_PRESENCE_DB"]

    var body: some View {
        Form {
            Section("Listening") {
                slider("VAD_THRESHOLD", "How loud counts as speech", lo: 0.1, hi: 0.9, help: "Lower hears softer voices and more noise.")
                slider("TURN_THRESHOLD", "How sure he must be that you're done", lo: 0.1, hi: 0.95, help: "Raise if he jumps in early; lower if he waits too long.")
                slider("TURN_MAX_SILENCE", "Longest pause he waits through (s)", lo: 0.5, hi: 6, help: "His patience limit when you trail off.")
                slider("AWAKE_SECONDS", "Stays awake after an exchange (s)", lo: 10, hi: 600, help: "No wake word needed while awake.")
                Toggle("Let me interrupt him while he talks", isOn: boolBinding("BARGE_IN"))
                slider("BARGE_IN_MIN_SPEECH", "How long you must talk to cut him off (s)", lo: 0.2, hi: 2, help: "Shorter cuts in faster; longer ignores coughs and echo.")
                Toggle("Check whether room talk is meant for him", isOn: boolBinding("ADDRESSED_CHECK"))
                slider("ADDRESSED_THRESHOLD", "How sure he must be it was for him", lo: 0.1, hi: 0.9, help: "Lower answers more; higher stays quiet more. The last judgment shows in the log.")
            }
            Section("Voice") {
                TextField("Built-in voice (when Fish Audio is off)", text: binding("TTS_FALLBACK_VOICE")).onSubmit { save("TTS_FALLBACK_VOICE", strings["TTS_FALLBACK_VOICE"] ?? "") }
                slider("TTS_LEVEL", "Loudness", lo: 0.02, hi: 0.4, help: "Held at this level; raise system volume for everyday loudness.")
                slider("TTS_HIGHPASS_HZ", "Bass cut (Hz)", lo: 0, hi: 400, help: "0 is off.")
                slider("TTS_PRESENCE_DB", "Presence (dB)", lo: 0, hi: 8, help: "Lifts a muffled voice.")
            }
            Section("Brain") {
                TextField("Name (wake word is \"hey <name>\")", text: binding("ROBOT_NAME")).onSubmit { save("ROBOT_NAME", strings["ROBOT_NAME"] ?? "") }
                Picker("Character", selection: pickerBinding("PERSONALITY")) {
                    Text("Helper").tag("helper"); Text("Rocky (Project Hail Mary)").tag("rocky")
                }
                Picker("Everyday model", selection: pickerBinding("CLAUDE_MODEL")) {
                    Text("Haiku (fast)").tag("haiku"); Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus")
                }
                Picker("Model for real work", selection: pickerBinding("CLAUDE_SMART_MODEL")) {
                    Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus"); Text("Haiku").tag("haiku")
                }
                Stepper("Spoken sentences per reply: \(Int(values["REPLY_MAX_SENTENCES"] ?? 4))", value: intBinding("REPLY_MAX_SENTENCES"), in: 1...12)
                Toggle("Write long answers into a fleeting note", isOn: boolBinding("NOTE_LONG_REPLIES"))
                Toggle("Listen on start", isOn: boolBinding("LISTEN_ON_START"))
                HStack {
                    if needsRestart { Text("Changes above apply after a restart.").foregroundStyle(.secondary).font(.caption) }
                    Spacer()
                    Button("Restart brain") { robot.brain.restart(); needsRestart = false }
                }
            }
            Section("Face") {
                Picker("Style", selection: Binding(get: { robot.faceStyle }, set: { robot.faceStyle = $0 })) { ForEach(FaceStyle.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Eye color", selection: Binding(get: { robot.eyeColor }, set: { robot.eyeColor = $0 })) { ForEach(EyeColor.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Size", selection: Binding(get: { Int((FacePanelController.shared?.scale ?? 2) * 10) }, set: { FacePanelController.shared?.scale = CGFloat($0) / 10 })) {
                    Text("Small").tag(15); Text("Medium").tag(20); Text("Large").tag(30)
                }
                Toggle("Ignore clicks while asleep", isOn: Binding(get: { robot.clickThroughAsleep }, set: { robot.clickThroughAsleep = $0 }))
            }
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .onAppear(perform: load)
        .onReceive(robot.$status) { _ in if !loaded { load() } }
    }

    // MARK: - plumbing

    private func load() {
        guard let st = robot.status, let settings = st.settings else { return }
        for (k, v) in settings {
            switch v {
            case .number(let d): values[k] = d
            case .string(let s): strings[k] = s
            case .bool(let b): bools[k] = b
            }
        }
        ranges = st.setting_ranges ?? [:]
        loaded = true
    }

    private func slider(_ key: String, _ label: String, lo: Double, hi: Double, help: String) -> some View {
        let r = ranges[key] ?? [lo, hi]
        return VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text(String(format: key == "AWAKE_SECONDS" ? "%.0f" : "%.2f", values[key] ?? lo)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { values[key] ?? lo }, set: { values[key] = $0 }), in: r[0]...r[1], onEditingChanged: { editing in
                if !editing { save(key, values[key] ?? lo) }
            })
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding(_ key: String) -> Binding<String> { Binding(get: { strings[key] ?? "" }, set: { strings[key] = $0 }) }
    private func pickerBinding(_ key: String) -> Binding<String> { Binding(get: { strings[key] ?? "" }, set: { strings[key] = $0; save(key, $0) }) }
    private func intBinding(_ key: String) -> Binding<Int> { Binding(get: { Int(values[key] ?? 0) }, set: { values[key] = Double($0); save(key, $0) }) }
    private func boolBinding(_ key: String) -> Binding<Bool> { Binding(get: { bools[key] ?? false }, set: { bools[key] = $0; save(key, $0) }) }

    private func save(_ key: String, _ value: Any) {
        Task {
            let ok: Bool
            if liveKeys.contains(key) {
                ok = await robot.client.control(voiceKeys.contains(key) ? "voice" : "tune", ["key": key, "value": value])
            } else {
                ok = await robot.client.control("setting", ["key": key, "value": value])
                if ok && !instantKeys.contains(key) { needsRestart = true }
            }
            note = ok ? "" : "Could not save \(key): is the brain running?"
        }
    }
}

/// A JSON value from /status.settings: number, string or bool.
enum SettingValue: Decodable {
    case number(Double), string(String), bool(Bool)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else { self = .string(try c.decode(String.self)) }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Desk Robot Settings"
            w.contentView = NSHostingView(rootView: SettingsView(robot: Robot.shared))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
