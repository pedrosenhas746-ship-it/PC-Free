import SceneKit
import UIKit

struct RagdollFactory {
    static func spawn(in scene: SCNScene, at origin: SCNVector3) -> [SCNNode] {
        var parts: [SCNNode] = []

        func makePart(_ name: String, geometry: SCNGeometry, position: SCNVector3, mass: CGFloat) -> SCNNode {
            geometry.firstMaterial?.diffuse.contents = UIColor(white: 0.82, alpha: 1)
            geometry.firstMaterial?.roughness.contents = 0.55
            let node = SCNNode(geometry: geometry)
            node.name = name
            node.position = position
            let body = SCNPhysicsBody.dynamic()
            body.mass = mass
            body.categoryBitMask = PhysicsCategory.npc
            body.collisionBitMask = PhysicsCategory.hand | PhysicsCategory.grabbable | PhysicsCategory.npc | PhysicsCategory.world
            body.contactTestBitMask = PhysicsCategory.hand
            body.friction = 0.75
            body.restitution = 0.08
            body.damping = 0.18
            body.angularDamping = 0.28
            node.physicsBody = body
            scene.rootNode.addChildNode(node)
            parts.append(node)
            return node
        }

        let pelvis = makePart("NPC_Pelvis", geometry: SCNBox(width: 0.28, height: 0.18, length: 0.16, chamferRadius: 0.04), position: origin, mass: 8)
        let torso = makePart("NPC_Torso", geometry: SCNBox(width: 0.34, height: 0.42, length: 0.18, chamferRadius: 0.06), position: SCNVector3(origin.x, origin.y + 0.30, origin.z), mass: 14)
        let head = makePart("NPC_Head", geometry: SCNSphere(radius: 0.13), position: SCNVector3(origin.x, origin.y + 0.63, origin.z), mass: 5)

        let upperArmL = makePart("NPC_UpperArm_L", geometry: SCNCapsule(capRadius: 0.055, height: 0.30), position: SCNVector3(origin.x - 0.25, origin.y + 0.36, origin.z), mass: 3)
        let lowerArmL = makePart("NPC_LowerArm_L", geometry: SCNCapsule(capRadius: 0.045, height: 0.28), position: SCNVector3(origin.x - 0.25, origin.y + 0.08, origin.z), mass: 2.2)
        let upperArmR = makePart("NPC_UpperArm_R", geometry: SCNCapsule(capRadius: 0.055, height: 0.30), position: SCNVector3(origin.x + 0.25, origin.y + 0.36, origin.z), mass: 3)
        let lowerArmR = makePart("NPC_LowerArm_R", geometry: SCNCapsule(capRadius: 0.045, height: 0.28), position: SCNVector3(origin.x + 0.25, origin.y + 0.08, origin.z), mass: 2.2)

        let upperLegL = makePart("NPC_UpperLeg_L", geometry: SCNCapsule(capRadius: 0.065, height: 0.40), position: SCNVector3(origin.x - 0.10, origin.y - 0.30, origin.z), mass: 5)
        let lowerLegL = makePart("NPC_LowerLeg_L", geometry: SCNCapsule(capRadius: 0.055, height: 0.40), position: SCNVector3(origin.x - 0.10, origin.y - 0.67, origin.z), mass: 4)
        let upperLegR = makePart("NPC_UpperLeg_R", geometry: SCNCapsule(capRadius: 0.065, height: 0.40), position: SCNVector3(origin.x + 0.10, origin.y - 0.30, origin.z), mass: 5)
        let lowerLegR = makePart("NPC_LowerLeg_R", geometry: SCNCapsule(capRadius: 0.055, height: 0.40), position: SCNVector3(origin.x + 0.10, origin.y - 0.67, origin.z), mass: 4)

        func joint(_ a: SCNNode, _ anchorA: SCNVector3, _ b: SCNNode, _ anchorB: SCNVector3) {
            guard let bodyA = a.physicsBody, let bodyB = b.physicsBody else { return }
            scene.physicsWorld.addBehavior(SCNPhysicsBallSocketJoint(bodyA: bodyA, anchorA: anchorA, bodyB: bodyB, anchorB: anchorB))
        }

        joint(pelvis, SCNVector3(0, 0.10, 0), torso, SCNVector3(0, -0.20, 0))
        joint(torso, SCNVector3(0, 0.22, 0), head, SCNVector3(0, -0.12, 0))
        joint(torso, SCNVector3(-0.18, 0.12, 0), upperArmL, SCNVector3(0, 0.14, 0))
        joint(upperArmL, SCNVector3(0, -0.14, 0), lowerArmL, SCNVector3(0, 0.13, 0))
        joint(torso, SCNVector3(0.18, 0.12, 0), upperArmR, SCNVector3(0, 0.14, 0))
        joint(upperArmR, SCNVector3(0, -0.14, 0), lowerArmR, SCNVector3(0, 0.13, 0))
        joint(pelvis, SCNVector3(-0.10, -0.08, 0), upperLegL, SCNVector3(0, 0.19, 0))
        joint(upperLegL, SCNVector3(0, -0.19, 0), lowerLegL, SCNVector3(0, 0.19, 0))
        joint(pelvis, SCNVector3(0.10, -0.08, 0), upperLegR, SCNVector3(0, 0.19, 0))
        joint(upperLegR, SCNVector3(0, -0.19, 0), lowerLegR, SCNVector3(0, 0.19, 0))

        return parts
    }
}
