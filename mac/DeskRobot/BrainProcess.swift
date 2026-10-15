import Foundation

/// Runs the Python brain (server/brain/main.py) as a child of the app, so one
/// launch brings up everything, the microphone permission belongs to the app,
/// and the console (stdin) is available for commands like `listen`.
final class BrainProcess {
    static let serverDirKey = "serverDir"

    private(set) var process: Process?
    private var stdinPipe: Pipe?
    private var stopping = false
    private(set) var log: [String] = []
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    private let maxLog = 600

    var serverDir: URL {
        if let s = UserDefaults.standard.string(forKey: Self.serverDirKey), !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("desk-robot/server")
    }
    var python: URL { serverDir.appendingPathComponent(".venv/bin/python") }
    var isRunning: Bool { process?.isRunning ?? false }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    /// A brain whose app died while it was blocked (for example inside the
    /// microphone permission request) keeps the ports. Its parent is launchd
    /// by then, so it is safe to tell apart from one someone runs in a terminal.
    private func reapOrphans() {
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        find.arguments = ["-f", "brain.main"]  // the venv python resolves to the framework binary, so match the module; no leading dash or pgrep eats it as an option
        let out = Pipe(); find.standardOutput = out
        try? find.run(); find.waitUntilExit()
        let pids = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } ?? []
        for pid in pids {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "ppid=", "-p", String(pid)]
            let o = Pipe(); ps.standardOutput = o
            try? ps.run(); ps.waitUntilExit()
            let ppid = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if ppid == "1" {
                kill(pid, SIGKILL)
                append("stopped an orphaned brain (pid \(pid))")
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        guard isInstalled else {
            append("brain not installed: expected \(python.path). See the README in desk-robot/mac.")
            return
        }
        stopping = false
        reapOrphans()
        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "brain.main"]
        p.currentDirectoryURL = serverDir
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""].joined(separator: ":")
        env["HOME"] = home
        env["DESK_ROBOT_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)  // the brain exits if we die
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inp = Pipe()
        p.standardInput = inp
        stdinPipe = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
                let t = String(line)
                if t.hasPrefix("objc[") { continue }  // library duplicate-class warnings, harmless
                DispatchQueue.main.async { self?.append(t) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.append("brain exited (code \(proc.terminationStatus))")
                out.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.onStateChange?(false)
                let portTaken = self.log.suffix(12).contains { $0.contains("Address already in use") }
                if portTaken {
                    self.append("another brain already owns the port; using that one instead of restarting")
                } else if !self.stopping {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.start() }
                }
            }
        }
        do {
            try p.run()
            process = p
            append("brain started (pid \(p.processIdentifier))")
            onStateChange?(true)
        } catch {
            append("could not start the brain: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopping = true
        guard let p = process, p.isRunning else { return }
        send("quit")
        p.terminate()
        p.waitUntilExit()
    }

    func restart() {
        stopping = true
        if let p = process, p.isRunning {
            send("quit")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if p.isRunning { p.terminate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
            }
        } else {
            start()
        }
    }

    /// A console command, exactly as you would type it in the server terminal.
    func send(_ line: String) {
        guard let fh = stdinPipe?.fileHandleForWriting, let data = (line + "\n").data(using: .utf8) else { return }
        try? fh.write(contentsOf: data)
    }

    private lazy var logFile: FileHandle? = {
        let dir = serverDir.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("brain.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let fh = try? FileHandle(forWritingTo: url)
        try? fh?.truncate(atOffset: 0)
        return fh
    }()

    /// A line from the app itself (the robot link, the audio engine) into the same log.
    func note(_ line: String) { append("app: " + line) }

    /// Also mirrored to server/logs/brain.log so it can be read from a terminal.
    private func append(_ line: String) {
        log.append(line)
        if log.count > maxLog { log.removeFirst(log.count - maxLog) }
        onLog?(line)
        // Overheard room talk stays out of the file on disk; it is still in the in-app log.
        if line.contains("(heard, ignoring:") { return }
        let stamp = Self.stamp.string(from: Date())
        if let d = ("\(stamp) " + line + "\n").data(using: .utf8) { try? logFile?.write(contentsOf: d) }
    }
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
}
