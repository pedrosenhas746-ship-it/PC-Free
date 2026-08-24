import UIKit
import SceneKit
import simd

final class GameWorld {
    let scene = SCNScene()
    let leftCameraNode = SCNNode()
    let rightCameraNode = SCNNode()

    private let leftPaw = SCNNode()
    private let rightPaw = SCNNode()
    private var lastHeadTransform = matrix_identity_float4x4
    private var heldByLeft: SCNNode?
    private var heldByRight: SCNNode?
    private var toyNodes: [SCNNode] = []
    private let goalNode = SCNNode()
    private let campaign = CampaignState.shared

    var onProgressChanged: ((String) -> Void)?

    init() {
        scene.physicsWorld.gravity = SCNVector3(0, -4.8, 0)
        setupLights()
        setupCameras()
        setupRoom()
        setupPaws()
        spawnToys()
    }

    private func material(_ color: UIColor, metalness: CGFloat = 0, roughness: CGFloat = 0.8) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        return m
    }

    private func setupLights() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        ambient.light?.color = UIColor(white: 0.82, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 950
        key.position = SCNVector3(0, 1.4, -0.7)
        scene.rootNode.addChildNode(key)
    }

    private func setupCameras() {
        for node in [leftCameraNode, rightCameraNode] {
            let camera = SCNCamera()
            camera.fieldOfView = 76
            camera.zNear = 0.01
            camera.zFar = 40
            node.camera = camera
            scene.rootNode.addChildNode(node)
        }
    }

    private func staticBox(name: String, size: SCNVector3, position: SCNVector3, color: UIColor) -> SCNNode {
        let geo = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.02)
        geo.materials = [material(color)]
        let node = SCNNode(geometry: geo)
        node.name = name
        node.position = position
        node.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: geo, options: nil))
        scene.rootNode.addChildNode(node)
        return node
    }

    private func setupRoom() {
        staticBox(name: "floor", size: SCNVector3(5.5, 0.12, 5.5), position: SCNVector3(0, -1.25, -1.5), color: UIColor(white: 0.22, alpha: 1))
        staticBox(name: "backWall", size: SCNVector3(5.5, 3.2, 0.12), position: SCNVector3(0, 0.25, -3.2), color: UIColor(white: 0.30, alpha: 1))
        staticBox(name: "leftWall", size: SCNVector3(0.12, 3.2, 5.5), position: SCNVector3(-2.7, 0.25, -1.5), color: UIColor(white: 0.26, alpha: 1))
        staticBox(name: "rightWall", size: SCNVector3(0.12, 3.2, 5.5), position: SCNVector3(2.7, 0.25, -1.5), color: UIColor(white: 0.26, alpha: 1))

        staticBox(name: "tableTop", size: SCNVector3(2.4, 0.12, 0.9), position: SCNVector3(-0.35, -0.45, -1.55), color: UIColor(red: 0.34, green: 0.22, blue: 0.13, alpha: 1))
        staticBox(name: "tableLegA", size: SCNVector3(0.12, 0.75, 0.12), position: SCNVector3(-1.35, -0.84, -1.85), color: UIColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1))
        staticBox(name: "tableLegB", size: SCNVector3(0.12, 0.75, 0.12), position: SCNVector3(0.65, -0.84, -1.85), color: UIColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1))

        let goalGeo = SCNBox(width: 0.85, height: 0.15, length: 0.85, chamferRadius: 0.06)
        goalGeo.materials = [material(UIColor(red: 0.16, green: 0.55, blue: 0.24, alpha: 0.65))]
        goalNode.geometry = goalGeo
        goalNode.name = "toyBasket"
        goalNode.position = SCNVector3(1.35, -1.08, -1.55)
        goalNode.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: goalGeo, options: nil))
        scene.rootNode.addChildNode(goalNode)
    }

    private func setupPaws() {
        func makePaw(_ node: SCNNode, color: UIColor) {
            let geo = SCNSphere(radius: 0.085)
            geo.segmentCount = 20
            geo.materials = [material(color, roughness: 0.65)]
            node.geometry = geo
            node.physicsBody = SCNPhysicsBody(type: .kinematic, shape: SCNPhysicsShape(geometry: geo, options: nil))
            node.physicsBody?.categoryBitMask = 1 << 3
            node.physicsBody?.collisionBitMask = 0
            scene.rootNode.addChildNode(node)
        }
        makePaw(leftPaw, color: UIColor(red: 0.95, green: 0.62, blue: 0.28, alpha: 1))
        makePaw(rightPaw, color: UIColor(red: 1.0, green: 0.78, blue: 0.46, alpha: 1))
    }

    private func spawnToys() {
        let specs: [(String, SCNGeometry, UIColor, SCNVector3)] = [
            ("toy_ball", SCNSphere(radius: 0.11), .systemRed, SCNVector3(-0.85, -0.20, -1.48)),
            ("toy_cube", SCNBox(width: 0.20, height: 0.20, length: 0.20, chamferRadius: 0.025), .systemBlue, SCNVector3(-0.25, -0.20, -1.50)),
            ("toy_capsule", SCNCapsule(capRadius: 0.09, height: 0.26), .systemYellow, SCNVector3(0.32, -0.18, -1.52))
        ]

        for (name, geo, color, pos) in specs {
            geo.materials = [material(color, roughness: 0.55)]
            let node = SCNNode(geometry: geo)
            node.name = name
            node.position = pos
            let shape = SCNPhysicsShape(geometry: geo, options: [SCNPhysicsShape.Option.type: SCNPhysicsShape.ShapeType.convexHull])
            node.physicsBody = SCNPhysicsBody(type: .dynamic, shape: shape)
            node.physicsBody?.mass = 0.18
            node.physicsBody?.friction = 0.55
            node.physicsBody?.restitution = 0.25
            node.physicsBody?.angularDamping = 0.3
            scene.rootNode.addChildNode(node)
            toyNodes.append(node)
        }
    }

    func updateHead(_ transform: simd_float4x4) {
        lastHeadTransform = transform
        var leftOffset = matrix_identity_float4x4
        var rightOffset = matrix_identity_float4x4
        leftOffset.columns.3.x = -0.032
        rightOffset.columns.3.x = 0.032
        leftCameraNode.simdTransform = simd_mul(transform, leftOffset)
        rightCameraNode.simdTransform = simd_mul(transform, rightOffset)
        updateHeldObject(heldByLeft, paw: leftPaw)
        updateHeldObject(heldByRight, paw: rightPaw)
        evaluateGoal()
    }

    func updateHands(_ hands: [TrackedHandState]) {
        let left = hands.indices.contains(0) ? hands[0] : nil
        let right = hands.indices.contains(1) ? hands[1] : nil
        updatePaw(leftPaw, hand: left, isLeft: true)
        updatePaw(rightPaw, hand: right, isLeft: false)
    }

    private func updatePaw(_ paw: SCNNode, hand: TrackedHandState?, isLeft: Bool) {
        guard let hand else {
            paw.isHidden = true
            releaseIfNeeded(isLeft: isLeft)
            return
        }

        paw.isHidden = false
        let localX = Float((hand.wristX - 0.5) * 1.30)
        let localY = Float((hand.wristY - 0.5) * 0.92 - 0.05)
        let local = SIMD4<Float>(localX, localY, -0.72, 1)
        let world = simd_mul(lastHeadTransform, local)
        paw.simdWorldPosition = SIMD3<Float>(world.x, world.y, world.z)

        if hand.pinch > 0.66 {
            grabIfNeeded(paw: paw, isLeft: isLeft)
        } else if hand.pinch < 0.42 {
            releaseIfNeeded(isLeft: isLeft)
        }

        if isLeft {
            updateHeldObject(heldByLeft, paw: paw)
        } else {
            updateHeldObject(heldByRight, paw: paw)
        }
    }

    private func nearestToy(to paw: SCNNode) -> SCNNode? {
        let p = paw.simdWorldPosition
        return toyNodes
            .filter { $0.parent != nil && $0.physicsBody?.type == .dynamic }
            .map { node -> (SCNNode, Float) in
                let d = simd_distance(node.simdWorldPosition, p)
                return (node, d)
            }
            .filter { $0.1 < 0.34 }
            .min { $0.1 < $1.1 }?.0
    }

    private func grabIfNeeded(paw: SCNNode, isLeft: Bool) {
        if isLeft, heldByLeft != nil { return }
        if !isLeft, heldByRight != nil { return }
        guard let toy = nearestToy(to: paw) else { return }
        toy.physicsBody?.type = .kinematic
        toy.physicsBody?.velocity = SCNVector3Zero
        toy.physicsBody?.angularVelocity = SCNVector4Zero
        if isLeft { heldByLeft = toy } else { heldByRight = toy }
        updateHeldObject(toy, paw: paw)
    }

    private func updateHeldObject(_ object: SCNNode?, paw: SCNNode) {
        guard let object else { return }
        object.simdWorldPosition = paw.simdWorldPosition + SIMD3<Float>(0, 0, -0.07)
    }

    private func releaseIfNeeded(isLeft: Bool) {
        let object = isLeft ? heldByLeft : heldByRight
        guard let object else { return }
        object.physicsBody?.type = .dynamic
        if isLeft { heldByLeft = nil } else { heldByRight = nil }
    }

    private func evaluateGoal() {
        let goal = goalNode.simdWorldPosition
        for toy in toyNodes where toy.parent != nil {
            let distance = simd_distance(toy.simdWorldPosition, goal)
            guard distance < 0.48, toy.simdWorldPosition.y < goal.y + 0.40 else { continue }
            guard let id = toy.name, campaign.collectToy(id: "\(campaign.chapter)-\(id)") else { continue }
            toy.physicsBody = nil
            toy.removeFromParentNode()
            onProgressChanged?(campaign.progressText)
        }
    }

    var progressText: String {
        campaign.progressText
    }
}
