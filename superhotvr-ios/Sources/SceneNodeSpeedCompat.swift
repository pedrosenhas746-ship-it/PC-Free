import SceneKit

// Compatibility shim: SceneKit physics time is controlled by SCNPhysicsWorld.speed.
// Static scene nodes do not need a separate speed multiplier.
extension SCNNode {
    var speed: Float {
        get { 1.0 }
        set { _ = newValue }
    }
}
