import Foundation
import Vision
import CoreVideo

struct TrackedHandState {
    let wristX: CGFloat
    let wristY: CGFloat
    let pinch: CGFloat
    let confidence: Float
}

final class HandTrackingEngine {
    private let queue = DispatchQueue(label: "iamcat.hand.vision", qos: .userInteractive)
    private var busy = false

    func process(_ pixelBuffer: CVPixelBuffer, completion: @escaping ([TrackedHandState]) -> Void) {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            defer { self?.busy = false }
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 2
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            do {
                try handler.perform([request])
                let hands = try (request.results ?? []).compactMap { observation -> TrackedHandState? in
                    let wrist = try observation.recognizedPoint(.wrist)
                    let thumb = try observation.recognizedPoint(.thumbTip)
                    let index = try observation.recognizedPoint(.indexTip)
                    guard wrist.confidence > 0.25, thumb.confidence > 0.25, index.confidence > 0.25 else { return nil }
                    let dx = thumb.location.x - index.location.x
                    let dy = thumb.location.y - index.location.y
                    let distance = sqrt(dx * dx + dy * dy)
                    let pinch = max(0, min(1, (0.12 - distance) / 0.10))
                    return TrackedHandState(
                        wristX: wrist.location.x,
                        wristY: wrist.location.y,
                        pinch: pinch,
                        confidence: min(wrist.confidence, min(thumb.confidence, index.confidence))
                    )
                }
                completion(hands.sorted { $0.wristX < $1.wristX })
            } catch {
                completion([])
            }
        }
    }
}
