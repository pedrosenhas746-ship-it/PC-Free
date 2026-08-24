import Foundation
import SceneKit
import ModelIO
import UIKit
import GLTFKit2

final class WorldBuilder {
    static let shared = WorldBuilder()
    private(set) var gorillaTemplate: SCNNode?
    private(set) var spawnPosition = SCNVector3(0, 1.55, 3.2)

    func buildWorld() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.57, green: 0.79, blue: 0.90, alpha: 1)
        scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)

        if !loadBundledMap(into: scene) {
            buildFallbackWorld(into: scene)
        }

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1100
        sun.eulerAngles = SCNVector3(-0.8, 0.6, 0)
        scene.rootNode.addChildNode(sun)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 430
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    private func loadBundledMap(into scene: SCNScene) -> Bool {
        guard let fbxURL = Bundle.main.url(forResource: "GorillaTagMap", withExtension: "fbx", subdirectory: "Assets") else {
            return false
        }
        let fm = FileManager.default
        guard let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        let size = (try? fm.attributesOfItem(atPath: fbxURL.path)[.size] as? NSNumber)?.intValue ?? 0
        let objURL = cache.appendingPathComponent("GorillaTagMap-\(size).obj")
        let textureDir = Bundle.main.bundleURL.appendingPathComponent("Assets/textures", isDirectory: true)

        if !fm.fileExists(atPath: objURL.path) {
            var sx: Float = 0, sy: Float = 1.55, sz: Float = 3.2
            let result = gtag_convert_fbx_to_obj(fbxURL.path, objURL.path, textureDir.path, &sx, &sy, &sz)
            guard result == 0 else { return false }
            spawnPosition = SCNVector3(sx, sy, sz)
            UserDefaults.standard.set([sx, sy, sz], forKey: "monketag.map.spawn.\(size)")
        } else if let saved = UserDefaults.standard.array(forKey: "monketag.map.spawn.\(size)") as? [NSNumber], saved.count == 3 {
            spawnPosition = SCNVector3(saved[0].floatValue, saved[1].floatValue, saved[2].floatValue)
        }

        let asset = MDLAsset(url: objURL)
        asset.loadTextures()
        guard asset.count > 0 else { return false }
        let mapRoot = SCNNode()
        mapRoot.name = "GorillaTagMap_REAL"
        for i in 0..<asset.count {
            let object = asset.object(at: i)
            mapRoot.addChildNode(SCNNode(mdlObject: object))
        }
        mapRoot.enumerateChildNodes { node, _ in
            node.categoryBitMask = 1
            node.geometry?.materials.forEach {
                $0.lightingModel = .lambert
                $0.isDoubleSided = true
            }
        }
        mapRoot.categoryBitMask = 1
        scene.rootNode.addChildNode(mapRoot)
        return true
    }

    private func buildFallbackWorld(into scene: SCNScene) {
        let floor = SCNNode(geometry: SCNBox(width: 36, height: 0.35, length: 36, chamferRadius: 0.1))
        floor.position = SCNVector3(0, -0.25, 0)
        floor.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.39, green: 0.28, blue: 0.17, alpha: 1)
        floor.name = "ground"
        floor.categoryBitMask = 1
        scene.rootNode.addChildNode(floor)

        let stump = SCNNode(geometry: SCNCylinder(radius: 2.4, height: 0.55))
        stump.position = SCNVector3(0, 0.15, -4.2)
        stump.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.38, green: 0.20, blue: 0.08, alpha: 1)
        stump.categoryBitMask = 1
        scene.rootNode.addChildNode(stump)

        for i in 0..<22 {
            let angle = Float(i) / 22 * Float.pi * 2
            let radius: Float = 9 + Float((i * 13) % 7) * 0.65
            addTree(to: scene.rootNode, at: SCNVector3(cos(angle) * radius, 0, sin(angle) * radius), scale: 0.85 + Float(i % 5) * 0.12)
        }
    }

    private func addTree(to root: SCNNode, at position: SCNVector3, scale: Float) {
        let trunk = SCNNode(geometry: SCNCylinder(radius: CGFloat(0.42 * scale), height: CGFloat(5.2 * scale)))
        trunk.position = position + SCNVector3(0, 2.6 * scale, 0)
        trunk.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.42, green: 0.24, blue: 0.11, alpha: 1)
        trunk.categoryBitMask = 1
        root.addChildNode(trunk)
        let crown = SCNNode(geometry: SCNSphere(radius: CGFloat(2.05 * scale)))
        crown.position = position + SCNVector3(0, 5.2 * scale, 0)
        crown.scale = SCNVector3(1, 0.72, 1)
        crown.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.20, green: 0.45, blue: 0.16, alpha: 1)
        crown.categoryBitMask = 1
        root.addChildNode(crown)
    }

    func loadGorilla(completion: @escaping (SCNNode?) -> Void) {
        guard let url = Bundle.main.url(forResource: "monke", withExtension: "glb", subdirectory: "Assets") else {
            completion(nil)
            return
        }
        GLTFAsset.load(with: url, options: [:]) { [weak self] _, status, maybeAsset, _, _ in
            guard status == .complete, let asset = maybeAsset else { return }
            DispatchQueue.main.async {
                let source = GLTFSCNSceneSource(asset: asset)
                guard let loadedScene = source.defaultScene else { completion(nil); return }
                let model = SCNNode()
                for child in loadedScene.rootNode.childNodes { model.addChildNode(child.clone()) }
                let container = SCNNode()
                if let box = self?.normalizedBox(for: model) {
                    let h = max(box.max.y - box.min.y, 0.001)
                    let s = Float(1.72 / h)
                    model.scale = SCNVector3(s, s, s)
                    let cx = (box.min.x + box.max.x) * 0.5
                    let cz = (box.min.z + box.max.z) * 0.5
                    model.position = SCNVector3(-cx * s, -box.min.y * s, -cz * s)
                }
                container.addChildNode(model)
                container.name = "REAL_MONKE_RIG"
                container.categoryBitMask = 2
                container.enumerateChildNodes { node, _ in node.categoryBitMask = 2 }
                self?.gorillaTemplate = container
                completion(container)
            }
        }
    }

    private func normalizedBox(for node: SCNNode) -> (min: SCNVector3, max: SCNVector3)? {
        var min = SCNVector3Zero, max = SCNVector3Zero
        return node.getBoundingBoxMin(&min, max: &max) ? (min, max) : nil
    }

    func makeFallbackGorilla(hue: Float) -> SCNNode {
        let root = SCNNode()
        root.categoryBitMask = 2
        let color = UIColor(hue: CGFloat(hue), saturation: 0.78, brightness: 0.86, alpha: 1)
        let body = SCNNode(geometry: SCNSphere(radius: 0.42)); body.scale = SCNVector3(1, 1.25, 0.75); body.position.y = 0.9
        body.geometry?.firstMaterial?.diffuse.contents = color; body.categoryBitMask = 2; root.addChildNode(body)
        let head = SCNNode(geometry: SCNSphere(radius: 0.32)); head.position = SCNVector3(0, 1.48, -0.03)
        head.geometry?.firstMaterial?.diffuse.contents = color; head.categoryBitMask = 2; root.addChildNode(head)
        for side: Float in [-1, 1] {
            let arm = SCNNode(geometry: SCNCapsule(capRadius: 0.11, height: 0.75)); arm.position = SCNVector3(side * 0.48, 0.95, 0)
            arm.eulerAngles.z = side * 0.6; arm.geometry?.firstMaterial?.diffuse.contents = color; arm.categoryBitMask = 2; root.addChildNode(arm)
        }
        return root
    }

    func tint(_ node: SCNNode, hue: Float) {
        let color = UIColor(hue: CGFloat(hue), saturation: 0.80, brightness: 0.90, alpha: 1)
        node.enumerateChildNodes { child, _ in
            child.geometry?.materials.forEach { $0.multiply.contents = color }
        }
    }
}
