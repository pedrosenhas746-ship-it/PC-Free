import SceneKit
import UIKit

final class WorldBuilder {
    static let shared = WorldBuilder()
    private(set) var gorillaTemplate: SCNNode?

    func buildWorld() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.57, green: 0.79, blue: 0.90, alpha: 1)
        scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)

        let floor = SCNNode(geometry: SCNBox(width: 36, height: 0.35, length: 36, chamferRadius: 0.1))
        floor.position = SCNVector3(0, -0.25, 0)
        floor.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.39, green: 0.28, blue: 0.17, alpha: 1)
        floor.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        floor.name = "ground"
        scene.rootNode.addChildNode(floor)

        let stump = SCNNode(geometry: SCNCylinder(radius: 2.4, height: 0.55))
        stump.position = SCNVector3(0, 0.15, -4.2)
        stump.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.38, green: 0.20, blue: 0.08, alpha: 1)
        stump.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        scene.rootNode.addChildNode(stump)

        for i in 0..<22 {
            let angle = Float(i) / 22 * Float.pi * 2
            let radius: Float = 9 + Float((i * 13) % 7) * 0.65
            addTree(to: scene.rootNode,
                    at: SCNVector3(cos(angle) * radius, 0, sin(angle) * radius),
                    scale: 0.85 + Float(i % 5) * 0.12)
        }

        for i in 0..<8 {
            let platform = SCNNode(geometry: SCNBox(width: 2.4, height: 0.25, length: 2.4, chamferRadius: 0.08))
            platform.position = SCNVector3(Float((i % 4) * 4 - 6), Float(1 + (i / 4) * 2), Float((i / 4) * -5 + 2))
            platform.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.55, green: 0.32, blue: 0.14, alpha: 1)
            platform.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
            scene.rootNode.addChildNode(platform)
        }

        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 1100
        sun.eulerAngles = SCNVector3(-0.8, 0.6, 0); scene.rootNode.addChildNode(sun)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 430
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    private func addTree(to root: SCNNode, at position: SCNVector3, scale: Float) {
        let trunk = SCNNode(geometry: SCNCylinder(radius: CGFloat(0.42 * scale), height: CGFloat(5.2 * scale)))
        trunk.position = position + SCNVector3(0, 2.6 * scale, 0)
        trunk.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.42, green: 0.24, blue: 0.11, alpha: 1)
        trunk.physicsBody = SCNPhysicsBody(type: .static, shape: nil); root.addChildNode(trunk)
        let crown = SCNNode(geometry: SCNSphere(radius: CGFloat(2.05 * scale)))
        crown.position = position + SCNVector3(0, 5.2 * scale, 0); crown.scale = SCNVector3(1, 0.72, 1)
        crown.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.20, green: 0.45, blue: 0.16, alpha: 1)
        crown.physicsBody = SCNPhysicsBody(type: .static, shape: nil); root.addChildNode(crown)
    }

    func loadGorilla(completion: @escaping (SCNNode?) -> Void) { completion(nil) }

    func makeFallbackGorilla(hue: Float) -> SCNNode {
        let root = SCNNode()
        let color = UIColor(hue: CGFloat(hue), saturation: 0.78, brightness: 0.86, alpha: 1)
        let body = SCNNode(geometry: SCNSphere(radius: 0.42)); body.scale = SCNVector3(1, 1.25, 0.75); body.position.y = 0.9
        body.geometry?.firstMaterial?.diffuse.contents = color; root.addChildNode(body)
        let head = SCNNode(geometry: SCNSphere(radius: 0.32)); head.position = SCNVector3(0, 1.48, -0.03)
        head.geometry?.firstMaterial?.diffuse.contents = color; root.addChildNode(head)
        for side: Float in [-1, 1] {
            let arm = SCNNode(geometry: SCNCapsule(capRadius: 0.11, height: 0.75)); arm.position = SCNVector3(side * 0.48, 0.95, 0)
            arm.eulerAngles.z = side * 0.6; arm.geometry?.firstMaterial?.diffuse.contents = color; root.addChildNode(arm)
        }
        return root
    }

    func tint(_ node: SCNNode, hue: Float) {
        let color = UIColor(hue: CGFloat(hue), saturation: 0.80, brightness: 0.90, alpha: 1)
        node.enumerateChildNodes { child, _ in child.geometry?.materials.forEach { $0.multiply.contents = color } }
    }
}
