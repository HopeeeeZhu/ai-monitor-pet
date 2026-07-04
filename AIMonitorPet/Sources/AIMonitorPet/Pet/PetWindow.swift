import Cocoa
import Combine

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        drawingRect.origin.y += max(0, (drawingRect.height - textHeight) / 2)
        drawingRect.size.height = textHeight
        return drawingRect
    }
}

class PetWindow: NSPanel {

    private var imageView: NSImageView!
    private var animationFrames: [PetAnimation: [NSImage]] = [:]
    private var monitorEngine: MonitorEngine
    private var cancellables = Set<AnyCancellable>()
    private var currentAnimation: PetAnimation = .sleeping
    private var animationTimer: Timer?
    private var isDragging = false
    private var didDrag = false
    private var dragOffset: NSPoint = .zero
    private var statusPanelController: StatusPanelController?
    private let voiceCaptureController: VoiceCaptureController
    private let captureStore: CaptureStore
    private var currentFrameIndex: Int = 0
    /// 每个 AI 工具一个独立气泡, 竖向堆叠在宠物头顶
    private var statusBubbles: [(background: NSView, label: NSTextField, size: NSSize)] = []
    private let statusLabelGap: CGFloat = 8
    private let bubbleSpacing: CGFloat = 6
    private let statusLabelPadding: CGFloat = 11
    private let statusLabelMinWidth: CGFloat = 102
    private let statusLabelMaxWidth: CGFloat = 340

    // 正方形窗口，保证横躺/竖立的姿势都不被截断
    static let defaultPetSize: CGFloat = 140
    private var petSize: CGFloat

    init(monitorEngine: MonitorEngine, voiceCaptureController: VoiceCaptureController, captureStore: CaptureStore) {
        self.monitorEngine = monitorEngine
        self.voiceCaptureController = voiceCaptureController
        self.captureStore = captureStore

        let savedSize = UserDefaults.standard.double(forKey: "petSize")
        self.petSize = savedSize > 0 ? CGFloat(savedSize) : PetWindow.defaultPetSize

        let frame = NSRect(x: 100, y: 100, width: petSize, height: petSize)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureWindow()
        voiceCaptureController.setAnchorWindow(self)
        loadSpriteFrames()
        setupImageView()
        bindToMonitorEngine()
        positionAtBottomRight()
        statusPanelController = StatusPanelController(monitorEngine: monitorEngine, captureStore: captureStore)
        setAnimation(.sleeping, force: true)
    }

    func resizePet(height: CGFloat) {
        petSize = height
        UserDefaults.standard.set(Double(height), forKey: "petSize")

        layoutContent(keepCenter: true)
    }

    private func configureWindow() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    private func loadSpriteFrames() {
        let animationFiles: [(PetAnimation, [String])] = [
            (.sleeping, ["sleep_0.png", "sleep_1.png", "sleep_2.png", "sleep_3.png"]),
            (.running, ["run_3.png", "run_2.png", "run_1.png", "run_0.png"]), // 倒序播放更顺
            (.waving, ["wave_0.png", "wave_1.png", "wave_2.png", "wave_3.png"]),
            (.celebrating, ["celebrate_0.png", "celebrate_1.png", "celebrate_2.png", "celebrate_3.png"]),
        ]

        guard let assetDir = findAssetDir() else {
            print("[PetWindow] ERROR: Cannot find asset directory")
            return
        }

        var totalFrames = 0
        for (animation, fileNames) in animationFiles {
            var frames: [NSImage] = []
            for name in fileNames {
                let path = (assetDir as NSString).appendingPathComponent(name)
                guard let image = NSImage(contentsOfFile: path) else {
                    print("[PetWindow] WARNING: Cannot load \(name)")
                    continue
                }
                let fitted = fitImageToSize(image, targetSize: NSSize(width: petSize, height: petSize))
                frames.append(fitted)
            }
            animationFrames[animation] = frames
            totalFrames += frames.count
        }

        print("[PetWindow] Loaded \(totalFrames) animation frames from \(assetDir)")
    }

    private func fitImageToSize(_ image: NSImage, targetSize: NSSize) -> NSImage {
        let imageSize = image.size
        let widthRatio = targetSize.width / imageSize.width
        let heightRatio = targetSize.height / imageSize.height
        let scale = min(widthRatio, heightRatio)

        let newWidth = imageSize.width * scale
        let newHeight = imageSize.height * scale

        let newImage = NSImage(size: NSSize(width: newWidth, height: newHeight))
        newImage.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: 0, width: newWidth, height: newHeight),
            from: NSRect(origin: .zero, size: imageSize),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }

    private func removeWhiteBackground(from image: NSImage) -> NSImage? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 白色阈值：RGB 各通道 > 240 视为白色背景
        let threshold: UInt8 = 240
        for i in 0..<(width * height) {
            let offset = i * bytesPerPixel
            let r = pixelData[offset]
            let g = pixelData[offset + 1]
            let b = pixelData[offset + 2]

            if r > threshold && g > threshold && b > threshold {
                pixelData[offset + 3] = 0 // alpha = 0
                pixelData[offset] = 0
                pixelData[offset + 1] = 0
                pixelData[offset + 2] = 0
            }
        }

        guard let outputContext = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let outputCGImage = outputContext.makeImage() else {
            return nil
        }

        let resultImage = NSImage(cgImage: outputCGImage, size: image.size)
        return resultImage
    }

    private func findAssetDir() -> String? {
        // 1. .app bundle: Contents/Resources/
        let bundleResource = Bundle.main.bundlePath + "/Contents/Resources"
        if FileManager.default.fileExists(atPath: bundleResource + "/sleep_0.png") {
            return bundleResource
        }

        // 2. 开发模式：从 executable 向上找 Assets 目录
        let execPath = CommandLine.arguments[0]
        let execURL = URL(fileURLWithPath: execPath)
        var searchDir = execURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = searchDir.appendingPathComponent("Assets").path
            if FileManager.default.fileExists(atPath: candidate + "/sleep_0.png") {
                return candidate
            }
            searchDir = searchDir.deletingLastPathComponent()
        }

        // 3. 硬编码开发路径
        let devPath = NSString("~/Desktop/CC给我上一课/AI监工/AIMonitorPet/Assets").expandingTildeInPath
        if FileManager.default.fileExists(atPath: devPath + "/sleep_0.png") {
            return devPath
        }

        return nil
    }

    private func setupImageView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: petSize, height: petSize))
        container.wantsLayer = true

        imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: petSize, height: petSize))
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignBottom
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = .clear

        if let firstFrame = animationFrames[.sleeping]?.first {
            imageView.image = firstFrame
        }

        container.addSubview(imageView)

        contentView = container
    }

    private func bindToMonitorEngine() {
        monitorEngine.$globalStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] newStatus in
                self?.handleStatusChange(newStatus)
            }
            .store(in: &cancellables)
    }

    private var lastStatus: AgentStatus = .idle
    private var celebrationTimer: Timer?

    private func handleStatusChange(_ newStatus: AgentStatus) {
        // globalStatus 会重复发布相同值, 必须去重, 否则会打断庆祝动画
        guard newStatus != lastStatus else { return }
        lastStatus = newStatus

        if celebrationTimer != nil {
            // 庆祝中翻到空闲: 让她跳完再睡; 翻到跑步/举手: 立刻切换
            if newStatus == .idle { return }
            celebrationTimer?.invalidate()
            celebrationTimer = nil
        }
        setAnimation(PetAnimation.from(status: newStatus))
    }

    /// 任意一个 AI 工具跑完任务时跳 3 秒庆祝（由 NotificationManager 调用），
    /// 跳完回到当前全局状态对应的动画
    func playCelebration(duration: TimeInterval = 3.0) {
        celebrationTimer?.invalidate()
        setAnimation(.celebrating)
        celebrationTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.celebrationTimer = nil
            self.setAnimation(PetAnimation.from(status: self.lastStatus))
        }
    }

    private func setAnimation(_ animation: PetAnimation, force: Bool = false) {
        guard !animationFrames.isEmpty else { return }
        if !force && animation == currentAnimation { return }
        currentAnimation = animation
        animationTimer?.invalidate()
        currentFrameIndex = 0

        // 显示第一帧
        if let firstFrame = animationFrames[animation]?.first {
            imageView.image = firstFrame
        }

        // 帧率：根据状态设定
        let interval: TimeInterval
        switch animation {
        case .sleeping: interval = 0.6
        case .running: interval = 0.2
        case .waving: interval = 0.3
        case .celebrating: interval = 0.15
        }

        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
    }

    private var baseOrigin: NSPoint = .zero

    private func tickAnimation() {
        guard let frames = animationFrames[currentAnimation], !frames.isEmpty else { return }

        // 轮播帧
        currentFrameIndex = (currentFrameIndex + 1) % frames.count
        imageView.image = frames[currentFrameIndex]

        // 附加窗口位移动画
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        let phase = CGFloat(currentFrameIndex)

        switch currentAnimation {
        case .sleeping:
            offsetY = 2.0 * sin(phase * .pi / 2)
        case .running:
            offsetY = 4.0 * abs(sin(phase * .pi / 2))
            offsetX = 2.0 * sin(phase * .pi / 2)
        case .waving:
            offsetX = 2.0 * sin(phase * .pi)
        case .celebrating:
            offsetY = 8.0 * abs(sin(phase * .pi / 2))
        }

        let newOrigin = NSPoint(
            x: baseOrigin.x + offsetX,
            y: baseOrigin.y + offsetY
        )
        setFrameOrigin(newOrigin)
        voiceCaptureController.positionHUD()
    }

    private func positionAtBottomRight() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let xPosition = screenFrame.maxX - frame.width - 20
        let yPosition = screenFrame.minY + 20
        let origin = NSPoint(x: xPosition, y: yPosition)
        setFrameOrigin(origin)
        baseOrigin = origin
    }

    // MARK: - 拖拽 + 点击支持

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        didDrag = false
        let windowFrame = self.frame
        let mouseLocation = NSEvent.mouseLocation
        dragOffset = NSPoint(
            x: mouseLocation.x - windowFrame.origin.x,
            y: mouseLocation.y - windowFrame.origin.y
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        didDrag = true
        let mouseLocation = NSEvent.mouseLocation
        let newOrigin = NSPoint(
            x: mouseLocation.x - dragOffset.x,
            y: mouseLocation.y - dragOffset.y
        )
        setFrameOrigin(newOrigin)
        voiceCaptureController.positionHUD()
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            baseOrigin = frame.origin
        }
        isDragging = false
        if !didDrag {
            statusPanelController?.toggle(relativeTo: self)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        showContextMenu(at: event)
    }

    private func showContextMenu(at event: NSEvent) {
        let menu = NSMenu()

        let voiceItem = NSMenuItem(title: "语音记录", action: #selector(startVoiceCapture), keyEquivalent: "v")
        voiceItem.keyEquivalentModifierMask = [.control, .option]
        voiceItem.target = self
        menu.addItem(voiceItem)

        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for size in [100, 120, 140, 160, 200, 260, 320, 400] {
            let item = NSMenuItem(title: "\(size)px", action: #selector(changeSizeAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = size
            if Int(petSize) == size {
                item.state = .on
            }
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "宠物大小", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出小安竺来咯", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: imageView)
    }

    @objc private func changeSizeAction(_ sender: NSMenuItem) {
        let newHeight = CGFloat(sender.tag)
        resizePet(height: newHeight)
    }

    @objc private func startVoiceCapture() {
        voiceCaptureController.startRecording()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func show() {
        orderFront(nil)
        let totalFrames = animationFrames.values.reduce(0) { $0 + $1.count }
        print("[PetWindow] Shown at \(frame.origin), size: \(Int(petSize))x\(Int(petSize)), frames loaded: \(totalFrames)")
    }

    func updateAnimation(to status: AgentStatus) {
        handleStatusChange(status)
    }

    /// 更新宠物头顶的状态气泡, 每个 AI 工具一个（由 NotificationManager 调用）
    func updateStatusBubbles(_ texts: [String]) {
        for bubble in statusBubbles {
            bubble.background.removeFromSuperview()
        }
        statusBubbles = texts.map { makeBubble(text: $0) }
        for bubble in statusBubbles {
            contentView?.addSubview(bubble.background)
        }
        layoutContent(keepCenter: true)
    }

    private func makeBubble(text: String) -> (background: NSView, label: NSTextField, size: NSSize) {
        let label = NSTextField(labelWithString: "")
        label.cell = VerticallyCenteredTextFieldCell(textCell: "")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.stringValue = text

        // 用 cell 实测宽度(含内边距)，NSString.size 会偏小导致截断
        let measured = label.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: 10000, height: 1000)).width ?? 0
        let lineCount = text.components(separatedBy: "\n").count
        let width = min(max(ceil(measured) + statusLabelPadding * 2, statusLabelMinWidth), statusLabelMaxWidth)
        let height: CGFloat = lineCount <= 1 ? 24 : CGFloat(lineCount) * 17 + 10

        let background = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.wantsLayer = true
        background.layer?.cornerRadius = min(height / 2, 12)
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        label.frame = NSRect(x: statusLabelPadding, y: 0, width: width - statusLabelPadding * 2, height: height)
        background.addSubview(label)
        return (background, label, NSSize(width: width, height: height))
    }

    private func layoutContent(keepCenter: Bool) {
        let maxBubbleWidth = statusBubbles.map { $0.size.width }.max() ?? 0
        let windowWidth = max(petSize, maxBubbleWidth)
        let bubblesHeight = statusBubbles.reduce(CGFloat(0)) { $0 + $1.size.height }
            + (statusBubbles.isEmpty ? 0 : statusLabelGap + CGFloat(statusBubbles.count - 1) * bubbleSpacing)
        let windowHeight = petSize + bubblesHeight
        let oldFrame = frame
        let x = keepCenter ? oldFrame.midX - windowWidth / 2 : oldFrame.origin.x

        setFrame(NSRect(x: x, y: oldFrame.origin.y, width: windowWidth, height: windowHeight), display: true)
        contentView?.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        imageView.frame = NSRect(x: (windowWidth - petSize) / 2, y: 0, width: petSize, height: petSize)

        // 气泡从宠物头顶向上堆叠
        var y = petSize + statusLabelGap
        for bubble in statusBubbles.reversed() {
            bubble.background.frame = NSRect(
                x: (windowWidth - bubble.size.width) / 2,
                y: y,
                width: bubble.size.width,
                height: bubble.size.height
            )
            y += bubble.size.height + bubbleSpacing
        }

        baseOrigin = frame.origin
        voiceCaptureController.positionHUD()
    }
}
