import UIKit
import ARKit
import Vision

final class VRViewController: UIViewController, ARSessionDelegate {
    private let session = ARSession()
    private let leftLabel = UILabel()
    private let rightLabel = UILabel()
    private let statusLabel = UILabel()
    private let handQueue = DispatchQueue(label: "iamcat.hand.vision")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        session.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func setupUI() {
        func style(_ l: UILabel) {
            l.textColor = .white
            l.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
            l.numberOfLines = 0
            l.textAlignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(l)
        }
        style(leftLabel); style(rightLabel); style(statusLabel)
        leftLabel.text = "LEFT EYE\n6DoF + Hand Tracking"
        rightLabel.text = "RIGHT EYE\n6DoF + Hand Tracking"
        statusLabel.text = "Starting ARKit…"
        NSLayoutConstraint.activate([
            leftLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftLabel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5),
            leftLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            rightLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightLabel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5),
            rightLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)
        ])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.camera.transform.columns.3
        DispatchQueue.main.async {
            self.statusLabel.text = String(format: "6DoF  x %.2f  y %.2f  z %.2f", t.x, t.y, t.z)
        }
        detectHands(frame.capturedImage)
    }

    private func detectHands(_ pixelBuffer: CVPixelBuffer) {
        handQueue.async {
            let req = VNDetectHumanHandPoseRequest()
            req.maximumHandCount = 2
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            try? handler.perform([req])
            let count = req.results?.count ?? 0
            DispatchQueue.main.async {
                self.leftLabel.text = "LEFT EYE\nHands: \(count)"
                self.rightLabel.text = "RIGHT EYE\nHands: \(count)"
            }
        }
    }
}
