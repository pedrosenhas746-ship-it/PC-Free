import Foundation
import SceneKit

extension SCNVector3 {
    static func +(lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 { .init(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z) }
    static func -(lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 { .init(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z) }
    static func *(lhs: SCNVector3, rhs: Float) -> SCNVector3 { .init(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs) }
    static func /(lhs: SCNVector3, rhs: Float) -> SCNVector3 { .init(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs) }
    var length: Float { sqrt(x*x + y*y + z*z) }
    var normalized: SCNVector3 { let l = max(length, 0.0001); return self / l }
}

func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float { min(max(value, lo), hi) }
