import UIKit
import ARKit
import Vision

final class VRViewController: UIViewController, ARSessionDelegate {
    private let session = ARSession()
    private let handTracker = HandTrackingEngine()
    private let leftLabel = UILabel()
    private let rightLabel = UILabel()
    private let statusLabel = UILabel()
    private let portLabel = UILabel()
    private var lastHands: [TrackedHandState] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        session.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else {
            statusLabel.text = "ARKit 6DoF unavailable on this device"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.pause()
    }

    private func setupUI() {
        func style(_ label: UILabel, size: CGFloat) {
            label.textColor = .white
            label.font = .monospacedSystemFont(ofSize: size, weight: .medium)
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }

        style(leftLabel, size: 15)
        style(rightLabel, size: 15)
        style(statusLabel, size: 13)
        style(portLabel, size: 11)

        leftLabel.text = "LEFT EYE\nWaiting for hand"
        rightLabel.text = "RIGHT EYE\nWaiting for hand"
        statusLabel.text = "Starting ARKit 6DoF…"
        portLabel.text = "I Am Cat iOS Port Stage 1\n\(PortAssetManifest.sourceCoverageText)\nUnity source: \(PortAssetManifest.unityVersion)"

        let divider = UIView()
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)

        NSLayoutConstraint.activate([
            leftLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftLabel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5),
            leftLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            rightLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightLabel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5),
            rightLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            divider.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            portLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            portLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let p = camera.transform.columns.3
        let tracking: String
        switch camera.trackingState {
        case .normal: tracking = "TRACKING"
        case .notAvailable: tracking = "NO TRACKING"
        case .limited: tracking = "LIMITED"
        @unknown default: tracking = "UNKNOWN"
        }

        DispatchQueue.main.async {
            self.statusLabel.text = String(
                format: "%@  6DoF  x %.2f  y %.2f  z %.2f  | hands %d",
                tracking, p.x, p.y, p.z, self.lastHands.count
            )
        }

        handTracker.process(frame.capturedImage) { [weak self] hands in
            guard let self else { return }
            self.lastHands = hands
            DispatchQueue.main.async {
                self.renderHands(hands)
            }
        }
    }

    private func renderHands(_ hands: [TrackedHandState]) {
        func text(for hand: TrackedHandState?, eye: String) -> String {
            guard let hand else { return "\(eye)\nNo hand" }
            let grab = hand.pinch > 0.62 ? "GRAB" : "OPEN"
            return String(
                format: "%@\nHand %.0f%%\nPinch %.0f%%  %@\nWrist %.2f, %.2f",
                eye,
                hand.confidence * 100,
                hand.pinch * 100,
                grab,
                hand.wristX,
                hand.wristY
            )
        }

        let left = hands.indices.contains(0) ? hands[0] : nil
        let right = hands.indices.contains(1) ? hands[1] : nil
        leftLabel.text = text(for: left, eye: "LEFT EYE")
        rightLabel.text = text(for: right, eye: "RIGHT EYE")
    }
}
