import Carbon.HIToolbox
import Cocoa

@MainActor
final class VoiceCaptureController {
    let service = VoiceCaptureService()

    private let store: CaptureStore
    private var hudWindow: VoiceCaptureHUDWindow?
    private var hotKeyManager: HotKeyManager?
    private weak var anchorWindow: NSWindow?

    init(store: CaptureStore) {
        self.store = store
    }

    func setAnchorWindow(_ window: NSWindow) {
        anchorWindow = window
    }

    func startHotKey() {
        guard hotKeyManager == nil else { return }
        let manager = HotKeyManager(
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(controlKey) | UInt32(optionKey),
            handler: { [weak self] in
                Task { @MainActor in
                    self?.toggleCapture()
                }
            }
        )
        manager.register()
        hotKeyManager = manager
    }

    func stopHotKey() {
        hotKeyManager?.unregister()
        hotKeyManager = nil
    }

    func toggleCapture() {
        switch service.phase {
        case .recording:
            stopRecording(saveImmediately: true)
        case .requestingPermission:
            cancel()
        case .reviewing:
            showHUD()
        case .idle, .saved, .failed:
            startRecording()
        }
    }

    func startRecording() {
        showHUD()
        service.start()
    }

    func startManualEntry() {
        showHUD()
        service.startManualEntry()
        positionHUD()
    }

    func stopRecording(saveImmediately: Bool = false) {
        service.stop()
        positionHUD()
        guard saveImmediately else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let text = service.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            save(kind: .todo, text: text, reminderAt: nil)
        }
    }

    func save(kind: CaptureKind, text: String, reminderAt: Date?) {
        do {
            try store.save(text: text, kind: kind, reminderAt: reminderAt)
            service.markSaved()
            positionHUD()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.hideHUD()
                self.service.cancel()
            }
        } catch {
            service.phase = .failed("保存失败")
        }
    }

    func cancel() {
        service.cancel()
        hideHUD()
    }

    func positionHUD() {
        guard let anchorWindow, let hudWindow, hudWindow.isVisible else { return }
        hudWindow.position(relativeTo: anchorWindow)
    }

    private func showHUD() {
        if hudWindow == nil {
            let view = VoiceCaptureHUDView(
                service: service,
                onStop: { [weak self] in self?.stopRecording() },
                onSave: { [weak self] kind, text, reminderAt in
                    self?.save(kind: kind, text: text, reminderAt: reminderAt)
                },
                onCancel: { [weak self] in self?.cancel() }
            )
            hudWindow = VoiceCaptureHUDWindow(contentView: view)
        }

        guard let anchorWindow else { return }
        hudWindow?.show(relativeTo: anchorWindow)
    }

    private func hideHUD() {
        hudWindow?.hide()
    }
}
