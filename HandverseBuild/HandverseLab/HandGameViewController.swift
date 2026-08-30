import UIKit
import SpriteKit
import AVFoundation
import Vision
import ImageIO

final class HandGameViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private let visionQueue = DispatchQueue(label: "handverse.vision.queue", qos: .userInteractive)
    private let handPoseRequest = VNDetectHumanHandPoseRequest()

    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var spriteView: SKView!
    private var gameScene: HandPhysicsScene!

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        handPoseRequest.maximumHandCount = 2
        configureCamera()
        configureGameLayer()
        requestCameraAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        spriteView?.frame = view.bounds
        if gameScene != nil {
            gameScene.size = view.bounds.size
        }
    }

    private func configureCamera() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }

        captureSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: visionQueue)
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        }

        captureSession.commitConfiguration()

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
    }

    private func configureGameLayer() {
        spriteView = SKView(frame: view.bounds)
        spriteView.backgroundColor = .clear
        spriteView.isOpaque = false
        spriteView.allowsTransparency = true
        spriteView.ignoresSiblingOrder = true
        view.addSubview(spriteView)

        gameScene = HandPhysicsScene(size: view.bounds.size)
        gameScene.scaleMode = .resizeFill
        spriteView.presentScene(gameScene)
    }

    private func requestCameraAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                self?.startCapture()
            }
        default:
            break
        }
    }

    private func startCapture() {
        visionQueue.async { [weak self] in
            guard let self = self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: imageOrientationForCurrentDevice(),
            options: [:]
        )

        do {
            try handler.perform([handPoseRequest])
        } catch {
            return
        }

        guard let observations = handPoseRequest.results else { return }
        var hands: [[TrackedJoint: CGPoint]] = []

        for observation in observations.prefix(2) {
            guard let recognized = try? observation.recognizedPoints(.all) else { continue }
            var hand: [TrackedJoint: CGPoint] = [:]

            addPoint(.thumbTip, from: recognized[.thumbTip], to: &hand)
            addPoint(.indexTip, from: recognized[.indexTip], to: &hand)
            addPoint(.middleTip, from: recognized[.middleTip], to: &hand)
            addPoint(.ringTip, from: recognized[.ringTip], to: &hand)
            addPoint(.littleTip, from: recognized[.littleTip], to: &hand)
            addPoint(.wrist, from: recognized[.wrist], to: &hand)

            if hand[.thumbTip] != nil && hand[.indexTip] != nil {
                hands.append(hand)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.gameScene?.updateHands(hands)
        }
    }

    private func addPoint(_ name: TrackedJoint,
                          from point: VNRecognizedPoint?,
                          to hand: inout [TrackedJoint: CGPoint]) {
        guard let point = point, point.confidence >= 0.25 else { return }
        hand[name] = CGPoint(x: point.location.x, y: point.location.y)
    }

    private func imageOrientationForCurrentDevice() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .up
        case .landscapeRight:
            return .down
        case .portraitUpsideDown:
            return .left
        default:
            return .right
        }
    }
}
