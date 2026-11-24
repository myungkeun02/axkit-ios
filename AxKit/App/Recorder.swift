import AVFoundation
import AxKitCore
import Foundation
import Observation

/// Records speech to a small AAC file (about 11 MB per hour). Keeps going with the screen off (background audio).
@MainActor @Observable
final class Recorder {
    enum State: Equatable { case idle, recording(startedAt: Date) }

    private(set) var state: State = .idle
    private var recorder: AVAudioRecorder?
    private var fileName: String?
    var problem: String?

    var isRecording: Bool { if case .recording = state { true } else { false } }
    var startedAt: Date? { if case .recording(let at) = state { at } else { nil } }

    func start(into folder: URL) async {
        guard !isRecording else { return }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else {
            problem = "마이크를 쓸 수 없어요. 설정 › ax-kit에서 마이크를 켜 주세요."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio)
            try session.setActive(true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "rec-\(Int(Date().timeIntervalSince1970)).m4a"
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000,
            ]
            let recorder = try AVAudioRecorder(url: folder.appendingPathComponent(name), settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            fileName = name
            state = .recording(startedAt: Date())
        } catch {
            problem = "녹음을 시작하지 못했어요."
        }
    }

    /// Stops and returns what to send to the Mac.
    func stop() -> PendingRecording? {
        guard let recorder, let fileName, let startedAt else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.recorder = nil
        self.fileName = nil
        state = .idle
        let size = (try? FileManager.default.attributesOfItem(atPath: recorder.url.path)[.size] as? Int) ?? 0
        guard duration >= 1, size > 0 else {
            try? FileManager.default.removeItem(at: recorder.url)
            problem = "너무 짧아서 저장하지 않았어요."
            return nil
        }
        return PendingRecording(fileName: fileName, startedAt: startedAt, durationSec: duration, size: size)
    }
}
