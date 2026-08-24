import SceneKit
import UIKit

final class PhysicsHand {
    let root: SCNNode
    private(set) var velocity = SCNVector3Zero
    private(set) var isPinching = false
    private var lastPosition = SCNVector3Zero
    private var lastTimestamp: TimeInterval = 0
    private var grabJoint: SCNPhysicsBallSocketJoint?
    private weak var grabbedNode: SCNNode?

    init(name: String, tint: UIColor) {
        root = SCNNode()
        root.name = name

        let palmGeo = SCNBox(width: 0.095, height: 0.028, length: 0.12, chamferRadius: 0.018)
        palmGeo.firstMaterial?.diffuse.contents = tint
        palmGeo.firstMaterial?.metalness.contents = 0.28
        palmGeo.firstMaterial?.roughness.contents = 0.34
        let palm = SCNNode(geometry: palmGeo)
        palm.eulerAngles.x = -.pi / 12
        root.addChildNode(palm)

        for i in 0..<4 {
            let fingerGeo = SCNCapsule(capRadius: 0.010, height: 0.075)
            fingerGeo.firstMaterial?.diffuse.contents = tint
            let finger = SCNNode(geometry: fingerGeo)
            finger.position = SCNVector3(Float(i - 2) * 0.022 + 0.012, 0.005, -0.078)
            finger.eulerAngles.x = .pi / 2.5
            root.addChildNode(finger)
        }

        let thumbGeo = SCNCapsule(capRadius: 0.012, height: 0.065)
        thumbGeo.firstMaterial?.diffuse.contents = tint
        let thumb = SCNNode(geometry: thumbGeo)
        thumb.position = SCNVector3(0.057, -0.002, -0.015)
        thumb.eulerAngles.z = -.pi / 3.3
        root.addChildNode(thumb)

        let shape = SCNPhysicsShape(geometry: SCNBox(width: 0.11, height: 0.055, length: 0.14, chamferRadius: 0.02), options: nil)
        let body = SCNPhysicsBody(type: .kinematic, shape: shape)
        body.categoryBitMask = PhysicsCategory.hand
        body.collisionBitMask = PhysicsCategory.grabbable | PhysicsCategory.npc | PhysicsCategory.world
        body.contactTestBitMask = PhysicsCategory.grabbable | PhysicsCategory.npc
        body.friction = 0.85
        body.restitution = 0.05
        root.physicsBody = body
        root.isHidden = true
    }

    func update(position: SCNVector3, timestamp: TimeInterval, visible: Bool) {
        root.isHidden = !visible
        guard visible else {
            velocity = .zero
            lastTimestamp = timestamp
            lastPosition = position
            return
        }

        if lastTimestamp > 0 {
            let dt = max(0.001, timestamp - lastTimestamp)
            velocity = SCNVector3(
                (position.x - lastPosition.x) / Float(dt),
                (position.y - lastPosition.y) / Float(dt),
                (position.z - lastPosition.z) / Float(dt)
            )
        }

        let alpha: Float = 0.42
        if root.isHidden {
            root.position = position
        } else {
            root.position = SCNVector3(
                root.position.x + (position.x - root.position.x) * alpha,
                root.position.y + (position.y - root.position.y) * alpha,
                root.position.z + (position.z - root.position.z) * alpha
            )
        }

        lastPosition = position
        lastTimestamp = timestamp
    }

    func setPinching(_ newValue: Bool, scene: SCNScene, grabbables: [SCNNode]) {
        let changed = newValue != isPinching
        isPinching = newValue
        guard changed else { return }

        if newValue {
            beginGrab(scene: scene, grabbables: grabbables)
        } else {
            release(scene: scene)
        }
    }

    func release(scene: SCNScene) {
        if let joint = grabJoint {
            scene.physicsWorld.removeBehavior(joint)
        }
        grabJoint = nil
        grabbedNode?.physicsBody?.damping = 0.12
        grabbedNode?.physicsBody?.angularDamping = 0.18
        grabbedNode = nil
    }

    private func beginGrab(scene: SCNScene, grabbables: [SCNNode]) {
        guard grabJoint == nil, let handBody = root.physicsBody else { return }

        var nearest: SCNNode?
        var nearestDistance: Float = 0.24
        for node in grabbables {
            guard let body = node.physicsBody, body.type == .dynamic, node.parent != nil else { continue }
            let p = node.presentation.worldPosition
            let h = root.presentation.worldPosition
            let dx = p.x - h.x, dy = p.y - h.y, dz = p.z - h.z
            let d = sqrt(dx * dx + dy * dy + dz * dz)
            if d < nearestDistance {
                nearestDistance = d
                nearest = node
            }
        }

        guard let target = nearest, let targetBody = target.physicsBody else { return }
        let joint = SCNPhysicsBallSocketJoint(
            bodyA: handBody,
            anchorA: SCNVector3Zero,
            bodyB: targetBody,
            anchorB: SCNVector3Zero
        )
        scene.physicsWorld.addBehavior(joint)
        targetBody.damping = 0.45
        targetBody.angularDamping = 0.55
        grabJoint = joint
        grabbedNode = target
    }
}

enum PhysicsCategory {
    static let hand = 1 << 0
    static let grabbable = 1 << 1
    static let npc = 1 << 2
    static let world = 1 << 3
}

private extension SCNVector3 {
    static var zero: SCNVector3 { SCNVector3Zero }
}
