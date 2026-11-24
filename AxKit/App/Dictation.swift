import AVFoundation
import AxKitCore
import Foundation
import Observation

/// §30 받아쓰기: the mic button next to the chat box. Records a short AAC clip, the Mac turns it into words, and the
/// words go into the box for the owner to fix and send (never sent by itself). The clip lives in a temp file only
/// until it is read for sending.
@MainActor @Observable
final class Dictation {
    enum Phase: Equatable { case idle, recording(startedAt: Date), transcribing }

    private(set) var phase: Phase = .idle
    /// 0...1, the loudness right now (the bars that show the mic is listening).
    private(set) var level: Double = 0
    /// Seconds recorded so far.
    private(set) var elapsed: TimeInterval = 0
    /// Words to show for a moment (too short, nothing heard, the Mac's own message).
    var problem: String?
    /// Where the words go (set by the chat box).
    var onText: ((String) -> Void)?

    var isRecording: Bool { if case .recording = phase { true } else { false } }
    var isBusy: Bool { phase != .idle }

    private var recorder: AVAudioRecorder?
    private var peakDb: Float = -.infinity
    private var meterTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    /// Bumped by every cancel: an answer for an older recording is dropped.
    private var generation = 0

    func start() async {
        guard phase == .idle else { return }
        problem = nil
        let my = generation
        guard await AVAudioApplication.requestRecordPermission() else { problem = DictationRules.denied; return }
        guard my == generation, phase == .idle else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            peakDb = -.infinity
            elapsed = 0
            phase = .recording(startedAt: Date())
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.tick()
                }
            }
        } catch {
            discardRecording()
            problem = "녹음을 시작하지 못했어요."
        }
    }

    private func tick() {
        guard let recorder, case .recording(let at) = phase else { return }
        recorder.updateMeters()
        peakDb = max(peakDb, recorder.peakPower(forChannel: 0))
        level = DictationRules.meter(recorder.averagePower(forChannel: 0))
        elapsed = Date().timeIntervalSince(at)
        if elapsed >= DictationRules.maxSeconds { finish() }
    }

    /// Stops recording and sends the clip to the Mac.
    func finish() {
        guard let recorder, case .recording(let at) = phase else { return }
        let seconds = Date().timeIntervalSince(at)
        recorder.updateMeters()
        let loudest = max(peakDb, recorder.peakPower(forChannel: 0))
        recorder.stop()
        let url = recorder.url
        stopMeter()
        let bytes = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        phase = .idle
        guard seconds >= DictationRules.minSeconds, let bytes, !bytes.isEmpty else { problem = DictationRules.tooShort; return }
        guard loudest >= DictationRules.silentDb else { problem = DictationRules.silent; return }
        guard let client = AppModel.shared.client else { problem = DictationRules.failed; return }
        phase = .transcribing
        let my = generation
        sendTask = Task { [weak self] in
            let result: Result<DictationAnswer, Error>
            do { result = .success(try await client.dictate(bytes)) } catch { result = .failure(error) }
            guard let self, my == self.generation else { return }
            self.phase = .idle
            self.sendTask = nil
            switch result {
            case .success(let answer):
                if answer.text.isEmpty { self.problem = answer.message ?? DictationRules.nothingHeard } else { self.onText?(answer.text) }
            case .failure(let error):
                if error is CancellationError { return }
                switch error as? APIError {
                case .refused(let message): self.problem = message
                case .offline: self.problem = "맥에 연결되지 않아서 받아쓰지 못했어요."
                case .notFound: self.problem = "이 맥은 아직 받아쓰기를 하지 못해요."
                default: self.problem = DictationRules.failed
                }
            }
        }
    }

    /// Recording: throw it away. Writing: stop waiting for the Mac. Nothing goes in the box.
    func cancel() {
        generation += 1
        sendTask?.cancel()
        sendTask = nil
        discardRecording()
        phase = .idle
    }

    private func discardRecording() {
        if let recorder {
            recorder.stop()
            try? FileManager.default.removeItem(at: recorder.url)
        }
        stopMeter()
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
        recorder = nil
        level = 0
        // Deactivating the session can take a moment; never on the main thread.
        Task.detached { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
