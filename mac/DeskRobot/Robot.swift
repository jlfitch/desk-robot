import Foundation
import SwiftUI
import Combine

/// The app's one shared model: the face, the brain connection, the child process.
@MainActor
final class Robot: ObservableObject {
    static let shared = Robot()

    let face = FaceEngine()
    let client = BrainClient()
    let brain = BrainProcess()
    let link = RobotLink()
    let agents = AgentsWatcher()
    @Published var bodyConnected = false
    @Published var busyAgents = 0
    @Published var waitingAgents = 0

    @Published var status: BrainStatus?
    @Published var connected = false
    @Published var faceVisible = true
    @Published var askShown = false
    @Published var logLines: [String] = []
    @Published var lastHeard = ""
    @Published var lastSaid = ""
    @Published var listening = true
    /// Speech bubble above the face: what he's saying (or just said), what he heard, the typed box.
    @Published var saying = ""
    @Published var bubbleShown = false
    private var bubbleUntil = Date.distantPast
    @Published var lastHeardAt = Date.distantPast
    /// The question line is shown only while it is plausibly what he's answering.
    var heardIsRecent: Bool { Date().timeIntervalSince(lastHeardAt) < 90 }
    private var wasSpeaking = false

    @Published var faceStyle: FaceStyle = FaceStyle(rawValue: UserDefaults.standard.string(forKey: "faceStyle") ?? "") ?? .cozmoDots {
        didSet { UserDefaults.standard.set(faceStyle.rawValue, forKey: "faceStyle"); face.style = faceStyle }
    }
    @Published var eyeColor: EyeColor = EyeColor(rawValue: UserDefaults.standard.string(forKey: "eyeColor") ?? "") ?? .ice {
        didSet { UserDefaults.standard.set(eyeColor.rawValue, forKey: "eyeColor") }
    }

    static let clickThroughKey = "clickThroughAsleep"
    /// While asleep the panel lets clicks fall through to the window beneath,
    /// so a stray click never lands on the robot. The menu bar is the way in.
    var clickThroughAsleep: Bool {
        get { UserDefaults.standard.object(forKey: Self.clickThroughKey) as? Bool ?? false }  // off by default: dragging should always work
        set { UserDefaults.standard.set(newValue, forKey: Self.clickThroughKey); objectWillChange.send(); updateClickThrough() }
    }
    func updateClickThrough() {
        FacePanelController.shared?.panel.ignoresMouseEvents = clickThroughAsleep && isAsleep && connected && !askShown
    }

    static let runBrainKey = "runBrain"
    var runsBrain: Bool {
        get { UserDefaults.standard.object(forKey: Self.runBrainKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.runBrainKey); objectWillChange.send() }
    }

    private var lastEmotion = ""

    private init() {
        face.style = faceStyle
        brain.onLog = { [weak self] line in
            guard let self else { return }
            self.logLines.append(line)
            if self.logLines.count > 400 { self.logLines.removeFirst(self.logLines.count - 400) }
        }
    }

    func start() {
        if runsBrain { brain.start() }
        client.startPolling { [weak self] st in self?.apply(st) }
        link.tokenProvider = { [weak self] in self?.robotToken() }
        link.onConnected = { [weak self] on in self?.bodyConnected = on }
        link.onEmotion = { [weak self] e in if let em = Emotion(rawValue: e) { self?.lastEmotion = e; self?.face.setEmotion(em) } }
        link.onAsleep = { [weak self] on in self?.face.setAsleep(on) }
        link.onSpeaking = { [weak self] on in self?.face.setTalking(on); self?.speakingViaLink = on }
        link.onLevel = { [weak self] lvl in self?.face.externalLevel = lvl }
        link.onNote = { [weak self] note in self?.brain.note(note) }
        link.start()
        agents.onChange = { [weak self] b, w in self?.busyAgents = b; self?.waitingAgents = w }
        agents.start()
    }

    private var speakingViaLink = false

    /// ROBOT_TOKEN from server/.env, the same secret the brain checks.
    private func robotToken() -> String? {
        let url = brain.serverDir.appendingPathComponent(".env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("ROBOT_TOKEN=") {
            return String(line.dropFirst("ROBOT_TOKEN=".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    func shutdown() {
        client.stopPolling()
        link.stop()
        brain.stop()
    }

    private func apply(_ st: BrainStatus?) {
        status = st
        let wasConnected = connected
        connected = st != nil
        guard let st else {
            if wasConnected { face.setAsleep(true) }
            face.setTalking(false)
            face.hearing = false
            updateClickThrough()
            return
        }
        if !wasConnected { face.setAsleep(!(st.awake ?? false)) }
        if let e = st.emotion, e != lastEmotion, let em = Emotion(rawValue: e) {
            lastEmotion = e
            face.setEmotion(em)
        }
        face.setAsleep(!(st.awake ?? false))
        if !bodyConnected { face.setTalking(st.speaking ?? false) }  // when the app is the body it knows first-hand
        face.hearing = st.hearing ?? false
        listening = st.listening ?? false
        updateClickThrough()
        if let h = st.last_heard, !h.isEmpty, h != lastHeard { lastHeard = h; lastHeardAt = Date() }
        if let s = st.last_said, s != lastSaid { lastSaid = s }
        let speakingNow = st.speaking ?? false
        if let live = st.saying, !live.isEmpty { saying = live } else if !speakingNow, !lastSaid.isEmpty, saying.isEmpty { saying = lastSaid }
        if speakingNow { bubbleUntil = .distantFuture }
        if wasSpeaking && !speakingNow { bubbleUntil = Date().addingTimeInterval(8); if !lastSaid.isEmpty { saying = lastSaid } }
        wasSpeaking = speakingNow
        let shown = askShown || speakingNow || Date() < bubbleUntil
        if shown != bubbleShown { bubbleShown = shown }
    }

    // MARK: - Actions

    func ask(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lastHeard = t
        lastHeardAt = Date()
        saying = ""
        bubbleUntil = Date().addingTimeInterval(20)   // keep the bubble up while he thinks
        bubbleShown = true
        Task { await client.ask(t) }
    }

    func sleep(_ on: Bool) { Task { await client.sleep(on) } }
    func stopTalking() { Task { await client.control("stop") } }

    func toggleListening() {
        // `listen` is a console-only command; it needs the brain to be our child.
        brain.send("listen")
    }

    var isAsleep: Bool { !(status?.awake ?? false) }
}
