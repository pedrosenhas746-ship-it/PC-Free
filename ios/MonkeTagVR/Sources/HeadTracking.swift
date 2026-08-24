import CoreMotion
import SceneKit

final class HeadTrackingService {
    private let motion = CMMotionManager()
    private var baseYaw: Double?
    var onOrientation: ((SCNVector4) -> Void)?

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 90.0
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let a = data.attitude
            if baseYaw == nil { baseYaw = a.yaw }
            let yaw = a.yaw - (baseYaw ?? 0)
            let qYaw = simd_quatf(angle: Float(-yaw), axis: SIMD3<Float>(0,1,0))
            let qPitch = simd_quatf(angle: Float(a.pitch), axis: SIMD3<Float>(1,0,0))
            let qRoll = simd_quatf(angle: Float(-a.roll), axis: SIMD3<Float>(0,0,1))
            let q = qYaw * qPitch * qRoll
            onOrientation?(SCNVector4(q.axis.x, q.axis.y, q.axis.z, q.angle))
        }
    }

    func recenter() { baseYaw = motion.deviceMotion?.attitude.yaw }
    func stop() { motion.stopDeviceMotionUpdates() }
}
