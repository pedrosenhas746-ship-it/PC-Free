import Foundation
import SceneKit
import Compression
import UIKit

final class MeshPacketLoader {
    static func node(resource: String, color: UIColor, staticBody: Bool, category: Int) -> SCNNode? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "cmhz"),
              let compressed = try? Data(contentsOf: url),
              let raw = inflate(compressed), raw.count > 36,
              String(data: raw.prefix(4), encoding: .ascii) == "CMH2" else { return nil }

        var o
 = 4
        func u16() -> UInt16 {
            guard o + 2 <= raw.count else { return 0 }
            let v = UInt16(raw[o]) | (UInt16(raw[o + 1]) << 8)
            o += 2
            return v
        }
        func u32() -> UInt32 {
            guard o + 4 <= raw.count else { return 0 }
            let v = UInt32(raw[o]) |
                (UInt32(raw[o + 1]) << 8) |
                (UInt32(raw[o + 2]) << 16) |
                (UInt32(raw[o + 3]) << 24)
            o += 4
            return v
        }
        func f32() -> Float { Float(bitPattern: u32()) }

        let vertexCount = Int(u32())
        let indexCount = Int(u32())
        guard vertexCount > 0, indexCount >= 3, vertexCount < 200_000, indexCount < 1_000_000 else { return nil }
        let minX = f32(), minY = f32(), minZ = f32(), maxX = f32(), maxY = f32(), maxZ = f32()
        let mins = SIMD3<Float>(minX, minY, minZ)
        let spans = SIMD3<Float>(maxX - minX, maxY - minY, maxZ - minZ)
        guard raw.count >= o + vertexCount * 6 + indexCount * 4 else { return nil }

        var positions = [SCNVector3](); positions.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let q = SIMD3<Float>(Float(u16()) / 65535, Float(u16()) / 65535, Float(u16()) / 65535)
            let p = mins + q * spans
            positions.append(SCNVector3(p.x, p.y, p.z))
        }

        var indices = [UInt32](); indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount { indices.append(u32()) }

        let vertexData = positions.withUnsafeBytes { Data($0) }
        let source = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: positions.count, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SCNVector3>.stride)
        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: indices.count / 3, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geo = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .physicallyBased
        mat.roughness.contents = resource.contains("Tommy") ? 0.34 : 0.76
        mat.metallness.contents = resource.contains("Tommy") ? 0.58 : 0.05
        mat.isDoubleSided = true
        geo.materials = [mat]

        let node = SCNNode(geometry: geo)
        if staticBody {
            let shape = SCNPhysicsShape(geometry: geo, options: [.type: SCNPhysicsShape.ShapeType.concavePolyhedron])
            let body = SCNPhysicsBody(type: .static, shape: shape)
            body.categoryBitMask = category; body.collisionBitMask = ~0; node.physicsBody = body
        } else {
            let shape = SCNPhysicsShape(geometry: geo, options: [.type: SCNPhysicsShape.ShapeType.convexHull])
            let body = SCNPhysicsBody(type: .dynamic, shape: shape)
            body.mass = 3.8; body.categoryBitMask = category; body.collisionBitMask = ~0
            body.contactTestBitMask = PhysicsCategory.npc; body.friction = 0.75; body.angularDamping = 0.2
            node.physicsBody = body
        }
        return node
    }

    private static func inflate(_ data: Data) -> Data? {
        var size = max(data.count * 8, 65_536)
      while size <= 8_000_000 {
            var out = Data(count: size)
            let decoded = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, size, s, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if decoded > 0 { out.count = decoded; return out }
            size *= 2
        }
        return nil
    }
}
