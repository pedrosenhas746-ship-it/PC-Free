import UIKit
import ARKit
import SceneKit
import Vision

private enum Mask {
    static let room = 1 << 0
    static let weapon = 1 << 1
    static let npc = 1 << 2
}

private extension SCNVector3 {
    static func +(l: SCNVector3, r: SCNVector3) -> SCNVector3 { .init(l.x+r.x,l.y+r.y,l.z+r.z) }
    static func -(l: SCNVector3, r: SCNVector3) -> SCNVector3 { .init(l.x-r.x,l.y-r.y,l.z-r.z) }
    static func *(l: SCNVector3, r: Float) -> SCNVector3 { .init(l.x*r,l.y*r,l.z*r) }
    var length: Float { sqrt(x*x+y*y+z*z) }
    var normalized: SCNVector3 { let d=max(length,0.0001); return self*(1/d) }
}

private func dist(_ a: SCNVector3,_ b: SCNVector3)->Float { (a-b).length }
private func clamp(_ x:Float,_ a:Float,_ b:Float)->Float { min(max(x,a),b) }

private struct HandSample {
    let wrist: CGPoint
    let thumb: CGPoint
    let index: CGPoint
    let middle: CGPoint
    var palm: CGPoint { CGPoint(x:(wrist.x+middle.x)*0.5,y:(wrist.y+middle.y)*0.5) }
    var span: CGFloat { hypot(wrist.x-middle.x,wrist.y-middle.y) }
    var pinch: Bool { hypot(thumb.x-index.x,thumb.y-index.y) < 0.058 }
}

private final class HandVision {
    private let q = DispatchQueue(label:"breakroom.fitness.hands",qos:.userInteractive)
    private let request: VNDetectHumanHandPoseRequest = {
        let r=VNDetectHumanHandPoseRequest(); r.maximumHandCount=2; return r
    }()
    private var busy=false
    private(set) var latest:[HandSample]=[]

    func process(_ pixelBuffer:CVPixelBuffer) {
        guard !busy else { return }
        busy=true
        q.async { [weak self] in
            guard let self else { return }
            defer { self.busy=false }
            let handler=VNImageRequestHandler(cvPixelBuffer:pixelBuffer,orientation:.right,options:[:])
            do {
                try handler.perform([self.request])
                var samples:[HandSample]=[]
                for obs in self.request.results ?? [] {
                    guard let w=try? obs.recognizedPoint(.wrist),
                          let t=try? obs.recognizedPoint(.thumbTip),
                          let i=try? obs.recognizedPoint(.indexTip),
                          let m=try? obs.recognizedPoint(.middleMCP) else { continue }
                    let conf=[w.confidence,t.confidence,i.confidence,m.confidence].min() ?? 0
                    guard conf > 0.22 else { continue }
                    func cv(_ p:VNRecognizedPoint)->CGPoint { CGPoint(x:p.location.x,y:1-p.location.y) }
                    samples.append(.init(wrist:cv(w),thumb:cv(t),index:cv(i),middle:cv(m)))
                }
                samples.sort { $0.palm.x < $1.palm.x }
                DispatchQueue.main.async { self.latest=samples }
            } catch { }
        }
    }
}

private final class Weapon {
    enum Kind: CaseIterable { case sword, axe, hammer, bat, staff }
    let kind:Kind
    let node=SCNNode()
    let mass:CGFloat
    let power:Float
    var heldBy:Int?=nil
    var lastHit:TimeInterval=0

    init(_ kind:Kind) {
        self.kind=kind
        switch kind {
        case .sword: mass=1.15; power=1.25
        case .axe: mass=2.15; power=1.55
        case .hammer: mass=3.0; power=1.7
        case .bat: mass=1.3; power=1.0
        case .staff: mass=1.55; power=1.15
        }
        build()
        node.name="weapon_\(kind)"
        let shape=SCNPhysicsShape(node:node,options:[.type:SCNPhysicsShape.ShapeType.boundingBox])
        let body=SCNPhysicsBody(type:.dynamic,shape:shape)
        body.mass=mass; body.friction=0.75; body.restitution=0.08
        body.categoryBitMask=Mask.weapon; body.collisionBitMask=Mask.room|Mask.weapon|Mask.npc
        body.contactTestBitMask=Mask.npc
        body.continuousCollisionDetectionThreshold=0.0001
        node.physicsBody=body
    }

    private func mat(_ c:UIColor,metal:CGFloat=0,rough:CGFloat=0.5)->SCNMaterial {
        let m=SCNMaterial();m.diffuse.contents=c;m.metalness.contents=metal;m.roughness.contents=rough;return m
    }
    private func add(_ g:SCNGeometry,_ p:SCNVector3,_ c:UIColor,metal:CGFloat=0,rough:CGFloat=0.5) {
        g.materials=[mat(c,metal:metal,rough:rough)]
        let n=SCNNode(geometry:g);n.position=p;node.addChildNode(n)
    }
    private func cylinder(radius:CGFloat,height:CGFloat,pos:SCNVector3,color:UIColor) {
        let g=SCNCylinder(radius:radius,height:height);g.materials=[mat(color,rough:0.8)]
        let n=SCNNode(geometry:g);n.eulerAngles.x=.pi/2;n.position=pos;node.addChildNode(n)
    }
    private func build() {
        switch kind {
        case .sword:
            add(SCNBox(width:0.048,height:0.012,length:0.70,chamferRadius:0.006),.init(0,0,0.40),.init(white:0.9,alpha:1),metal:0.95,rough:0.18)
            add(SCNBox(width:0.25,height:0.035,length:0.045,chamferRadius:0.012),.init(0,0,0.03),.systemYellow,metal:0.7,rough:0.3)
            cylinder(radius:0.026,height:0.22,pos:.init(0,0,-0.11),color:.black)
        case .axe:
            cylinder(radius:0.026,height:0.68,pos:.init(0,0,0.12),color:.brown)
            add(SCNBox(width:0.34,height:0.08,length:0.18,chamferRadius:0.025),.init(0,0,0.48),.darkGray,metal:0.9,rough:0.24)
            add(SCNBox(width:0.12,height:0.04,length:0.23,chamferRadius:0.012),.init(0.20,0,0.48),.lightGray,metal:0.96,rough:0.15)
        case .hammer:
            cylinder(radius:0.029,height:0.62,pos:.init(0,0,0.10),color:.brown)
            add(SCNBox(width:0.38,height:0.16,length:0.16,chamferRadius:0.035),.init(0,0,0.45),.darkGray,metal:0.86,rough:0.28)
        case .bat:
            let g=SCNCapsule(capRadius:0.045,height:0.72);g.materials=[mat(.systemRed,rough:0.45)]
            let n=SCNNode(geometry:g);n.eulerAngles.x=.pi/2;n.position=.init(0,0,0.22);node.addChildNode(n)
        case .staff:
            cylinder(radius:0.026,height:1.05,pos:.init(0,0,0.30),color:.systemTeal)
            add(SCNSphere(radius:0.05),.init(0,0,0.84),.white,metal:0.6,rough:0.25)
        }
    }
}

private final class Fighter {
    enum State { case approach, circle, windup, strike, recover, stunned, dead }
    let root=SCNNode()
    let head=SCNNode()
    let torso=SCNNode()
    let arm=SCNNode()
    var state:State=.approach
    var stateTime:Float=0
    var hp:Float=100
    var strafe:Float=Bool.random() ? 1 : -1
    var dead=false
    var lastContact:TimeInterval=0
    var weapon:Weapon?

    init(index:Int) {
        root.name="fighter_\(index)"
        let red=UIColor(red:0.76,green:0.025,blue:0.045,alpha:1)
        let dark=UIColor(white:0.055,alpha:1)
        func m(_ c:UIColor)->SCNMaterial { let x=SCNMaterial();x.diffuse.contents=c;x.roughness.contents=0.35;return x }
        let pelvis=SCNNode(geometry:SCNCapsule(capRadius:0.13,height:0.34));pelvis.position=.init(0,0.72,0);pelvis.geometry?.materials=[m(dark)];root.addChildNode(pelvis)
        torso.geometry=SCNBox(width:0.43,height:0.48,length:0.23,chamferRadius:0.055);torso.position=.init(0,1.10,0);torso.geometry?.materials=[m(red)];root.addChildNode(torso)
        let plate=SCNNode(geometry:SCNBox(width:0.34,height:0.29,length:0.08,chamferRadius:0.025));plate.position=.init(0,0,0.15);plate.geometry?.materials=[m(dark)];torso.addChildNode(plate)
        head.geometry=SCNCapsule(capRadius:0.145,height:0.28);head.position=.init(0,1.53,0);head.geometry?.materials=[m(red)];root.addChildNode(head)
        let mask=SCNNode(geometry:SCNBox(width:0.20,height:0.12,length:0.045,chamferRadius:0.015));mask.position=.init(0,0,0.14);mask.geometry?.materials=[m(dark)];head.addChildNode(mask)
        for side:Float in [-1,1] {
            let upper=SCNNode(geometry:SCNCapsule(capRadius:0.067,height:0.34));upper.position=.init(0.29*side,1.22,0);upper.geometry?.materials=[m(dark)];root.addChildNode(upper)
            let lower=SCNNode(geometry:SCNCapsule(capRadius:0.056,height:0.30));lower.position=.init(0,-0.29,0.02);lower.geometry?.materials=[m(red)];upper.addChildNode(lower)
            if side > 0 { arm.addChildNode(upper);root.addChildNode(arm);upper.position=.init(0.29,1.22,0) }
            let thigh=SCNNode(geometry:SCNCapsule(capRadius:0.087,height:0.42));thigh.position=.init(0.12*side,0.43,0);thigh.geometry?.materials=[m(dark)];root.addChildNode(thigh)
            let shin=SCNNode(geometry:SCNCapsule(capRadius:0.071,height:0.37));shin.position=.init(0,-0.36,0.03);shin.geometry?.materials=[m(red)];thigh.addChildNode(shin)
        }
        let shape=SCNPhysicsShape(geometry:SCNCapsule(capRadius:0.23,height:1.55),options:nil)
        let b=SCNPhysicsBody(type:.kinematic,shape:shape);b.categoryBitMask=Mask.npc;b.collisionBitMask=Mask.room|Mask.weapon|Mask.npc;b.contactTestBitMask=Mask.weapon;root.physicsBody=b
    }
}

final class FitnessGameViewController:UIViewController,ARSCNViewDelegate,SCNPhysicsContactDelegate {
    private let ar=ARSCNView(frame:.zero)
    private let vision=HandVision()
    private var handNodes:[SCNNode]=[]
    private var handPrev:[SCNVector3?]=[nil,nil]
    private var handVelocity:[SCNVector3]=[.init(),.init()]
    private var pinchPrev=[false,false]
    private var held:[Weapon?]=[nil,nil]
    private var weapons:[Weapon]=[]
    private var fighters:[Fighter]=[]
    private var lastTime:TimeInterval=0
    private var cameraPrev:SCNVector3?
    private var cameraBaseY:Float?
    private var fightTime:Float=45
    private var restTime:Float=10
    private var fighting=true
    private var round=1
    private var score=0
    private var combo=0
    private var movement:Float=0
    private var attackFlash=UIView()
    private let status=UILabel()
    private let sub=UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        ar.frame=view.bounds;ar.autoresizingMask=[.flexibleWidth,.flexibleHeight];ar.delegate=self;ar.scene.physicsWorld.contactDelegate=self;ar.scene.physicsWorld.gravity=.init(0,-9.8,0);ar.automaticallyUpdatesLighting=true;view.addSubview(ar)
        attackFlash.frame=view.bounds;attackFlash.autoresizingMask=[.flexibleWidth,.flexibleHeight];attackFlash.backgroundColor=UIColor.systemRed.withAlphaComponent(0);attackFlash.isUserInteractionEnabled=false;view.addSubview(attackFlash)
        status.frame=CGRect(x:22,y:18,width:720,height:44);status.font=.monospacedSystemFont(ofSize:22,weight:.bold);status.textColor=.white;status.shadowColor=.black;view.addSubview(status)
        sub.frame=CGRect(x:22,y:60,width:900,height:34);sub.font=.monospacedSystemFont(ofSize:15,weight:.semibold);sub.textColor=.white;sub.shadowColor=.black;view.addSubview(sub)
        for _ in 0..<2 { let h=makeHand();handNodes.append(h);ar.scene.rootNode.addChildNode(h) }
    }

    override func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let c=ARWorldTrackingConfiguration();c.planeDetection=[.horizontal,.vertical];c.environmentTexturing=.automatic
        ar.session.run(c,options:[.resetTracking,.removeExistingAnchors])
        DispatchQueue.main.asyncAfter(deadline:.now()+1.0){[weak self] in self?.setupArena()}
    }
    override func viewWillDisappear(_ animated:Bool) { super.viewWillDisappear(animated);ar.session.pause() }

    private func makeHand()->SCNNode {
        let r=SCNNode();let mat=SCNMaterial();mat.diffuse.contents=UIColor(white:0.9,alpha:0.9);mat.metalness.contents=0.6;mat.roughness.contents=0.2
        let p=SCNNode(geometry:SCNBox(width:0.085,height:0.025,length:0.10,chamferRadius:0.025));p.geometry?.materials=[mat];r.addChildNode(p)
        for x:Float in [-0.03,0.03] { let n=SCNNode(geometry:SCNSphere(radius:0.017));n.geometry?.materials=[mat];n.position=.init(x,0,-0.07);r.addChildNode(n) }
        return r
    }

    private func setupArena() {
        guard let pov=ar.pointOfView else { return }
        let cam=pov.presentation.worldPosition;cameraBaseY=cam.y
        let f=pov.presentation.convertVector(.init(0,0,-1),to:nil).normalized;let r=SCNVector3(-f.z,0,f.x)
        for i in 0..<10 {
            let kind=Weapon.Kind.allCases[i % Weapon.Kind.allCases.count];let w=Weapon(kind)
            let side=Float(i%5)-2;let row=Float(i/5)
            w.node.position=cam+f*(0.9+row*0.42)+r*(side*0.34)+SCNVector3(0,-0.58,0)
            ar.scene.rootNode.addChildNode(w.node);weapons.append(w)
        }
        for i in 0..<3 { spawnFighter(i,delay:Double(i)*0.18) }
    }

    private func spawnFighter(_ index:Int,delay:Double=0) {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay){[weak self] in
            guard let self, self.fighting, let pov=self.ar.pointOfView else { return }
            let n=Fighter(index:index+Int.random(in:10...9999));let cam=pov.presentation.worldPosition
            var f=pov.presentation.convertVector(.init(0,0,-1),to:nil);f.y=0;f=f.normalized;let r=SCNVector3(-f.z,0,f.x)
            n.root.position=cam+f*Float.random(in:1.8...2.5)+r*Float.random(in:-1.25...1.25)+SCNVector3(0,-0.92,0)
            self.ar.scene.rootNode.addChildNode(n.root);self.fighters.append(n)
            let w=Weapon(Weapon.Kind.allCases.randomElement()!);w.node.physicsBody?.type=.kinematic;w.node.physicsBody?.isAffectedByGravity=false;self.ar.scene.rootNode.addChildNode(w.node);self.weapons.append(w);n.weapon=w
        }
    }

    private func handWorld(_ s:HandSample)->SCNVector3 {
        let pt=CGPoint(x:s.palm.x*view.bounds.width,y:s.palm.y*view.bounds.height)
        let a=ar.unprojectPoint(.init(Float(pt.x),Float(pt.y),0));let b=ar.unprojectPoint(.init(Float(pt.x),Float(pt.y),1));let d=(b-a).normalized
        let depth=clamp(Float(0.72-s.span*2.1),0.28,0.72)
        return a+d*depth
    }

    func renderer(_ renderer:SCNSceneRenderer,updateAtTime time:TimeInterval) {
        guard let frame=ar.session.currentFrame, let pov=ar.pointOfView else { return }
        vision.process(frame.capturedImage)
        let dt=lastTime == 0 ? 1.0/60.0 : min(time-lastTime,0.05);lastTime=time
        let cam=pov.presentation.worldPosition
        updateMovement(cam:cam,dt:Float(dt))
        updateHands(dt:Float(dt))
        if fighting { updateFight(dt:Float(dt),camera:cam) } else { updateRest(dt:Float(dt)) }
        DispatchQueue.main.async { [weak self] in self?.updateHUD() }
    }

    private func updateMovement(cam:SCNVector3,dt:Float) {
        if let p=cameraPrev { movement += (cam-p).length*8 }
        cameraPrev=cam
        for v in handVelocity { movement += min(v.length*dt*0.5,0.2) }
    }

    private func updateHands(dt:Float) {
        let samples=vision.latest
        for i in 0..<2 {
            guard i < samples.count else { handNodes[i].isHidden=true;continue }
            handNodes[i].isHidden=false
            let s=samples[i];let p=handWorld(s)
            if let old=handPrev[i] { handVelocity[i]=(p-old)*(1/max(dt,0.001)) } else { handVelocity[i]=.init() }
            handPrev[i]=p;handNodes[i].position=p
            let pinch=s.pinch
            if pinch && !pinchPrev[i] { tryGrab(hand:i,at:p) }
            if !pinch && pinchPrev[i] { release(hand:i) }
            pinchPrev[i]=pinch
            if let w=held[i] {
                w.node.position=p
                let v=handVelocity[i]
                if v.length > 0.08 { w.node.look(at:p+v.normalized,up:ar.scene.rootNode.worldUp,localFront:.init(0,0,1)) }
            } else { punch(hand:i,at:p,velocity:handVelocity[i]) }
        }
    }

    private func tryGrab(hand:Int,at p:SCNVector3) {
        var best:Weapon?;var bd:Float=0.24
        for w in weapons where w.heldBy == nil {
            let d=dist(w.node.presentation.worldPosition,p)
            if d<bd { bd=d;best=w }
        }
        guard let w=best else { return }
        w.heldBy=hand;held[hand]=w;w.node.physicsBody?.type=.kinematic;w.node.physicsBody?.isAffectedByGravity=false;combo += 1
    }

    private func release(hand:Int) {
        guard let w=held[hand] else { return }
        w.heldBy=nil;held[hand]=nil;w.node.physicsBody?.type=.dynamic;w.node.physicsBody?.isAffectedByGravity=true;w.node.physicsBody?.velocity=handVelocity[hand];w.node.physicsBody?.angularVelocity=SCNVector4(handVelocity[hand].z,handVelocity[hand].x,0,handVelocity[hand].length*2.2)
    }

    private func punch(hand:Int,at p:SCNVector3,velocity:SCNVector3) {
        let speed=velocity.length;guard speed>0.62 else { return }
        for f in fighters where !f.dead {
            let hp=f.head.presentation.worldPosition;let tp=f.torso.presentation.worldPosition
            if min(dist(p,hp),dist(p,tp)) < 0.25 {
                hit(f,point:p,velocity:velocity,power:0.85);score += Int(speed*18);movement += speed*0.04;return
            }
        }
    }

    private func hit(_ f:Fighter,point:SCNVector3,velocity:SCNVector3,power:Float) {
        let now=CFAbsoluteTimeGetCurrent();guard now-f.lastContact>0.11 else { return };f.lastContact=now
        let impact=velocity.length*power;guard impact>0.5 else { return }
        f.hp -= clamp(impact*13,7,60);f.state=.stunned;f.stateTime=0.45
        f.root.physicsBody?.type=.dynamic;f.root.physicsBody?.mass=72;f.root.physicsBody?.isAffectedByGravity=true;f.root.physicsBody?.applyForce(velocity.normalized*CGFloat(clamp(impact*1.8,1.0,8.0)),asImpulse:true)
        score += Int(impact*30);combo += 1
        if f.hp<=0 || impact>7.2 { kill(f) }
    }

    private func kill(_ f:Fighter) {
        guard !f.dead else { return };f.dead=true;f.state=.dead;score += 300+combo*8
        if let w=f.weapon { w.node.physicsBody?.type=.dynamic;w.node.physicsBody?.isAffectedByGravity=true;f.weapon=nil }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.0){[weak self,weak f] in f?.root.removeFromParentNode();if let self,self.fighting { self.spawnFighter(Int.random(in:0...999)) } }
    }

    private func updateFight(dt:Float,camera:SCNVector3) {
        fightTime -= dt
        if fightTime<=0 { fighting=false;restTime=10;for f in fighters where !f.dead { f.root.isPaused=true };return }
        let alive=fighters.filter{!$0.dead && $0.root.parent != nil}.count
        let desired=min(2+round,6)
        if alive<desired { spawnFighter(Int.random(in:0...999),delay:0.05) }
        for f in fighters where !f.dead { updateAI(f,dt:dt,camera:camera) }
    }

    private func updateRest(dt:Float) {
        restTime -= dt
        if restTime<=0 {
            round += 1;fightTime=max(26,45-Float(round-1)*2);fighting=true
            for f in fighters where !f.dead { f.root.isPaused=false }
        }
    }

    private func updateAI(_ f:Fighter,dt:Float,camera:SCNVector3) {
        if f.state == .stunned {
            f.stateTime -= dt
            if f.stateTime<=0 && !f.dead { f.root.physicsBody?.type=.kinematic;f.root.physicsBody?.isAffectedByGravity=false;f.state=.approach;f.stateTime=0 }
            return
        }
        f.stateTime += dt
        var to=camera-f.root.presentation.worldPosition;to.y=0;let d=to.length;let dir=to.normalized;let side=SCNVector3(-dir.z,0,dir.x)*f.strafe
        switch f.state {
        case .approach:
            let speed=0.80+Float(round)*0.055
            if d>1.15 { f.root.position=f.root.position+dir*speed*dt+side*0.10*dt } else { f.state=.circle;f.stateTime=0 }
        case .circle:
            f.root.position=f.root.position+side*(0.38+Float(round)*0.02)*dt
            if f.stateTime>Float.random(in:0.45...0.95) { f.state=.windup;f.stateTime=0 }
        case .windup:
            f.arm.eulerAngles.x = -0.7*min(f.stateTime/0.36,1)
            if f.stateTime>0.36 { f.state=.strike;f.stateTime=0 }
        case .strike:
            f.arm.eulerAngles.x = -0.7+2.2*min(f.stateTime/0.24,1)
            if f.stateTime>0.12 && f.stateTime<0.19 { enemyAttack(f,camera:camera) }
            if f.stateTime>0.25 { f.state=.recover;f.stateTime=0 }
        case .recover:
            f.arm.eulerAngles.x *= 0.84
            if f.stateTime>max(0.30,0.62-Float(round)*0.035) { f.state=.approach;f.stateTime=0 }
        case .stunned,.dead: break
        }
        let angle=atan2(dir.x,dir.z);f.root.eulerAngles.y=angle
        if let w=f.weapon {
            let hand=f.root.presentation.convertPosition(.init(0.40,0.88,0.08),to:nil);w.node.position=hand;w.node.eulerAngles=.init(f.arm.eulerAngles.x,f.root.eulerAngles.y,0)
        }
    }

    private func enemyAttack(_ f:Fighter,camera:SCNVector3) {
        let d=dist(f.root.presentation.worldPosition,camera);guard d<1.42 else { return }
        let lateral=abs((cameraPrev ?? camera).x-camera.x)
        let crouched=(cameraBaseY ?? camera.y)-camera.y > 0.20
        if lateral<0.09 && !crouched {
            combo=0
            DispatchQueue.main.async { [weak self] in guard let self else{return};self.attackFlash.backgroundColor=UIColor.systemRed.withAlphaComponent(0.34);UIView.animate(withDuration:0.28){self.attackFlash.backgroundColor=UIColor.systemRed.withAlphaComponent(0)} }
        } else { score += 80;combo += 1;movement += 0.35 }
    }

    func physicsWorld(_ world:SCNPhysicsWorld,didBegin contact:SCNPhysicsContact) {
        let nodes=[contact.nodeA,contact.nodeB]
        guard let weaponNode=nodes.first(where:{$0.physicsBody?.categoryBitMask == Mask.weapon}),
              let npcNode=nodes.first(where:{$0.physicsBody?.categoryBitMask == Mask.npc}),
              let w=weapons.first(where:{$0.node===weaponNode}),
              let f=fighters.first(where:{$0.root===npcNode}),!f.dead else { return }
        let now=CFAbsoluteTimeGetCurrent();guard now-w.lastHit>0.10 else{return};w.lastHit=now
        let v=weaponNode.physicsBody?.velocity ?? .init();let mult=Float(w.mass)*w.power
        if v.length>0.42 { hit(f,point:contact.contactPoint,velocity:v,power:mult) }
    }

    func renderer(_ renderer:SCNSceneRenderer,didAdd node:SCNNode,for anchor:ARAnchor) {
        guard let p=anchor as? ARPlaneAnchor else{return}
        let plane=SCNPlane(width:CGFloat(p.planeExtent.width),height:CGFloat(p.planeExtent.height));plane.firstMaterial?.diffuse.contents=UIColor.clear
        let n=SCNNode(geometry:plane)
        if p.alignment == .horizontal { n.eulerAngles.x=-.pi/2 }
        let b=SCNPhysicsBody(type:.static,shape:SCNPhysicsShape(geometry:plane,options:nil));b.categoryBitMask=Mask.room;b.collisionBitMask=Mask.weapon|Mask.npc;n.physicsBody=b;node.addChildNode(n)
    }

    private func updateHUD() {
        status.text = fighting ? "ROUND \(round)   \(Int(ceil(fightTime)))s   SCORE \(score)" : "RECUPERA \(Int(ceil(restTime)))s"
        sub.text = "COMBO x\(combo)   ATIVIDADE \(Int(movement*10))   PINCH=PEGAR  •  SOCA  •  DESVIA  •  ABAIXA"
    }
}
