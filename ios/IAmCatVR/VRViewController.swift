import UIKit
import ARKit
import Vision
import SceneKit

final class VRViewController: UIViewController, ARSessionDelegate {
    private let session = ARSession()
    private let handTracker = HandTrackingEngine()
    private let world = GameWorld()

    private let leftView = SCNView()
    private let rightView = SCNView()
    private let leftHUD = UILabel()
    private let rightHUD = UILabel()
    private let statusLabel = UILabel()
    private let campaignLabel = UILabel()

    private var lastHands: [TrackedHandState] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupStereoViews()
        setupHUD()
        session.delegate = self

        world.onProgressChanged = { [weak self] text in
            DispatchQueue.main.async {
                self?.campaignLabel.text = text
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else {
            statusLabel.text = "ARKit 6DoF unavailable"
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isLightEstimationEnabled = true
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.pause()
    }

    private func setupStereoViews() {
        for scnView in [leftView, rightView] {
            scnView.scene = world.scene
            scnView.backgroundColor = .black
            scnView.isPlaying = true
            scnView.preferredFramesPerSecond = 60
            scnView.antialiasingMode = .multisampling2X
            scnView.rendersContinuously = true
            scnView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scnView)
        }

        leftView.pointOfView = world.leftCameraNode
        rightView.pointOfView = world.rightCameraNode

        NSLayoutConstraint.activate([
            leftView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftView.topAnchor.constraint(equalTo: view.topAnchor),
            leftView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5),

            rightView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightView.topAnchor.constraint(equalTo: view.topAnchor),
            rightView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rightView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5)
        ])
    }

    private func setupHUD() {
        func configure(_ label: UILabel, size: CGFloat) {
            label.textColor = .white
            label.font = .monospacedSystemFont(ofSize: size, weight: .semibold)
            label.textAlignment = .center
            label.numberOfLines = 0
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.9
            label.layer.shadowRadius = 2
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }

        configure(leftHUD, size: 11)
        configure(rightHUD, size: 11)
        configure(statusLabel, size: 10)
        configure(campaignLabel, size: 10)

        leftHUD.text = "LEFT PAW — OPEN"
        rightHUD.text = "RIGHT PAW — OPEN"
        statusLabel.text = "Starting 6DoF…"
        campaignLabel.text = world.progressText

        let divider = UIView()
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)

        NSLayoutConstraint.activate([
            leftHUD.centerXAnchor.constraint(equalTo: leftView.centerXAnchor),
            leftHUD.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            leftHUD.widthAnchor.constraint(equalTo: leftView.widthAnchor, multiplier: 0.82),

            rightHUD.centerXAnchor.constraint(equalTo: rightView.centerXAnchor),
            rightHUD.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            rightHUD.widthAnchor.constraint(equalTo: rightView.widthAnchor, multiplier: 0.82),

            campaignLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            campaignLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),

            divider.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1)
        ])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let p = transform.columns.3

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.world.updateHead(transform)
            self.statusLabel.text = String(
                format: "%@  x %.2f y %.2f z %.2f | hands %d",
                self.trackingText(frame.camera.trackingState),
                p.x, p.y, p.z,
                self.lastHands.count
            )
        }

        handTracker.process(frame.capturedImage) { [weak self] hands in
            guard let self else { return }
            self.lastHands = hands
            DispatchQueue.main.async {
                self.world.updateHands(hands)
                self.renderHandHUD(hands)
            }
        }
    }

    private func trackingText(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "6DOF OK"
        case .notAvailable:
            return "NO TRACKING"
        case .limited(let reason):
            switch reason {
            case .initializing: return "INITIALIZING"
            case .excessiveMotion: return "MOVE SLOWER"
            case .insufficientFeatures: return "NEED MORE LIGHT"
            case .relocalizing: return "RELOCALIZING"
            @unknown default: return "LIMITED"
            }
        }
    }

    private func renderHandHUD(_ hands: [TrackedHandState]) {
        let left = hands.indices.contains(0) ? hands[0] : nil
        let right = hands.indices.contains(1) ? hands[1] : nil

        func labelText(_ hand: TrackedHandState?, name: String) -> String {
            guard let hand else { return "\(name) — NOT SEEN" }
            let state = hand.pinch > 0.66 ? "GRAB" : "OPEN"
            return String(format: "%@ — %@ — pinch %.0f%%", name, state, hand.pinch * 100)
        }

        leftHUD.text = labelText(left, name: "LEFT PAW")
        rightHUD.text = labelText(right, name: "RIGHT PAW")
        campaignLabel.text = world.progressText
    }
}
