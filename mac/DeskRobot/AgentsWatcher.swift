import Foundation

/// Counts Rocky's sub-agents (Claude Code sessions on this Mac) that are
/// working right now, so the face can show a small cue. Polls `claude agents
/// --json` every few seconds; Rocky's own brain session is not counted.
final class AgentsWatcher {
    private var timer: Timer?
    private let claude: String?
    private(set) var busy = 0
    private(set) var waiting = 0
    var onChange: ((Int, Int) -> Void)?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var found: String? = nil
        for cand in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude"] where FileManager.default.isExecutableFile(atPath: cand) { found = cand; break }
        if found == nil, let dirs = try? FileManager.default.contentsOfDirectory(atPath: home + "/.nvm/versions/node") {
            for d in dirs.sorted().reversed() {
                let c = home + "/.nvm/versions/node/\(d)/bin/claude"
                if FileManager.default.isExecutableFile(atPath: c) { found = c; break }
            }
        }
        claude = found
    }

    func start(every seconds: TimeInterval = 8) {
        timer?.invalidate()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard let claude else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = ["agents", "--json"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (claude as NSString).deletingLastPathComponent + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
            env.removeValue(forKey: "CLAUDECODE")
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run() } catch { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var b = 0, w = 0
            for s in list {
                let cwd = (s["cwd"] as? String) ?? ""
                if cwd.hasPrefix(home + "/desk-robot/workspace") { continue }
                switch (s["status"] as? String) ?? "" {
                case "busy", "running", "working": b += 1
                case "waiting", "needs_input", "blocked": w += 1
                default: break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if b != self.busy || w != self.waiting {
                    self.busy = b; self.waiting = w
                    self.onChange?(b, w)
                }
            }
        }
    }
}
