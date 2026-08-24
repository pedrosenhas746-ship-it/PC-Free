import UIKit
import SceneKit

final class GameViewController: UIViewController, SCNSceneRendererDelegate, HandTrackingDelegate {
    private let leftView = SCNView(); private let rightView = SCNView()
    private let overlay = UIView(); private let card = UIView(); private let status = UILabel(); private let players = UILabel()
    private let nameField = UITextField(); private let codeField = UITextField(); private let createButton = UIButton(type: .system); private let joinButton = UIButton(type: .system)
    private let network = RoomNetwork(); private let hands = HandTrackingService(); private let headTracker = HeadTrackingService()
    private var scene = SCNScene(); private var locomotion: GorillaLocomotion!
    private var leftCamera = SCNNode(); private var rightCamera = SCNNode()
    private var remote: [String: SCNNode] = [:]
    private var lastNetworkSend: TimeInterval = 0
    private var currentHeadOrientation = SCNVector4(0,1,0,0)
    private var leftLocal = SCNVector3(-0.35, 0.0, -0.55); private var rightLocal = SCNVector3(0.35, 0.0, -0.55)

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scene = WorldBuilder.shared.buildWorld()
        locomotion = GorillaLocomotion(scene: scene)
        configureStereo(); configureMenu(); configureNetworking()
        hands.delegate = self
        headTracker.onOrientation = { [weak self] q in self?.currentHeadOrientation = q; self?.locomotion.head.rotation = q }
        WorldBuilder.shared.loadGorilla { _ in }
    }

    private func configureStereo() {
        [leftView, rightView].forEach { v in
            v.scene = scene; v.backgroundColor = .black; v.delegate = self; v.isPlaying = true; v.preferredFramesPerSecond = 60
            v.antialiasingMode = .multisampling2X; view.addSubview(v)
        }
        leftView.translatesAutoresizingMaskIntoConstraints = false; rightView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leftView.leadingAnchor.constraint(equalTo: view.leadingAnchor), leftView.topAnchor.constraint(equalTo: view.topAnchor), leftView.bottomAnchor.constraint(equalTo: view.bottomAnchor), leftView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5),
            rightView.trailingAnchor.constraint(equalTo: view.trailingAnchor), rightView.topAnchor.constraint(equalTo: view.topAnchor), rightView.bottomAnchor.constraint(equalTo: view.bottomAnchor), rightView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5)
        ])
        let ipd: Float = 0.032
        for (camera, x) in [(leftCamera, -ipd), (rightCamera, ipd)] {
            camera.camera = SCNCamera(); camera.camera?.fieldOfView = 86; camera.camera?.zNear = 0.03; camera.camera?.zFar = 150
            camera.position = SCNVector3(x, 0.03, 0); locomotion.head.addChildNode(camera)
        }
        leftView.pointOfView = leftCamera; rightView.pointOfView = rightCamera
    }

    private func configureMenu() {
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.42); view.addSubview(overlay); overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),overlay.topAnchor.constraint(equalTo: view.topAnchor),overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        card.backgroundColor = UIColor(red: 0.055, green: 0.07, blue: 0.06, alpha: 0.96); card.layer.cornerRadius = 22; card.layer.borderWidth = 1; card.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        overlay.addSubview(card); card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),card.widthAnchor.constraint(equalToConstant: 430)])
        let title = UILabel(); title.text = "MONKE TAG VR"; title.textColor = .white; title.font = .systemFont(ofSize: 30, weight: .black); title.textAlignment = .center
        let sub = UILabel(); sub.text = "VRBOX • HAND TRACKING • ONLINE"; sub.textColor = UIColor.white.withAlphaComponent(0.55); sub.font = .monospacedSystemFont(ofSize: 12, weight: .semibold); sub.textAlignment = .center
        styleField(nameField, placeholder: "SEU NOME"); styleField(codeField, placeholder: "CÓDIGO DA SALA"); codeField.autocapitalizationType = .allCharacters
        styleButton(createButton, title: "CRIAR SALA"); styleButton(joinButton, title: "ENTRAR NA SALA")
        createButton.addTarget(self, action: #selector(createRoom), for: .touchUpInside); joinButton.addTarget(self, action: #selector(joinRoom), for: .touchUpInside)
        status.text = "PRONTO"; status.textColor = UIColor.white.withAlphaComponent(0.52); status.font = .monospacedSystemFont(ofSize: 11, weight: .medium); status.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [title, sub, nameField, codeField, createButton, joinButton, status]); stack.axis = .vertical; stack.spacing = 12
        card.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),nameField.heightAnchor.constraint(equalToConstant: 46),codeField.heightAnchor.constraint(equalToConstant: 46),createButton.heightAnchor.constraint(equalToConstant: 48),joinButton.heightAnchor.constraint(equalToConstant: 48)])
        players.text = "1 ONLINE"; players.textColor = .white; players.font = .monospacedSystemFont(ofSize: 12, weight: .bold); players.backgroundColor = UIColor.black.withAlphaComponent(0.42); players.textAlignment = .center; players.layer.cornerRadius = 10; players.clipsToBounds = true; players.isHidden = true
        view.addSubview(players); players.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([players.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),players.centerXAnchor.constraint(equalTo: view.centerXAnchor),players.widthAnchor.constraint(equalToConstant: 110),players.heightAnchor.constraint(equalToConstant: 32)])
    }

    private func styleField(_ f: UITextField, placeholder: String) {
        f.placeholder = placeholder; f.textColor = .white; f.tintColor = .white; f.backgroundColor = UIColor.white.withAlphaComponent(0.07); f.layer.cornerRadius = 12; f.font = .monospacedSystemFont(ofSize: 15, weight: .semibold); f.textAlignment = .center
        f.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.35)])
    }

    private func styleButton(_ b: UIButton, title: String) {
        b.setTitle(title, for: .normal); b.setTitleColor(.white, for: .normal); b.titleLabel?.font = .systemFont(ofSize: 15, weight: .black); b.backgroundColor = UIColor(red: 0.15, green: 0.48, blue: 0.22, alpha: 1); b.layer.cornerRadius = 13
    }

    private func configureNetworking() {
        network.onStatus = { [weak self] s in self?.status.text = s }
        network.onCount = { [weak self] n in self?.players.text = "\(n) ONLINE" }
        network.onState = { [weak self] state in self?.applyRemote(state) }
    }

    @objc private func createRoom() { let code = RoomNetwork.makeRoomCode(); codeField.text = code; startRoom(code) }
    @objc private func joinRoom() {
        let code = (codeField.text ?? "").uppercased(); guard code.count >= 4 else { status.text = "DIGITE UM CÓDIGO"; return }; startRoom(code)
    }

    private func startRoom(_ code: String) {
        network.playerName = (nameField.text?.isEmpty == false ? nameField.text! : "MONKE")
        network.connect(roomCode: code)
        UIView.animate(withDuration: 0.28) { self.overlay.alpha = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.overlay.isHidden = true }
        players.isHidden = false; hands.start(); headTracker.start()
    }

    func handTracking(_ tracker: HandTrackingService, didUpdateLeft left: SCNVector3?, right: SCNVector3?) {
        if let left { leftLocal = left; locomotion.desiredLeft = left }
        if let right { rightLocal = right; locomotion.desiredRight = right }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        locomotion.update(time: time, scene: scene)
        guard time - lastNetworkSend >= 1.0 / 15.0 else { return }
        lastNetworkSend = time
        let p = locomotion.rigRoot.position; let q = currentHeadOrientation
        network.send(PlayerState(type: "state", id: network.playerID, name: network.playerName,
                                 px: p.x, py: p.y, pz: p.z, hx: q.x, hy: q.y, hz: q.z, hw: q.w,
                                 lx: leftLocal.x, ly: leftLocal.y, lz: leftLocal.z,
                                 rx: rightLocal.x, ry: rightLocal.y, rz: rightLocal.z,
                                 hue: network.hue, t: Date().timeIntervalSince1970))
    }

    private func applyRemote(_ s: PlayerState) {
        let node: SCNNode
        if let existing = remote[s.id] { node = existing }
        else {
            if let template = WorldBuilder.shared.gorillaTemplate { node = template.clone(); WorldBuilder.shared.tint(node, hue: s.hue) }
            else { node = WorldBuilder.shared.makeFallbackGorilla(hue: s.hue) }
            scene.rootNode.addChildNode(node); remote[s.id] = node
            let tag = SCNNode(geometry: SCNText(string: s.name.uppercased(), extrusionDepth: 0.006)); tag.scale = SCNVector3(0.006,0.006,0.006); tag.position = SCNVector3(-0.25,1.95,0); tag.geometry?.firstMaterial?.diffuse.contents = UIColor.white; node.addChildNode(tag)
        }
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.08
        node.position = SCNVector3(s.px, s.py - 1.55, s.pz); node.rotation = SCNVector4(s.hx, s.hy, s.hz, s.hw)
        SCNTransaction.commit()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); network.disconnect(); hands.stop(); headTracker.stop()
    }
}
