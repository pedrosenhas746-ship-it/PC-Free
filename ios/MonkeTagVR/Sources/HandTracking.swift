import AVFoundation
import Vision
import SceneKit

protocol HandTrackingDelegate: AnyObject {
    func handTracking(_ tracker: HandTrackingService, didUpdateLeft left: SCNVector3?, right: SCNVector3?)
}

final class HandTrackingService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var delegate: HandTrackingDelegate?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "hand-tracking", qos: .userInteractive)
    private let request = VNDetectHumanHandPoseRequest()
    private var smoothedLeft: SCNVector3?
    private var smoothedRight: SCNVector3?
    private let alpha: Float = 0.42

    override init() {
        super.init()
        request.maximumHandCount = 2
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            self?.queue.async { self?.configureAndRun() }
        }
    }

    func stop() { queue.async { [weak self] in self?.session.stopRunning() } }

    private func configureAndRun() {
        guard !session.isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        defer { session.commitConfiguration() }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.connection(with: .video)?.videoOrientation = .landscapeRight
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            var candidates: [(x: Float, pos: SCNVector3)] = []
            for hand in observations {
                guard let wrist = try? hand.recognizedPoint(.wrist),
                      let middle = try? hand.recognizedPoint(.middleMCP),
                      wrist.confidence > 0.35, middle.confidence > 0.35 else { continue }
                let x = Float(wrist.location.x)
                let y = Float(wrist.location.y)
                let spread = hypot(Float(wrist.location.x - middle.location.x), Float(wrist.location.y - middle.location.y))
                let depth = clamp(0.78 - spread * 4.1, 0.22, 0.95)
                let local = SCNVector3((x - 0.5) * 1.65, (y - 0.50) * 1.22 - 0.05, -depth)
                candidates.append((x, local))
            }
            candidates.sort { $0.x < $1.x }
            var left: SCNVector3? = nil
            var right: SCNVector3? = nil
            if candidates.count == 1 {
                if candidates[0].x < 0.5 { left = candidates[0].pos } else { right = candidates[0].pos }
            } else if candidates.count >= 2 {
                left = candidates[0].pos
                right = candidates[candidates.count - 1].pos
            }
            smoothedLeft = smooth(old: smoothedLeft, new: left)
            smoothedRight = smooth(old: smoothedRight, new: right)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.handTracking(self, didUpdateLeft: self.smoothedLeft, right: self.smoothedRight)
            }
        } catch { }
    }

    private func smooth(old: SCNVector3?, new: SCNVector3?) -> SCNVector3? {
        guard let new else { return old }
        guard let old else { return new }
        return old * (1 - alpha) + new * alpha
    }
}
