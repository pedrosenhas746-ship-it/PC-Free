import UIKit
import ARKit
import SceneKit
import Vision
import ImageIO
import simd

final class AssetsGameViewController: UIViewController, ARSessionDelegate, SCNPhysicsContactDelegate {
    private let sceneView = ARSCNView(frame: .zero)
    private let hud = UILabel()
    private let fireButton = UIButton(type: .system)
    private let ragdollButton = UIButton(type: .system)
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let visionQueue = DispatchQueue(label: "chaosvr.v3.hands", qos: .userInitiated)
    private var visionBusy = false
    private var lastVision: TimeInterval = 0
    private var leftHand: PhysicsHand!
    private var rightHand: PhysicsHand!
    private var grabbables: [SCNNode] = []
    private var ragdollParts: [SCNNode] = []
    private var gun: SCNNode?
    private var worldSpawned = false
    private var shots = 0
    private var lastShot: TimeInterval = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupScene(); setupHands(); setupHUD()
        handRequest.maximumHandCount = 2
        sceneView.scene.physicsWorld.contactDelegate = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else { hud.text = "CHAOS VR v0.3\nARKit não suportado"; return }
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.planeDetection = [.horizontal, .vertical]
        c.environmentTexturing = .automatic
        sceneView.session.delegate = self
        sceneView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.spawnWorld() }
    }

    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); sceneView.session.pause() }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    private func setupScene() {
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.scene = SCNScene(); sceneView.automaticallyUpdatesLighting = true; sceneView.autoenablesDefaultLighting = true
        sceneView.scene.physicsWorld.gravity = SCNVector3(0,-9.81,0)
        view.addSubview(sceneView)
        NSLayoutConstraint.activate([sceneView.leadingAnchor.constraint(equalTo:view.leadingAnchor),sceneView.trailingAnchor.constraint(equalTo:view.trailingAnchor),sceneView.topAnchor.constraint(equalTo:view.topAnchor),sceneView.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        let light = SCNLight(); light.type = .ambient; light.intensity = 430
        let ln = SCNNode(); ln.light = light; sceneView.scene.rootNode.addChildNode(ln)
    }

    private func setupHands() {
        leftHand = PhysicsHand(name:"HandLeft", tint:UIColor(red:0.12,green:0.18,blue:0.22,alpha:1))
        rightHand = PhysicsHand(name:"HandRight", tint:UIColor(red:0.14,green:0.20,blue:0.24,alpha:1))
        sceneView.scene.rootNode.addChildNode(leftHand.root); sceneView.scene.rootNode.addChildNode(rightHand.root)
    }

    private func setupHUD() {
        hud.translatesAutoresizingMaskIntoConstraints = false; hud.numberOfLines = 0; hud.textAlignment = .center; hud.textColor = .white; hud.font = .monospacedSystemFont(ofSize:12,weight:.bold); hud.backgroundColor = UIColor.black.withAlphaComponent(0.55); hud.layer.cornerRadius = 10; hud.layer.masksToBounds = true
        hud.text = "CHAOS VR v0.3 • GHOST CITY\nPinch: agarrar • Tommy Gun física"
        view.addSubview(hud)
        button(fireButton,"FIRE"); fireButton.addTarget(self,action:#selector(fire),for:.touchDown); view.addSubview(fireButton)
        button(ragdollButton,"+ NPC"); ragdollButton.addTarget(self,action:#selector(spawnNPC),for:.touchUpInside); view.addSubview(ragdollButton)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:6),hud.centerXAnchor.constraint(equalTo:view.centerXAnchor),hud.widthAnchor.constraint(lessThanOrEqualTo:view.widthAnchor,multiplier:0.66),
            fireButton.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-10),fireButton.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-12),fireButton.widthAnchor.constraint(equalToConstant:90),fireButton.heightAnchor.constraint(equalToConstant:48),
            ragdollButton.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:10),ragdollButton.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:10),ragdollButton.widthAnchor.constraint(equalToConstant:86),ragdollButton.heightAnchor.constraint(equalToConstant:38)])
    }
    private func button(_ b:UIButton,_ title:String){ b.translatesAutoresizingMaskIntoConstraints = false;b.setTitle(title,for:.normal);b.setTitleColor(.white,for:.normal);b.titleLabel?.font = .systemFont(ofSize:14,weight:.bold);b.backgroundColor = UIColor.black.withAlphaComponent(0.62);b.layer.cornerRadius = 12 }

    private func spawnWorld() {
        guard !worldSpawned, let t = sceneView.session.currentFrame?.camera.transform else{return}; worldSpawned = true
        if let city = MeshPacketLoader.node(resource:"GhostCity",color:UIColor(red:0.29,green:0.31,blue:0.32,alpha:1),staticBody:true,category:PhysicsCategory.world){
            city.name = "GhostCity"; city.scale = SCNVector3(0.18,0.18,0.18); city.position = SCNVector3(-2.0,-1.7,-7.0); sceneView.scene.rootNode.addChildNode(city)
        }
        let p = worldPoint(t,forward:0.85,down:0.30,right:0.38)
        if let g = MeshPacketLoader.node(resource:"TommyGun",color:UIColor(red:0.18,green:0.16,blue:0.13,alpha:1),staticBody:false,category:PhysicsCategory.grabbable){
            g.name = "Grab_TommyGun"; g.position = p; g.scale = SCNVector3(0.78,0.78,0.78); g.eulerAngles = SCNVector3(0,.pi/2,0); g.physicsBody?.mass = 3.6; sceneView.scene.rootNode.addChildNode(g); grabbables.append(g); gun = g
        }
        spawnNPC()
        hud.text = "CHAOS VR v0.3 • GHOST CITY carregada\nMostre as mãos • pinch para pegar a Tommy"
    }

    @objc private func spawnNPC(){
        guard let t = sceneView.session.currentFrame?.camera.transform else{return}; let p = worldPoint(t,forward:1.65,down:0.2,right:-0.25)
        let parts = RagdollFactory.spawn(in:sceneView.scene,at:p); ragdollParts.append(contentsOf:parts); grabbables.append(contentsOf:parts)
    }

    @objc private func fire(){
        let now = CACurrentMediaTime(); guard now-lastShot>0.08 else{return}; lastShot = now
        guard let g = gun, g.parent != nil else{return}
        let gp = g.presentation.worldPosition; let dl = distance(gp,leftHand.root.presentation.worldPosition); let dr = distance(gp,rightHand.root.presentation.worldPosition)
        guard (leftHand.isPinching && dl<0.42)||(rightHand.isPinching && dr<0.42) else { hud.text = "Segure a TOMMY com pinch para atirar"; return }
        guard let pov = sceneView.pointOfView else{return}
        let m = pov.presentation.simdWorldTransform; let f = -SIMD3<Float>(m.columns.2.x,m.columns.2.y,m.columns.2.z); let start = gp; let end = SCNVector3(start.x+f.x*35,start.y+f.y*35,start.z+f.z*35)
        let hits = sceneView.scene.physicsWorld.rayTestWithSegment(from:start,to:end,options:[.searchMode:SCNPhysicsWorld.TestSearchMode.closest])
        if let h = hits.first, let body = h.node.physicsBody, body.type == .dynamic { body.applyForce(SCNVector3(f.x*18,f.y*18+1,f.z*18),at:h.worldCoordinates,asImpulse:true) }
        g.physicsBody?.applyForce(SCNVector3(-f.x*0.45,-f.y*0.45,-f.z*0.45),asImpulse:true)
        muzzle(at:start,direction:f); shots + = 1; hud.text = "CHAOS VR v0.3 • GHOST CITY\nTOMMY • tiros: \(shots)"
    }

    private func muzzle(at p:SCNVector3,direction:SIMD3<Float>){ let s = SCNSphere(radius:0.035);s.firstMaterial?.emission.contents = UIColor.orange;s.firstMaterial?.diffuse.contents = UIColor.yellow;let n = SCNNode(geometry:s);n.position = SCNVector3(p.x+direction.x*0.35,p.y+direction.y*0.35,p.z+direction.z*0.35);sceneView.scene.rootNode.addChildNode(n);n.runAction(.sequence([.fadeOut(duration:0.08),.removeFromParentNode()])) }

    func session(_ session:ARSession,didUpdate frame:ARFrame){ processHands(frame) }
    private struct HSample { let point:CGPoint; let pinch:Bool; let span:CGFloat }
    private func processHands(_ frame:ARFrame){
        guard frame.timestamp-lastVision>0.075,!visionBusy else{return};lastVision = frame.timestamp;visionBusy = true;let pb = frame.capturedImage
        visionQueue.async{[weak self] in guard let self else{return};defer{self.visionBusy = false};let h = VNImageRequestHandler(cvPixelBuffer:pb,orientation:.right,options:[:]);do{try h.perform([self.handRequest]);let samples = (self.handRequest.results ?? []).compactMap{self.sample($0)}.sorted{$0.point.x<$1.point.x};DispatchQueue.main.async{self.apply(samples,frame.timestamp)}}catch{}}
    }
    private func sample(_ o:VNHumanHandPoseObservation)->HSample?{
        guard let w = try? o.recognizedPoint(.wrist),let i = try? o.recognizedPoint(.indexTip),let th = try? o.recognizedPoint(.thumbTip),w.confidence>0.25,i.confidence>0.25,th.confidence>0.25 else{return nil}
        let d = hypot(i.location.x-th.location.x,i.location.y-th.location.y); return HSample(point:CGPoint(x:(w.location.x+i.location.x)*0.5,y:(w.location.y+i.location.y)*0.5),pinch:d<0.075,span:max(0.04,d))
    }
    private func apply(_ s:[HSample],_ time:TimeInterval){
        let hands = [leftHand!,rightHand!]
        for idx in 0..<2 { guard idx<s.count else{hands[idx].update(position:hands[idx].root.position,timestamp:time,visible:false);hands[idx].setPinching(false,scene:sceneView.scene,grabbables:grabbables);continue}; let v = s[idx];let p = worldFromVision(v.point,depth:0.62);hands[idx].update(position:p,timestamp:time,visible:true);hands[idx].setPinching(v.pinch,scene:sceneView.scene,grabbables:grabbables) }
    }
    private func worldFromVision(_ p:CGPoint,depth:Float)->SCNVector3{ guard let t = sceneView.session.currentFrame?.camera.transform else{return .zero};let pos = SIMD3<Float>(t.columns.3.x,t.columns.3.y,t.columns.3.z);let r = SIMD3<Float>(t.columns.0.x,t.columns.0.y,t.columns.0.z);let u = SIMD3<Float>(t.columns.1.x,t.columns.1.y,t.columns.1.z);let f = -SIMD3<Float>(t.columns.2.x,t.columns.2.y,t.columns.2.z);let x = Float(p.x-0.5)*0.72;let y = Float(p.y-0.5)*0.46;let q = pos+f*depth+r*x+u*y;return SCNVector3(q.x,q.y,q.z) }
    private func worldPoint(_ t:simd_float4x4,forward:Float,down:Float,right:Float)->SCNVector3{let p = SIMD3<Float>(t.columns.3.x,t.columns.3.y,t.columns.3.z);let f = -SIMD3<Float>(t.columns.2.x,t.columns.2.y,t.columns.2.z);let r = SIMD3<Float>(t.columns.0.x,t.columns.0.y,t.columns.0.z);let q = p+f*forward+r*right+SIMD3<Float>(0,-down,0);return SCNVector3(q.x,q.y,q.z)}
    private func distance(_ a:SCNVector3,_ b:SCNVector3)->Float{let x = a.x-b.x,y = a.y-b.y,z = a.z-b.z;return sqrt(x*x+y*y+z*z)}
}

private extension SCNVector3 { static var zero:SCNVector3 { SCNVector3Zero } }
