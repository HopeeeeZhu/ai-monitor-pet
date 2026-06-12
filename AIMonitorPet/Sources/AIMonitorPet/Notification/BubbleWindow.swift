import Cocoa

private final class BubbleTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        drawingRect.origin.y += max(0, (drawingRect.height - textHeight) / 2)
        drawingRect.size.height = textHeight
        return drawingRect
    }
}

class BubbleWindow: NSPanel {

    private let label: NSTextField
    private let defaultBubbleHeight: CGFloat = 36
    private let warningBubbleHeight: CGFloat = 42
    private let defaultBubblePadding: CGFloat = 12
    private let warningBubblePadding: CGFloat = 15
    private var hideTimer: Timer?

    init() {
        label = NSTextField(labelWithString: "")
        label.cell = BubbleTextFieldCell(textCell: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true

        let frame = NSRect(x: 0, y: 0, width: 200, height: 36)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating + 1
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false

        setupContent()
    }

    private func setupContent() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: defaultBubbleHeight))
        container.wantsLayer = true
        container.layer?.cornerRadius = defaultBubbleHeight / 2
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        label.frame = NSRect(x: defaultBubblePadding, y: 0, width: 200 - defaultBubblePadding * 2, height: defaultBubbleHeight)
        container.addSubview(label)

        contentView = container
    }

    func show(message: String, relativeTo petWindow: NSWindow, duration: TimeInterval = 4.0) {
        hideTimer?.invalidate()

        let isWarning = message.contains("需要授权") || message.contains("等你确认")
        let bubbleHeight = isWarning ? warningBubbleHeight : defaultBubbleHeight
        let bubblePadding = isWarning ? warningBubblePadding : defaultBubblePadding

        label.font = isWarning ? .systemFont(ofSize: 14, weight: .bold) : .systemFont(ofSize: 12, weight: .medium)
        label.textColor = isWarning ? .black : .labelColor
        label.stringValue = message
        label.sizeToFit()

        let textWidth = label.frame.width + bubblePadding * 2
        let bubbleWidth = min(max(textWidth, isWarning ? 190 : 80), 320)

        let petFrame = petWindow.frame
        let bubbleX = petFrame.midX - bubbleWidth / 2
        let bubbleY = petFrame.maxY + 8

        setFrame(NSRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight), display: true)
        label.frame = NSRect(x: bubblePadding, y: 0, width: bubbleWidth - bubblePadding * 2, height: bubbleHeight)
        contentView?.frame = NSRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)

        if isWarning {
            contentView?.layer?.cornerRadius = 14
            contentView?.layer?.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.48, alpha: 0.96).cgColor
            contentView?.layer?.borderWidth = 2
            contentView?.layer?.borderColor = NSColor(calibratedRed: 0.86, green: 0.57, blue: 0.00, alpha: 1.0).cgColor
        } else {
            contentView?.layer?.cornerRadius = bubbleHeight / 2
            contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            contentView?.layer?.borderWidth = 0.5
            contentView?.layer?.borderColor = NSColor.separatorColor.cgColor
        }

        alphaValue = 0
        orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            self.animator().alphaValue = 1.0
        }

        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
}
