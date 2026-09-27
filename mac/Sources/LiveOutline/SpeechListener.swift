import AVFoundation
import Speech
import SwiftUI

/// Streams microphone audio into Apple's speech recognizer and reports the transcript.
@MainActor
@Observable
final class SpeechListener {
    private(set) var isListening = false
    private(set) var transcript = ""
    private(set) var level: Float = 0
    var errorMessage: String?
    var contextualStrings: [String] = []

    @ObservationIgnored var onTranscript: ((String, Bool) -> Void)?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest? {
        didSet { sink.set(request) }
    }
    /// Lets the audio thread hand buffers to the current request without waiting on the main thread.
    @ObservationIgnored private let sink = RequestSink()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Text from earlier recognition passes, kept for the on-screen ticker.
    @ObservationIgnored private var history = ""

    func start() {
        errorMessage = nil
        Task {
            guard await Self.requestPermissions() else {
                errorMessage = "Live Outline needs microphone and speech recognition access. Turn them on in System Settings → Privacy & Security."
                return
            }
            guard let recognizer, recognizer.isAvailable else {
                errorMessage = "Speech recognition isn't available right now."
                return
            }
            do {
                try startEngine()
                isListening = true
                beginRecognition(with: recognizer)
            } catch {
                errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        isListening = false
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        level = 0
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            sink.append(buffer)
            let rms = Self.rms(buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.level = self.level * 0.6 + rms * 0.4
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func beginRecognition(with recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = contextualStrings
        request.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition {
            // Keeps audio on the Mac and avoids the one-minute server limit.
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text {
                    self.transcript = Self.tail(self.history + " " + text)
                    self.onTranscript?(text, isFinal)
                    if isFinal { self.history = self.transcript }
                }
                // Recognition passes end on pauses or time limits; start a new one while listening.
                if (isFinal || failed) && self.isListening {
                    self.request?.endAudio()
                    self.beginRecognition(with: recognizer)
                }
            }
        }
    }

    private static func tail(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 400 ? String(trimmed.suffix(400)) : trimmed
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(1, (sum / Float(buffer.frameLength)).squareRoot() * 8)
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && mic
    }
}

private final class RequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }
}
