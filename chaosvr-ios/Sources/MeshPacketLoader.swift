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

        var o = 4
        func u32() -> UInt32 { defer { o += 4 }; return raw.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }.littleEndian }
        func f32() -> Float { defer { o += 4 }; let bits = raw.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }.littleEndian; return Float(bitPattern: bits) }

        let vertexCount = Int(u32())
        let indexCount = Int(u32())
        let minX=f32(), minY=f32(), minZ=f32(), maxX=f32(), maxY=f32(), maxZ=f32()
        let mins = SIMD3<Float>(minX,minY,minZ), spans = SIMD3<Float>(maxX-minX,maxY-minY,maxZ-minZ)

        var positions = [SCNVector3](); positions.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let qx = raw.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt16.self) }.littleEndian; o += 2
            let qy = raw.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt16.self) }.littleEndian; o += 2
            let qz = raw.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt16.self) }.littleEndian; o += 2
            let q = SIMD3<Float>(Float(qx)/65535, Float(qy)/65535, Float(qz)/65535)
            let p = mins + q * spans
            positions.append(SCNVector3(p.x,p.y,p.z))
        }

        var indices = [UInt32](); indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount {
            let v = raw.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }.littleEndian; o += 4
            indices.append(v)
        }

        let vertexData = positions.withUnsafeBytes { Data($0) }
        let source = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: positions.count, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SCNVector3>.stride)
        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: indices.count/3, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geo = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial(); mat.diffuse.contents = color; mat.lightingModel = .physicallyBased; mat.roughness.contents = 0.72; mat.metalness.contents = resource.contains("Tommy") ? 0.55 : 0.05; mat.isDoubleSided = true
        geo.materials = [mat]
        let node = SCNNode(geometry: geo)
        if staticBody {
            let shape = SCNPhysicsShape(geometry: geo, options: [.type: SCNPhysicsShape.ShapeType.concavePolyhedron])
            let body = SCNPhysicsBody(type: .static, shape: shape); body.categoryBitMask = category; body.collisionBitMask = ~0; node.physicsBody = body
        } else {
            let shape = SCNPhysicsShape(geometry: geo, options: [.type: SCNPhysicsShape.ShapeType.convexHull])
            let body = SCNPhysicsBody(type: .dynamic, shape: shape); body.mass = 3.8; body.categoryBitMask = category; body.collisionBitMask = ~0; body.contactTestBitMask = PhysicsCategory.npc; body.friction = 0.75; body.angularDamping = 0.2; node.physicsBody = body
        }
        return node
    }

    private static func inflate(_ data: Data) -> Data? {
        var size = max(data.count * 8, 65536)
        while size < 8_000_000 {
            var out = Data(count: size)
            let decoded = out.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) } }
            if decoded > 0 { out.count = decoded; return out }
            size *= 2
        }
        return nil
    }
}