import SpriteKit

enum TrackedJoint: Hashable {
    case thumbTip
    case indexTip
    case middleTip
    case ringTip
    case littleTip
    case wrist
}

final class HandPhysicsScene: SKScene {
    private final class HandCursor {
        let thumb: SKShapeNode
        let index: SKShapeNode
        var joint: SKPhysicsJointPin?
        var grabbedNode: SKNode?

        init() {
            thumb = SKShapeNode(circleOfRadius: 13)
            index = SKShapeNode(circleOfRadius: 15)
            thumb.fillColor = .systemYellow
            index.fillColor = .systemCyan
            thumb.strokeColor = .white
            index.strokeColor = .white
            thumb.lineWidth = 2
            index.lineWidth = 2
            thumb.name = "hand-cursor"
            index.name = "hand-cursor"
            thumb.physicsBody = SKPhysicsBody(circleOfRadius: 13)
            index.physicsBody = SKPhysicsBody(circleOfRadius: 15)
            thumb.physicsBody?.isDynamic = false
            index.physicsBody?.isDynamic = false
            thumb.zPosition = 100
            index.zPosition = 100
        }
    }

    private var cursors: [HandCursor] = []
    private let titleLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
    private let hintLabel = SKLabelNode(fontNamed: "AvenirNext-Medium")

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .clear
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    override func didMove(to view: SKView) {
        physicsWorld.gravity = CGVector(dx: 0, dy: -1.4)
        makeWorldBounds()
        makeHUD()
        spawnStarterObjects()
    }

    private func makeWorldBounds() {
        physicsBody = SKPhysicsBody(edgeLoopFrom: frame)
        physicsBody?.friction = 0.35
        physicsBody?.restitution = 0.25
    }

    private func makeHUD() {
        titleLabel.text = "HANDVERSE LAB"
        titleLabel.fontSize = 28
        titleLabel.position = CGPoint(x: size.width / 2, y: size.height - 44)
        titleLabel.zPosition = 200
        addChild(titleLabel)

        hintLabel.text = "Pinça: polegar + indicador para pegar objetos"
        hintLabel.fontSize = 16
        hintLabel.position = CGPoint(x: size.width / 2, y: size.height - 72)
        hintLabel.zPosition = 200
        addChild(hintLabel)
    }

    private func spawnStarterObjects() {
        for i in 0..<6 {
            let block = SKShapeNode(rectOf: CGSize(width: 72, height: 72), cornerRadius: 12)
            block.fillColor = i.isMultiple(of: 2) ? .systemPink : .systemIndigo
            block.strokeColor = .white
            block.lineWidth = 2
            block.position = CGPoint(x: 130 + CGFloat(i) * 95, y: size.height * 0.55 + CGFloat(i % 2) * 85)
            block.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 72, height: 72))
            block.physicsBody?.mass = 0.18
            block.physicsBody?.friction = 0.45
            block.physicsBody?.restitution = 0.22
            block.name = "grabbable"
            addChild(block)
        }

        for i in 0..<5 {
            let ball = SKShapeNode(circleOfRadius: 30)
            ball.fillColor = .systemGreen
            ball.strokeColor = .white
            ball.lineWidth = 2
            ball.position = CGPoint(x: 180 + CGFloat(i) * 120, y: size.height * 0.30)
            ball.physicsBody = SKPhysicsBody(circleOfRadius: 30)
            ball.physicsBody?.mass = 0.10
            ball.physicsBody?.restitution = 0.65
            ball.name = "grabbable"
            addChild(ball)
        }
    }

    private func cursor(at index: Int) -> HandCursor {
        while cursors.count <= index {
            let newCursor = HandCursor()
            cursors.append(newCursor)
            addChild(newCursor.thumb)
            addChild(newCursor.index)
        }
        return cursors[index]
    }

    func updateHands(_ hands: [[TrackedJoint: CGPoint]]) {
        for i in 0..<2 {
            let handCursor = cursor(at: i)

            guard i < hands.count,
                  let thumbPoint = hands[i][.thumbTip],
                  let indexPoint = hands[i][.indexTip] else {
                handCursor.thumb.isHidden = true
                handCursor.index.isHidden = true
                release(handCursor)
                continue
            }

            handCursor.thumb.isHidden = false
            handCursor.index.isHidden = false

            let thumb = CGPoint(x: thumbPoint.x * size.width, y: thumbPoint.y * size.height)
            let index = CGPoint(x: indexPoint.x * size.width, y: indexPoint.y * size.height)
            handCursor.thumb.position = thumb
            handCursor.index.position = index

            let dx = thumb.x - index.x
            let dy = thumb.y - index.y
            let distance = sqrt(dx * dx + dy * dy)

            if distance < 62 {
                if handCursor.joint == nil {
                    grabNearestObject(with: handCursor, at: index)
                }
            } else if distance > 90 {
                release(handCursor)
            }
        }
    }

    private func grabNearestObject(with handCursor: HandCursor, at point: CGPoint) {
        guard let cursorBody = handCursor.index.physicsBody else { return }

        let candidates = nodes(at: point).filter {
            $0.name == "grabbable" && $0.physicsBody?.isDynamic == true
        }
        guard let target = candidates.first,
              let targetBody = target.physicsBody else { return }

        let joint = SKPhysicsJointPin.joint(withBodyA: cursorBody, bodyB: targetBody, anchor: point)
        physicsWorld.add(joint)
        handCursor.joint = joint
        handCursor.grabbedNode = target
        target.run(.scale(to: 1.08, duration: 0.08))
    }

    private func release(_ handCursor: HandCursor) {
        if let joint = handCursor.joint {
            physicsWorld.remove(joint)
            handCursor.joint = nil
        }
        if let node = handCursor.grabbedNode {
            node.run(.scale(to: 1.0, duration: 0.08))
            handCursor.grabbedNode = nil
        }
    }
}
