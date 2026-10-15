import AVFoundation
import Foundation

/// The robot's ears and mouth, in the app: the microphone with macOS voice
/// processing (echo cancellation, so he can listen while he talks) streamed
/// to the brain as 16 kHz 16-bit frames, and the brain's reply audio played
/// through the same engine so the echo canceller knows what he is saying.
final class AudioIO {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var pendingMic = Data()
    private let frameBytes = 960   // 30 ms of 16 kHz s16le, what the brain expects

    private(set) var aec = false
    private(set) var running = false
    var micOn = false
    var onMicFrame: ((Data) -> Void)?
    var onDiag: ((String) -> Void)?
    private var diagCount = 0
    private var diagPeakIn: Float = 0
    private var diagPeakOut: Int16 = 0
    private var diagFormat = ""
    var onLevel: ((Float) -> Void)?
    var onDrained: (() -> Void)?

    private var generation = 0
    private var scheduled = 0
    private var levels: [Float] = []
    private var ending = false
    private let q = DispatchQueue(label: "co.goodendeavors.deskrobot.audio")

    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        // `defaults write co.goodendeavors.deskrobot useVoiceProcessing -bool false` turns
        // echo cancellation off (then the brain mutes the ears while he talks, as before).
        let wantVP = UserDefaults.standard.object(forKey: "useVoiceProcessing") as? Bool ?? true
        do {
            if !wantVP { throw NSError(domain: "DeskRobot", code: 1, userInfo: [NSLocalizedDescriptionKey: "turned off in defaults"]) }
            try input.setVoiceProcessingEnabled(true)
            aec = true
        } catch {
            aec = false
            NSLog("voice processing unavailable (%@); listening without echo cancellation", error.localizedDescription)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let inFormat = input.outputFormat(forBus: 0)
        // The voice-processing input shows up as many channels (9 on this
        // MacBook); the converter silently makes zeros of a 9→1 downmix, so
        // take channel 0 ourselves and only ask the converter to resample.
        monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false)!
        if aec {
            // The voice-processing unit insists that what it plays and what it
            // records share one format (error -10875 otherwise): mono at the
            // input's sample rate. The mixer resamples the 16 kHz reply into it.
            let ioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false)!
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: ioFormat)
        }
        converter = AVAudioConverter(from: monoFormat!, to: micFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.handleInput(buf)
        }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        running = false
    }

    // MARK: - microphone → brain

    private func handleInput(_ raw: AVAudioPCMBuffer) {
        guard micOn, let conv = converter, let mono = monoFormat, raw.frameLength > 0,
              let src = raw.floatChannelData,
              let buf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: raw.frameLength) else { return }
        buf.frameLength = raw.frameLength
        let n = Int(raw.frameLength)
        let dst = buf.floatChannelData![0]
        var pk: Float = 0
        for i in 0..<n { let v = src[0][i]; dst[i] = v; pk = max(pk, abs(v)) }
        diagPeakIn = max(diagPeakIn, pk)
        diagFormat = "\(Int(raw.format.sampleRate)) Hz, \(raw.format.channelCount) ch in, frames \(raw.frameLength)"
        let ratio = micFormat.sampleRate / mono.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: cap) else { return }
        var handed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, outStatus in
            if handed { outStatus.pointee = .noDataNow; return nil }
            handed = true
            outStatus.pointee = .haveData
            return buf
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else {
            diagCount += 1
            if diagCount % 100 == 1 { onDiag?("mic convert failed: status \(status.rawValue) \(err?.localizedDescription ?? "") in: \(diagFormat)") }
            return
        }
        for i in 0..<Int(out.frameLength) { let v = Int32(ch[0][i]); diagPeakOut = max(diagPeakOut, Int16(clamping: v < 0 ? -v : v)) }  // abs(Int16.min) traps
        diagCount += 1
        if diagCount % 300 == 0 {
            onDiag?("mic peak in \(String(format: "%.3f", diagPeakIn)) out \(diagPeakOut) (\(diagFormat))")
            diagPeakIn = 0; diagPeakOut = 0
        }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        q.async { [self] in
            pendingMic.append(data)
            while pendingMic.count >= frameBytes {
                let frame = pendingMic.prefix(frameBytes)
                pendingMic.removeFirst(frameBytes)
                onMicFrame?(Data(frame))
            }
        }
    }

    // MARK: - brain → speaker

    /// A reply is starting: forget any leftover audio.
    func beginSpeech() {
        q.sync { ending = false; levels.removeAll() }
    }

    /// 16 kHz s16le mono PCM from the brain, about 100 ms at a time.
    func enqueue(_ pcm: Data) {
        let n = pcm.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        var sum: Float = 0
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            let dst = buf.floatChannelData![0]
            for i in 0..<n { let v = Float(s[i]) / 32768; dst[i] = v; sum += v * v }
        }
        let rms = (sum / Float(n)).squareRoot()
        let gen = q.sync { () -> Int in
            scheduled += 1
            if levels.isEmpty { onLevel?(rms) }   // nothing was playing: this buffer starts now
            levels.append(rms)
            return generation
        }
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.q.async {
                guard gen == self.generation else { return }
                self.scheduled -= 1
                if !self.levels.isEmpty { self.levels.removeFirst() }
                self.onLevel?(self.levels.first ?? 0)
                if self.ending && self.scheduled == 0 { self.ending = false; self.onDrained?() }
            }
        }
    }

    /// No more audio is coming; call onDrained once what is queued has played.
    func endSpeech() {
        q.async { [self] in
            ending = true
            if scheduled == 0 { ending = false; onDrained?() }
        }
    }

    /// Cut him off now (the human started talking).
    func stopSpeech() {
        q.sync { generation += 1; scheduled = 0; levels.removeAll(); ending = false }
        player.stop()
        player.play()
        onLevel?(0)
    }
}
