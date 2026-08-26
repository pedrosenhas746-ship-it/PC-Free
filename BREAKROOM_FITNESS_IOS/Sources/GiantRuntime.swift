import UIKit
import ARKit
import SceneKit
import Vision
import AudioToolbox

enum GMask {
    static let room = 1 << 8
    static let weapon = 1 << 9
    static let enemy = 1 << 10
    static let ragdoll = 1 << 11
}

func gAdd(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 { .init(a.x+b.x,a.y+b.y,a.z+b.z) }
func gSub(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 { .init(a.x-b.x,a.y-b.y,a.z-b.z) }
func gMul(_ a: SCNVector3, _ s: Float) -> SCNVector3 { .init(a.x*s,a.y*s,a.z*s) }
func gLen(_ a: SCNVector3) -> Float { sqrt(a.x*a.x+a.y*a.y+a.z*a.z) }
func gNorm(_ a: SCNVector3) -> SCNVector3 { let l=max(gLen(a),0.0001); return gMul(a,1/l) }
func gDistance(_ a: SCNVector3, _ b: SCNVector3) -> Float { gLen(gSub(a,b)) }
func gClamp(_ x:Float,_ a:Float,_ b:Float)->Float { min(max(x,a),b) }
func gSegDistance(_ p:SCNVector3,_ a:SCNVector3,_ b:SCNVector3)->Float {
    let ab=gSub(b,a), ap=gSub(p,a)
    let den=max(ab.x*ab.x+ab.y*ab.y+ab.z*ab.z,0.00001)
    let t=gClamp((ap.x*ab.x+ap.y*ab.y+ap.z*ab.z)/den,0,1)
    return gDistance(p,gAdd(a,gMul(ab,t)))
}

let gJointNames:[VNHumanHandPoseObservation.JointName] = [
    .wrist,.thumbCMC,.thumbMP,.thumbIP,.thumbTip,
    .indexMCP,.indexPIP,.indexDIP,.indexTip,
    .middleMCP,.middlePIP,.middleDIP,.middleTip,
    .ringMCP,.ringPIP,.ringDIP,.ringTip,
    .littleMCP,.littlePIP,.littleDIP,.littleTip
]
let gHandLinks:[(Int,Int)] = [
    (0,1),(1,2),(2,3),(3,4),(0,5),(5,6),(6,7),(7,8),
    (0,9),(9,10),(10,11),(11,12),(0,13),(13,14),(14,15),(15,16),
    (0,17),(17,18),(18,19),(19,20),(5,9),(9,13),(13,17)
]

struct GHandPose {
    let points:[CGPoint]
    let confidence:Float
    var palm:CGPoint {
        guard points.count==21 else{return .zero}
        return CGPoint(x:(points[0].x+points[5].x+points[9].x+points[13].x+points[17].x)/5,
                       y:(points[0].y+points[5].y+points[9].y+points[13].y+points[17].y)/5)
    }
    var span:CGFloat {
        guard points.count==21 else{return 0.1}
        return hypot(points[0].x-points[9].x,points[0].y-points[9].y)
    }
    var pinch:Bool {
        guard points.count==21 else{return false}
        let d=hypot(points[4].x-points[8].x,points[4].y-points[8].y)
        let p=max(hypot(points[0].x-points[9].x,points[0].y-points[9].y),0.035)
        return d < p*0.52
    }
}

final class GHandVision {
    private let queue=DispatchQueue(label:"breakroom.giant.handvision",qos:.userInteractive)
    private let request:VNDetectHumanHandPoseRequest = {
        let r=VNDetectHumanHandPoseRequest();r.maximumHandCount=2;return r
    }()
    private var busy=false
    private(set) var latest:[GHandPose]=[]
    func process(_ buffer:CVPixelBuffer) {
        guard !busy else{return};busy=true
        queue.async { [weak self] in
            guard let self else{return}
            defer{self.busy=false}
            let handler=VNImageRequestHandler(cvPixelBuffer:buffer,orientation:.right,options:[:])
            do {
                try handler.perform([self.request])
                var found:[GHandPose]=[]
                for obs in self.request.results ?? [] {
                    var pts:[CGPoint]=[], minC:Float=1, ok=true
                    for name in gJointNames {
                        guard let p=try? obs.recognizedPoint(name),p.confidence>0.15 else{ok=false;break}
                        minC=min(minC,p.confidence)
                        pts.append(CGPoint(x:p.location.x,y:1-p.location.y))
                    }
                    if ok && pts.count==21 { found.append(.init(points:pts,confidence:minC)) }
                }
                found.sort{$0.palm.x<$1.palm.x}
                DispatchQueue.main.async{self.latest=found}
            } catch { DispatchQueue.main.async{self.latest=[]} }
        }
    }
}

final class GTrackingOverlay:UIView {
    var poses:[GHandPose]=[]{didSet{setNeedsDisplay()}}
    override init(frame:CGRect){super.init(frame:frame);backgroundColor=.clear;isOpaque=false;isUserInteractionEnabled=false}
    required init?(coder:NSCoder){fatalError()}
    override func draw(_ rect:CGRect) {
        guard let c=UIGraphicsGetCurrentContext() else{return}
        c.setLineCap(.round);c.setLineJoin(.round)
        for pose in poses {
            let tint=pose.pinch ? UIColor.systemGreen : UIColor.systemCyan
            c.setStrokeColor(tint.withAlphaComponent(.9).cgColor);c.setLineWidth(3)
            for (a,b) in gHandLinks {
                let pa=CGPoint(x:pose.points[a].x*bounds.width,y:pose.points[a].y*bounds.height)
                let pb=CGPoint(x:pose.points[b].x*bounds.width,y:pose.points[b].y*bounds.height)
                c.move(to:pa);c.addLine(to:pb);c.strokePath()
            }
            for (i,p) in pose.points.enumerated() {
                let q=CGPoint(x:p.x*bounds.width,y:p.y*bounds.height)
                let r:CGFloat=[4,8,12,16,20].contains(i) ? 6:4
                c.setFillColor((i==4 || i==8 ? UIColor.systemYellow:tint).cgColor)
                c.fillEllipse(in:CGRect(x:q.x-r,y:q.y-r,width:r*2,height:r*2))
            }
        }
    }
}

final class GHandRig {
    let root=SCNNode();private var joints:[SCNNode]=[];private var bones:[SCNNode]=[]
    init(tint:UIColor) {
        let jm=SCNMaterial();jm.diffuse.contents=tint;jm.emission.contents=tint.withAlphaComponent(.3);jm.roughness.contents=0.22
        let bm=SCNMaterial();bm.diffuse.contents=UIColor(white:.9,alpha:.95);bm.metalness.contents=.35;bm.roughness.contents=.22
        for i in 0..<21 {
            let s=SCNSphere(radius:[4,8,12,16,20].contains(i) ? .013:.009)
            s.materials=[jm];let n=SCNNode(geometry:s);root.addChildNode(n);joints.append(n)
        }
        for _ in gHandLinks {
            let g=SCNCylinder(radius:.005,height:1);g.materials=[bm]
            let n=SCNNode(geometry:g);root.addChildNode(n);bones.append(n)
        }
    }
    func hide(){root.isHidden=true}
    func update(_ pts:[SCNVector3]) {
        guard pts.count==21 else{hide();return};root.isHidden=false
        for i in 0..<21 { joints[i].position=pts[i] }
        for (i,link) in gHandLinks.enumerated() {
            let a=pts[link.0],b=pts[link.1],d=gSub(b,a),l=gLen(d)
            let n=bones[i];n.position=gMul(gAdd(a,b),.5);n.scale=SCNVector3(1,l,1)
            n.look(at:b,up:SCNVector3(0,1,0),localFront:SCNVector3(0,1,0))
        }
    }
}

final class GAudio {
    static let shared=GAudio()
    private var sources:[String:SCNAudioSource]=[:]
    private init() {
        for name in ["swing","metal_hit","body_hit","parry","grab","whoosh","enemy_spawn","enemy_down","round_start","round_end","dodge","shield"] {
            if let s=SCNAudioSource(fileNamed:"Audio/\(name).wav") {
                s.isPositional=true;s.shouldStream=false;s.load();sources[name]=s
            }
        }
    }
    func play(_ name:String,on node:SCNNode,volume:Float=1) {
        guard let src=sources[name]?.copy() as? SCNAudioSource else{return}
        src.volume=volume
        node.runAction(.playAudio(src,waitForCompletion:false))
    }
}

enum GAssets {
    static func loadedNode(_ name:String)->SCNNode? {
        guard let url=Bundle.main.url(forResource:name,withExtension:"obj",subdirectory:"Models") else{return nil}
        guard let ref=SCNReferenceNode(url:url) else{return nil}
        ref.load()
        return ref
    }
    static func material(_ color:UIColor,metal:CGFloat=0,rough:CGFloat=.4,emission:UIColor?=nil)->SCNMaterial {
        let m=SCNMaterial();m.lightingModel=.physicallyBased;m.diffuse.contents=color;m.metalness.contents=metal;m.roughness.contents=rough
        if let emission {m.emission.contents=emission}
        return m
    }
    static func apply(_ node:SCNNode,material:SCNMaterial) {
        node.enumerateChildNodes { n,_ in
            if let g=n.geometry { g.materials=Array(repeating:material,count:max(1,g.materials.count)) }
        }
    }
    static func glow(_ color:UIColor,radius:CGFloat=.045)->SCNNode {
        let g=SCNSphere(radius:radius);g.materials=[material(color,metal:.1,rough:.2,emission:color)]
        return SCNNode(geometry:g)
    }
}

final class GWeapon {
    enum Kind:String,CaseIterable { case longsword,katana,axe,warhammer,staff,shield,spear,mace }
    let kind:Kind;let node=SCNNode();let mass:CGFloat;let power:Float;let reach:Float
    var heldBy:Int?;var enemyOwner:GEnemy?;var onRack=true;var pedestal:SCNNode?;var lastHit:TimeInterval=0
    init(_ kind:Kind) {
        self.kind=kind
        switch kind {
        case .longsword:mass=1.25;power=1.35;reach=.88
        case .katana:mass=1.05;power=1.28;reach=.90
        case .axe:mass=2.3;power=1.62;reach=.78
        case .warhammer:mass=3.2;power=1.78;reach=.76
        case .staff:mass=1.5;power=1.08;reach=1.05
        case .shield:mass=3.1;power=.9;reach=.38
        case .spear:mass=1.8;power=1.46;reach=1.38
        case .mace:mass=2.1;power=1.48;reach=.72
        }
        build()
        node.name="giant_weapon_\(kind.rawValue)"
        let shape=SCNPhysicsShape(node:node,options:[.type:SCNPhysicsShape.ShapeType.boundingBox])
        let body=SCNPhysicsBody(type:.kinematic,shape:shape);body.mass=mass;body.friction=.72;body.restitution=.1
        body.categoryBitMask=GMask.weapon;body.collisionBitMask=GMask.room|GMask.weapon|GMask.enemy|GMask.ragdoll
        body.contactTestBitMask=GMask.enemy|GMask.ragdoll;body.continuousCollisionDetectionThreshold=.0001
        node.physicsBody=body
    }
    private func build() {
        if let model=GAssets.loadedNode(kind.rawValue) {
            let metal=GAssets.material(.init(white:.72,alpha:1),metal:.9,rough:.22)
            GAssets.apply(model,material:metal);node.addChildNode(model);return
        }
        let g=SCNBox(width:.06,height:.02,length:CGFloat(reach),chamferRadius:.008)
        g.materials=[GAssets.material(.lightGray,metal:.9,rough:.2)]
        let n=SCNNode(geometry:g);n.position.z=reach*.45;node.addChildNode(n)
    }
}

final class GEnemy {
    enum Archetype:String,CaseIterable { case duelist,brute,sentinel,striker }
    enum State { case approach,strafe,feint,telegraph,strike,recover,evade,stunned,disarmed,dead }
    let root=SCNNode();let archetype:Archetype
    let head=SCNNode(),torso=SCNNode(),pelvis=SCNNode()
    let rightArm=SCNNode(),leftArm=SCNNode(),leftLeg=SCNNode(),rightLeg=SCNNode()
    var state:State=.approach;var stateTime:Float=0;var hp:Float;var strafe:Float
    var dead=false;var weapon:GWeapon?;var lastImpact:TimeInterval=0;var attackConnected=false
    var speed:Float;var attackRange:Float;var recovery:Float
    init(index:Int,archetype:Archetype) {
        self.archetype=archetype;self.strafe=Bool.random() ? 1:-1
        switch archetype {
        case .duelist:hp=105;speed=.48;attackRange=1.30;recovery=.78
        case .brute:hp=165;speed=.34;attackRange=1.22;recovery=1.05
        case .sentinel:hp=135;speed=.40;attackRange=1.36;recovery=.92
        case .striker:hp=85;speed=.58;attackRange=1.25;recovery=.65
        }
        root.name="giant_enemy_\(index)"
        buildBody(index:index)
        let shape=SCNPhysicsShape(geometry:SCNCapsule(capRadius:.24,height:1.58),options:nil)
        let b=SCNPhysicsBody(type:.kinematic,shape:shape);b.categoryBitMask=GMask.enemy;b.collisionBitMask=GMask.room|GMask.weapon|GMask.enemy;b.contactTestBitMask=GMask.weapon
        root.physicsBody=b
    }
    private func buildBody(index:Int) {
        let colors:[UIColor]=[.systemRed,.systemOrange,.systemPurple,.systemBlue]
        let armor=colors[index%colors.count],dark=UIColor(white:.035,alpha:1)
        let am=GAssets.material(armor,metal:.55,rough:.28),dm=GAssets.material(dark,metal:.75,rough:.2),sm=GAssets.material(.init(white:.35,alpha:1),metal:.92,rough:.22)
        pelvis.geometry=SCNCapsule(capRadius:.14,height:.34);pelvis.geometry?.materials=[dm];pelvis.position=.init(0,.70,0);root.addChildNode(pelvis)
        torso.geometry=SCNBox(width:.43,height:.48,length:.23,chamferRadius:.055);torso.geometry?.materials=[am];torso.position=.init(0,1.08,0);root.addChildNode(torso)
        if let chest=GAssets.loadedNode("enemy_chest") { chest.scale=.init(.85,.85,.85);chest.position=.init(0,0,.02);GAssets.apply(chest,material:sm);torso.addChildNode(chest) }
        head.geometry=SCNCapsule(capRadius:.15,height:.28);head.geometry?.materials=[am];head.position=.init(0,1.54,0);root.addChildNode(head)
        if let helmet=GAssets.loadedNode("enemy_helmet") { helmet.scale=.init(.9,.9,.9);GAssets.apply(helmet,material:dm);head.addChildNode(helmet) }
        let visor=GAssets.glow(.systemRed,radius:.035);visor.scale=.init(1.8,.45,.3);visor.position=.init(0,-.02,.17);head.addChildNode(visor)
        makeArm(pivot:leftArm,side:-1,armor:am,dark:dm);makeArm(pivot:rightArm,side:1,armor:am,dark:dm)
        makeLeg(pivot:leftLeg,side:-1,armor:am,dark:dm);makeLeg(pivot:rightLeg,side:1,armor:am,dark:dm)
        let core=GAssets.glow(archetype == .brute ? .systemOrange:.systemRed,radius:.055);core.position=.init(0,0,.15);torso.addChildNode(core)
    }
    private func makeArm(pivot:SCNNode,side:Float,armor:SCNMaterial,dark:SCNMaterial) {
        pivot.position=.init(.29*side,1.28,0);root.addChildNode(pivot)
        let upper=SCNNode(geometry:SCNCapsule(capRadius:.068,height:.33));upper.geometry?.materials=[dark];upper.position=.init(0,-.17,0);pivot.addChildNode(upper)
        let lower=SCNNode(geometry:SCNCapsule(capRadius:.058,height:.30));lower.geometry?.materials=[armor];lower.position=.init(0,-.31,.025);upper.addChildNode(lower)
        if let br=GAssets.loadedNode("enemy_bracer") { br.scale=.init(.75,.75,.75);br.position=.init(0,-.08,0);GAssets.apply(br,material:armor);lower.addChildNode(br) }
        let hand=SCNNode(geometry:SCNSphere(radius:.072));hand.geometry?.materials=[dark];hand.position=.init(0,-.19,.02);lower.addChildNode(hand)
    }
    private func makeLeg(pivot:SCNNode,side:Float,armor:SCNMaterial,dark:SCNMaterial) {
        pivot.position=.init(.12*side,.62,0);root.addChildNode(pivot)
        let thigh=SCNNode(geometry:SCNCapsule(capRadius:.088,height:.42));thigh.geometry?.materials=[dark];thigh.position=.init(0,-.18,0);pivot.addChildNode(thigh)
        let shin=SCNNode(geometry:SCNCapsule(capRadius:.073,height:.37));shin.geometry?.materials=[armor];shin.position=.init(0,-.36,.03);thigh.addChildNode(shin)
        let boot=SCNNode(geometry:SCNBox(width:.14,height:.10,length:.24,chamferRadius:.025));boot.geometry?.materials=[dark];boot.position=.init(0,-.22,.08);shin.addChildNode(boot)
    }
    func handPosition()->SCNVector3 { root.presentation.convertPosition(.init(.40,.92,.07),to:nil) }
    func ragdoll(in scene:SCNScene,impulse:SCNVector3) {
        root.isHidden=true
        let specs:[(SCNGeometry,SCNVector3,CGFloat)] = [
            (SCNSphere(radius:.15),head.presentation.worldPosition,5),
            (SCNBox(width:.42,height:.48,length:.23,chamferRadius:.05),torso.presentation.worldPosition,18),
            (SCNCapsule(capRadius:.14,height:.34),pelvis.presentation.worldPosition,12),
            (SCNCapsule(capRadius:.07,height:.55),leftArm.presentation.worldPosition,6),
            (SCNCapsule(capRadius:.07,height:.55),rightArm.presentation.worldPosition,6),
            (SCNCapsule(capRadius:.09,height:.68),leftLeg.presentation.worldPosition,9),
            (SCNCapsule(capRadius:.09,height:.68),rightLeg.presentation.worldPosition,9)
        ]
        for (g,p,mass) in specs {
            g.materials=[GAssets.material(.systemRed,metal:.45,rough:.32)]
            let n=SCNNode(geometry:g);n.position=p
            let b=SCNPhysicsBody(type:.dynamic,shape:SCNPhysicsShape(geometry:g,options:nil));b.mass=mass;b.categoryBitMask=GMask.ragdoll;b.collisionBitMask=GMask.room|GMask.weapon|GMask.ragdoll
            n.physicsBody=b;scene.rootNode.addChildNode(n);b.applyForce(gMul(impulse,Float(mass/20)),asImpulse:true)
            n.runAction(.sequence([.wait(duration:7),.fadeOut(duration:.8),.removeFromParentNode()]))
        }
    }
}

final class GEffects {
    static func spark(at p:SCNVector3,in scene:SCNScene,color:UIColor=.systemOrange) {
        let host=SCNNode();host.position=p
        let ps=SCNParticleSystem();ps.birthRate=420;ps.particleLifeSpan=.35;ps.emissionDuration=.035;ps.particleSize=.018;ps.particleVelocity=2.1;ps.particleVelocityVariation=1.0;ps.spreadingAngle=180;ps.particleColor=color;ps.blendMode=.additive
        host.addParticleSystem(ps);scene.rootNode.addChildNode(host);host.runAction(.sequence([.wait(duration:.7),.removeFromParentNode()]))
    }
    static func ring(at p:SCNVector3,in scene:SCNScene,color:UIColor) {
        let g=SCNTorus(ringRadius:.10,pipeRadius:.008);g.materials=[GAssets.material(color,metal:.2,rough:.2,emission:color)]
        let n=SCNNode(geometry:g);n.position=p;scene.rootNode.addChildNode(n)
        n.runAction(.group([.scale(to:4,duration:.28),.fadeOut(duration:.28)])){n.removeFromParentNode()}
    }
}
