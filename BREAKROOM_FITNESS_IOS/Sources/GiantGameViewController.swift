import UIKit
import ARKit
import SceneKit
import Vision
import AudioToolbox

final class GiantGameViewController:UIViewController,ARSCNViewDelegate,SCNPhysicsContactDelegate {
    enum Mode:String { case cardio="CARDIO",power="POWER",survival="SURVIVAL" }
    private let ar=ARSCNView(frame:.zero), vision=GHandVision(), overlay=GTrackingOverlay()
    private let leftRig=GHandRig(tint:.systemCyan),rightRig=GHandRig(tint:.systemPink)
    private var worldPoints:[[SCNVector3]]=[[],[]],prevPalm:[SCNVector3?]=[nil,nil],vel:[SCNVector3]=[.init(),.init()],pinchPrev=[false,false]
    private var held:[GWeapon?]=[nil,nil],grabbed:[GEnemy?]=[nil,nil]
    private var weapons:[GWeapon]=[],enemies:[GEnemy]=[]
    private var arenaReady=false,floorY:Float=0,lastTime:TimeInterval=0,cameraPrev:SCNVector3?,cameraBaseY:Float?
    private var round=1,fightTime:Float=50,restTime:Float=12,fighting=true,score=0,combo=0,activity:Float=0
    private var punches=0,dodges=0,throws=0,kills=0,parries=0
    private var mode:Mode=.cardio
    private let tracking=UILabel(),status=UILabel(),sub=UILabel(),modeLabel=UILabel(),flash=UIView()
    private let haptic=UIImpactFeedbackGenerator(style:.medium)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        ar.frame=view.bounds;ar.autoresizingMask=[.flexibleWidth,.flexibleHeight];ar.delegate=self;ar.scene.physicsWorld.contactDelegate=self
        ar.scene.physicsWorld.gravity=.init(0,-9.8,0);ar.automaticallyUpdatesLighting=true;ar.preferredFramesPerSecond=60;view.addSubview(ar)
        ar.scene.rootNode.addChildNode(leftRig.root);ar.scene.rootNode.addChildNode(rightRig.root)
        overlay.frame=view.bounds;overlay.autoresizingMask=[.flexibleWidth,.flexibleHeight];view.addSubview(overlay)
        setupHUD();setupModeButtons();setupLighting();haptic.prepare()
    }
    
    private func setupHUD() {
        tracking.frame=.init(x:18,y:12,width:620,height:30);tracking.font=.monospacedSystemFont(ofSize:14,weight:.bold);tracking.textColor=.systemYellow;tracking.shadowColor=.black;view.addSubview(tracking)
        status.frame=.init(x:18,y:44,width:880,height:40);status.font=.monospacedSystemFont(ofSize:22,weight:.heavy);status.textColor=.white;status.shadowColor=.black;view.addSubview(status)
        sub.frame=.init(x:18,y:84,width:1100,height:30);sub.font=.monospacedSystemFont(ofSize:13,weight:.semibold);sub.textColor=.white;sub.shadowColor=.black;view.addSubview(sub)
        modeLabel.frame=.init(x:18,y:116,width:540,height:28);modeLabel.font=.monospacedSystemFont(ofSize:12,weight:.bold);modeLabel.textColor=.systemCyan;view.addSubview(modeLabel)
        flash.frame=view.bounds;flash.autoresizingMask=[.flexibleWidth,.flexibleHeight];flash.backgroundColor=.clear;flash.isUserInteractionEnabled=false;view.addSubview(flash)
    }
    private func setupModeButtons() {
        let items:[(String,Mode)]=[("CARDIO",.cardio),("POWER",.power),("SURVIVAL",.survival)]
        for (i,item) in items.enumerated() {
            let b=UIButton(type:.system);b.frame=.init(x:view.bounds.width-330+CGFloat(i*105),y:14,width:96,height:32);b.autoresizingMask=[.flexibleLeftMargin]
            b.setTitle(item.0,for:.normal);b.titleLabel?.font=.monospacedSystemFont(ofSize:11,weight:.bold);b.backgroundColor=UIColor.black.withAlphaComponent(.45);b.layer.cornerRadius=8
            b.addAction(UIAction{[weak self]_ in self?.mode=item.1;self?.resetSession()},for:.touchUpInside);view.addSubview(b)
        }
    }
    private func setupLighting() {
        let light=SCNLight();light.type=.omni;light.intensity=650;light.temperature=6000
        let n=SCNNode();n.light=light;n.position=.init(0,2,0);ar.scene.rootNode.addChildNode(n)
        let amb=SCNLight();amb.type=.ambient;amb.intensity=220;amb.color=UIColor(white:.55,alpha:1)
        let a=SCNNode();a.light=amb;ar.scene.rootNode.addChildNode(a)
    }
    
    override func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else{return}
        let c=ARWorldTrackingConfiguration();c.planeDetection=[.horizontal,.vertical];c.environmentTexturing=.automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth){c.frameSemantics.insert(.sceneDepth)}
        ar.session.run(c,options:[.resetTracking,.removeExistingAnchors])
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2){[weak self] in self?.setupArena()}
    }
    override func viewWillDisappear(_ animated:Bool){super.viewWillDisappear(animated);ar.session.pause()}
    
    private func resetSession() {
        round=1;fightTime=mode == .power ? 40:50;restTime=12;fighting=true;score=0;combo=0;activity=0;punches=0;dodges=0;throws=0;kills=0;parries=0
        for e in enemies {e.root.removeFromParentNode();e.weapon?.node.removeFromParentNode()};enemies.removeAll()
        for i in 0..<initialEnemyCount(){spawnEnemy(index:i,delay:Double(i)*.45)}
        GAudio.shared.play("round_start",on:ar.scene.rootNode)
    }
    private func initialEnemyCount()->Int { mode == .survival ? 3:2 }
    private func targetEnemyCount()->Int {
        switch mode {
        case .cardio:return min(2+(round-1)/3,4)
        case .power:return min(1+(round-1)/4,3)
        case .survival:return min(3+(round-1)/2,6)
        }
    }
    
    private func setupArena() {
        guard !arenaReady,let pov=ar.pointOfView else{return};arenaReady=true
        let cam=pov.presentation.worldPosition;cameraBaseY=cam.y;floorY=cam.y-1.30
        var f=pov.presentation.convertVector(.init(0,0,-1),to:nil);f.y=0;f=gNorm(f);let r=SCNVector3(-f.z,0,f.x)
        for (i,k) in GWeapon.Kind.allCases.enumerated() {
            let row=i/4,col=i%4
            var p=gAdd(cam,gAdd(gMul(f,1.05+Float(row)*.52),gMul(r,(Float(col)-1.5)*.48)));p.y=floorY+.80
            createRackWeapon(k,p,f)
        }
        for i in 0..<initialEnemyCount(){spawnEnemy(index:i,delay:Double(i)*.5)}
        GAudio.shared.play("round_start",on:ar.scene.rootNode)
    }
    private func createRackWeapon(_ kind:GWeapon.Kind,_ p:SCNVector3,_ face:SCNVector3) {
        let pedestal=SCNNode();pedestal.position=p
        let bg=SCNCylinder(radius:.18,height:.08);bg.materials=[GAssets.material(UIColor(white:.04,alpha:.92),metal:.8,rough:.22)]
        let b=SCNNode(geometry:bg);b.position.y=-.38;pedestal.addChildNode(b)
        let rg=SCNTorus(ringRadius:.16,pipeRadius:.012);rg.materials=[GAssets.material(.systemCyan,metal:.1,rough:.2,emission:.systemCyan)]
        let ring=SCNNode(geometry:rg);ring.position.y=-.33;pedestal.addChildNode(ring)
        let tx=SCNText(string:kind.rawValue.uppercased(),extrusionDepth:.005);tx.font=.boldSystemFont(ofSize:.08);tx.firstMaterial?.diffuse.contents=UIColor.white
        let label=SCNNode(geometry:tx);label.scale=.init(.55,.55,.55);label.position=.init(-.17,-.20,.04);pedestal.addChildNode(label)
        ar.scene.rootNode.addChildNode(pedestal)
        let w=GWeapon(kind);w.node.position=p;w.node.eulerAngles=.init(-.12,atan2(face.x,face.z),0);w.pedestal=pedestal
        ar.scene.rootNode.addChildNode(w.node);weapons.append(w)
    }
    
    private func spawnEnemy(index:Int,delay:Double=0) {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay){[weak self] in
            guard let self,self.fighting,let pov=self.ar.pointOfView else{return}
            let arch=self.pickArchetype(),e=GEnemy(index:index+Int.random(in:100...9999),archetype:arch)
            let cam=pov.presentation.worldPosition;var f=pov.presentation.convertVector(.init(0,0,-1),to:nil);f.y=0;f=gNorm(f);let r=SCNVector3(-f.z,0,f.x)
            var p=gAdd(cam,gAdd(gMul(f,Float.random(in:2.4...3.2)),gMul(r,Float.random(in:-1.15...1.15))));p.y=self.floorY;e.root.position=p
            self.ar.scene.rootNode.addChildNode(e.root);self.enemies.append(e)
            let kind=self.enemyWeapon(for:arch);let w=GWeapon(kind);w.onRack=false;w.enemyOwner=e;w.node.physicsBody?.type=.kinematic;w.node.physicsBody?.isAffectedByGravity=false
            self.ar.scene.rootNode.addChildNode(w.node);self.weapons.append(w);e.weapon=w
            GAudio.shared.play("enemy_spawn",on:e.root,volume:.55)
        }
    }
    private func pickArchetype()->GEnemy.Archetype {
        switch mode {
        case .cardio:return [.duelist,.striker,.sentinel].randomElement() ?? .duelist
        case .power:return [.brute,.sentinel,.brute,.duelist].randomElement() ?? .brute
        case .survival:return GEnemy.Archetype.allCases.randomElement() ?? .duelist
        }
    }
    private func enemyWeapon(for a:GEnemy.Archetype)->GWeapon.Kind {
        switch a {case .duelist:return [.longsword,.katana,.spear].randomElement()!;case .brute:return [.warhammer,.axe,.mace].randomElement()!;case .sentinel:return [.shield,.spear,.staff].randomElement()!;case .striker:return [.katana,.staff,.longsword].randomElement()!}
    }
    
    private func handWorld(_ pose:GHandPose)->[SCNVector3] {
        let base=gClamp(Float(.78-pose.span*2.15),.28,.74)
        return pose.points.map { p in
            let x=p.x*view.bounds.width,y=p.y*view.bounds.height
            let a=ar.unprojectPoint(.init(Float(x),Float(y),0)),b=ar.unprojectPoint(.init(Float(x),Float(y),1))
            return gAdd(a,gMul(gNorm(gSub(b,a)),base))
        }
    }
    
    func renderer(_ renderer:SCNSceneRenderer,updateAtTime time:TimeInterval) {
        guard let frame=ar.session.currentFrame,let pov=ar.pointOfView else{return}
        vision.process(frame.capturedImage)
        let dt=Float(lastTime==0 ? 1.0/60.0:min(time-lastTime,.05));lastTime=time
        let cam=pov.presentation.worldPosition
        updateHands(dt);updateActivity(cam,dt)
        if fighting{updateCombat(dt,cam)}else{updateRest(dt)}
        cameraPrev=cam
        DispatchQueue.main.async{[weak self] in self?.overlay.poses=self?.vision.latest ?? [];self?.updateHUD()}
    }
    
    private func updateHands(_ dt:Float) {
        let poses=vision.latest,rigs=[leftRig,rightRig]
        for i in 0..<2 {
            guard i<poses.count else{rigs[i].hide();worldPoints[i]=[];prevPalm[i]=nil;continue}
            let pose=poses[i],pts=handWorld(pose);worldPoints[i]=pts;rigs[i].update(pts);guard pts.count==21 else{continue}
            let palm=gMul(gAdd(gAdd(pts[0],pts[9]),gAdd(pts[5],pts[17])),.25),old=prevPalm[i]
            if let old{vel[i]=gMul(gSub(palm,old),1/max(dt,.001))}else{vel[i]=.init()};prevPalm[i]=palm
            if pose.pinch {
                if held[i]==nil && grabbed[i]==nil { tryGrab(i,palm) }
            } else if pinchPrev[i] { release(i) }
            pinchPrev[i]=pose.pinch
            if let w=held[i] {
                w.node.position=palm;let forward=gNorm(gSub(pts[8],pts[0])),up=gNorm(gSub(pts[5],pts[17]))
                w.node.look(at:gAdd(palm,forward),up:up,localFront:.init(0,0,1))
            } else if let e=grabbed[i] {
                e.root.position=gAdd(palm,.init(0,-1.0,0));e.root.eulerAngles.y += dt*2.3
            } else if let old { checkPunch(i,old,palm,vel[i]) }
        }
    }
    
    private func tryGrab(_ hand:Int,_ palm:SCNVector3) {
        var best:GWeapon?,bd:Float=.34
        for w in weapons where w.heldBy==nil && w.enemyOwner==nil {
            let d=gDistance(w.node.presentation.worldPosition,palm);if d<bd{bd=d;best=w}
        }
        if let w=best {
            w.heldBy=hand;w.onRack=false;w.pedestal?.isHidden=true;w.node.physicsBody?.type=.kinematic;w.node.physicsBody?.isAffectedByGravity=false;held[hand]=w
            GAudio.shared.play("grab",on:w.node);haptic.impactOccurred(intensity:.5);return
        }
        var enemy:GEnemy?,ed:Float=.25
        for e in enemies where !e.dead && e.state == .stunned {
            let d=min(gDistance(e.head.presentation.worldPosition,palm),gDistance(e.torso.presentation.worldPosition,palm));if d<ed{ed=d;enemy=e}
        }
        if let e=enemy {grabbed[hand]=e;e.root.physicsBody?.type=.kinematic;e.root.physicsBody?.isAffectedByGravity=false;combo+=1}
    }
    private func release(_ hand:Int) {
        if let w=held[hand] {
            w.heldBy=nil;w.node.physicsBody?.type=.dynamic;w.node.physicsBody?.isAffectedByGravity=true;w.node.physicsBody?.velocity=vel[hand]
            w.node.physicsBody?.angularVelocity=.init(vel[hand].z,vel[hand].x,vel[hand].y,min(gLen(vel[hand])*2.2,9));held[hand]=nil;throws+=1;GAudio.shared.play("whoosh",on:w.node,volume:.7)
        }
        if let e=grabbed[hand] {
            grabbed[hand]=nil;e.root.physicsBody?.type=.dynamic;e.root.physicsBody?.isAffectedByGravity=true;e.root.physicsBody?.velocity=vel[hand];e.state = .stunned;e.stateTime=.7
        }
    }
    
    private func checkPunch(_ hand:Int,_ a:SCNVector3,_ b:SCNVector3,_ velocity:SCNVector3) {
        let speed=gLen(velocity);guard speed>.34 else{return}
        for e in enemies where !e.dead {
            let h=e.head.presentation.worldPosition,t=e.torso.presentation.worldPosition,p=e.pelvis.presentation.worldPosition
            let d=min(gSegDistance(h,a,b),gSegDistance(t,a,b),gSegDistance(p,a,b))
            if d<.23 {
                if speed<.62 { e.root.position=gAdd(e.root.position,gMul(gNorm(velocity),.05));return }
                punches+=1;hit(e,velocity,power:1.0,point:b);score+=Int(speed*24);return
            }
        }
    }
    private func hit(_ e:GEnemy,_ velocity:SCNVector3,power:Float,point:SCNVector3) {
        let now=CFAbsoluteTimeGetCurrent();guard now-e.lastImpact>.10 else{return};e.lastImpact=now
        let impact=gLen(velocity)*power;guard impact>.25 else{return};e.hp-=gClamp(impact*16,5,72);e.state=.stunned;e.stateTime=.55
        e.root.physicsBody?.type=.dynamic;e.root.physicsBody?.mass=68;e.root.physicsBody?.isAffectedByGravity=true
        let impulse=gMul(gNorm(velocity),gClamp(impact*1.65,.7,8.5));e.root.physicsBody?.applyForce(impulse,asImpulse:true)
        GEffects.spark(at:point,in:ar.scene);GAudio.shared.play("body_hit",on:e.root);haptic.impactOccurred(intensity:min(CGFloat(impact/5),1));score+=Int(impact*32);combo+=1
        if impact>3.4 && e.weapon != nil && Bool.random(){disarm(e,impulse)}
        if e.hp<=0 || impact>7.0 { kill(e,impulse) }
    }
    private func disarm(_ e:GEnemy,_ force:SCNVector3) {
        guard let w=e.weapon else{return};e.weapon=nil;w.enemyOwner=nil;w.node.physicsBody?.type=.dynamic;w.node.physicsBody?.isAffectedByGravity=true;w.node.physicsBody?.velocity=gAdd(force,.init(0,.7,0));e.state=.disarmed;e.stateTime=0
        GAudio.shared.play("metal_hit",on:w.node);score+=120
    }
    private func kill(_ e:GEnemy,_ impulse:SCNVector3) {
        guard !e.dead else{return};e.dead=true;e.state=.dead;kills+=1;score+=350+combo*10
        if e.weapon != nil{disarm(e,gMul(impulse,.6))}
        e.ragdoll(in:ar.scene,impulse:impulse);GAudio.shared.play("enemy_down",on:e.root);GEffects.ring(at:e.torso.presentation.worldPosition,in:ar.scene,color:.systemRed)
        DispatchQueue.main.asyncAfter(deadline:.now()+.15){e.root.removeFromParentNode()}
        DispatchQueue.main.asyncAfter(deadline:.now()+1.15){[weak self] in guard let self,self.fighting else{return};self.spawnEnemy(index:Int.random(in:0...999))}
    }
    
    private func updateCombat(_ dt:Float,_ cam:SCNVector3) {
        fightTime-=dt;if fightTime<=0{fighting=false;restTime=mode == .survival ? 7:12;GAudio.shared.play("round_end",on:ar.scene.rootNode);return}
        let active=enemies.filter{!$0.dead && $0.root.parent != nil}.count
        if active<targetEnemyCount(){spawnEnemy(index:Int.random(in:0...999),delay:.35)}
        for e in enemies where !e.dead { updateEnemy(e,dt,cam) }
    }
    private func updateRest(_ dt:Float) {
        restTime-=dt;if restTime<=0{round+=1;fightTime=mode == .power ? 42:50;fighting=true;GAudio.shared.play("round_start",on:ar.scene.rootNode)}
    }
    
    private func updateEnemy(_ e:GEnemy,_ dt:Float,_ cam:SCNVector3) {
        if e.state == .stunned {
            e.stateTime-=dt
            if e.stateTime<=0 && !e.dead {e.root.physicsBody?.type=.kinematic;e.root.physicsBody?.isAffectedByGravity=false;var p=e.root.presentation.worldPosition;p.y=floorY;e.root.position=p;e.state=e.weapon==nil ? .disarmed:.recover;e.stateTime=0}
            return
        }
        e.stateTime+=dt;var to=gSub(cam,e.root.presentation.worldPosition);to.y=0;let d=gLen(to),dir=gNorm(to),side=gMul(SCNVector3(-dir.z,0,dir.x),e.strafe)
        if incomingThreat(to:e.root.presentation.worldPosition) && e.state != .strike && e.state != .telegraph {e.state=.evade;e.stateTime=0}
        switch e.state {
        case .approach:
            if d>e.attackRange {e.root.position=gAdd(e.root.position,gAdd(gMul(dir,e.speed*dt),gMul(side,.08*dt)))} else {e.state=.strafe;e.stateTime=0}
        case .strafe:
            e.root.position=gAdd(e.root.position,gMul(side,(e.archetype == .striker ? .34:.25)*dt))
            if e.stateTime>.65 {e.state=Bool.random() ? .feint:.telegraph;e.stateTime=0}
        case .feint:
            e.rightArm.eulerAngles.x = -.5*min(e.stateTime/.25,1)
            if e.stateTime>.28 {e.strafe *= -1;e.state=.strafe;e.stateTime=0}
        case .telegraph:
            e.rightArm.eulerAngles.x = -1.0*min(e.stateTime/.55,1);e.leftArm.eulerAngles.z=.20*sin(e.stateTime*8)
            if e.stateTime>.55 {e.state=.strike;e.stateTime=0;e.attackConnected=false;GAudio.shared.play("swing",on:e.root,volume:.65)}
        case .strike:
            e.rightArm.eulerAngles.x = -1.0+2.25*min(e.stateTime/.30,1)
            if e.stateTime>.13 && e.stateTime<.22 && !e.attackConnected { e.attackConnected=true;enemyAttack(e,cam) }
            if e.stateTime>.32 {e.state=.recover;e.stateTime=0}
        case .recover:
            e.rightArm.eulerAngles.x *= .84;if e.stateTime>e.recovery {e.state=.approach;e.stateTime=0}
        case .evade:
            e.root.position=gAdd(e.root.position,gMul(side,.72*dt));if e.stateTime>.42{e.state=.approach;e.stateTime=0}
        case .disarmed:
            if let w=nearestLooseWeapon(e.root.presentation.worldPosition,.95) {
                w.enemyOwner=e;w.node.physicsBody?.type=.kinematic;w.node.physicsBody?.isAffectedByGravity=false;e.weapon=w;e.state=.recover;e.stateTime=0
            } else {e.root.position=gAdd(e.root.position,gMul(dir,.22*dt));if e.stateTime>1.4{e.state=.telegraph;e.stateTime=0}}
        case .stunned,.dead:break
        }
        e.root.eulerAngles.y=atan2(dir.x,dir.z)
        if let w=e.weapon {w.node.position=e.handPosition();w.node.eulerAngles=.init(e.rightArm.eulerAngles.x,e.root.eulerAngles.y,0)}
    }
    private func incomingThreat(to p:SCNVector3)->Bool {
        for i in 0..<2 {
            guard let w=held[i],gLen(vel[i])>.85 else{continue}
            if gDistance(w.node.presentation.worldPosition,p)<.75{return true}
        }
        return false
    }
    private func nearestLooseWeapon(_ p:SCNVector3,_ maxD:Float)->GWeapon? {
        var best:GWeapon?,d=maxD
        for w in weapons where w.heldBy==nil && w.enemyOwner==nil && !w.onRack {
            let x=gDistance(w.node.presentation.worldPosition,p);if x<d{d=x;best=w}
        }
        return best
    }
    
    private func enemyAttack(_ e:GEnemy,_ cam:SCNVector3) {
        guard gDistance(e.root.presentation.worldPosition,cam)<1.52 else{return}
        if checkParry(e){return}
        let crouched=(cameraBaseY ?? cam.y)-cam.y>.19,lateral=abs((cameraPrev ?? cam).x-cam.x)
        if crouched || lateral>.060 {dodges+=1;combo+=1;score+=90;GAudio.shared.play("dodge",on:ar.scene.rootNode,volume:.65);return}
        combo=0;DispatchQueue.main.async{[weak self] in guard let self else{return};self.flash.backgroundColor=UIColor.systemRed.withAlphaComponent(.32);UIView.animate(withDuration:.30){self.flash.backgroundColor=.clear}}
    }
    private func checkParry(_ e:GEnemy)->Bool {
        guard let ew=e.weapon else{return false}
        let ep=ew.node.presentation.worldPosition
        for w in held.compactMap({$0}) {
            if gDistance(w.node.presentation.worldPosition,ep)<.24 {
                parries+=1;combo+=1;score+=180;e.state=.stunned;e.stateTime=.75
                GAudio.shared.play("parry",on:ew.node);GEffects.spark(at:ep,in:ar.scene,color:.systemCyan);haptic.impactOccurred(intensity:1)
                if Bool.random(){disarm(e,.init(Float.random(in:-1...1),.8,Float.random(in:-1...1)))}
                return true
            }
        }
        return false
    }
    
    private func updateActivity(_ cam:SCNVector3,_ dt:Float) {
        if let c=cameraPrev{activity+=gLen(gSub(cam,c))*7}
        for v in vel{activity+=min(gLen(v)*dt*.45,.16)}
    }
    private func updateHUD() {
        let count=vision.latest.count,pinches=vision.latest.filter{$0.pinch}.count
        tracking.text=count==0 ? "HAND TRACKING: PROCURANDO..." : "HAND TRACKING \(count)/2  •  PINCH \(pinches)"
        tracking.textColor=count==2 ? .systemGreen:(count==1 ? .systemYellow:.systemRed)
        status.text=fighting ? "ROUND \(round)   \(Int(ceil(fightTime)))s   SCORE \(score)   x\(combo)" : "RECUPERA \(Int(ceil(restTime)))s"
        sub.text="SOCO \(punches)  •  ESQUIVA \(dodges)  •  PARRY \(parries)  •  ARREMESSO \(throws)  •  KOs \(kills)  •  ATIVIDADE \(Int(activity*10))"
        modeLabel.text="MODO \(mode.rawValue)  •  PINCH=PEGAR  •  SOLTA=JOGAR  •  ABAIXA/DESVIA"
    }
    
    func physicsWorld(_ world:SCNPhysicsWorld,didBegin contact:SCNPhysicsContact) {
        let nodes=[contact.nodeA,contact.nodeB]
        guard let wn=nodes.first(where:{$0.physicsBody?.categoryBitMask==GMask.weapon}),
              let w=weapons.first(where:{$0.node===wn}) else{return}
        if let en=nodes.first(where:{$0.physicsBody?.categoryBitMask==GMask.enemy}),let e=enemies.first(where:{$0.root===en}),!e.dead {
            let now=CFAbsoluteTimeGetCurrent();guard now-w.lastHit>.10 else{return};w.lastHit=now
            let v=wn.physicsBody?.velocity ?? .init();if gLen(v)>.38 {hit(e,v,power:Float(w.mass)*w.power,point:contact.contactPoint)}
        }
    }
    
    func renderer(_ renderer:SCNSceneRenderer,didAdd node:SCNNode,for anchor:ARAnchor) {
        guard let p=anchor as? ARPlaneAnchor else{return}
        let plane=SCNPlane(width:CGFloat(p.planeExtent.width),height:CGFloat(p.planeExtent.height));plane.firstMaterial?.diffuse.contents=UIColor.clear
        let n=SCNNode(geometry:plane);if p.alignment == .horizontal{n.eulerAngles.x = -.pi/2}
        let b=SCNPhysicsBody(type:.static,shape:SCNPhysicsShape(geometry:plane,options:nil));b.categoryBitMask=GMask.room;b.collisionBitMask=GMask.weapon|GMask.enemy|GMask.ragdoll;n.physicsBody=b;node.addChildNode(n)
    }
}
