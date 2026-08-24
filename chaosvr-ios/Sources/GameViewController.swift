import UIKit
import ARKit
import SceneKit
import Vision
import ImageIO
import simd

final class GameViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate, SCNPhysicsContactDelegate {
    private let sceneView = ARSCNView(frame: .zero)
    private let stereoContainer = UIView()
    private let leftView = SCNView()
    private let rightView = SCNView()
    private let leftCamera = SCNNode()
    private let rightCamera = SCNNode()
    private let hud = UILabel()
    private let modeButton = UIButton(type: .system)
    private let spawnButton = UIButton(type: .system)

    private let handRequest = VNDetectHumanHandPoseRequest()
    private let visionQueue = DispatchQueue(label: "chaosvr.handtracking", qos: .userInitiated)
    private var visionBusy = false
    private var lastVisionTimestamp: TimeInterval = 0
    private var lastHandsSeen: TimeInterval = 0

    private var leftHand: PhysicsHand!
    private var rightHand: PhysicsHand!
    private var grabbables: [SCNNode] = []
    private var ragdollParts: [SCNNode] = []
    private var arenaSpawned = false
    private var isVRMode = false
    private var impacts = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupScene()
        setupStereoVR()
        setupHands()
        setupHUD()
        sceneView.scene.physicsWorld.contactDelegate = self
        handRequest.maximumHandCount = 2
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else {
            hud.text = "CHAOS VR\nARKit não é suportado neste iPhone."
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        sceneView.session.delegate = self
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.spawnArenaIfNeeded()
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
        sceneView.scene.physicsWorld.speed = 1
        view.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: view.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 320
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        sceneView.scene.rootNode.addChildNode(ambientNode)
    }

    private func setupStereoVR() {
        stereoContainer.translatesAutoresizingMaskIntoConstraints = false
        stereoContainer.isHidden = true
        stereoContainer.backgroundColor = .black
        view.addSubview(stereoContainer)
        NSLayoutConstraint.activate([
            stereoContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stereoContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stereoContainer.topAnchor.constraint(equalTo: view.topAnchor),
            stereoContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let stack = UIStackView(arrangedSubviews: [leftView, rightView])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stereoContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: stereoContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: stereoContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: stereoContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: stereoContainer.bottomAnchor)
        ])

        for v in [leftView, rightView] {
            v.scene = sceneView.scene
            v.backgroundColor = UIColor(white: 0.015, alpha: 1)
            v.isPlaying = true
            v.rendersContinuously = true
            v.antialiasingMode = .multisampling2X
        }

        let left = SCNCamera()
        left.fieldOfView = 94
        left.zNear = 0.015
        left.zFar = 80
        leftCamera.camera = left

        let right = SCNCamera()
        right.fieldOfView = 94
        right.zNear = 0.015
        right.zFar = 80
        rightCamera.camera = right

        sceneView.scene.rootNode.addChildNode(leftCamera)
        sceneView.scene.rootNode.addChildNode(rightCamera)
        leftView.pointOfView = leftCamera
        rightView.pointOfView = rightCamera
    }

    private func setupHands() {
        leftHand = PhysicsHand(name: "HandLeft", tint: UIColor(red: 0.2, green: 0.75, blue: 1, alpha: 1))
        rightHand = PhysicsHand(name: "HandRight", tint: UIColor(red: 1, green: 0.28, blue: 0.45, alpha: 1))
        sceneView.scene.rootNode.addChildNode(leftHand.root)
        sceneView.scene.rootNode.addChildNode(rightHand.root)
    }

    private func setupHUD() {
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.numberOfLines = 0
        hud.textAlignment = .center
        hud.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        hud.textColor = .white
        hud.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hud.layer.cornerRadius = 10
        hud.layer.masksToBounds = true
        hud.text = "CHAOS VR PHYSICS v0.2\nMostre as mãos para a câmera • junte polegar+indicador para agarrar"
        view.addSubview(hud)

        configureButton(modeButton, title: "VR")
        modeButton.addTarget(self, action: #selector(toggleMode), for: .touchUpInside)
        view.addSubview(modeButton)

        configureButton(spawnButton, title: "+ RAGDOLL")
        spawnButton.addTarget(self, action: #selector(spawnAnotherRagdoll), for: .touchUpInside)
        view.addSubview(spawnButton)

        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.72),

            modeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            modeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            modeButton.widthAnchor.constraint(equalToConstant: 64),
            modeButton.heightAnchor.constraint(equalToConstant: 36),

            spawnButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            spawnButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            spawnButton.widthAnchor.constraint(equalToConstant: 108),
            spawnButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func configureButton(_ button: UIButton, title: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        button.layer.cornerRadius = 10
    }

    @objc private func toggleMode() {
        isVRMode.toggle()
        sceneView.isHidden = isVRMode
        stereoContainer.isHidden = !isVRMode
        modeButton.setTitle(isVRMode ? "MR" : "VR", for: .normal)
        updateHUD(extra: isVRMode ? "STEREO VR" : "MR")
    }

    @objc private func spawnAnotherRagdoll() {
        guard let camera = sceneView.session.currentFrame?.camera.transform else { return }
        let origin = worldPoint(camera: camera, forward: 1.55, down: 0.25, right: 0)
        let parts = RagdollFactory.spawn(in: sceneView.scene, at: SCNVector3(origin.x, origin.y, origin.z))
        ragdollParts.append(contentsOf: parts)
        grabbables.append(contentsOf: parts)
        updateHUD(extra: "RAGDOLL SPAWN")
    }

    private func spawnArenaIfNeeded() {
        guard !arenaSpawned, let camera = sceneView.session.currentFrame?.camera.transform else { return }
        arenaSpawned = true

        let floorPos = worldPoint(camera: camera, forward: 1.7, down: 1.02, right: 0)
        let floorGeo = SCNBox(width: 4.6, height: 0.06, length: 5.5, chamferRadius: 0.025)
        floorGeo.firstMaterial?.diffuse.contents = UIColor(white: 0.09, alpha: 0.30)
        floorGeo.firstMaterial?.roughness.contents = 0.88
        let floor = SCNNode(geometry: floorGeo)
        floor.position = SCNVector3(floorPos.x, floorPos.y, floorPos.z)
        let floorBody = SCNPhysicsBody.static()
        floorBody.categoryBitMask = PhysicsCategory.world
        floorBody.collisionBitMask = PhysicsCategory.hand | PhysicsCategory.grabbable | PhysicsCategory.npc
        floorBody.friction = 0.95
        floor.physicsBody = floorBody
        sceneView.scene.rootNode.addChildNode(floor)

        for i in 0..<8 {
            let column = Float(i % 4) - 1.5
            let row = Float(i / 4)
            let p = worldPoint(camera: camera, forward: 1.0 + row * 0.5, down: 0.42, right: column * 0.32)
            makeCrate(at: SCNVector3(p.x, p.y, p.z), mass: CGFloat(0.7 + Float(i % 3) * 0.8))
        }

        let weaponP = worldPoint(camera: camera, forward: 0.85, down: 0.38, right: 0.45)
        makeCrowbar(at: SCNVector3(weaponP.x, weaponP.y, weaponP.z))

        let npcP = worldPoint(camera: camera, forward: 1.55, down: 0.18, right: -0.35)
        let parts = RagdollFactory.spawn(in: sceneView.scene, at: SCNVector3(npcP.x, npcP.y, npcP.z))
        ragdollParts.append(contentsOf: parts)
        grabbables.append(contentsOf: parts)
    }

    private func makeCrate(at position: SCNVector3, mass: CGFloat) {
        let geo = SCNBox(width: 0.22, height: 0.22, length: 0.22, chamferRadius: 0.025)
        geo.firstMaterial?.diffuse.contents = UIColor(red: 0.27, green: 0.29, blue: 0.33, alpha: 1)
        geo.firstMaterial?.metalness.contents = 0.15
        geo.firstMaterial?.roughness.contents = 0.58
        let node = SCNNode(geometry: geo)
        node.name = "Grab_Crate"
        node.position = position
        let body = SCNPhysicsBody.dynamic()
        body.mass = mass
        body.categoryBitMask = PhysicsCategory.grabbable
        body.collisionBitMask = PhysicsCategory.hand | PhysicsCategory.grabbable | PhysicsCategory.npc | PhysicsCategory.world
        body.contactTestBitMask = PhysicsCategory.hand
        body.friction = 0.72
        body.restitution = 0.12
        body.damping = 0.12
        body.angularDamping = 0.18
        node.physicsBody = body
        sceneView.scene.rootNode.addChildNode(node)
        grabbables.append(node)
    }

    private func makeCrowbar(at position: SCNVector3) {
        let bar = SCNCapsule(capRadius: 0.025, height: 0.62)
        bar.firstMaterial?.diffuse.contents = UIColor(red: 0.45, green: 0.08, blue: 0.06, alpha: 1)
        bar.firstMaterial?.metalness.contents = 0.75
        bar.firstMaterial?.roughness.contents = 0.28
        let node = SCNNode(geometry: bar)
        node.name = "Grab_Crowbar"
        node.position = position
        node.eulerAngles.z = .pi / 2.8

        let hookGeo = SCNTorus(ringRadius: 0.055, pipeRadius: 0.018)
        hookGeo.firstMaterial?.diffuse.contents = UIColor(red: 0.45, green: 0.08, blue: 0.06, alpha: 1)
        let hook = SCNNode(geometry: hookGeo)
        hook.position = SCNVector3(0, 0.30, 0)
        hook.eulerAngles.x = .pi / 2
        node.addChildNode(hook)

        let body = SCNPhysicsBody.dynamic()
        body.mass = 2.4
        body.categoryBitMask = PhysicsCategory.grabbable
        body.collisionBitMask = PhysicsCategory.hand | PhysicsCategory.grabbable | PhysicsCategory.npc | PhysicsCategory.world
        body.contactTestBitMask = PhysicsCategory.hand | PhysicsCategory.npc
        body.friction = 0.82
        body.restitution = 0.06
        body.damping = 0.08
        body.angularDamping = 0.14
        node.physicsBody = body
        sceneView.scene.rootNode.addChildNode(node)
        grabbables.append(node)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateStereoCameras(frame: frame)
        processHands(frame: frame)
    }

    private func updateStereoCameras(frame: ARFrame) {
        guard isVRMode else { return }
        var leftT = frame.camera.transform
        var rightT = frame.camera.transform
        let rightAxis = SIMD3<Float>(frame.camera.transform.columns.0.x, frame.camera.transform.columns.0.y, frame.camera.transform.columns.0.z)
        let ipd: Float = 0.064
        leftT.columns.3.x -= rightAxis.x * ipd * 0.5
        leftT.columns.3.y -= rightAxis.y * ipd * 0.5
        leftT.columns.3.z -= rightAxis.z * ipd * 0.5
        rightT.columns.3.x += rightAxis.x * ipd * 0.5
        rightT.columns.3.y += rightAxis.y * ipd * 0.5
        rightT.columns.3.z += rightAxis.z * ipd * 0.5
        DispatchQueue.main.async { [weak self] in
            self?.leftCamera.simdTransform = leftT
            self?.rightCamera.simdTransform = rightT
        }
    }

    private func processHands(frame: ARFrame) {
        let now = frame.timestamp
        guard now - lastVisionTimestamp > 0.065, !visionBusy else { return }
        lastVisionTimestamp = now
        visionBusy = true
        let pixelBuffer = frame.capturedImage

        visionQueue.async { [weak self] in
            guard let self else { return }
            defer { self.visionBusy = false }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            do {
                try handler.perform([self.handRequest])
                let observations = self.handRequest.results ?? []
                let samples = observations.compactMap { self.handSample(from: $0) }.sorted { $0.screen.x < $1.screen.x }
                DispatchQueue.main.async {
                    self.applyHandSamples(samples, timestamp: now)
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateHUD(extra: "HAND TRACK ERROR")
                }
            }
        }
    }

    private struct HandSample {
        let screen: CGPoint
        let pinch: Bool
        let rotation: Float
        let span: CGFloat
    }

    private func handSample(from observation: VNHumanHandPoseObservation) -> HandSample? {
        guard let wrist = try? observation.recognizedPoint(.wrist),
              let index = try? observation.recognizedPoint(.indexTip),
              let thumb = try? observation.recognizedPoint(.thumbTip),
              let middle = try? observation.recognizedPoint(.middleMCP),
              wrist.confidence > 0.35, index.confidence > 0.35, thumb.confidence > 0.35, middle.confidence > 0.35 else { return nil }

        let cx = CGFloat((wrist.location.x + middle.location.x) * 0.5)
        let cy = CGFloat((wrist.location.y + middle.location.y) * 0.5)
        let dx = CGFloat(index.location.x - thumb.location.x)
        let dy = CGFloat(index.location.y - thumb.location.y)
        let pinchDistance = sqrt(dx * dx + dy * dy)
        let wx = CGFloat(middle.location.x - wrist.location.x)
        let wy = CGFloat(middle.location.y - wrist.location.y)
        let span = sqrt(wx * wx + wy * wy)
        let rotation = Float(atan2(wy, wx))
        return HandSample(screen: CGPoint(x: cx, y: cy), pinch: pinchDistance < 0.055, rotation: rotation, span: span)
    }

    private func applyHandSamples(_ samples: [HandSample], timestamp: TimeInterval) {
        let leftSample = samples.first
        let rightSample = samples.count > 1 ? samples.last : nil

        if let s = leftSample {
            let p = worldHandPosition(sample: s)
            leftHand.root.eulerAngles.z = s.rotation - .pi / 2
            leftHand.update(position: p, timestamp: timestamp, visible: true)
            leftHand.setPinching(s.pinch, scene: sceneView.scene, grabbables: grabbables)
            lastHandsSeen = timestamp
        } else {
            leftHand.update(position: leftHand.root.position, timestamp: timestamp, visible: false)
            leftHand.setPinching(false, scene: sceneView.scene, grabbables: grabbables)
        }

        if let s = rightSample, samples.count > 1 {
            let p = worldHandPosition(sample: s)
            rightHand.root.eulerAngles.z = s.rotation - .pi / 2
            rightHand.update(position: p, timestamp: timestamp, visible: true)
            rightHand.setPinching(s.pinch, scene: sceneView.scene, grabbables: grabbables)
            lastHandsSeen = timestamp
        } else {
            rightHand.update(position: rightHand.root.position, timestamp: timestamp, visible: false)
            rightHand.setPinching(false, scene: sceneView.scene, grabbables: grabbables)
        }

        let status: String
        if samples.isEmpty {
            status = "MÃOS NÃO VISÍVEIS"
        } else if samples.count == 1 {
            status = "1 MÃO • \(leftSample?.pinch == true ? "GRIP" : "OPEN")"
        } else {
            status = "2 MÃOS • L:\(leftSample?.pinch == true ? "GRIP" : "OPEN") R:\(rightSample?.pinch == true ? "GRIP" : "OPEN")"
        }
        updateHUD(extra: status)
    }

    private func worldHandPosition(sample: HandSample) -> SCNVector3 {
        let size = sceneView.bounds.size
        let point = CGPoint(x: sample.screen.x * size.width, y: (1 - sample.screen.y) * size.height)
        let near = sceneView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0.02))
        let far = sceneView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0.98))
        let ray = normalized(SCNVector3(far.x - near.x, far.y - near.y, far.z - near.z))
        let camera = sceneView.pointOfView?.presentation.worldPosition ?? near
        let estimatedDepth = max(0.34, min(0.88, Float(0.72 - sample.span * 1.6)))
        return SCNVector3(camera.x + ray.x * estimatedDepth, camera.y + ray.y * estimatedDepth, camera.z + ray.z * estimatedDepth)
    }

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        let a = contact.nodeA
        let b = contact.nodeB
        if isHandNode(a) { applyHandImpact(handNode: a, other: b) }
        else if isHandNode(b) { applyHandImpact(handNode: b, other: a) }
    }

    private func isHandNode(_ node: SCNNode) -> Bool {
        node === leftHand.root || node === rightHand.root || node.name?.hasPrefix("Hand") == true
    }

    private func applyHandImpact(handNode: SCNNode, other: SCNNode) {
        guard let body = other.physicsBody, body.type == .dynamic else { return }
        let v = handNode === leftHand.root ? leftHand.velocity : rightHand.velocity
        let speed = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        guard speed > 0.55 else { return }
        let capped = min(speed, 5.5)
        let impulse = SCNVector3(v.x / max(speed, 0.001) * capped * 1.55,
                                 v.y / max(speed, 0.001) * capped * 1.55,
                                 v.z / max(speed, 0.001) * capped * 1.55)
        body.applyForce(impulse, at: contactPointNear(node: other), asImpulse: true)
        impacts += 1
        updateHUD(extra: "PHYSICS HIT x\(impacts)")
    }

    private func contactPointNear(node: SCNNode) -> SCNVector3 {
        node.presentation.worldPosition
    }

    private func worldPoint(camera: simd_float4x4, forward: Float, down: Float, right: Float) -> SIMD3<Float> {
        let origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let f = -SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        let r = SIMD3<Float>(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z)
        return origin + f * forward + r * right + SIMD3<Float>(0, -down, 0)
    }

    private func normalized(_ v: SCNVector3) -> SCNVector3 {
        let length = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        guard length > 0.0001 else { return SCNVector3Zero }
        return SCNVector3(v.x / length, v.y / length, v.z / length)
    }

    private func updateHUD(extra: String) {
        let mode = isVRMode ? "VR STEREO" : "MR"
        hud.text = "CHAOS VR PHYSICS v0.2 • \(mode)\n\(extra) • pinch=grab • soco usa velocidade real da mão"
    }
}
