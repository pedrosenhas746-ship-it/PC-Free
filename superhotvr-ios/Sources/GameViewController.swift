import UIKit
import ARKit
import SceneKit
import Vision
import ImageIO
import simd

private struct HandSnapshot {
    let id: Int
    let points: [String: CGPoint]
    let pinch: Bool
    let fist: Bool

    var aimPoint: CGPoint {
        if let a = points["indexTip"], let b = points["thumbTip"] {
            return CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
        }
        return points["wrist"] ?? CGPoint(x: 0.5, y: 0.5)
    }
}

private final class HandOverlayView: UIView {
    var hands: [HandSnapshot] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let chains = [
            ["wrist", "thumbCMC", "thumbMP", "thumbIP", "thumbTip"],
            ["wrist", "indexMCP", "indexPIP", "indexDIP", "indexTip"],
            ["wrist", "middleMCP", "middlePIP", "middleDIP", "middleTip"],
            ["wrist", "ringMCP", "ringPIP", "ringDIP", "ringTip"],
            ["wrist", "littleMCP", "littlePIP", "littleDIP", "littleTip"]
        ]

        for hand in hands {
            let active = hand.pinch || hand.fist
            let color = active ? UIColor.red : UIColor.white
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(active ? 3.5 : 2.0)

            for chain in chains {
                var started = false
                ctx.beginPath()
                for key in chain {
                    guard let p = hand.points[key] else { continue }
                    let v = CGPoint(x: p.x * bounds.width, y: (1.0 - p.y) * bounds.height)
                    if !started { ctx.move(to: v); started = true } else { ctx.addLine(to: v) }
                }
                ctx.strokePath()
            }

            for p in hand.points.values {
                let v = CGPoint(x: p.x * bounds.width, y: (1.0 - p.y) * bounds.height)
                ctx.fillEllipse(in: CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6))
            }
        }
    }
}

final class GameViewController: UIViewController, ARSessionDelegate, SCNSceneRendererDelegate {
    private let session = ARSession()
    private let scene = SCNScene()
    private let leftView = SCNView(frame: .zero)
    private let rightView = SCNView(frame: .zero)
    private let leftOverlay = HandOverlayView(frame: .zero)
    private let rightOverlay = HandOverlayView(frame: .zero)
    private let leftCamera = SCNNode()
    private let rightCamera = SCNNode()
    private let hud = UILabel()

    private let visionQueue = DispatchQueue(label: "superhot.handtracking", qos: .userInteractive)
    private var visionBusy = false
    private var frameCounter = 0
    private var previousPinch = [false, false]
    private var heldNodes: [Int: SCNNode] = [:]
    private var latestCameraTransform = matrix_identity_float4x4
    private var lastCameraTransform: simd_float4x4?
    private var activityUntil: CFTimeInterval = 0
    private var timeScale: Float = 0.08
    private var hits = 0
    private var shots = 0
    private var enemies = 0
    private let ipd: Float = 0.064

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupStereoViews()
        setupScene()
        setupHUD()
        session.delegate = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else {
            hud.text = "SUPERHOT VR\nARKit nao suportado neste iPhone"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        config.environmentTexturing = .none
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.pause()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    private func setupStereoViews() {
        [leftView, rightView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.scene = scene
            $0.backgroundColor = UIColor(white: 0.965, alpha: 1)
            $0.autoenablesDefaultLighting = false
            $0.rendersContinuously = true
            $0.preferredFramesPerSecond = 60
            $0.delegate = self
            $0.isPlaying = true
            view.addSubview($0)
        }

        leftView.pointOfView = leftCamera
        rightView.pointOfView = rightCamera

        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        view.addSubview(divider)

        [leftOverlay, rightOverlay].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            leftView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftView.topAnchor.constraint(equalTo: view.topAnchor),
            leftView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftView.trailingAnchor.constraint(equalTo: view.centerXAnchor),

            rightView.leadingAnchor.constraint(equalTo: view.centerXAnchor),
            rightView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightView.topAnchor.constraint(equalTo: view.topAnchor),
            rightView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            divider.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 2),

            leftOverlay.leadingAnchor.constraint(equalTo: leftView.leadingAnchor),
            leftOverlay.trailingAnchor.constraint(equalTo: leftView.trailingAnchor),
            leftOverlay.topAnchor.constraint(equalTo: leftView.topAnchor),
            leftOverlay.bottomAnchor.constraint(equalTo: leftView.bottomAnchor),

            rightOverlay.leadingAnchor.constraint(equalTo: rightView.leadingAnchor),
            rightOverlay.trailingAnchor.constraint(equalTo: rightView.trailingAnchor),
            rightOverlay.topAnchor.constraint(equalTo: rightView.topAnchor),
            rightOverlay.bottomAnchor.constraint(equalTo: rightView.bottomAnchor)
        ])
    }

    private func setupScene() {
        scene.physicsWorld.gravity = SCNVector3(0, -9.81, 0)
        scene.background.contents = UIColor(white: 0.97, alpha: 1)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 900
        ambient.color = UIColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let omni = SCNLight()
        omni.type = .omni
        omni.intensity = 1400
        omni.castsShadow = true
        let lightNode = SCNNode()
        lightNode.light = omni
        lightNode.position = SCNVector3(0, 2.6, -1.5)
        scene.rootNode.addChildNode(lightNode)

        leftCamera.camera = makeCamera()
        rightCamera.camera = makeCamera()
        scene.rootNode.addChildNode(leftCamera)
        scene.rootNode.addChildNode(rightCamera)

        addRoom()
        addEnemies()
    }

    private func makeCamera() -> SCNCamera {
        let camera = SCNCamera()
        camera.fieldOfView = 78
        camera.zNear = 0.02
        camera.zFar = 80
        camera.wantsHDR = true
        return camera
    }

    private func addRoom() {
        let floor = SCNBox(width: 8, height: 0.06, length: 12, chamferRadius: 0)
        floor.firstMaterial?.diffuse.contents = UIColor(white: 0.9, alpha: 1)
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -1.05, -4.0)
        floorNode.physicsBody = SCNPhysicsBody.static()
        scene.rootNode.addChildNode(floorNode)

        for x in stride(from: -3.0, through: 3.0, by: 1.5) {
            let pillar = SCNBox(width: 0.12, height: 2.5, length: 0.12, chamferRadius: 0)
            pillar.firstMaterial?.diffuse.contents = UIColor(white: 0.78, alpha: 1)
            let node = SCNNode(geometry: pillar)
            node.position = SCNVector3(x, 0.18, -5.6)
            node.physicsBody = SCNPhysicsBody.static()
            scene.rootNode.addChildNode(node)
        }

        for z in [-2.2 as Float, -4.2, -6.2] {
            let cover = SCNBox(width: 1.0, height: 0.75, length: 0.25, chamferRadius: 0.02)
            cover.firstMaterial?.diffuse.contents = UIColor(white: 0.86, alpha: 1)
            let node = SCNNode(geometry: cover)
            node.position = SCNVector3((z == -4.2 ? -1.3 : 1.25), -0.65, z)
            node.physicsBody = SCNPhysicsBody.static()
            scene.rootNode.addChildNode(node)
        }
    }

    private func addEnemies() {
        let positions: [SCNVector3] = [
            SCNVector3(-1.3, -0.45, -2.6),
            SCNVector3(1.15, -0.45, -3.3),
            SCNVector3(0.15, -0.45, -4.8),
            SCNVector3(-1.7, -0.45, -5.9),
            SCNVector3(1.65, -0.45, -6.5)
        ]
        for (i, p) in positions.enumerated() { spawnEnemy(at: p, index: i) }
    }

    private func spawnEnemy(at p: SCNVector3, index: Int) {
        let root = SCNNode()
        root.name = "enemy-\(index)"
        root.position = p

        let bodyGeo = SCNCapsule(capRadius: 0.18, height: 0.72)
        bodyGeo.firstMaterial?.diffuse.contents = UIColor(red: 0.92, green: 0.02, blue: 0.03, alpha: 1)
        bodyGeo.firstMaterial?.roughness.contents = 0.24
        let body = SCNNode(geometry: bodyGeo)
        body.position.y = 0.35
        root.addChildNode(body)

        let headGeo = SCNSphere(radius: 0.17)
        headGeo.firstMaterial?.diffuse.contents = UIColor(red: 0.95, green: 0.03, blue: 0.04, alpha: 1)
        let head = SCNNode(geometry: headGeo)
        head.position.y = 0.87
        root.addChildNode(head)

        let gunGeo = SCNBox(width: 0.08, height: 0.08, length: 0.42, chamferRadius: 0.015)
        gunGeo.firstMaterial?.diffuse.contents = UIColor(white: 0.08, alpha: 1)
        let gun = SCNNode(geometry: gunGeo)
        gun.position = SCNVector3(0.24, 0.45, -0.2)
        root.addChildNode(gun)

        root.physicsBody = SCNPhysicsBody.dynamic()
        root.physicsBody?.mass = 4.5
        root.physicsBody?.friction = 0.8
        root.physicsBody?.restitution = 0.05
        root.physicsBody?.damping = 0.55
        root.physicsBody?.angularDamping = 0.7
        scene.rootNode.addChildNode(root)
        enemies += 1
    }

    private func setupHUD() {
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.numberOfLines = 0
        hud.textAlignment = .center
        hud.textColor = .black
        hud.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        hud.backgroundColor = UIColor.white.withAlphaComponent(0.72)
        hud.layer.cornerRadius = 8
        hud.layer.masksToBounds = true
        hud.text = "SUPERHOT VR • HAND TRACKING\nPINCA = ATIRAR • PUNHO = AGARRAR"
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 5),
            hud.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.48)
        ])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestCameraTransform = frame.camera.transform
        updateActivity(with: frame.camera.transform)

        frameCounter += 1
        guard frameCounter % 3 == 0, !visionBusy else { return }
        visionBusy = true
        let buffer = frame.capturedImage

        visionQueue.async { [weak self] in
            guard let self else { return }
            defer { self.visionBusy = false }
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 2
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
            do {
                try handler.perform([request])
                let observations = request.results ?? []
                let hands = observations.compactMap { self.snapshot(from: $0) }
                    .sorted { ($0.points["wrist"]?.x ?? 0) < ($1.points["wrist"]?.x ?? 0) }
                    .enumerated()
                    .map { HandSnapshot(id: $0.offset, points: $0.element.points, pinch: $0.element.pinch, fist: $0.element.fist) }
                DispatchQueue.main.async { self.consumeHands(hands) }
            } catch {
                DispatchQueue.main.async { self.updateHUD(extra: "Vision: \(error.localizedDescription)") }
            }
        }
    }

    private func snapshot(from observation: VNHumanHandPoseObservation) -> HandSnapshot? {
        let names: [(String, VNHumanHandPoseObservation.JointName)] = [
            ("wrist", .wrist),
            ("thumbCMC", .thumbCMC), ("thumbMP", .thumbMP), ("thumbIP", .thumbIP), ("thumbTip", .thumbTip),
            ("indexMCP", .indexMCP), ("indexPIP", .indexPIP), ("indexDIP", .indexDIP), ("indexTip", .indexTip),
            ("middleMCP", .middleMCP), ("middlePIP", .middlePIP), ("middleDIP", .middleDIP), ("middleTip", .middleTip),
            ("ringMCP", .ringMCP), ("ringPIP", .ringPIP), ("ringDIP", .ringDIP), ("ringTip", .ringTip),
            ("littleMCP", .littleMCP), ("littlePIP", .littlePIP), ("littleDIP", .littleDIP), ("littleTip", .littleTip)
        ]
        var points: [String: CGPoint] = [:]
        for (key, joint) in names {
            if let p = try? observation.recognizedPoint(joint), p.confidence > 0.25 {
                points[key] = p.location
            }
        }
        guard points["wrist"] != nil else { return nil }

        let pinch: Bool = {
            guard let a = points["thumbTip"], let b = points["indexTip"] else { return false }
            return distance(a, b) < 0.075
        }()

        let fist: Bool = {
            guard let palm = points["middleMCP"] else { return false }
            let tips = ["indexTip", "middleTip", "ringTip", "littleTip"].compactMap { points[$0] }
            guard tips.count >= 3 else { return false }
            return tips.map { distance($0, palm) }.reduce(0, +) / CGFloat(tips.count) < 0.145
        }()

        return HandSnapshot(id: 0, points: points, pinch: pinch, fist: fist)
    }

    private func consumeHands(_ hands: [HandSnapshot]) {
        leftOverlay.hands = hands
        rightOverlay.hands = hands

        var labels: [String] = []
        for id in 0..<2 {
            let hand = hands.first(where: { $0.id == id })
            let pinch = hand?.pinch ?? false
            if pinch && !previousPinch[id], let hand { fire(hand: hand) }
            previousPinch[id] = pinch

            if let hand {
                if hand.fist { updateGrab(hand: hand) } else { releaseGrab(id: id) }
                labels.append("H\(id + 1):\(hand.pinch ? "PINCH" : hand.fist ? "GRAB" : "TRACK")")
            } else {
                releaseGrab(id: id)
                labels.append("H\(id + 1):--")
            }
        }

        if !hands.isEmpty { activityUntil = CACurrentMediaTime() + 0.16 }
        updateHUD(extra: labels.joined(separator: " "))
    }

    private func fire(hand: HandSnapshot) {
        activityUntil = CACurrentMediaTime() + 0.22
        shots += 1
        let point = pointInEye(hand.aimPoint, view: leftView)
        let hitsAtPoint = leftView.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        if let hit = hitsAtPoint.first(where: { $0.node.parent?.name?.hasPrefix("enemy-") == true || $0.node.name?.hasPrefix("enemy-") == true }) {
            let enemy = hit.node.name?.hasPrefix("enemy-") == true ? hit.node : (hit.node.parent ?? hit.node)
            enemy.physicsBody?.applyForce(SCNVector3(0, 1.4, -7.5), at: hit.worldCoordinates, asImpulse: true)
            shatter(enemy)
            self.hits += 1
            return
        }

        guard let pov = leftView.pointOfView else { return }
        let origin = pov.presentation.worldPosition
        let far = leftView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0.65))
        let dir = normalized(SCNVector3(far.x - origin.x, far.y - origin.y, far.z - origin.z))

        let bulletGeo = SCNSphere(radius: 0.025)
        bulletGeo.firstMaterial?.diffuse.contents = UIColor.black
        let bullet = SCNNode(geometry: bulletGeo)
        bullet.position = SCNVector3(origin.x + dir.x * 0.18, origin.y + dir.y * 0.18, origin.z + dir.z * 0.18)
        bullet.physicsBody = SCNPhysicsBody.dynamic()
        bullet.physicsBody?.mass = 0.04
        bullet.physicsBody?.isAffectedByGravity = false
        bullet.physicsBody?.continuousCollisionDetectionThreshold = 0.01
        scene.rootNode.addChildNode(bullet)
        bullet.physicsBody?.applyForce(SCNVector3(dir.x * 18, dir.y * 18, dir.z * 18), asImpulse: true)
        bullet.runAction(.sequence([.wait(duration: 3.0), .removeFromParentNode()]))
    }

    private func updateGrab(hand: HandSnapshot) {
        let id = hand.id
        if heldNodes[id] == nil {
            let point = pointInEye(hand.aimPoint, view: leftView)
            let results = leftView.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            if let hit = results.first(where: { $0.node.physicsBody?.type == .dynamic || $0.node.parent?.physicsBody?.type == .dynamic }) {
                let node = hit.node.physicsBody?.type == .dynamic ? hit.node : (hit.node.parent ?? hit.node)
                heldNodes[id] = node
                node.physicsBody?.type = .kinematic
            }
        }

        guard let node = heldNodes[id], let pov = leftView.pointOfView else { return }
        let camera = pov.presentation.simdWorldTransform
        let origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let forward = -SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        let right = SIMD3<Float>(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z)
        let up = SIMD3<Float>(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z)
        let x = Float((hand.aimPoint.x - 0.5) * 0.75)
        let y = Float((hand.aimPoint.y - 0.5) * 0.55)
        let target = origin + forward * 0.72 + right * x + up * y
        node.simdPosition = target
        activityUntil = CACurrentMediaTime() + 0.18
    }

    private func releaseGrab(id: Int) {
        guard let node = heldNodes.removeValue(forKey: id) else { return }
        node.physicsBody?.type = .dynamic
        if let pov = leftView.pointOfView {
            let t = pov.presentation.simdWorldTransform
            let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            node.physicsBody?.velocity = SCNVector3(forward.x * 1.8, forward.y * 1.8, forward.z * 1.8)
        }
    }

    private func shatter(_ node: SCNNode) {
        node.physicsBody?.type = .dynamic
        for _ in 0..<9 {
            let geo = SCNBox(width: 0.07, height: 0.07, length: 0.07, chamferRadius: 0.005)
            geo.firstMaterial?.diffuse.contents = UIColor.red
            let shard = SCNNode(geometry: geo)
            shard.position = node.presentation.worldPosition
            shard.physicsBody = SCNPhysicsBody.dynamic()
            shard.physicsBody?.mass = 0.06
            scene.rootNode.addChildNode(shard)
            let f = SCNVector3(Float.random(in: -2.5...2.5), Float.random(in: 0.3...3.0), Float.random(in: -2.5...2.5))
            shard.physicsBody?.applyForce(f, asImpulse: true)
            shard.runAction(.sequence([.wait(duration: 2.5), .fadeOut(duration: 0.35), .removeFromParentNode()]))
        }
        node.runAction(.sequence([.fadeOut(duration: 0.12), .removeFromParentNode()]))
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let head = latestCameraTransform
        var leftOffset = matrix_identity_float4x4
        leftOffset.columns.3.x = -ipd * 0.5
        var rightOffset = matrix_identity_float4x4
        rightOffset.columns.3.x = ipd * 0.5
        leftCamera.simdTransform = simd_mul(head, leftOffset)
        rightCamera.simdTransform = simd_mul(head, rightOffset)

        let target: Float = CACurrentMediaTime() < activityUntil ? 1.0 : 0.045
        timeScale += (target - timeScale) * 0.16
        scene.physicsWorld.speed = CGFloat(timeScale)
        for child in scene.rootNode.childNodes where child !== leftCamera && child !== rightCamera {
            if child.physicsBody == nil { child.speed = timeScale }
        }
    }

    private func updateActivity(with transform: simd_float4x4) {
        defer { lastCameraTransform = transform }
        guard let old = lastCameraTransform else {
            activityUntil = CACurrentMediaTime() + 0.3
            return
        }
        let a = SIMD3<Float>(old.columns.3.x, old.columns.3.y, old.columns.3.z)
        let b = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let translation = simd_length(a - b)
        let oldForward = -SIMD3<Float>(old.columns.2.x, old.columns.2.y, old.columns.2.z)
        let newForward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let rotationDelta = simd_length(oldForward - newForward)
        if translation > 0.0012 || rotationDelta > 0.0015 {
            activityUntil = CACurrentMediaTime() + 0.14
        }
    }

    private func pointInEye(_ normalized: CGPoint, view: SCNView) -> CGPoint {
        CGPoint(x: normalized.x * view.bounds.width, y: (1.0 - normalized.y) * view.bounds.height)
    }

    private func updateHUD(extra: String) {
        hud.text = "SUPERHOT VR • TIME \(Int(timeScale * 100))%\n\(extra) • SHOTS \(shots) • HITS \(hits)"
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func normalized(_ v: SCNVector3) -> SCNVector3 {
        let l = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        guard l > 0.0001 else { return SCNVector3Zero }
        return SCNVector3(v.x / l, v.y / l, v.z / l)
    }
}
