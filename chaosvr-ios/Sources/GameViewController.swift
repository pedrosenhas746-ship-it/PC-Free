import UIKit
import ARKit
import SceneKit
import simd

final class GameViewController: UIViewController, ARSCNViewDelegate {
    private let sceneView = ARSCNView(frame: .zero)
    private let hud = UILabel()
    private var spawned = 0
    private var hits = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupScene()
        setupHUD()
        setupGestures()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else {
            hud.text = "CHAOS VR\nARKit não suportado neste iPhone"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.spawnArena()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    private func setupScene() {
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.scene = SCNScene()
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.scene.physicsWorld.gravity = SCNVector3(0, -9.81, 0)
        view.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: view.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupHUD() {
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.numberOfLines = 0
        hud.textAlignment = .center
        hud.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        hud.textColor = .white
        hud.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        hud.layer.cornerRadius = 10
        hud.layer.masksToBounds = true
        hud.text = "CHAOS VR • MR PHYSICS\nTap: impacto • Duplo tap: spawn • Segure: teia"
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82)
        ])
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapAction(_:)))
        tap.numberOfTapsRequired = 1
        sceneView.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapAction(_:)))
        doubleTap.numberOfTapsRequired = 2
        sceneView.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdAction(_:)))
        hold.minimumPressDuration = 0.28
        sceneView.addGestureRecognizer(hold)
    }

    private func spawnArena() {
        guard let camera = sceneView.session.currentFrame?.camera.transform else { return }
        let origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let forward = -SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        let right = SIMD3<Float>(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z)

        let floorGeo = SCNBox(width: 4.0, height: 0.05, length: 5.0, chamferRadius: 0.02)
        floorGeo.firstMaterial?.diffuse.contents = UIColor(white: 0.08, alpha: 0.28)
        let floor = SCNNode(geometry: floorGeo)
        let floorPos = origin + forward * 1.5 + SIMD3<Float>(0, -1.0, 0)
        floor.position = SCNVector3(floorPos.x, floorPos.y, floorPos.z)
        floor.physicsBody = SCNPhysicsBody.static()
        floor.physicsBody?.friction = 0.9
        sceneView.scene.rootNode.addChildNode(floor)

        for i in 0..<12 {
            let col = Float(i % 4) - 1.5
            let row = Float(i / 4)
            let pos = origin + forward * (1.0 + row * 0.55) + right * (col * 0.38) + SIMD3<Float>(0, -0.45 + row * 0.08, 0)
            spawnProp(at: pos, impulse: nil, target: i % 4 == 0)
        }

        addPortal(at: origin + forward * 2.6 + right * -0.85, color: .systemPurple)
        addPortal(at: origin + forward * 2.6 + right * 0.85, color: .systemTeal)
    }

    private func spawnProp(at position: SIMD3<Float>, impulse: SIMD3<Float>?, target: Bool) {
        let geometry: SCNGeometry
        if target {
            geometry = SCNCapsule(capRadius: 0.10, height: 0.42)
        } else if spawned % 2 == 0 {
            geometry = SCNBox(width: 0.22, height: 0.22, length: 0.22, chamferRadius: 0.025)
        } else {
            geometry = SCNSphere(radius: 0.11)
        }

        let colors: [UIColor] = [.systemOrange, .systemBlue, .systemGreen, .systemRed, .systemYellow, .systemIndigo]
        geometry.firstMaterial?.diffuse.contents = colors[spawned % colors.count]
        geometry.firstMaterial?.metalness.contents = target ? 0.7 : 0.15
        geometry.firstMaterial?.roughness.contents = target ? 0.22 : 0.55

        let node = SCNNode(geometry: geometry)
        node.name = target ? "Target" : "PhysicsProp"
        node.position = SCNVector3(position.x, position.y, position.z)
        node.physicsBody = SCNPhysicsBody.dynamic()
        node.physicsBody?.mass = target ? 4.0 : 1.0
        node.physicsBody?.friction = 0.7
        node.physicsBody?.restitution = 0.22
        node.physicsBody?.damping = 0.16
        node.physicsBody?.angularDamping = 0.22
        sceneView.scene.rootNode.addChildNode(node)
        spawned += 1

        if let impulse {
            node.physicsBody?.applyForce(SCNVector3(impulse.x, impulse.y, impulse.z), asImpulse: true)
        }
        updateHUD("SPAWN")
    }

    private func addPortal(at position: SIMD3<Float>, color: UIColor) {
        let ring = SCNTorus(ringRadius: 0.34, pipeRadius: 0.035)
        ring.firstMaterial?.diffuse.contents = color
        ring.firstMaterial?.emission.contents = color.withAlphaComponent(0.8)
        let node = SCNNode(geometry: ring)
        node.position = SCNVector3(position.x, position.y - 0.2, position.z)
        node.eulerAngles.x = .pi / 2
        node.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: .pi * 2, duration: 4.0)))
        sceneView.scene.rootNode.addChildNode(node)
    }

    @objc private func tapAction(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: sceneView)
        let results = sceneView.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        if let hit = results.first(where: { $0.node.physicsBody?.type == .dynamic }) {
            let camera = sceneView.pointOfView?.presentation.worldPosition ?? SCNVector3Zero
            let p = hit.worldCoordinates
            let dir = normalized(SCNVector3(p.x - camera.x, p.y - camera.y, p.z - camera.z))
            hit.node.physicsBody?.applyForce(SCNVector3(dir.x * 7.5, dir.y * 7.5 + 1.1, dir.z * 7.5), asImpulse: true)
            hits += 1
            updateHUD("IMPACT")
        } else {
            shootOrb()
        }
    }

    @objc private func doubleTapAction(_ gesture: UITapGestureRecognizer) {
        guard let pov = sceneView.pointOfView else { return }
        let t = pov.presentation.simdWorldTransform
        let origin = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        spawnProp(at: origin + forward * 0.65, impulse: forward * 2.0 + SIMD3<Float>(0, 0.45, 0), target: spawned % 5 == 0)
    }

    @objc private func holdAction(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: sceneView)
        let results = sceneView.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        guard let hit = results.first(where: { $0.node.physicsBody?.type == .dynamic }),
              let cameraNode = sceneView.pointOfView else {
            updateHUD("WEB MISSED")
            return
        }

        let start = cameraNode.presentation.worldPosition
        let end = hit.worldCoordinates
        makeWeb(from: start, to: end)
        let dir = normalized(SCNVector3(start.x - end.x, start.y - end.y, start.z - end.z))
        hit.node.physicsBody?.applyForce(SCNVector3(dir.x * 6.0, dir.y * 6.0 + 0.6, dir.z * 6.0), asImpulse: true)
        updateHUD("WEB PULL")
    }

    private func shootOrb() {
        guard let pov = sceneView.pointOfView else { return }
        let t = pov.presentation.simdWorldTransform
        let origin = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        spawnProp(at: origin + forward * 0.35, impulse: forward * 4.8, target: false)
    }

    private func makeWeb(from start: SCNVector3, to end: SCNVector3) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        let length = sqrt(dx * dx + dy * dy + dz * dz)
        guard length > 0.02 else { return }

        let geo = SCNCylinder(radius: 0.008, height: CGFloat(length))
        geo.firstMaterial?.diffuse.contents = UIColor.white
        geo.firstMaterial?.emission.contents = UIColor.white
        let web = SCNNode(geometry: geo)
        web.position = SCNVector3((start.x + end.x) / 2, (start.y + end.y) / 2, (start.z + end.z) / 2)
        web.look(at: end, up: sceneView.scene.rootNode.worldUp, localFront: SCNVector3(0, 1, 0))
        sceneView.scene.rootNode.addChildNode(web)
        web.runAction(.sequence([.wait(duration: 0.55), .fadeOut(duration: 0.2), .removeFromParentNode()]))
    }

    private func normalized(_ v: SCNVector3) -> SCNVector3 {
        let length = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        if length < 0.0001 { return SCNVector3Zero }
        return SCNVector3(v.x / length, v.y / length, v.z / length)
    }

    private func updateHUD(_ action: String) {
        hud.text = "CHAOS VR • \(action)\nProps: \(spawned) • Hits: \(hits) • ARKit 6DoF"
    }
}
