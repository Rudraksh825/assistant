import AVFoundation
import Speech

/// Microphone → on-device speech recognition. `SFSpeechRecognizer` rather than the newer analyzer API:
/// it needs no model download step and builds with Command Line Tools alone.
/// Callbacks arrive on the main queue.
final class SpeechEngine: @unchecked Sendable {
    enum Failure: Error {
        case noRecognizer, notOnDevice, noInput
    }

    var onPartial: (String) -> Void = { _ in }
    /// 0…1, roughly 20 times a second.
    var onLevel: (Float) -> Void = { _ in }
    /// The finished utterance (possibly empty). Called exactly once per `start`.
    var onFinal: (String) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finished = true

    func start() throws {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw Failure.noRecognizer }
        // Audio never leaves the machine: without an on-device model there is no dictation.
        guard recognizer.supportsOnDeviceRecognition else { throw Failure.notOnDevice }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }

        latest = ""
        finished = false
        self.request = request
        var lastLevel = CFAbsoluteTimeGetCurrent()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastLevel > 0.05, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            lastLevel = now
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            // Speech sits around -45…-10 dBFS; map that range onto 0…1.
            let db = 10 * log10(max(sum / Float(buffer.frameLength), 1e-9))
            let level = min(1, max(0, (db + 50) / 40))
            DispatchQueue.main.async { self?.onLevel(level) }
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = result?.isFinal == true || error != nil
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if let text {
                    self.latest = text
                    self.onPartial(text)
                }
                if done { self.finish() }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            task?.cancel()
            finished = true
            throw error
        }
    }

    /// Stops listening; `onFinal` follows once the recognizer has settled on the last words.
    func stop() {
        guard !finished else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // The recognizer normally answers within a few hundred ms; do not wait on it forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        onFinal(latest)
    }
}
