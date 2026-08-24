import SceneKit
import UIKit

final class GorillaLocomotion {
    let rigRoot: SCNNode
    let head: SCNNode
    let leftHand: SCNNode
    let rightHand: SCNNode

    var desiredLeft = SCNVector3(-0.35, 0.05, -0.55)
    var desiredRight = SCNVector3(0.35, 0.05, -0.55)
    var maxArmLength: Float = 1.5
    var jumpMultiplier: Float = 1.35
    var maxJumpSpeed: Float = 7.0
    var velocityLimit: Float = 0.25

    private var lastLeftWorld = SCNVector3Zero
    private var lastRightWorld = SCNVector3Zero
    private var velocityHistory = Array(repeating: SCNVector3Zero, count: 12)
    private var velocityIndex = 0
    private var bodyVelocity = SCNVector3Zero
    private var leftContact: SCNVector3?
    private var rightContact: SCNVector3?
    private var lastTime: TimeInterval = 0

    init(scene: SCNScene) {
        rigRoot = SCNNode(); rigRoot.position = SCNVector3(0, 1.55, 3.2)
        head = SCNNode(); rigRoot.addChildNode(head)
        leftHand = SCNNode(geometry: SCNSphere(radius: 0.075)); rightHand = SCNNode(geometry: SCNSphere(radius: 0.075))
        leftHand.geometry?.firstMaterial?.diffuse.contents = UIColor.white
        rightHand.geometry?.firstMaterial?.diffuse.contents = UIColor.white
        scene.rootNode.addChildNode(rigRoot); scene.rootNode.addChildNode(leftHand); scene.rootNode.addChildNode(rightHand)
        lastLeftWorld = worldDesired(desiredLeft); lastRightWorld = worldDesired(desiredRight)
    }

    func update(time: TimeInterval, scene: SCNScene) {
        let dt = lastTime > 0 ? Float(min(max(time - lastTime, 1.0/120.0), 1.0/20.0)) : 1.0/60.0
        lastTime = time
        var leftDesiredWorld = worldDesired(constrain(desiredLeft))
        var rightDesiredWorld = worldDesired(constrain(desiredRight))

        if let hit = rayHit(scene: scene, from: lastLeftWorld, to: leftDesiredWorld) { leftContact = hit }
        else if let c = leftContact, (leftDesiredWorld - c).length > 0.23 { leftContact = nil }
        if let hit = rayHit(scene: scene, from: lastRightWorld, to: rightDesiredWorld) { rightContact = hit }
        else if let c = rightContact, (rightDesiredWorld - c).length > 0.23 { rightContact = nil }

        var move = SCNVector3Zero; var count: Float = 0
        if let c = leftContact { move = move + (c - leftDesiredWorld); leftDesiredWorld = c; count += 1 }
        if let c = rightContact { move = move + (c - rightDesiredWorld); rightDesiredWorld = c; count += 1 }

        if count > 0 {
            move = move / count; rigRoot.position = rigRoot.position + move
        } else {
            bodyVelocity.y -= 9.8 * dt; rigRoot.position = rigRoot.position + bodyVelocity * dt
            if rigRoot.position.y < 1.25 { rigRoot.position.y = 1.25; bodyVelocity.y = max(0, bodyVelocity.y) }
        }

        leftHand.position = leftDesiredWorld; rightHand.position = rightDesiredWorld
        lastLeftWorld = leftDesiredWorld; lastRightWorld = rightDesiredWorld
        velocityHistory[velocityIndex] = move / max(dt, 0.001)
        velocityIndex = (velocityIndex + 1) % velocityHistory.count
        var avg = SCNVector3Zero
        for v in velocityHistory { avg = avg + v }
        avg = avg / Float(velocityHistory.count)
        if count > 0 && avg.length > velocityLimit {
            let impulse = avg * jumpMultiplier
            bodyVelocity = impulse.length > maxJumpSpeed ? impulse.normalized * maxJumpSpeed : impulse
        }
    }

    private func constrain(_ p: SCNVector3) -> SCNVector3 {
        let d = p.length; return d <= maxArmLength ? p : p.normalized * maxArmLength
    }

    private func worldDesired(_ local: SCNVector3) -> SCNVector3 {
        let m = rigRoot.simdWorldTransform; let v = m * SIMD4<Float>(local.x, local.y, local.z, 1)
        return SCNVector3(v.x, v.y, v.z)
    }

    private func rayHit(scene: SCNScene, from: SCNVector3, to: SCNVector3) -> SCNVector3? {
        guard (to - from).length > 0.001 else { return nil }
        return scene.physicsWorld.rayTestWithSegment(from: from, to: to, options: [.searchMode: SCNPhysicsWorld.TestSearchMode.closest, .backfaceCulling: false]).first?.worldCoordinates
    }
}
