import UIKit
import ARKit
import SceneKit
import Vision
import ImageIO

private enum V2Mask {
    static let room = 1 << 4
    static let weapon = 1 << 5
    static let enemy = 1 << 6
}

private func v2Add(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z)
}

private func v2Sub(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z)
}

private func v2Mul(_ a: SCNVector3, _ s: Float) -> SCNVector3 {
    SCNVector3(a.x * s, a.y * s, a.z * s)
}

private func v2Len(_ a: SCNVector3) -> Float {
    sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
}

private func v2Norm(_ a: SCNVector3) -> SCNVector3 {
    let l = max(v2Len(a), 0.0001)
    return v2Mul(a, 1 / l)
}

private func v2Distance(_ a: SCNVector3, _ b: SCNVector3) -> Float {
    v2Len(v2Sub(a, b))
}

private func v2Clamp(_ x: Float, _ a: Float, _ b: Float) -> Float {
    min(max(x, a), b)
}

private func v2SegmentDistance(_ p: SCNVector3, _ a: SCNVector3, _ b: SCNVector3) -> Float {
    let ab = v2Sub(b, a)
    let ap = v2Sub(p, a)
    let den = max(ab.x * ab.x + ab.y * ab.y + ab.z * ab.z, 0.00001)
    let t = v2Clamp((ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / den, 0, 1)
    return v2Distance(p, v2Add(a, v2Mul(ab, t)))
}

private let v2JointNames: [VNHumanHandPoseObservation.JointName] = [
    .wrist,
    .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
    .indexMCP, .indexPIP, .indexDIP, .indexTip,
    .middleMCP, .middlePIP, .middleDIP, .middleTip,
    .ringMCP, .ringPIP, .ringDIP, .ringTip,
    .littleMCP, .littlePIP, .littleDIP, .littleTip
]

private let v2HandLinks: [(Int, Int)] = [
    (0,1),(1,2),(2,3),(3,4),
    (0,5),(5,6),(6,7),(7,8),
    (0,9),(9,10),(10,11),(11,12),
    (0,13),(13,14),(14,15),(15,16),
    (0,17),(17,18),(18,19),(19,20),
    (5,9),(9,13),(13,17)
]

private struct V2HandPose {
    let points: [CGPoint]
    let confidence: Float

    var palm: CGPoint {
        guard points.count == 21 else { return .zero }
        return CGPoint(
            x: (points[0].x + points[5].x + points[9].x + points[13].x + points[17].x) / 5,
            y: (points[0].y + points[5].y + points[9].y + points[13].y + points[17].y) / 5
        )
    }

    var span: CGFloat {
        guard points.count == 21 else { return 0.1 }
        return hypot(points[0].x - points[9].x, points[0].y - points[9].y)
    }

    var pinch: Bool {
        guard points.count == 21 else { return false }
        let finger = hypot(points[4].x - points[8].x, points[4].y - points[8].y)
        let palmSize = max(hypot(points[0].x - points[9].x, points[0].y - points[9].y), 0.035)
        return finger < palmSize * 0.48
    }
}

private final class V2HandVision {
    private let queue = DispatchQueue(label: "breakroom.v2.handvision", qos: .userInteractive)
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private var busy = false
    private(set) var latest: [V2HandPose] = []

    func process(_ buffer: CVPixelBuffer) {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
            do {
                try handler.perform([self.request])
                var poses: [V2HandPose] = []
                for observation in self.request.results ?? [] {
                    var pts: [CGPoint] = []
                    var minConfidence: Float = 1
                    var valid = true
                    for name in v2JointNames {
                        guard let rp = try? observation.recognizedPoint(name), rp.confidence > 0.16 else {
                            valid = false
                            break
                        }
                        minConfidence = min(minConfidence, rp.confidence)
                        pts.append(CGPoint(x: rp.location.x, y: 1 - rp.location.y))
                    }
                    if valid && pts.count == 21 {
                        poses.append(V2HandPose(points: pts, confidence: minConfidence))
                    }
                }
                poses.sort { $0.palm.x < $1.palm.x }
                DispatchQueue.main.async {
                    self.latest = poses
                }
            } catch {
                DispatchQueue.main.async { self.latest = [] }
            }
        }
    }
}

private final class V2TrackingOverlay: UIView {
    var poses: [V2HandPose] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for pose in poses {
            let tint = pose.pinch ? UIColor.systemGreen : UIColor.systemCyan
            ctx.setStrokeColor(tint.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(3)
            for (a, b) in v2HandLinks where a < pose.points.count && b < pose.points.count {
                let pa = CGPoint(x: pose.points[a].x * bounds.width, y: pose.points[a].y * bounds.height)
                let pb = CGPoint(x: pose.points[b].x * bounds.width, y: pose.points[b].y * bounds.height)
                ctx.move(to: pa)
                ctx.addLine(to: pb)
                ctx.strokePath()
            }
            for (index, p) in pose.points.enumerated() {
                let c = CGPoint(x: p.x * bounds.width, y: p.y * bounds.height)
                let radius: CGFloat = [4,8,12,16,20].contains(index) ? 6 : 4
                ctx.setFillColor((index == 4 || index == 8 ? UIColor.systemYellow : tint).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            }
        }
    }
}

private final class V2HandRig {
    let root = SCNNode()
    private var joints: [SCNNode] = []
    private var bones: [SCNNode] = []

    init(tint: UIColor) {
        let jointMat = SCNMaterial()
        jointMat.diffuse.contents = tint
        jointMat.emission.contents = tint.withAlphaComponent(0.35)
        jointMat.roughness.contents = 0.25

        let boneMat = SCNMaterial()
        boneMat.diffuse.contents = UIColor(white: 0.88, alpha: 0.95)
        boneMat.metalness.contents = 0.35
        boneMat.roughness.contents = 0.25

        for i in 0..<21 {
            let radius: CGFloat = [4,8,12,16,20].contains(i) ? 0.012 : 0.009
            let n = SCNNode(geometry: SCNSphere(radius: radius))
            n.geometry?.materials = [jointMat]
            root.addChildNode(n)
            joints.append(n)
        }
        for _ in v2HandLinks {
            let g = SCNBox(width: 0.009, height: 0.009, length: 1, chamferRadius: 0.003)
            g.materials = [boneMat]
            let n = SCNNode(geometry: g)
            root.addChildNode(n)
            bones.append(n)
        }
    }

    func hide() {
        root.isHidden = true
    }

    func update(worldPoints: [SCNVector3]) {
        guard worldPoints.count == 21 else { hide(); return }
        root.isHidden = false
        for i in 0..<21 {
            joints[i].position = worldPoints[i]
        }
        for (idx, link) in v2HandLinks.enumerated() {
            let a = worldPoints[link.0]
            let b = worldPoints[link.1]
            let mid = v2Mul(v2Add(a, b), 0.5)
            let length = max(v2Distance(a, b), 0.001)
            let bone = bones[idx]
            bone.position = mid
            bone.scale = SCNVector3(1, 1, length)
            bone.look(at: b, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, 1))
        }
    }
}

private final class V2Weapon {
    enum Kind: CaseIterable {
        case longsword, katana, axe, warhammer, staff, shield
    }

    let kind: Kind
    let node = SCNNode()
    let power: Float
    let mass: CGFloat
    var heldBy: Int?
    var enemyOwned = false
    var onRack = true
    var lastHit: TimeInterval = 0
    weak var pedestal: SCNNode?

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .longsword: power = 1.35; mass = 1.35
        case .katana: power = 1.25; mass = 1.05
        case .axe: power = 1.55; mass = 2.25
        case .warhammer: power = 1.72; mass = 3.1
        case .staff: power = 1.12; mass = 1.5
        case .shield: power = 0.92; mass = 2.8
        }
        buildVisual()
        node.name = "v2_weapon_\(kind)"
        let shape = SCNPhysicsShape(node: node, options: [.type: SCNPhysicsShape.ShapeType.boundingBox])
        let body = SCNPhysicsBody(type: .kinematic, shape: shape)
        body.mass = mass
        body.friction = 0.7
        body.restitution = 0.07
        body.categoryBitMask = V2Mask.weapon
        body.collisionBitMask = V2Mask.room | V2Mask.enemy | V2Mask.weapon
        body.contactTestBitMask = V2Mask.enemy
        body.continuousCollisionDetectionThreshold = 0.0001
        body.isAffectedByGravity = false
        node.physicsBody = body
    }

    private func material(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.45, glow: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        if let glow { m.emission.contents = glow }
        return m
    }

    private func box(_ size: SCNVector3, at p: SCNVector3, color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.45, rot: SCNVector3 = .init()) {
        let g = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.008)
        g.materials = [material(color, metal: metal, rough: rough)]
        let n = SCNNode(geometry: g)
        n.position = p
        n.eulerAngles = rot
        node.addChildNode(n)
    }

    private func cyl(radius: CGFloat, height: CGFloat, at p: SCNVector3, color: UIColor, metal: CGFloat = 0, rot: SCNVector3 = SCNVector3(Float.pi / 2, 0, 0)) {
        let g = SCNCylinder(radius: radius, height: height)
        g.materials = [material(color, metal: metal, rough: 0.52)]
        let n = SCNNode(geometry: g)
        n.position = p
        n.eulerAngles = rot
        node.addChildNode(n)
    }

    private func sphere(_ radius: CGFloat, at p: SCNVector3, color: UIColor, metal: CGFloat = 0) {
        let g = SCNSphere(radius: radius)
        g.materials = [material(color, metal: metal, rough: 0.3)]
        let n = SCNNode(geometry: g)
        n.position = p
        node.addChildNode(n)
    }

    private func buildVisual() {
        let steel = UIColor(red: 0.72, green: 0.78, blue: 0.84, alpha: 1)
        let edge = UIColor(red: 0.94, green: 0.97, blue: 1, alpha: 1)
        let black = UIColor(white: 0.035, alpha: 1)
        let leather = UIColor(red: 0.12, green: 0.055, blue: 0.025, alpha: 1)
        let gold = UIColor(red: 0.72, green: 0.42, blue: 0.08, alpha: 1)

        switch kind {
        case .longsword:
            box(SCNVector3(0.065, 0.012, 0.70), at: SCNVector3(0, 0, 0.40), color: steel, metal: 0.92, rough: 0.18)
            box(SCNVector3(0.020, 0.010, 0.61), at: SCNVector3(0, 0.008, 0.40), color: edge, metal: 1, rough: 0.1)
            box(SCNVector3(0.31, 0.038, 0.055), at: SCNVector3(0, 0, 0.035), color: gold, metal: 0.7)
            cyl(radius: 0.029, height: 0.24, at: SCNVector3(0, 0, -0.12), color: leather)
            sphere(0.045, at: SCNVector3(0, 0, -0.26), color: steel, metal: 0.9)
        case .katana:
            box(SCNVector3(0.050, 0.010, 0.34), at: SCNVector3(0.00, 0, 0.24), color: edge, metal: 0.95, rough: 0.14, rot: SCNVector3(0, -0.03, 0))
            box(SCNVector3(0.046, 0.010, 0.31), at: SCNVector3(0.025, 0, 0.56), color: edge, metal: 0.95, rough: 0.14, rot: SCNVector3(0, -0.07, 0))
            box(SCNVector3(0.040, 0.009, 0.22), at: SCNVector3(0.065, 0, 0.82), color: edge, metal: 0.95, rough: 0.12, rot: SCNVector3(0, -0.12, 0))
            cyl(radius: 0.075, height: 0.026, at: SCNVector3(0, 0, 0.025), color: gold, metal: 0.65, rot: SCNVector3(Float.pi / 2, 0, 0))
            cyl(radius: 0.026, height: 0.30, at: SCNVector3(0, 0, -0.16), color: black)
        case .axe:
            cyl(radius: 0.028, height: 0.78, at: SCNVector3(0, 0, 0.12), color: leather)
            box(SCNVector3(0.36, 0.10, 0.18), at: SCNVector3(0, 0, 0.53), color: steel, metal: 0.88, rough: 0.25)
            box(SCNVector3(0.18, 0.035, 0.27), at: SCNVector3(0.22, 0, 0.53), color: edge, metal: 0.98, rough: 0.12, rot: SCNVector3(0, 0, -0.12))
            box(SCNVector3(0.12, 0.05, 0.20), at: SCNVector3(-0.20, 0, 0.53), color: edge, metal: 0.98, rough: 0.12, rot: SCNVector3(0, 0, 0.12))
        case .warhammer:
            cyl(radius: 0.031, height: 0.72, at: SCNVector3(0, 0, 0.10), color: leather)
            box(SCNVector3(0.44, 0.17, 0.18), at: SCNVector3(0, 0, 0.52), color: black, metal: 0.75, rough: 0.32)
            cyl(radius: 0.095, height: 0.12, at: SCNVector3(0.26, 0, 0.52), color: steel, metal: 0.9, rot: SCNVector3(0, 0, Float.pi / 2))
            box(SCNVector3(0.15, 0.12, 0.12), at: SCNVector3(-0.27, 0, 0.52), color: steel, metal: 0.9, rough: 0.2)
        case .staff:
            cyl(radius: 0.027, height: 1.15, at: SCNVector3(0, 0, 0.30), color: UIColor(red: 0.08, green: 0.15, blue: 0.16, alpha: 1), metal: 0.25)
            cyl(radius: 0.045, height: 0.18, at: SCNVector3(0, 0, 0.91), color: gold, metal: 0.7)
            sphere(0.075, at: SCNVector3(0, 0, 1.04), color: UIColor.systemCyan, metal: 0.5)
        case .shield:
            let disc = SCNCylinder(radius: 0.34, height: 0.07)
            disc.materials = [material(UIColor(white: 0.08, alpha: 1), metal: 0.65, rough: 0.3)]
            let d = SCNNode(geometry: disc)
            d.eulerAngles.x = Float.pi / 2
            d.position = SCNVector3(0, 0, 0.15)
            node.addChildNode(d)
            let face = SCNCylinder(radius: 0.27, height: 0.035)
            face.materials = [material(UIColor(red: 0.55, green: 0.025, blue: 0.04, alpha: 1), metal: 0.25, rough: 0.35)]
            let f = SCNNode(geometry: face)
            f.eulerAngles.x = Float.pi / 2
            f.position = SCNVector3(0, 0, 0.20)
            node.addChildNode(f)
            sphere(0.09, at: SCNVector3(0, 0, 0.245), color: steel, metal: 0.95)
        }
    }
}

private final class V2Enemy {
    enum State { case approach, circle, telegraph, strike, recover, stunned, dead }

    let root = SCNNode()
    let torso = SCNNode()
    let head = SCNNode()
    let rightArmPivot = SCNNode()
    let leftArmPivot = SCNNode()
    var state: State = .approach
    var stateTime: Float = 0
    var hp: Float = 120
    var strafe: Float = Bool.random() ? 1 : -1
    var dead = false
    var lastImpact: TimeInterval = 0
    var weapon: V2Weapon?

    init(index: Int, variant: Int) {
        root.name = "v2_enemy_\(index)"
        buildModel(variant: variant)
        let shape = SCNPhysicsShape(geometry: SCNCapsule(capRadius: 0.24, height: 1.58), options: nil)
        let body = SCNPhysicsBody(type: .kinematic, shape: shape)
        body.categoryBitMask = V2Mask.enemy
        body.collisionBitMask = V2Mask.room | V2Mask.weapon | V2Mask.enemy
        body.contactTestBitMask = V2Mask.weapon
        body.isAffectedByGravity = false
        root.physicsBody = body
    }

    private func mat(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.42, glow: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        if let glow { m.emission.contents = glow }
        return m
    }

    private func addPart(_ parent: SCNNode, _ geo: SCNGeometry, _ pos: SCNVector3, _ material: SCNMaterial, rot: SCNVector3 = .init()) -> SCNNode {
        geo.materials = [material]
        let n = SCNNode(geometry: geo)
        n.position = pos
        n.eulerAngles = rot
        parent.addChildNode(n)
        return n
    }

    private func buildModel(variant: Int) {
        let armorColors: [UIColor] = [
            UIColor(red: 0.62, green: 0.025, blue: 0.045, alpha: 1),
            UIColor(red: 0.08, green: 0.26, blue: 0.34, alpha: 1),
            UIColor(red: 0.31, green: 0.08, blue: 0.42, alpha: 1)
        ]
        let armor = armorColors[variant % armorColors.count]
        let dark = UIColor(white: 0.035, alpha: 1)
        let metal = UIColor(red: 0.34, green: 0.38, blue: 0.43, alpha: 1)
        let glow = variant % 2 == 0 ? UIColor.systemOrange : UIColor.systemCyan

        let pelvis = addPart(root, SCNCapsule(capRadius: 0.14, height: 0.34), SCNVector3(0, 0.72, 0), mat(dark, metal: 0.2))
        _ = addPart(pelvis, SCNBox(width: 0.34, height: 0.09, length: 0.22, chamferRadius: 0.025), SCNVector3(0, 0.08, 0), mat(metal, metal: 0.7, rough: 0.28))

        torso.geometry = SCNBox(width: 0.44, height: 0.48, length: 0.24, chamferRadius: 0.055)
        torso.position = SCNVector3(0, 1.10, 0)
        torso.geometry?.materials = [mat(armor, metal: 0.2, rough: 0.33)]
        root.addChildNode(torso)
        _ = addPart(torso, SCNBox(width: 0.35, height: 0.30, length: 0.075, chamferRadius: 0.025), SCNVector3(0, 0.02, 0.15), mat(dark, metal: 0.72, rough: 0.27))
        _ = addPart(torso, SCNSphere(radius: 0.055), SCNVector3(0, 0.02, 0.20), mat(glow, metal: 0.4, rough: 0.18, glow: glow.withAlphaComponent(0.55)))
        _ = addPart(torso, SCNBox(width: 0.08, height: 0.26, length: 0.05, chamferRadius: 0.018), SCNVector3(-0.14, 0.02, 0.19), mat(metal, metal: 0.75, rough: 0.25))
        _ = addPart(torso, SCNBox(width: 0.08, height: 0.26, length: 0.05, chamferRadius: 0.018), SCNVector3(0.14, 0.02, 0.19), mat(metal, metal: 0.75, rough: 0.25))

        head.geometry = SCNCapsule(capRadius: 0.145, height: 0.29)
        head.position = SCNVector3(0, 1.54, 0)
        head.geometry?.materials = [mat(armor, metal: 0.18, rough: 0.32)]
        root.addChildNode(head)
        _ = addPart(head, SCNBox(width: 0.22, height: 0.13, length: 0.045, chamferRadius: 0.016), SCNVector3(0, 0, 0.145), mat(dark, metal: 0.65, rough: 0.22))
        _ = addPart(head, SCNBox(width: 0.15, height: 0.018, length: 0.018, chamferRadius: 0.008), SCNVector3(0, 0.02, 0.172), mat(glow, metal: 0.2, rough: 0.1, glow: glow))
        _ = addPart(head, SCNBox(width: 0.045, height: 0.22, length: 0.10, chamferRadius: 0.015), SCNVector3(0, 0.18, -0.02), mat(dark, metal: 0.7, rough: 0.3), rot: SCNVector3(0.06, 0, 0))

        for side: Float in [-1, 1] {
            let pivot = side > 0 ? rightArmPivot : leftArmPivot
            pivot.position = SCNVector3(0.30 * side, 1.28, 0)
            root.addChildNode(pivot)
            _ = addPart(pivot, SCNSphere(radius: 0.105), SCNVector3(0, 0, 0), mat(metal, metal: 0.65, rough: 0.27))
            let upper = addPart(pivot, SCNCapsule(capRadius: 0.068, height: 0.33), SCNVector3(0, -0.18, 0), mat(dark, metal: 0.15))
            let lower = addPart(upper, SCNCapsule(capRadius: 0.058, height: 0.31), SCNVector3(0, -0.31, 0.025), mat(armor, metal: 0.12, rough: 0.36))
            _ = addPart(lower, SCNBox(width: 0.13, height: 0.12, length: 0.13, chamferRadius: 0.03), SCNVector3(0, -0.22, 0.03), mat(dark, metal: 0.25))
        }

        for side: Float in [-1, 1] {
            let thigh = addPart(root, SCNCapsule(capRadius: 0.09, height: 0.42), SCNVector3(0.13 * side, 0.43, 0), mat(dark, metal: 0.18))
            let knee = addPart(thigh, SCNBox(width: 0.15, height: 0.13, length: 0.12, chamferRadius: 0.025), SCNVector3(0, -0.25, 0.06), mat(metal, metal: 0.75, rough: 0.28))
            let shin = addPart(knee, SCNCapsule(capRadius: 0.072, height: 0.36), SCNVector3(0, -0.22, -0.03), mat(armor, metal: 0.12, rough: 0.36))
            _ = addPart(shin, SCNBox(width: 0.15, height: 0.10, length: 0.25, chamferRadius: 0.03), SCNVector3(0, -0.22, 0.07), mat(dark, metal: 0.28))
        }
    }
}

final class FitnessGameV2ViewController: UIViewController, ARSCNViewDelegate, SCNPhysicsContactDelegate {
    private let ar = ARSCNView(frame: .zero)
    private let vision = V2HandVision()
    private let trackingOverlay = V2TrackingOverlay(frame: .zero)
    private let leftRig = V2HandRig(tint: .systemCyan)
    private let rightRig = V2HandRig(tint: .systemOrange)
    private let trackingLabel = UILabel()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let damageFlash = UIView()

    private var handWorldPoints: [[SCNVector3]] = [[], []]
    private var previousPalm: [SCNVector3?] = [nil, nil]
    private var handVelocity: [SCNVector3] = [.init(), .init()]
    private var pinchPrev = [false, false]
    private var held: [V2Weapon?] = [nil, nil]
    private var weapons: [V2Weapon] = []
    private var enemies: [V2Enemy] = []
    private var lastFrameTime: TimeInterval = 0
    private var floorY: Float = -1.2
    private var cameraBaseY: Float?
    private var cameraPrev: SCNVector3?
    private var round = 1
    private var fightTime: Float = 50
    private var restTime: Float = 12
    private var fighting = true
    private var score = 0
    private var combo = 0
    private var arenaReady = false

    override func viewDidLoad() {
        super.viewDidLoad()
        ar.frame = view.bounds
        ar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ar.delegate = self
        ar.scene.physicsWorld.contactDelegate = self
        ar.scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)
        ar.automaticallyUpdatesLighting = true
        view.addSubview(ar)

        ar.scene.rootNode.addChildNode(leftRig.root)
        ar.scene.rootNode.addChildNode(rightRig.root)

        trackingOverlay.frame = view.bounds
        trackingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(trackingOverlay)

        trackingLabel.frame = CGRect(x: 18, y: 14, width: 560, height: 34)
        trackingLabel.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        trackingLabel.textColor = .systemYellow
        trackingLabel.shadowColor = .black
        trackingLabel.text = "HAND TRACKING: PROCURANDO..."
        view.addSubview(trackingLabel)

        statusLabel.frame = CGRect(x: 18, y: 48, width: 720, height: 40)
        statusLabel.font = .monospacedSystemFont(ofSize: 21, weight: .bold)
        statusLabel.textColor = .white
        statusLabel.shadowColor = .black
        view.addSubview(statusLabel)

        hintLabel.frame = CGRect(x: 18, y: 88, width: 980, height: 32)
        hintLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        hintLabel.textColor = .white
        hintLabel.shadowColor = .black
        hintLabel.text = "PINCH = PEGAR  •  SOLTA = ARREMESSAR  •  SOCO FORTE = IMPACTO"
        view.addSubview(hintLabel)

        damageFlash.frame = view.bounds
        damageFlash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        damageFlash.backgroundColor = UIColor.systemRed.withAlphaComponent(0)
        damageFlash.isUserInteractionEnabled = false
        view.addSubview(damageFlash)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        ar.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.setupArena()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ar.session.pause()
    }

    private func setupArena() {
        guard !arenaReady, let pov = ar.pointOfView else { return }
        arenaReady = true
        let cam = pov.presentation.worldPosition
        cameraBaseY = cam.y
        floorY = cam.y - 1.30
        var forward = pov.presentation.convertVector(SCNVector3(0, 0, -1), to: nil)
        forward.y = 0
        forward = v2Norm(forward)
        let right = SCNVector3(-forward.z, 0, forward.x)

        let kinds = V2Weapon.Kind.allCases
        for i in 0..<kinds.count {
            let row = i / 3
            let col = i % 3
            let side = Float(col - 1) * 0.62
            let depth = 1.05 + Float(row) * 0.50
            var pos = v2Add(cam, v2Add(v2Mul(forward, depth), v2Mul(right, side)))
            pos.y = floorY + 0.78
            createPedestalWeapon(kind: kinds[i], position: pos, faceDirection: forward)
        }

        for i in 0..<2 {
            spawnEnemy(index: i, delay: Double(i) * 0.5)
        }
    }

    private func createPedestalWeapon(kind: V2Weapon.Kind, position: SCNVector3, faceDirection: SCNVector3) {
        let pedestal = SCNNode()
        pedestal.position = position

        let baseGeo = SCNCylinder(radius: 0.20, height: 0.08)
        let baseMat = SCNMaterial()
        baseMat.diffuse.contents = UIColor(white: 0.06, alpha: 0.92)
        baseMat.metalness.contents = 0.65
        baseMat.roughness.contents = 0.25
        baseGeo.materials = [baseMat]
        let base = SCNNode(geometry: baseGeo)
        base.position = SCNVector3(0, -0.38, 0)
        pedestal.addChildNode(base)

        let ringGeo = SCNTorus(ringRadius: 0.18, pipeRadius: 0.012)
        let ringMat = SCNMaterial()
        ringMat.diffuse.contents = UIColor.systemCyan
        ringMat.emission.contents = UIColor.systemCyan.withAlphaComponent(0.65)
        ringGeo.materials = [ringMat]
        let ring = SCNNode(geometry: ringGeo)
        ring.position = SCNVector3(0, -0.33, 0)
        pedestal.addChildNode(ring)

        let text = SCNText(string: displayName(kind), extrusionDepth: 0.006)
        text.font = UIFont.boldSystemFont(ofSize: 0.10)
        text.flatness = 0.15
        text.firstMaterial?.diffuse.contents = UIColor.white
        text.firstMaterial?.emission.contents = UIColor.white.withAlphaComponent(0.20)
        let label = SCNNode(geometry: text)
        label.scale = SCNVector3(0.55, 0.55, 0.55)
        label.position = SCNVector3(-0.19, -0.20, 0.04)
        pedestal.addChildNode(label)

        ar.scene.rootNode.addChildNode(pedestal)

        let weapon = V2Weapon(kind: kind)
        weapon.node.position = position
        weapon.node.eulerAngles = SCNVector3(-0.15, atan2(faceDirection.x, faceDirection.z), 0)
        weapon.pedestal = pedestal
        ar.scene.rootNode.addChildNode(weapon.node)
        weapons.append(weapon)
    }

    private func displayName(_ kind: V2Weapon.Kind) -> String {
        switch kind {
        case .longsword: return "ESPADA"
        case .katana: return "KATANA"
        case .axe: return "MACHADO"
        case .warhammer: return "MARTELO"
        case .staff: return "BASTAO"
        case .shield: return "ESCUDO"
        }
    }

    private func spawnEnemy(index: Int, delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.fighting, let pov = self.ar.pointOfView else { return }
            let enemy = V2Enemy(index: index + Int.random(in: 100...9999), variant: Int.random(in: 0...2))
            let cam = pov.presentation.worldPosition
            var forward = pov.presentation.convertVector(SCNVector3(0, 0, -1), to: nil)
            forward.y = 0
            forward = v2Norm(forward)
            let right = SCNVector3(-forward.z, 0, forward.x)
            var pos = v2Add(cam, v2Add(v2Mul(forward, Float.random(in: 2.25...2.85)), v2Mul(right, Float.random(in: -0.85...0.85))))
            pos.y = self.floorY
            enemy.root.position = pos
            self.ar.scene.rootNode.addChildNode(enemy.root)
            self.enemies.append(enemy)

            let weaponKinds: [V2Weapon.Kind] = [.longsword, .katana, .axe, .staff]
            let weapon = V2Weapon(kind: weaponKinds.randomElement() ?? .longsword)
            weapon.enemyOwned = true
            weapon.onRack = false
            weapon.node.physicsBody?.type = .kinematic
            weapon.node.physicsBody?.isAffectedByGravity = false
            self.ar.scene.rootNode.addChildNode(weapon.node)
            self.weapons.append(weapon)
            enemy.weapon = weapon
        }
    }

    private func handWorldPoints(for pose: V2HandPose) -> [SCNVector3] {
        let depth = v2Clamp(Float(0.76 - pose.span * 2.15), 0.30, 0.72)
        return pose.points.map { p in
            let px = p.x * view.bounds.width
            let py = p.y * view.bounds.height
            let near = ar.unprojectPoint(SCNVector3(Float(px), Float(py), 0))
            let far = ar.unprojectPoint(SCNVector3(Float(px), Float(py), 1))
            return v2Add(near, v2Mul(v2Norm(v2Sub(far, near)), depth))
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let frame = ar.session.currentFrame, let pov = ar.pointOfView else { return }
        vision.process(frame.capturedImage)
        let dt = Float(lastFrameTime == 0 ? 1.0 / 60.0 : min(time - lastFrameTime, 0.05))
        lastFrameTime = time
        let camera = pov.presentation.worldPosition
        updateHands(dt: dt)
        if fighting {
            updateCombat(dt: dt, camera: camera)
        } else {
            updateRest(dt: dt)
        }
        cameraPrev = camera
        DispatchQueue.main.async { [weak self] in
            self?.updateHUD()
        }
    }

    private func updateHands(dt: Float) {
        let poses = vision.latest
        DispatchQueue.main.async { [weak self] in
            self?.trackingOverlay.poses = poses
        }

        let rigs = [leftRig, rightRig]
        for i in 0..<2 {
            guard i < poses.count else {
                rigs[i].hide()
                handWorldPoints[i] = []
                previousPalm[i] = nil
                continue
            }
            let pose = poses[i]
            let world = handWorldPoints(for: pose)
            handWorldPoints[i] = world
            rigs[i].update(worldPoints: world)
            guard world.count == 21 else { continue }

            let palm = v2Mul(v2Add(v2Add(world[0], world[9]), v2Add(world[5], world[17])), 0.25)
            if let prev = previousPalm[i] {
                handVelocity[i] = v2Mul(v2Sub(palm, prev), 1 / max(dt, 0.001))
            } else {
                handVelocity[i] = .init()
            }
            let oldPalm = previousPalm[i]
            previousPalm[i] = palm

            let pinching = pose.pinch
            if pinching && held[i] == nil {
                tryGrabContinuously(hand: i, palm: palm)
            }
            if !pinching && pinchPrev[i] {
                release(hand: i)
            }
            pinchPrev[i] = pinching

            if let weapon = held[i] {
                weapon.node.position = palm
                let forward = v2Norm(v2Sub(world[8], world[0]))
                weapon.node.look(at: v2Add(palm, forward), up: v2Norm(v2Sub(world[5], world[17])), localFront: SCNVector3(0, 0, 1))
            } else if let oldPalm {
                checkPunch(hand: i, from: oldPalm, to: palm, velocity: handVelocity[i])
            }
        }
    }

    private func tryGrabContinuously(hand: Int, palm: SCNVector3) {
        var best: V2Weapon?
        var bestDistance: Float = 0.34
        for weapon in weapons where weapon.heldBy == nil && !weapon.enemyOwned {
            let d = v2Distance(weapon.node.presentation.worldPosition, palm)
            if d < bestDistance {
                bestDistance = d
                best = weapon
            }
        }
        guard let weapon = best else { return }
        weapon.heldBy = hand
        weapon.onRack = false
        weapon.pedestal?.isHidden = true
        weapon.node.physicsBody?.type = .kinematic
        weapon.node.physicsBody?.isAffectedByGravity = false
        held[hand] = weapon
        combo += 1
    }

    private func release(hand: Int) {
        guard let weapon = held[hand] else { return }
        weapon.heldBy = nil
        weapon.node.physicsBody?.type = .dynamic
        weapon.node.physicsBody?.isAffectedByGravity = true
        weapon.node.physicsBody?.velocity = handVelocity[hand]
        weapon.node.physicsBody?.angularVelocity = SCNVector4(handVelocity[hand].z, handVelocity[hand].x, handVelocity[hand].y, min(v2Len(handVelocity[hand]) * 2.1, 8))
        held[hand] = nil
    }

    private func checkPunch(hand: Int, from a: SCNVector3, to b: SCNVector3, velocity: SCNVector3) {
        let speed = v2Len(velocity)
        guard speed > 0.45 else { return }
        for enemy in enemies where !enemy.dead {
            let head = enemy.head.presentation.worldPosition
            let chest = enemy.torso.presentation.worldPosition
            let hitDistance = min(v2SegmentDistance(head, a, b), v2SegmentDistance(chest, a, b))
            if hitDistance < 0.23 {
                hitEnemy(enemy, velocity: velocity, power: speed > 0.80 ? 1.0 : 0.45)
                score += Int(speed * 22)
                return
            }
        }
    }

    private func hitEnemy(_ enemy: V2Enemy, velocity: SCNVector3, power: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - enemy.lastImpact > 0.10 else { return }
        enemy.lastImpact = now
        let impact = v2Len(velocity) * power
        guard impact > 0.28 else { return }
        enemy.hp -= v2Clamp(impact * 17, 5, 70)
        enemy.state = .stunned
        enemy.stateTime = 0.52
        enemy.root.physicsBody?.type = .dynamic
        enemy.root.physicsBody?.mass = 66
        enemy.root.physicsBody?.isAffectedByGravity = true
        let impulse = v2Mul(v2Norm(velocity), v2Clamp(impact * 1.7, 0.8, 7.5))
        enemy.root.physicsBody?.applyForce(impulse, asImpulse: true)
        score += Int(impact * 35)
        combo += 1
        if enemy.hp <= 0 || impact > 6.8 {
            killEnemy(enemy)
        }
    }

    private func killEnemy(_ enemy: V2Enemy) {
        guard !enemy.dead else { return }
        enemy.dead = true
        enemy.state = .dead
        score += 350 + combo * 9
        enemy.root.physicsBody?.type = .dynamic
        enemy.root.physicsBody?.isAffectedByGravity = true
        if let weapon = enemy.weapon {
            weapon.enemyOwned = false
            weapon.node.physicsBody?.type = .dynamic
            weapon.node.physicsBody?.isAffectedByGravity = true
            enemy.weapon = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self, weak enemy] in
            enemy?.root.removeFromParentNode()
            guard let self, self.fighting else { return }
            self.spawnEnemy(index: Int.random(in: 0...999))
        }
    }

    private func updateCombat(dt: Float, camera: SCNVector3) {
        fightTime -= dt
        if fightTime <= 0 {
            fighting = false
            restTime = 12
            return
        }
        let active = enemies.filter { !$0.dead && $0.root.parent != nil }.count
        let target = min(2 + (round - 1) / 2, 3)
        if active < target {
            spawnEnemy(index: Int.random(in: 0...999), delay: 0.45)
        }
        for enemy in enemies where !enemy.dead {
            updateEnemy(enemy, dt: dt, camera: camera)
        }
    }

    private func updateRest(dt: Float) {
        restTime -= dt
        if restTime <= 0 {
            round += 1
            fightTime = 50
            fighting = true
        }
    }

    private func updateEnemy(_ enemy: V2Enemy, dt: Float, camera: SCNVector3) {
        if enemy.state == .stunned {
            enemy.stateTime -= dt
            if enemy.stateTime <= 0 && !enemy.dead {
                enemy.root.physicsBody?.type = .kinematic
                enemy.root.physicsBody?.isAffectedByGravity = false
                var p = enemy.root.presentation.worldPosition
                p.y = floorY
                enemy.root.position = p
                enemy.state = .recover
                enemy.stateTime = 0
            }
            return
        }

        enemy.stateTime += dt
        var toPlayer = v2Sub(camera, enemy.root.presentation.worldPosition)
        toPlayer.y = 0
        let distance = v2Len(toPlayer)
        let dir = v2Norm(toPlayer)
        let side = v2Mul(SCNVector3(-dir.z, 0, dir.x), enemy.strafe)

        switch enemy.state {
        case .approach:
            let speed = min(0.44 + Float(round - 1) * 0.025, 0.62)
            if distance > 1.35 {
                enemy.root.position = v2Add(enemy.root.position, v2Add(v2Mul(dir, speed * dt), v2Mul(side, 0.07 * dt)))
            } else {
                enemy.state = .circle
                enemy.stateTime = 0
            }
        case .circle:
            enemy.root.position = v2Add(enemy.root.position, v2Mul(side, 0.24 * dt))
            if enemy.stateTime > 0.75 {
                enemy.state = .telegraph
                enemy.stateTime = 0
            }
        case .telegraph:
            enemy.rightArmPivot.eulerAngles.x = -0.95 * min(enemy.stateTime / 0.62, 1)
            enemy.leftArmPivot.eulerAngles.z = 0.22 * sin(enemy.stateTime * 6)
            if enemy.stateTime > 0.62 {
                enemy.state = .strike
                enemy.stateTime = 0
            }
        case .strike:
            enemy.rightArmPivot.eulerAngles.x = -0.95 + 2.1 * min(enemy.stateTime / 0.32, 1)
            if enemy.stateTime > 0.15 && enemy.stateTime < 0.20 {
                enemyAttack(enemy, camera: camera)
            }
            if enemy.stateTime > 0.34 {
                enemy.state = .recover
                enemy.stateTime = 0
            }
        case .recover:
            enemy.rightArmPivot.eulerAngles.x *= 0.86
            if enemy.stateTime > 0.82 {
                enemy.state = .approach
                enemy.stateTime = 0
            }
        case .stunned, .dead:
            break
        }

        enemy.root.eulerAngles.y = atan2(dir.x, dir.z)
        if let weapon = enemy.weapon {
            let hand = enemy.root.presentation.convertPosition(SCNVector3(0.37, 0.88, 0.06), to: nil)
            weapon.node.position = hand
            weapon.node.eulerAngles = SCNVector3(enemy.rightArmPivot.eulerAngles.x, enemy.root.eulerAngles.y, 0)
        }
    }

    private func enemyAttack(_ enemy: V2Enemy, camera: SCNVector3) {
        let d = v2Distance(enemy.root.presentation.worldPosition, camera)
        guard d < 1.50 else { return }
        let crouched = (cameraBaseY ?? camera.y) - camera.y > 0.20
        let lateral = abs((cameraPrev ?? camera).x - camera.x)
        if crouched || lateral > 0.065 {
            score += 90
            combo += 1
            return
        }
        combo = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.damageFlash.backgroundColor = UIColor.systemRed.withAlphaComponent(0.30)
            UIView.animate(withDuration: 0.32) {
                self.damageFlash.backgroundColor = UIColor.systemRed.withAlphaComponent(0)
            }
        }
    }

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        let nodes = [contact.nodeA, contact.nodeB]
        guard let weaponNode = nodes.first(where: { $0.physicsBody?.categoryBitMask == V2Mask.weapon }),
              let enemyNode = nodes.first(where: { $0.physicsBody?.categoryBitMask == V2Mask.enemy }),
              let weapon = weapons.first(where: { $0.node === weaponNode }),
              let enemy = enemies.first(where: { $0.root === enemyNode }),
              !enemy.dead else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - weapon.lastHit > 0.10 else { return }
        weapon.lastHit = now
        let velocity = weaponNode.physicsBody?.velocity ?? SCNVector3()
        if v2Len(velocity) > 0.38 {
            hitEnemy(enemy, velocity: velocity, power: Float(weapon.mass) * weapon.power)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor else { return }
        let plane = SCNPlane(width: CGFloat(planeAnchor.planeExtent.width), height: CGFloat(planeAnchor.planeExtent.height))
        plane.firstMaterial?.diffuse.contents = UIColor.clear
        let collider = SCNNode(geometry: plane)
        if planeAnchor.alignment == .horizontal {
            collider.eulerAngles.x = -Float.pi / 2
        }
        let body = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: plane, options: nil))
        body.categoryBitMask = V2Mask.room
        body.collisionBitMask = V2Mask.weapon | V2Mask.enemy
        collider.physicsBody = body
        node.addChildNode(collider)
    }

    private func updateHUD() {
        let count = vision.latest.count
        if count == 0 {
            trackingLabel.text = "HAND TRACKING: NAO VI SUAS MAOS"
            trackingLabel.textColor = .systemRed
        } else {
            let pinchCount = vision.latest.filter { $0.pinch }.count
            trackingLabel.text = "HAND TRACKING: \(count)/2  •  PINCH \(pinchCount)"
            trackingLabel.textColor = .systemGreen
        }
        if fighting {
            statusLabel.text = "ROUND \(round)   \(Int(ceil(fightTime)))s   SCORE \(score)   COMBO x\(combo)"
        } else {
            statusLabel.text = "DESCANSO \(Int(ceil(restTime)))s   SCORE \(score)"
        }
    }
}
