import Foundation

/// What the brain reports at http://127.0.0.1:8766/status (server/brain/eyes.py).
struct BrainStatus: Decodable {
    var emotion: String?
    var awake: Bool?
    var speaking: Bool?
    var thinking: Bool?
    var hearing: Bool?
    var listening: Bool?
    var level: Double?
    var speech_prob: Double?
    var last_heard: String?
    var last_said: String?
    var mic: String?
    var volume: Double?
    var body_aec: Bool?
    var saying: String?
    var settings: [String: SettingValue]?
    var setting_ranges: [String: [Double]]?
}

/// Talks to the brain's local console API: polls /status and posts controls.
final class BrainClient {
    var baseURL = URL(string: "http://127.0.0.1:8766")!
    private let session: URLSession
    private var pollTask: Task<Void, Never>?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        cfg.timeoutIntervalForResource = 3
        session = URLSession(configuration: cfg)
    }

    func startPolling(every seconds: Double = 0.1, _ handler: @escaping (BrainStatus?) -> Void) {
        pollTask?.cancel()
        pollTask = Task.detached { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                var st: BrainStatus? = nil
                do {
                    let (data, _) = try await self.session.data(from: self.baseURL.appendingPathComponent("status"))
                    st = try JSONDecoder().decode(BrainStatus.self, from: data)
                    failures = 0
                } catch {
                    failures += 1
                }
                let result = st
                await MainActor.run { handler(result) }
                // Back off while the brain is down so we don't spin.
                let wait = failures > 0 ? min(2.0, 0.5 * Double(failures)) : seconds
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    @discardableResult
    func control(_ action: String, _ payload: [String: Any] = [:]) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/\(action)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Rocky-Console")  // the brain refuses controls without it (anti-CSRF)
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func ask(_ text: String) async -> Bool { await control("ask", ["text": String(text.prefix(300))]) }
    func say(_ text: String) async -> Bool { await control("say", ["text": String(text.prefix(300))]) }
    func sleep(_ on: Bool) async -> Bool { await control("sleep", ["on": on]) }
    func emotion(_ name: String) async -> Bool { await control("emotion", ["name": name]) }
}
