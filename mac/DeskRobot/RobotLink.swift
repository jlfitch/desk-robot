import Foundation
import AVFoundation

/// The app as the robot body: connects to the brain's WebSocket exactly as
/// the ESP32 would (docs/protocol.md), streams the microphone, plays replies,
/// and reports when playback is done. Head moves and camera are ignored.
@MainActor
final class RobotLink {
    private let audio = AudioIO()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession
    private var stateTimer: Timer?
    private var backoff: TimeInterval = 1
    private var stopping = false
    private(set) var connected = false
    private var currentEmotion = "neutral"

    var onConnected: ((Bool) -> Void)?
    var onEmotion: ((String) -> Void)?
    var onAsleep: ((Bool) -> Void)?
    var onSpeaking: ((Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onNote: ((String) -> Void)?
    var tokenProvider: () -> String? = { nil }

    init() {
        session = URLSession(configuration: .default)
        audio.onMicFrame = { [weak self] frame in
            var d = Data([0x01]); d.append(frame)
            self?.task?.send(.data(d)) { _ in }
        }
        audio.onLevel = { [weak self] lvl in DispatchQueue.main.async { self?.onLevel?(lvl) } }
        audio.onDiag = { [weak self] s in DispatchQueue.main.async { self?.onNote?(s) } }
        audio.onDrained = { [weak self] in
            DispatchQueue.main.async {
                self?.onSpeaking?(false)
                self?.sendJSON(["type": "speak_done"])
            }
        }
    }

    var aec: Bool { audio.aec }

    func start() {
        stopping = false
        // Ask for the microphone explicitly so the answer is visible in the log;
        // without it the engine runs and silently delivers zeros.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        onNote?("microphone permission: \(Self.describe(status))")
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    self.onNote?("microphone permission: \(ok ? "granted" : "denied")")
                    self.startEngineAndConnect()
                }
            }
        } else {
            startEngineAndConnect()
        }
    }

    private static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "granted"
        case .denied: return "denied (System Settings > Privacy & Security > Microphone > Desk Robot)"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    private func startEngineAndConnect() {
        do { try audio.start() } catch { onNote?("audio engine failed: \(error.localizedDescription)"); return }
        connect()
    }

    func stop() {
        stopping = true
        stateTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        audio.stop()
    }

    private func connect() {
        guard !stopping, let token = tokenProvider(), !token.isEmpty else {
            onNote?("no ROBOT_TOKEN in server/.env; the app cannot act as the robot")
            return
        }
        let t = session.webSocketTask(with: URL(string: "ws://127.0.0.1:8765")!)
        task = t
        t.resume()
        sendJSON(["type": "hello", "who": "desk-robot-mac", "fw": "mac-1.0", "token": token, "aec": audio.aec])
        receive()
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.sendJSON(["type": "state", "pan": 0, "emotion": self?.currentEmotion ?? "neutral"])
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.handleClosed(error.localizedDescription)
                case .success(let msg):
                    if !self.connected { self.connected = true; self.backoff = 1; self.onConnected?(true); self.onNote?("acting as the robot body (echo cancellation \(self.audio.aec ? "on" : "off"))") }
                    switch msg {
                    case .data(let d): self.handleBinary(d)
                    case .string(let s): self.handleText(s)
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func handleClosed(_ why: String) {
        if connected { onNote?("robot link closed: \(why)") }
        connected = false
        onConnected?(false)
        audio.micOn = false
        audio.stopSpeech()
        onSpeaking?(false)
        stateTimer?.invalidate()
        task = nil
        guard !stopping else { return }
        let wait = backoff
        backoff = min(10, backoff * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect() }
    }

    private func handleBinary(_ d: Data) {
        guard d.first == 0x01 else { return }
        audio.enqueue(d.dropFirst())
    }

    private func handleText(_ s: String) {
        guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "mic": audio.micOn = (obj["on"] as? Bool) ?? false
        case "speak_begin": audio.beginSpeech(); onSpeaking?(true)
        case "speak_end": audio.endSpeech()
        case "speak_stop": audio.stopSpeech(); onSpeaking?(false); sendJSON(["type": "speak_done"])
        case "volume": if let v = obj["level"] as? Double { audio.volume = Float(v) }
        case "emotion": if let n = obj["name"] as? String { currentEmotion = n; onEmotion?(n) }
        case "asleep": onAsleep?((obj["on"] as? Bool) ?? false)
        default: break   // pan, tilt, glance, stream: no head, no camera
        }
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }
}
