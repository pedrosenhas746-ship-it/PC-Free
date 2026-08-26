import UIKit
import ARKit
import SceneKit
import Vision

private enum CollisionMask {
    static let room = 1 << 0
    static let weapon = 1 << 1
    static let enemy = 1 << 2
}

private extension SCNVector3 {
    static func +(lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func -(lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    static func *(lhs: SCNVector3, rhs: Float) -> SCNVector3 {
        SCNVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    var magnitude: Float {
        sqrt(x * x + y * y + z * z)
    }

    var unit: SCNVector3 {
        let d = max(magnitude, 0.0001)
        return self * (1.0 / d)
    }
}

private func distance(_ a: SCNVector3, _ b: SCNVector3) -> Float {
    (a - b).magnitude
}

private func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
    min(max(value, low), high)
}

private struct HandPose2D {
    let wrist: CGPoint
    let thumb: CGPoint
    let index: CGPoint
    let middle: CGPoint

    var palm: CGPoint {
        CGPoint(x: (wrist.x + middle.x) * 0.5, y: (wrist.y + middle.y) * 0.5)
    }

    var span: CGFloat {
        hypot(wrist.x - middle.x, wrist.y - middle.y)
    }

    var pinching: Bool {
        hypot(thumb.x - index.x, thumb.y - index.y) < 0.06
    }
}

private final class HandTracker {
    private let queue = DispatchQueue(label: "breakroom.hand.tracker", qos: .userInteractive)
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    private var busy = false
    private(set) var latest: [HandPose2D] = []

    func process(_ pixelBuffer: CVPixelBuffer) {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.busy = false }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            do {
                try handler.perform([self.request])
                var result: [HandPose2D] = []
                for observation in self.request.results ?? [] {
                    guard let wrist = try? observation.recognizedPoint(.wrist),
                          let thumb = try? observation.recognizedPoint(.thumbTip),
                          let index = try? observation.recognizedPoint(.indexTip),
                          let middle = try? observation.recognizedPoint(.middleMCP) else {
                        continue
                    }

                    let confidence = [wrist.confidence, thumb.confidence, index.confidence, middle.confidence].min() ?? 0
                    guard confidence > 0.2 else { continue }

                    func convert(_ point: VNRecognizedPoint) -> CGPoint {
                        CGPoint(x: point.location.x, y: 1.0 - point.location.y)
                    }

                    result.append(
                        HandPose2D(
                            wrist: convert(wrist),
                            thumb: convert(thumb),
                            index: convert(index),
                            middle: convert(middle)
                        )
                    )
                }

                result.sort { $0.palm.x < $1.palm.x }
                DispatchQueue.main.async {
                    self.latest = result
                }
            } catch {
                DispatchQueue.main.async {
                    self.latest = []
                }
            }
        }
    }
}

private final class FitnessWeapon {
    enum Kind: CaseIterable {
        case sword, axe, hammer, bat, staff
    }

    let kind: Kind
    let node = SCNNode()
    let mass: CGFloat
    let power: Float
    var heldBy: Int?
    var lastHit: TimeInterval = 0

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .sword:
            mass = 1.15
            power = 1.25
        case .axe:
            mass = 2.1
            power = 1.5
        case .hammer:
            mass = 3.0
            power = 1.7
        case .bat:
            mass = 1.3
            power = 1.0
        case .staff:
            mass = 1.55
            power = 1.15
        }

        buildVisual()
        node.name = "fitness_weapon"
        let shape = SCNPhysicsShape(node: node, options: [.type: SCNPhysicsShape.ShapeType.boundingBox])
        let body = SCNPhysicsBody(type: .dynamic, shape: shape)
        body.mass = mass
        body.friction = 0.75
        body.restitution = 0.08
        body.categoryBitMask = CollisionMask.weapon
        body.collisionBitMask = CollisionMask.room | CollisionMask.weapon | CollisionMask.enemy
        body.contactTestBitMask = CollisionMask.enemy
        body.continuousCollisionDetectionThreshold = 0.0001
        node.physicsBody = body
    }

    private func material(_ color: UIColor, metalness: CGFloat = 0, roughness: CGFloat = 0.5) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.metalness.contents = metalness
        material.roughness.contents = roughness
        return material
    }

    private func addPart(_ geometry: SCNGeometry, position: SCNVector3, color: UIColor, metalness: CGFloat = 0, roughness: CGFloat = 0.5) {
        geometry.materials = [material(color, metalness: metalness, roughness: roughness)]
        let part = SCNNode(geometry: geometry)
        part.position = position
        node.addChildNode(part)
    }

    private func addHandle(radius: CGFloat, height: CGFloat, position: SCNVector3, color: UIColor) {
        let geometry = SCNCylinder(radius: radius, height: height)
        geometry.materials = [material(color, roughness: 0.8)]
        let handle = SCNNode(geometry: geometry)
        handle.eulerAngles.x = .pi / 2
        handle.position = position
        node.addChildNode(handle)
    }

    private func buildVisual() {
        switch kind {
        case .sword:
            addPart(SCNBox(width: 0.05, height: 0.012, length: 0.7, chamferRadius: 0.006), position: SCNVector3(0, 0, 0.4), color: .lightGray, metalness: 0.95, roughness: 0.18)
            addPart(SCNBox(width: 0.25, height: 0.035, length: 0.045, chamferRadius: 0.012), position: SCNVector3(0, 0, 0.03), color: .systemYellow, metalness: 0.7, roughness: 0.3)
            addHandle(radius: 0.026, height: 0.22, position: SCNVector3(0, 0, -0.11), color: .black)
        case .axe:
            addHandle(radius: 0.026, height: 0.68, position: SCNVector3(0, 0, 0.12), color: .brown)
            addPart(SCNBox(width: 0.34, height: 0.08, length: 0.18, chamferRadius: 0.025), position: SCNVector3(0, 0, 0.48), color: .darkGray, metalness: 0.9, roughness: 0.25)
            addPart(SCNBox(width: 0.12, height: 0.04, length: 0.23, chamferRadius: 0.01), position: SCNVector3(0.2, 0, 0.48), color: .lightGray, metalness: 0.95, roughness: 0.15)
        case .hammer:
            addHandle(radius: 0.029, height: 0.62, position: SCNVector3(0, 0, 0.1), color: .brown)
            addPart(SCNBox(width: 0.38, height: 0.16, length: 0.16, chamferRadius: 0.035), position: SCNVector3(0, 0, 0.45), color: .darkGray, metalness: 0.86, roughness: 0.28)
        case .bat:
            let geometry = SCNCapsule(capRadius: 0.045, height: 0.72)
            geometry.materials = [material(.systemRed, roughness: 0.45)]
            let bat = SCNNode(geometry: geometry)
            bat.eulerAngles.x = .pi / 2
            bat.position = SCNVector3(0, 0, 0.22)
            node.addChildNode(bat)
        case .staff:
            addHandle(radius: 0.026, height: 1.05, position: SCNVector3(0, 0, 0.3), color: .systemTeal)
            addPart(SCNSphere(radius: 0.05), position: SCNVector3(0, 0, 0.84), color: .white, metalness: 0.6, roughness: 0.25)
        }
    }
}

private final class FitnessEnemy {
    enum State {
        case approach, strafe, windup, strike, recover, stunned, dead
    }

    let root = SCNNode()
    let torso = SCNNode()
    let head = SCNNode()
    let attackArm = SCNNode()
    var state: State = .approach
    var stateTime: Float = 0
    var health: Float = 100
    var strafeDirection: Float = Bool.random() ? 1 : -1
    var dead = false
    var lastContact: TimeInterval = 0
    var weapon: FitnessWeapon?

    init(index: Int) {
        root.name = "fitness_enemy_\(index)"
        let red = UIColor(red: 0.78, green: 0.025, blue: 0.045, alpha: 1)
        let dark = UIColor(white: 0.055, alpha: 1)

        func material(_ color: UIColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.roughness.contents = 0.35
            return material
        }

        let pelvis = SCNNode(geometry: SCNCapsule(capRadius: 0.13, height: 0.34))
        pelvis.position = SCNVector3(0, 0.72, 0)
        pelvis.geometry?.materials = [material(dark)]
        root.addChildNode(pelvis)

        torso.geometry = SCNBox(width: 0.43, height: 0.48, length: 0.23, chamferRadius: 0.055)
        torso.position = SCNVector3(0, 1.1, 0)
        torso.geometry?.materials = [material(red)]
        root.addChildNode(torso)

        let plate = SCNNode(geometry: SCNBox(width: 0.34, height: 0.29, length: 0.08, chamferRadius: 0.025))
        plate.position = SCNVector3(0, 0, 0.15)
        plate.geometry?.materials = [material(dark)]
        torso.addChildNode(plate)

        head.geometry = SCNCapsule(capRadius: 0.145, height: 0.28)
        head.position = SCNVector3(0, 1.53, 0)
        head.geometry?.materials = [material(red)]
        root.addChildNode(head)

        let mask = SCNNode(geometry: SCNBox(width: 0.2, height: 0.12, length: 0.045, chamferRadius: 0.015))
        mask.position = SCNVector3(0, 0, 0.14)
        mask.geometry?.materials = [material(dark)]
        head.addChildNode(mask)

        for side: Float in [-1, 1] {
            let upperArm = SCNNode(geometry: SCNCapsule(capRadius: 0.067, height: 0.34))
            upperArm.position = SCNVector3(0.29 * side, 1.22, 0)
            upperArm.geometry?.materials = [material(dark)]
            root.addChildNode(upperArm)

            let lowerArm = SCNNode(geometry: SCNCapsule(capRadius: 0.056, height: 0.3))
            lowerArm.position = SCNVector3(0, -0.29, 0.02)
            lowerArm.geometry?.materials = [material(red)]
            upperArm.addChildNode(lowerArm)

            if side > 0 {
                attackArm.addChildNode(upperArm)
                root.addChildNode(attackArm)
                upperArm.position = SCNVector3(0.29, 1.22, 0)
            }

            let thigh = SCNNode(geometry: SCNCapsule(capRadius: 0.087, height: 0.42))
            thigh.position = SCNVector3(0.12 * side, 0.43, 0)
            thigh.geometry?.materials = [material(dark)]
            root.addChildNode(thigh)

            let shin = SCNNode(geometry: SCNCapsule(capRadius: 0.071, height: 0.37))
            shin.position = SCNVector3(0, -0.36, 0.03)
            shin.geometry?.materials = [material(red)]
            thigh.addChildNode(shin)
        }

        let bodyShape = SCNPhysicsShape(geometry: SCNCapsule(capRadius: 0.23, height: 1.55), options: nil)
        let body = SCNPhysicsBody(type: .kinematic, shape: bodyShape)
        body.categoryBitMask = CollisionMask.enemy
        body.collisionBitMask = CollisionMask.room | CollisionMask.weapon | CollisionMask.enemy
        body.contactTestBitMask = CollisionMask.weapon
        root.physicsBody = body
    }
}

final class FitnessGameViewController: UIViewController, ARSCNViewDelegate, SCNPhysicsContactDelegate {
    private let sceneView = ARSCNView(frame: .zero)
    private let handTracker = HandTracker()
    private var handNodes: [SCNNode] = []
    private var previousHandPositions: [SCNVector3?] = [nil, nil]
    private var handVelocities: [SCNVector3] = [.init(), .init()]
    private var previousPinch: [Bool] = [false, false]
    private var heldWeapons: [FitnessWeapon?] = [nil, nil]
    private var weapons: [FitnessWeapon] = []
    private var enemies: [FitnessEnemy] = []
    private var previousFrameTime: TimeInterval = 0
    private var previousCameraPosition: SCNVector3?
    private var cameraBaselineY: Float?
    private var roundTime: Float = 45
    private var restTime: Float = 10
    private var isFighting = true
    private var round = 1
    private var score = 0
    private var combo = 0
    private var activityPoints: Float = 0
    private let flashView = UIView()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.scene.physicsWorld.contactDelegate = self
        sceneView.scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)
        sceneView.automaticallyUpdatesLighting = true
        view.addSubview(sceneView)

        flashView.frame = view.bounds
        flashView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        flashView.backgroundColor = UIColor.systemRed.withAlphaComponent(0)
        flashView.isUserInteractionEnabled = false
        view.addSubview(flashView)

        statusLabel.frame = CGRect(x: 22, y: 18, width: 720, height: 44)
        statusLabel.font = .monospacedSystemFont(ofSize: 22, weight: .bold)
        statusLabel.textColor = .white
        statusLabel.shadowColor = .black
        view.addSubview(statusLabel)

        detailLabel.frame = CGRect(x: 22, y: 60, width: 940, height: 34)
        detailLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        detailLabel.textColor = .white
        detailLabel.shadowColor = .black
        view.addSubview(detailLabel)

        for _ in 0..<2 {
            let hand = makeHandNode()
            handNodes.append(hand)
            sceneView.scene.rootNode.addChildNode(hand)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else { return }

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.setupArena()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    private func makeHandNode() -> SCNNode {
        let root = SCNNode()
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.9, alpha: 0.9)
        material.metalness.contents = 0.6
        material.roughness.contents = 0.2

        let palm = SCNNode(geometry: SCNBox(width: 0.085, height: 0.025, length: 0.1, chamferRadius: 0.025))
        palm.geometry?.materials = [material]
        root.addChildNode(palm)

        for x: Float in [-0.03, 0.03] {
            let knuckle = SCNNode(geometry: SCNSphere(radius: 0.017))
            knuckle.geometry?.materials = [material]
            knuckle.position = SCNVector3(x, 0, -0.07)
            root.addChildNode(knuckle)
        }
        return root
    }

    private func setupArena() {
        guard let camera = sceneView.pointOfView else { return }
        let cameraPosition = camera.presentation.worldPosition
        cameraBaselineY = cameraPosition.y
        var forward = camera.presentation.convertVector(SCNVector3(0, 0, -1), to: nil)
        forward.y = 0
        forward = forward.unit
        let right = SCNVector3(-forward.z, 0, forward.x)

        for index in 0..<10 {
            let kind = FitnessWeapon.Kind.allCases[index % FitnessWeapon.Kind.allCases.count]
            let weapon = FitnessWeapon(kind: kind)
            let side = Float(index % 5) - 2
            let row = Float(index / 5)
            weapon.node.position = cameraPosition + forward * (0.9 + row * 0.42) + right * (side * 0.34) + SCNVector3(0, -0.58, 0)
            sceneView.scene.rootNode.addChildNode(weapon.node)
            weapons.append(weapon)
        }

        for index in 0..<3 {
            spawnEnemy(index: index, delay: Double(index) * 0.18)
        }
    }

    private func spawnEnemy(index: Int, delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isFighting, let camera = self.sceneView.pointOfView else { return }

            let enemy = FitnessEnemy(index: index + Int.random(in: 10...9999))
            let cameraPosition = camera.presentation.worldPosition
            var forward = camera.presentation.convertVector(SCNVector3(0, 0, -1), to: nil)
            forward.y = 0
            forward = forward.unit
            let right = SCNVector3(-forward.z, 0, forward.x)
            enemy.root.position = cameraPosition + forward * Float.random(in: 1.8...2.5) + right * Float.random(in: -1.25...1.25) + SCNVector3(0, -0.92, 0)
            self.sceneView.scene.rootNode.addChildNode(enemy.root)
            self.enemies.append(enemy)

            let weapon = FitnessWeapon(kind: FitnessWeapon.Kind.allCases.randomElement()!)
            weapon.node.physicsBody?.type = .kinematic
            weapon.node.physicsBody?.isAffectedByGravity = false
            self.sceneView.scene.rootNode.addChildNode(weapon.node)
            self.weapons.append(weapon)
            enemy.weapon = weapon
        }
    }

    private func handWorldPosition(_ pose: HandPose2D) -> SCNVector3 {
        let point = CGPoint(x: pose.palm.x * view.bounds.width, y: pose.palm.y * view.bounds.height)
        let nearPoint = sceneView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
        let farPoint = sceneView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
        let direction = (farPoint - nearPoint).unit
        let depth = clamp(Float(0.72 - pose.span * 2.1), 0.28, 0.72)
        return nearPoint + direction * depth
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let frame = sceneView.session.currentFrame, let camera = sceneView.pointOfView else { return }
        handTracker.process(frame.capturedImage)

        let dt = previousFrameTime == 0 ? Float(1.0 / 60.0) : Float(min(time - previousFrameTime, 0.05))
        previousFrameTime = time
        let cameraPosition = camera.presentation.worldPosition

        if let previous = previousCameraPosition {
            activityPoints += (cameraPosition - previous).magnitude * 8
        }
        previousCameraPosition = cameraPosition

        updateHands(dt: dt)
        if isFighting {
            updateFight(dt: dt, cameraPosition: cameraPosition)
        } else {
            updateRest(dt: dt)
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateHUD()
        }
    }

    private func updateHands(dt: Float) {
        let poses = handTracker.latest
        for index in 0..<2 {
            guard index < poses.count else {
                handNodes[index].isHidden = true
                continue
            }

            let pose = poses[index]
            let worldPosition = handWorldPosition(pose)
            handNodes[index].isHidden = false
            handNodes[index].position = worldPosition

            if let previous = previousHandPositions[index] {
                handVelocities[index] = (worldPosition - previous) * (1.0 / max(dt, 0.001))
            } else {
                handVelocities[index] = SCNVector3Zero
            }
            previousHandPositions[index] = worldPosition
            activityPoints += min(handVelocities[index].magnitude * dt * 0.5, 0.2)

            let pinching = pose.pinching
            if pinching && !previousPinch[index] {
                tryGrab(hand: index, at: worldPosition)
            }
            if !pinching && previousPinch[index] {
                release(hand: index)
            }
            previousPinch[index] = pinching

            if let weapon = heldWeapons[index] {
                weapon.node.position = worldPosition
                let velocity = handVelocities[index]
                if velocity.magnitude > 0.08 {
                    weapon.node.look(at: worldPosition + velocity.unit)
                }
            } else {
                punch(at: worldPosition, velocity: handVelocities[index])
            }
        }
    }

    private func tryGrab(hand: Int, at position: SCNVector3) {
        var closest: FitnessWeapon?
        var bestDistance: Float = 0.24
        for weapon in weapons where weapon.heldBy == nil {
            let d = distance(weapon.node.presentation.worldPosition, position)
            if d < bestDistance {
                bestDistance = d
                closest = weapon
            }
        }

        guard let weapon = closest else { return }
        weapon.heldBy = hand
        heldWeapons[hand] = weapon
        weapon.node.physicsBody?.type = .kinematic
        weapon.node.physicsBody?.isAffectedByGravity = false
        combo += 1
    }

    private func release(hand: Int) {
        guard let weapon = heldWeapons[hand] else { return }
        weapon.heldBy = nil
        heldWeapons[hand] = nil
        weapon.node.physicsBody?.type = .dynamic
        weapon.node.physicsBody?.isAffectedByGravity = true
        weapon.node.physicsBody?.velocity = handVelocities[hand]
        weapon.node.physicsBody?.angularVelocity = SCNVector4(handVelocities[hand].z, handVelocities[hand].x, 0, handVelocities[hand].magnitude * 2.2)
    }

    private func punch(at position: SCNVector3, velocity: SCNVector3) {
        let speed = velocity.magnitude
        guard speed > 0.62 else { return }

        for enemy in enemies where !enemy.dead {
            let headDistance = distance(position, enemy.head.presentation.worldPosition)
            let torsoDistance = distance(position, enemy.torso.presentation.worldPosition)
            if min(headDistance, torsoDistance) < 0.25 {
                hit(enemy, velocity: velocity, power: 0.85)
                score += Int(speed * 18)
                return
            }
        }
    }

    private func hit(_ enemy: FitnessEnemy, velocity: SCNVector3, power: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - enemy.lastContact > 0.11 else { return }
        enemy.lastContact = now

        let impact = velocity.magnitude * power
        guard impact > 0.5 else { return }

        enemy.health -= clamp(impact * 13, 7, 60)
        enemy.state = .stunned
        enemy.stateTime = 0.45
        enemy.root.physicsBody?.type = .dynamic
        enemy.root.physicsBody?.mass = 72
        enemy.root.physicsBody?.isAffectedByGravity = true
        enemy.root.physicsBody?.applyForce(velocity.unit * clamp(impact * 1.8, 1, 8), asImpulse: true)
        score += Int(impact * 30)
        combo += 1

        if enemy.health <= 0 || impact > 7.2 {
            kill(enemy)
        }
    }

    private func kill(_ enemy: FitnessEnemy) {
        guard !enemy.dead else { return }
        enemy.dead = true
        enemy.state = .dead
        score += 300 + combo * 8

        if let weapon = enemy.weapon {
            weapon.node.physicsBody?.type = .dynamic
            weapon.node.physicsBody?.isAffectedByGravity = true
            enemy.weapon = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak enemy] in
            enemy?.root.removeFromParentNode()
            if let self, self.isFighting {
                self.spawnEnemy(index: Int.random(in: 0...999))
            }
        }
    }

    private func updateFight(dt: Float, cameraPosition: SCNVector3) {
        roundTime -= dt
        if roundTime <= 0 {
            isFighting = false
            restTime = 10
            return
        }

        let aliveCount = enemies.filter { !$0.dead && $0.root.parent != nil }.count
        let targetCount = min(2 + round, 6)
        if aliveCount < targetCount {
            spawnEnemy(index: Int.random(in: 0...999), delay: 0.05)
        }

        for enemy in enemies where !enemy.dead {
            updateEnemy(enemy, dt: dt, cameraPosition: cameraPosition)
        }
    }

    private func updateRest(dt: Float) {
        restTime -= dt
        if restTime <= 0 {
            round += 1
            roundTime = max(26, 45 - Float(round - 1) * 2)
            isFighting = true
        }
    }

    private func updateEnemy(_ enemy: FitnessEnemy, dt: Float, cameraPosition: SCNVector3) {
        if enemy.state == .stunned {
            enemy.stateTime -= dt
            if enemy.stateTime <= 0 && !enemy.dead {
                enemy.root.physicsBody?.type = .kinematic
                enemy.root.physicsBody?.isAffectedByGravity = false
                enemy.state = .approach
                enemy.stateTime = 0
            }
            return
        }

        enemy.stateTime += dt
        var toPlayer = cameraPosition - enemy.root.presentation.worldPosition
        toPlayer.y = 0
        let distanceToPlayer = toPlayer.magnitude
        let direction = toPlayer.unit
        let side = SCNVector3(-direction.z, 0, direction.x) * enemy.strafeDirection

        switch enemy.state {
        case .approach:
            let speed = 0.8 + Float(round) * 0.055
            if distanceToPlayer > 1.15 {
                enemy.root.position = enemy.root.position + direction * speed * dt + side * 0.1 * dt
            } else {
                enemy.state = .strafe
                enemy.stateTime = 0
            }
        case .strafe:
            enemy.root.position = enemy.root.position + side * (0.38 + Float(round) * 0.02) * dt
            if enemy.stateTime > Float.random(in: 0.45...0.95) {
                enemy.state = .windup
                enemy.stateTime = 0
            }
        case .windup:
            enemy.attackArm.eulerAngles.x = -0.7 * min(enemy.stateTime / 0.36, 1)
            if enemy.stateTime > 0.36 {
                enemy.state = .strike
                enemy.stateTime = 0
            }
        case .strike:
            enemy.attackArm.eulerAngles.x = -0.7 + 2.2 * min(enemy.stateTime / 0.24, 1)
            if enemy.stateTime > 0.12 && enemy.stateTime < 0.19 {
                resolveEnemyAttack(enemy, cameraPosition: cameraPosition)
            }
            if enemy.stateTime > 0.25 {
                enemy.state = .recover
                enemy.stateTime = 0
            }
        case .recover:
            enemy.attackArm.eulerAngles.x *= 0.84
            if enemy.stateTime > max(0.3, 0.62 - Float(round) * 0.035) {
                enemy.state = .approach
                enemy.stateTime = 0
            }
        case .stunned, .dead:
            break
        }

        enemy.root.eulerAngles.y = atan2(direction.x, direction.z)
        if let weapon = enemy.weapon {
            let handPosition = enemy.root.presentation.convertPosition(SCNVector3(0.4, 0.88, 0.08), to: nil)
            weapon.node.position = handPosition
            weapon.node.eulerAngles = SCNVector3(enemy.attackArm.eulerAngles.x, enemy.root.eulerAngles.y, 0)
        }
    }

    private func resolveEnemyAttack(_ enemy: FitnessEnemy, cameraPosition: SCNVector3) {
        guard distance(enemy.root.presentation.worldPosition, cameraPosition) < 1.42 else { return }

        let crouched = (cameraBaselineY ?? cameraPosition.y) - cameraPosition.y > 0.2
        var lateralSpeed: Float = 0
        if let previous = previousCameraPosition {
            lateralSpeed = abs(cameraPosition.x - previous.x) + abs(cameraPosition.z - previous.z)
        }

        if !crouched && lateralSpeed < 0.03 {
            combo = 0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.flashView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.34)
                UIView.animate(withDuration: 0.28) {
                    self.flashView.backgroundColor = UIColor.systemRed.withAlphaComponent(0)
                }
            }
        } else {
            score += 80
            combo += 1
            activityPoints += 0.35
        }
    }

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        let nodes = [contact.nodeA, contact.nodeB]
        guard let weaponNode = nodes.first(where: { $0.physicsBody?.categoryBitMask == CollisionMask.weapon }),
              let enemyNode = nodes.first(where: { $0.physicsBody?.categoryBitMask == CollisionMask.enemy }),
              let weapon = weapons.first(where: { $0.node === weaponNode }),
              let enemy = enemies.first(where: { $0.root === enemyNode }),
              !enemy.dead else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - weapon.lastHit > 0.1 else { return }
        weapon.lastHit = now
        let velocity = weaponNode.physicsBody?.velocity ?? SCNVector3Zero
        let multiplier = Float(weapon.mass) * weapon.power
        if velocity.magnitude > 0.42 {
            hit(enemy, velocity: velocity, power: multiplier)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor else { return }
        let width = CGFloat(max(planeAnchor.extent.x, 0.1))
        let secondExtent = planeAnchor.alignment == .horizontal ? planeAnchor.extent.z : planeAnchor.extent.y
        let height = CGFloat(max(secondExtent, 0.1))
        let plane = SCNPlane(width: width, height: height)
        plane.firstMaterial?.diffuse.contents = UIColor.clear

        let planeNode = SCNNode(geometry: plane)
        if planeAnchor.alignment == .horizontal {
            planeNode.eulerAngles.x = -.pi / 2
        }

        let body = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: plane, options: nil))
        body.categoryBitMask = CollisionMask.room
        body.collisionBitMask = CollisionMask.weapon | CollisionMask.enemy
        planeNode.physicsBody = body
        node.addChildNode(planeNode)
    }

    private func updateHUD() {
        if isFighting {
            statusLabel.text = "ROUND \(round)   \(Int(ceil(roundTime)))s   SCORE \(score)"
        } else {
            statusLabel.text = "RECUPERA \(Int(ceil(restTime)))s"
        }
        detailLabel.text = "COMBO x\(combo)   ATIVIDADE \(Int(activityPoints * 10))   PINCH=PEGAR  •  SOCA  •  DESVIA  •  ABAIXA"
    }
}
