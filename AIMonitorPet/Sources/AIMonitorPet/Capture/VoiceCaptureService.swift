import AVFoundation
import Foundation
import Speech

enum VoiceCapturePhase: Equatable {
    case idle
    case requestingPermission
    case recording
    case reviewing
    case saved
    case failed(String)

    var isRecording: Bool {
        self == .recording || self == .requestingPermission
    }
}

@MainActor
final class VoiceCaptureService: ObservableObject {
    @Published var phase: VoiceCapturePhase = .idle
    @Published var transcript: String = ""
    @Published var elapsedSeconds: Int = 0

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timer: Timer?

    func start() {
        stopAudio()
        transcript = ""
        elapsedSeconds = 0
        phase = .requestingPermission

        requestPermissions { [weak self] granted, message in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.startRecording()
                } else {
                    self.phase = .failed(message ?? "没有录音权限")
                }
            }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        stopTimer()
        phase = .reviewing
    }

    func cancel() {
        stopAudio()
        transcript = ""
        elapsedSeconds = 0
        phase = .idle
    }

    func markSaved() {
        stopAudio()
        phase = .saved
    }

    private func requestPermissions(completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                completion(false, "需要开启语音识别权限")
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted, granted ? nil : "需要开启麦克风权限")
            }
        }
    }

    private func startRecording() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            phase = .failed("语音识别暂不可用")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil, self.phase == .recording, self.transcript.isEmpty {
                    self.phase = .failed("没有听清，再试一次")
                    self.stopAudio()
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            phase = .recording
            startTimer()
        } catch {
            stopAudio()
            phase = .failed("录音启动失败")
        }
    }

    private func stopAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
