import SpriteKit
import AppKit

enum PetAnimation: Int, CaseIterable {
    case sleeping = 0
    case running = 1
    case waving = 2
    case celebrating = 3

    var frameIndex: Int { rawValue }

    static func from(status: AgentStatus) -> PetAnimation {
        switch status {
        case .idle: return .sleeping
        case .running: return .running
        case .waitingApproval: return .waving
        }
    }
}

class PetScene: SKScene {

    private var petNode: SKSpriteNode!
    private var frames: [SKTexture] = []
    private var currentAnimation: PetAnimation = .sleeping
    private var isPlayingCelebration = false

    private let frameCount = 4
    private let frameWidth: CGFloat = 384
    private let frameHeight: CGFloat = 1024

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        scaleMode = .aspectFit

        loadFrames()
        setupPetNode()
        playAnimation(.sleeping)
    }

    private func loadFrames() {
        guard let imagePath = findAssetPath() else {
            print("[PetScene] ERROR: Cannot find pet_sprites.png")
            return
        }

        guard let fullImage = NSImage(contentsOfFile: imagePath) else {
            print("[PetScene] ERROR: Cannot load image from \(imagePath)")
            return
        }

        let fullTexture = SKTexture(image: fullImage)
        let textureWidth = fullTexture.size().width
        let textureHeight = fullTexture.size().height

        for i in 0..<frameCount {
            let xNormalized = CGFloat(i) * frameWidth / textureWidth
            let widthNormalized = frameWidth / textureWidth
            let rect = CGRect(x: xNormalized, y: 0, width: widthNormalized, height: 1.0)
            let frameTexture = SKTexture(rect: rect, in: fullTexture)
            frameTexture.filteringMode = SKTextureFilteringMode.nearest
            frames.append(frameTexture)
        }

        print("[PetScene] Loaded \(frames.count) frames from \(Int(textureWidth))x\(Int(textureHeight)) sprite sheet")
    }

    private func findAssetPath() -> String? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let projectRoot = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let assetPath = projectRoot.appendingPathComponent("Assets/pet_sprites.png").path
        if FileManager.default.fileExists(atPath: assetPath) {
            return assetPath
        }

        let hardcodedPaths = [
            NSString("~/Desktop/CC给我上一课/AI监工/AIMonitorPet/Assets/pet_sprites.png").expandingTildeInPath,
            Bundle.main.bundlePath + "/../Assets/pet_sprites.png"
        ]
        for path in hardcodedPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func setupPetNode() {
        guard !frames.isEmpty else {
            let placeholder = SKShapeNode(circleOfRadius: 40)
            placeholder.fillColor = .systemPink
            placeholder.position = CGPoint(x: size.width / 2, y: size.height / 2)
            addChild(placeholder)
            return
        }

        petNode = SKSpriteNode(texture: frames[0])
        petNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        let scale = min(size.width / frameWidth, size.height / frameHeight) * 0.9
        petNode.setScale(scale)
        addChild(petNode)
    }

    func playAnimation(_ animation: PetAnimation) {
        guard !frames.isEmpty else { return }
        guard animation != currentAnimation || isPlayingCelebration else { return }

        currentAnimation = animation
        isPlayingCelebration = false
        petNode.removeAllActions()
        petNode.texture = frames[animation.frameIndex]

        switch animation {
        case .sleeping:
            addBreathingEffect()
        case .running:
            addBouncingEffect()
        case .waving:
            addWavingEffect()
        case .celebrating:
            addCelebratingEffect()
        }
    }

    func playCelebration(then nextAnimation: PetAnimation) {
        guard !frames.isEmpty else { return }
        isPlayingCelebration = true
        petNode.removeAllActions()
        petNode.texture = frames[PetAnimation.celebrating.frameIndex]

        addCelebratingEffect()

        let waitAction = SKAction.wait(forDuration: 2.5)
        let switchAction = SKAction.run { [weak self] in
            self?.isPlayingCelebration = false
            self?.playAnimation(nextAnimation)
        }
        petNode.run(SKAction.sequence([waitAction, switchAction]), withKey: "celebration_timer")
    }

    private func addBreathingEffect() {
        let scaleUp = SKAction.scale(by: 1.03, duration: 1.5)
        let scaleDown = scaleUp.reversed()
        let breathe = SKAction.sequence([scaleUp, scaleDown])
        petNode.run(SKAction.repeatForever(breathe), withKey: "breathing")
    }

    private func addBouncingEffect() {
        let moveUp = SKAction.moveBy(x: 0, y: 4, duration: 0.3)
        moveUp.timingMode = .easeOut
        let moveDown = moveUp.reversed()
        moveDown.timingMode = .easeIn
        let bounce = SKAction.sequence([moveUp, moveDown])
        petNode.run(SKAction.repeatForever(bounce), withKey: "bouncing")
    }

    private func addWavingEffect() {
        let rotateLeft = SKAction.rotate(byAngle: 0.08, duration: 0.4)
        let rotateRight = SKAction.rotate(byAngle: -0.16, duration: 0.4)
        let rotateBack = SKAction.rotate(byAngle: 0.08, duration: 0.4)
        let wave = SKAction.sequence([rotateLeft, rotateRight, rotateBack])
        petNode.run(SKAction.repeatForever(wave), withKey: "waving")
    }

    private func addCelebratingEffect() {
        let jumpUp = SKAction.moveBy(x: 0, y: 12, duration: 0.25)
        jumpUp.timingMode = .easeOut
        let jumpDown = jumpUp.reversed()
        jumpDown.timingMode = .easeIn
        let jump = SKAction.sequence([jumpUp, jumpDown, SKAction.wait(forDuration: 0.2)])
        petNode.run(SKAction.repeatForever(jump), withKey: "celebrating")

        let spin = SKAction.rotate(byAngle: .pi * 2, duration: 0.6)
        petNode.run(SKAction.sequence([SKAction.wait(forDuration: 0.5), spin]), withKey: "spin")
    }
}
