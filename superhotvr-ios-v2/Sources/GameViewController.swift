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
        return points["indexTip"] ?? points["wrist"] ?? CGPoint(x: 0.5, y: 0.5)
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
            let color = active ? UIColor.red : UIColor.black
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(active ? 3.0 : 2.0)
            for chain in chains {
                ctx.beginPath()
                var started = false
                for key in chain {
                    guard let p = hand.points[key] else { continue }
                    let v = CGPoint(x: p.x * bounds.width, y: (1 - p.y) * bounds.height)
                    if started { ctx.addLine(to: v) } else { ctx.move(to: v); started = true }
                }
                ctx.strokePath()
            }
            for p in hand.points.values {
                let v = CGPoint(x: p.x * bounds.width, y: (1 - p.y) * bounds.height)
                ctx.fillEllipse(in: CGRect(x: v.x - 2.5, y: v.y - 2.5, width: 5, height: 5))
            }
        }
    }
}

final class GameViewController: UIViewController, ARSessionDelegate, SCNSceneRendererDelegate {
    private let session = ARSession()
    private let scene = SCNScene()
    private let staticContainer = SCNNode()
    private let gameplayContainer = SCNNode()
    private let leftView = SCNView(frame: .zero)
    private let rightView = SCNView(frame: .zero)
    private let leftCamera = SCNNode()
    private let rightCamera = SCNNode()
    private let leftOverlay = HandOverlayView(frame: .zero)
    private let rightOverlay = HandOverlayView(frame: .zero)
    private var hudLabels: [UILabel] = []

    private let visionQueue = DispatchQueue(label: "superhot.full.handtracking", qos: .userInteractive)
    private let levelQueue = DispatchQueue(label: "superhot.full.level-loader", qos: .userInitiated)
    private var visionBusy = false
    private var frameCounter = 0
    private var previousPinch = [false, false]
    private var heldNodes: [Int: SCNNode] = [:]
    private var lastHandPoints: [Int: CGPoint] = [:]
    private var latestCameraTransform = matrix_identity_float4x4
    private var lastCameraTransform: simd_float4x4?
    private var activityUntil: CFTimeInterval = 0
    private var timeScale: Float = 0.05
    private var hits = 0
    private var shots = 0
    private var enemies = 0
    private let ipd: Float = 0.064

    private var levelURLs: [URL] = []
    private var levelIndex = 0
    private var levelLoading = false
    private var bothFistsSince: CFTimeInterval?
    private var nextLevelCooldown: CFTimeInterval = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        setupStereo()
        setupScene()
        setupHUD()
        discoverLevels()
        session.delegate = self

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(debugNextLevel))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else {
            setHUD("ARKit 6DoF nao suportado neste iPhone")
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        config.environmentTexturing = .none
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.loadLevel() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.pause()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    private func setupStereo() {
        for scnView in [leftView, rightView] {
            scnView.translatesAutoresizingMaskIntoConstraints = false
            scnView.scene = scene
            scnView.backgroundColor = UIColor(white: 0.965, alpha: 1)
            scnView.autoenablesDefaultLighting = false
            scnView.rendersContinuously = true
            scnView.preferredFramesPerSecond = 60
            scnView.delegate = self
            scnView.isPlaying = true
            scnView.antialiasingMode = .multisampling2X
            view.addSubview(scnView)
        }
        leftView.pointOfView = leftCamera
        rightView.pointOfView = rightCamera

        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .black
        view.addSubview(divider)

        for overlay in [leftOverlay, rightOverlay] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
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
        scene.background.contents = UIColor(white: 0.97, alpha: 1)
        scene.physicsWorld.gravity = SCNVector3(0, -9.81, 0)
        scene.rootNode.addChildNode(staticContainer)
        scene.rootNode.addChildNode(gameplayContainer)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 1050
        ambient.color = UIColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let omni = SCNLight()
        omni.type = .omni
        omni.intensity = 1500
        omni.castsShadow = false
        let lightNode = SCNNode()
        lightNode.light = omni
        lightNode.position = SCNVector3(0, 3.2, 0)
        scene.rootNode.addChildNode(lightNode)

        leftCamera.camera = makeCamera()
        rightCamera.camera = makeCamera()
        scene.rootNode.addChildNode(leftCamera)
        scene.rootNode.addChildNode(rightCamera)
    }

    private func makeCamera() -> SCNCamera {
        let camera = SCNCamera()
        camera.fieldOfView = 82
        camera.zNear = 0.025
        camera.zFar = 120
        camera.wantsHDR = false
        return camera
    }

    private func setupHUD() {
        for host in [leftView, rightView] {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = .monospacedSystemFont(ofSize: 9.5, weight: .bold)
            label.textColor = .black
            label.backgroundColor = UIColor.white.withAlphaComponent(0.7)
            label.layer.cornerRadius = 7
            label.layer.masksToBounds = true
            host.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                label.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 4),
                label.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.9)
            ])
            hudLabels.append(label)
        }
        updateHUD(extra: "PINCA = ATIRAR | PUNHO = AGARRAR | 2 PUNHOS = PROXIMA FASE")
    }

    private func discoverLevels() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("OriginalAssets") else { return }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "glb" { urls.append(url) }
        levelURLs = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func loadLevel() {
        guard !levelLoading else { return }
        levelLoading = true
        heldNodes.removeAll()
        staticContainer.childNodes.forEach { $0.removeFromParentNode() }
        gameplayContainer.childNodes.forEach { $0.removeFromParentNode() }
        enemies = 0

        guard !levelURLs.isEmpty else {
            buildFallbackRoom()
            spawnEnemies()
            levelLoading = false
            updateHUD(extra: "Assets originais nao encontrados no bundle; fallback ativo")
            return
        }

        levelIndex = ((levelIndex % levelURLs.count) + levelURLs.count) % levelURLs.count
        let url = levelURLs[levelIndex]
        setHUD("Carregando fase \(levelIndex + 1)/\(levelURLs.count) • \(url.deletingPathExtension().lastPathComponent)")

        levelQueue.async { [weak self] in
            guard let self else { return }
            do {
                let recovered = try GLBSceneLoader.load(url: url)
                self.normalizeRecoveredLevel(recovered)
                DispatchQueue.main.async {
                    self.staticContainer.addChildNode(recovered)
                    self.addPhysicsFloor()
                    self.spawnEnemies()
                    self.levelLoading = false
                    self.updateHUD(extra: "\(url.deletingPathExtension().lastPathComponent) carregado")
                }
            } catch {
                DispatchQueue.main.async {
                    self.buildFallbackRoom()
                    self.spawnEnemies()
                    self.levelLoading = false
                    self.updateHUD(extra: "Falha ao abrir GLB: \(error.localizedDescription)")
                }
            }
        }
    }

    private func normalizeRecoveredLevel(_ root: SCNNode) {
        var globalMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var globalMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var found = false

        root.enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }
            let box = node.boundingBox
            let corners = [
                SIMD3<Float>(box.min.x, box.min.y, box.min.z), SIMD3<Float>(box.max.x, box.min.y, box.min.z),
                SIMD3<Float>(box.min.x, box.max.y, box.min.z), SIMD3<Float>(box.max.x, box.max.y, box.min.z),
                SIMD3<Float>(box.min.x, box.min.y, box.max.z), SIMD3<Float>(box.max.x, box.min.y, box.max.z),
                SIMD3<Float>(box.min.x, box.max.y, box.max.z), SIMD3<Float>(box.max.x, box.max.y, box.max.z)
            ]
            let transform = node.simdWorldTransform
            for p in corners {
                let q4 = simd_mul(transform, SIMD4<Float>(p.x, p.y, p.z, 1))
                let q = SIMD3<Float>(q4.x, q4.y, q4.z)
                globalMin = simd_min(globalMin, q)
                globalMax = simd_max(globalMax, q)
                found = true
            }
        }
        guard found else { return }

        let extent = globalMax - globalMin
        let largest = max(extent.x, max(extent.y, extent.z))
        var scale: Float = 1
        if largest > 45 { scale = 30 / largest }
        if largest > 0, largest < 5 { scale = min(2.0, 8 / largest) }
        let centerX = (globalMin.x + globalMax.x) * 0.5
        let centerZ = (globalMin.z + globalMax.z) * 0.5
        root.simdScale = SIMD3<Float>(repeating: scale)
        root.simdPosition = SIMD3<Float>(-centerX * scale, -1.02 - globalMin.y * scale, -4.0 - centerZ * scale)
    }

    private func addPhysicsFloor() {
        let floor = SCNBox(width: 45, height: 0.04, length: 45, chamferRadius: 0)
        floor.firstMaterial?.diffuse.contents = UIColor.clear
        let node = SCNNode(geometry: floor)
        node.position = SCNVector3(0, -1.04, -5)
        node.opacity = 0.01
        node.physicsBody = SCNPhysicsBody.static()
        node.physicsBody?.friction = 0.9
        staticContainer.addChildNode(node)
    }

    private func buildFallbackRoom() {
        let floor = SCNBox(width: 8, height: 0.05, length: 12, chamferRadius: 0)
        floor.firstMaterial?.diffuse.contents = UIColor(white: 0.9, alpha: 1)
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -1.03, -5)
        floorNode.physicsBody = SCNPhysicsBody.static()
        staticContainer.addChildNode(floorNode)
        for i in 0..<8 {
            let box = SCNBox(width: 0.25, height: 2.4, length: 0.25, chamferRadius: 0)
            box.firstMaterial?.diffuse.contents = UIColor(white: 0.82, alpha: 1)
            let n = SCNNode(geometry: box)
            n.position = SCNVector3(Float(i % 4) * 1.6 - 2.4, 0.2, Float(i / 4) * -3.5 - 3)
            staticContainer.addChildNode(n)
        }
        addPhysicsFloor()
    }

    private func spawnEnemies() {
        let count = 6 + (levelIndex % 4)
        let positions: [SCNVector3] = [
            SCNVector3(-1.2, -0.58, -2.6), SCNVector3(1.1, -0.58, -3.0), SCNVector3(0.0, -0.58, -4.0),
            SCNVector3(-1.7, -0.58, -4.8), SCNVector3(1.7, -0.58, -5.2), SCNVector3(-0.6, -0.58, -6.0),
            SCNVector3(0.9, -0.58, -6.7), SCNVector3(2.0, -0.58, -7.4), SCNVector3(-2.0, -0.58, -7.7)
        ]
        for i in 0..<min(count, positions.count) { spawnEnemy(at: positions[i], index: i) }
    }

    private func spawnEnemy(at position: SCNVector3, index: Int) {
        let bodyGeo = SCNCapsule(capRadius: 0.19, height: 0.82)
        bodyGeo.firstMaterial?.diffuse.contents = UIColor(red: 0.93, green: 0.015, blue: 0.02, alpha: 1)
        bodyGeo.firstMaterial?.roughness.contents = 0.28
        let enemy = SCNNode(geometry: bodyGeo)
        enemy.name = "enemy-\(index)"
        enemy.position = position
        enemy.physicsBody = SCNPhysicsBody.dynamic()
        enemy.physicsBody?.mass = 3.6
        enemy.physicsBody?.friction = 0.8
        enemy.physicsBody?.restitution = 0.05
        enemy.physicsBody?.damping = 0.55
        enemy.physicsBody?.angularDamping = 0.75

        let headGeo = SCNSphere(radius: 0.17)
        headGeo.firstMaterial?.diffuse.contents = UIColor(red: 0.96, green: 0.02, blue: 0.025, alpha: 1)
        let head = SCNNode(geometry: headGeo)
        head.position = SCNVector3(0, 0.55, 0)
        enemy.addChildNode(head)

        let gunGeo = SCNBox(width: 0.07, height: 0.07, length: 0.38, chamferRadius: 0.01)
        gunGeo.firstMaterial?.diffuse.contents = UIColor(white: 0.07, alpha: 1)
        let gun = SCNNode(geometry: gunGeo)
        gun.position = SCNVector3(0.24, 0.1, -0.22)
        enemy.addChildNode(gun)

        gameplayContainer.addChildNode(enemy)
        enemies += 1
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
                let raw = request.results ?? []
                let snapshots = raw.compactMap { self.snapshot(from: $0) }
                    .sorted { ($0.points["wrist"]?.x ?? 0) < ($1.points["wrist"]?.x ?? 0) }
                    .enumerated()
                    .map { HandSnapshot(id: $0.offset, points: $0.element.points, pinch: $0.element.pinch, fist: $0.element.fist) }
                DispatchQueue.main.async { self.consumeHands(snapshots) }
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
            if let p = try? observation.recognizedPoint(joint), p.confidence > 0.25 { points[key] = p.location }
        }
        guard points["wrist"] != nil else { return nil }

        let pinch: Bool = {
            guard let a = points["thumbTip"], let b = points["indexTip"] else { return false }
            return distance(a, b) < 0.072
        }()
        let fist: Bool = {
            guard let palm = points["middleMCP"] else { return false }
            let tips = ["indexTip", "middleTip", "ringTip", "littleTip"].compactMap { points[$0] }
            guard tips.count >= 3 else { return false }
            let mean = tips.map { distance($0, palm) }.reduce(0, +) / CGFloat(tips.count)
            return mean < 0.135
        }()
        return HandSnapshot(id: 0, points: points, pinch: pinch, fist: fist)
    }

    private func consumeHands(_ hands: [HandSnapshot]) {
        leftOverlay.hands = hands
        rightOverlay.hands = hands

        for hand in hands {
            if let old = lastHandPoints[hand.id], distance(old, hand.aimPoint) > 0.006 {
                activityUntil = CACurrentMediaTime() + 0.14
            }
            lastHandPoints[hand.id] = hand.aimPoint

            if hand.id < previousPinch.count {
                if hand.pinch && !previousPinch[hand.id] { shoot(with: hand) }
                previousPinch[hand.id] = hand.pinch
            }
            if hand.fist { grabOrMove(with: hand) } else { release(hand.id) }
        }

        let visibleIds = Set(hands.map { $0.id })
        for id in Array(heldNodes.keys) where !visibleIds.contains(id) { release(id) }
        for id in 0..<previousPinch.count where !visibleIds.contains(id) { previousPinch[id] = false }

        let bothFists = hands.count >= 2 && hands.prefix(2).allSatisfy { $0.fist }
        if bothFists {
            if bothFistsSince == nil { bothFistsSince = CACurrentMediaTime() }
            if let start = bothFistsSince,
               CACurrentMediaTime() - start > 0.85,
               CACurrentMediaTime() > nextLevelCooldown {
                nextLevelCooldown = CACurrentMediaTime() + 1.8
                bothFistsSince = nil
                nextLevel()
            }
        } else {
            bothFistsSince = nil
        }
        updateHUD(extra: "Hands: \(hands.count)/2")
    }

    private func shoot(with hand: HandSnapshot) {
        shots += 1
        activityUntil = CACurrentMediaTime() + 0.25
        let ray = aimRay(for: hand)
        let from = SCNVector3(ray.origin.x, ray.origin.y, ray.origin.z)
        let far = ray.origin + ray.direction * 35
        let to = SCNVector3(far.x, far.y, far.z)
        let results = scene.rootNode.hitTestWithSegment(from: from, to: to, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .backFaceCulling: false])

        var impact = to
        for result in results {
            impact = result.worldCoordinates
            if let enemy = enemyRoot(from: result.node) {
                hits += 1
                shatter(enemy)
                break
            }
        }
        makeTracer(from: from, to: impact)
        updateHUD(extra: "SHOT")
    }

    private func grabOrMove(with hand: HandSnapshot) {
        activityUntil = CACurrentMediaTime() + 0.12
        let ray = aimRay(for: hand)
        if let held = heldNodes[hand.id] {
            let target = ray.origin + ray.direction * 1.15
            held.simdPosition = target
            held.physicsBody?.velocity = SCNVector3Zero
            held.physicsBody?.angularVelocity = SCNVector4Zero
            return
        }

        let from = SCNVector3(ray.origin.x, ray.origin.y, ray.origin.z)
        let end = ray.origin + ray.direction * 3.0
        let to = SCNVector3(end.x, end.y, end.z)
        let results = gameplayContainer.hitTestWithSegment(from: from, to: to, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        for result in results {
            if let enemy = enemyRoot(from: result.node) {
                heldNodes[hand.id] = enemy
                enemy.physicsBody?.isAffectedByGravity = false
                enemy.physicsBody?.clearAllForces()
                return
            }
        }
    }

    private func release(_ id: Int) {
        guard let node = heldNodes.removeValue(forKey: id) else { return }
        node.physicsBody?.isAffectedByGravity = true
        let forward = -SIMD3<Float>(latestCameraTransform.columns.2.x, latestCameraTransform.columns.2.y, latestCameraTransform.columns.2.z)
        node.physicsBody?.applyForce(SCNVector3(forward.x * 2.0, forward.y * 2.0 + 0.4, forward.z * 2.0), asImpulse: true)
    }

    private func aimRay(for hand: HandSnapshot) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let p = hand.aimPoint
        let x = Float((p.x - 0.5) * 1.35)
        let y = Float((p.y - 0.5) * 1.05)
        let local = simd_normalize(SIMD3<Float>(x, y, -1))
        let m = latestCameraTransform
        let world = SIMD3<Float>(
            m.columns.0.x * local.x + m.columns.1.x * local.y + m.columns.2.x * local.z,
            m.columns.0.y * local.x + m.columns.1.y * local.y + m.columns.2.y * local.z,
            m.columns.0.z * local.x + m.columns.1.z * local.y + m.columns.2.z * local.z
        )
        let origin = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        return (origin, simd_normalize(world))
    }

    private func enemyRoot(from node: SCNNode) -> SCNNode? {
        var current: SCNNode? = node
        while let c = current {
            if c.name?.hasPrefix("enemy-") == true { return c }
            current = c.parent
        }
        return nil
    }

    private func shatter(_ enemy: SCNNode) {
        let center = enemy.presentation.worldPosition
        enemy.removeFromParentNode()
        enemies = max(0, enemies - 1)

        for _ in 0..<12 {
            let geo = SCNBox(width: 0.055, height: 0.055, length: 0.055, chamferRadius: 0.004)
            geo.firstMaterial?.diffuse.contents = UIColor(red: 0.95, green: 0.02, blue: 0.025, alpha: 1)
            let shard = SCNNode(geometry: geo)
            shard.position = center
            shard.physicsBody = SCNPhysicsBody.dynamic()
            shard.physicsBody?.mass = 0.08
            gameplayContainer.addChildNode(shard)
            let force = SCNVector3(Float.random(in: -2.5...2.5), Float.random(in: 0.4...3.2), Float.random(in: -2.5...2.5))
            shard.physicsBody?.applyForce(force, asImpulse: true)
            shard.runAction(.sequence([.wait(duration: 2.0), .fadeOut(duration: 0.3), .removeFromParentNode()]))
        }

        if enemies == 0 {
            setHUD("SUPERHOT • FASE LIMPA")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.nextLevel() }
        }
    }

    private func makeTracer(from: SCNVector3, to: SCNVector3) {
        let dx = to.x - from.x, dy = to.y - from.y, dz = to.z - from.z
        let length = sqrt(dx * dx + dy * dy + dz * dz)
        guard length > 0.02 else { return }
        let geo = SCNCylinder(radius: 0.006, height: CGFloat(length))
        geo.firstMaterial?.diffuse.contents = UIColor.red
        geo.firstMaterial?.emission.contents = UIColor.red
        let tracer = SCNNode(geometry: geo)
        tracer.position = SCNVector3((from.x + to.x) * 0.5, (from.y + to.y) * 0.5, (from.z + to.z) * 0.5)
        tracer.look(at: to, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 1, 0))
        gameplayContainer.addChildNode(tracer)
        tracer.runAction(.sequence([.wait(duration: 0.07), .fadeOut(duration: 0.12), .removeFromParentNode()]))
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let head = latestCameraTransform
        var leftOffset = matrix_identity_float4x4
        leftOffset.columns.3.x = -ipd * 0.5
        var rightOffset = matrix_identity_float4x4
        rightOffset.columns.3.x = ipd * 0.5
        leftCamera.simdTransform = simd_mul(head, leftOffset)
        rightCamera.simdTransform = simd_mul(head, rightOffset)

        let target: Float = CACurrentMediaTime() < activityUntil ? 1.0 : 0.035
        timeScale += (target - timeScale) * 0.14
        scene.physicsWorld.speed = CGFloat(timeScale)
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
        let rotation = simd_length(oldForward - newForward)
        if translation > 0.0012 || rotation > 0.0015 { activityUntil = CACurrentMediaTime() + 0.14 }
    }

    private func nextLevel() {
        guard !levelLoading else { return }
        levelIndex = levelURLs.isEmpty ? 0 : (levelIndex + 1) % levelURLs.count
        loadLevel()
    }

    @objc private func debugNextLevel() { nextLevel() }

    private func updateHUD(extra: String) {
        let levelName: String
        if !levelURLs.isEmpty, levelIndex < levelURLs.count {
            levelName = levelURLs[levelIndex].deletingPathExtension().lastPathComponent
        } else {
            levelName = "Fallback"
        }
        setHUD("SUPERHOT VR • \(levelName)\nINIMIGOS \(enemies) • HITS \(hits)/\(shots) • \(extra)")
    }

    private func setHUD(_ text: String) {
        for label in hudLabels { label.text = text }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
}
