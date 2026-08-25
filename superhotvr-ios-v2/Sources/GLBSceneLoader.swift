import Foundation
import SceneKit
import UIKit
import simd

enum GLBSceneLoaderError: Error {
    case invalidHeader
    case missingJSON
    case missingBinary
    case invalidScene
}

final class GLBSceneLoader {
    private static let jsonChunkType: UInt32 = 0x4E4F534A
    private static let binChunkType: UInt32 = 0x004E4942

    static func load(url: URL) throws -> SCNNode {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 20,
              u32(data, 0) == 0x46546C67,
              u32(data, 4) == 2 else { throw GLBSceneLoaderError.invalidHeader }

        var jsonData: Data?
        var binData: Data?
        var cursor = 12
        while cursor + 8 <= data.count {
            let length = Int(u32(data, cursor))
            let type = u32(data, cursor + 4)
            cursor += 8
            guard length >= 0, cursor + length <= data.count else { break }
            let chunk = data.subdata(in: cursor..<(cursor + length))
            if type == jsonChunkType { jsonData = trimJSONPadding(chunk) }
            if type == binChunkType { binData = chunk }
            cursor += length
        }

        guard let jsonData else { throw GLBSceneLoaderError.missingJSON }
        guard let binData else { throw GLBSceneLoaderError.missingBinary }
        guard let rootJSON = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw GLBSceneLoaderError.invalidScene
        }

        let accessors = rootJSON["accessors"] as? [[String: Any]] ?? []
        let bufferViews = rootJSON["bufferViews"] as? [[String: Any]] ?? []
        let meshes = rootJSON["meshes"] as? [[String: Any]] ?? []
        let nodesJSON = rootJSON["nodes"] as? [[String: Any]] ?? []
        let materials = rootJSON["materials"] as? [[String: Any]] ?? []

        var nodes: [SCNNode] = nodesJSON.map { nodeJSON in
            let node = SCNNode()
            node.name = nodeJSON["name"] as? String
            applyTransform(nodeJSON, to: node)
            return node
        }

        for (index, nodeJSON) in nodesJSON.enumerated() {
            guard index < nodes.count else { continue }
            let node = nodes[index]

            if let meshIndex = number(nodeJSON["mesh"]), meshIndex >= 0, meshIndex < meshes.count {
                appendMesh(meshes[meshIndex], to: node, accessors: accessors, bufferViews: bufferViews, binary: binData, materials: materials)
            }

            if let children = nodeJSON["children"] as? [NSNumber] {
                for childNumber in children {
                    let childIndex = childNumber.intValue
                    if childIndex >= 0, childIndex < nodes.count {
                        node.addChildNode(nodes[childIndex])
                    }
                }
            }
        }

        let root = SCNNode()
        root.name = url.deletingPathExtension().lastPathComponent
        let sceneIndex = number(rootJSON["scene"]) ?? 0
        let scenes = rootJSON["scenes"] as? [[String: Any]] ?? []
        if sceneIndex >= 0, sceneIndex < scenes.count,
           let rootNodes = scenes[sceneIndex]["nodes"] as? [NSNumber] {
            for n in rootNodes {
                let i = n.intValue
                if i >= 0, i < nodes.count { root.addChildNode(nodes[i]) }
            }
        } else {
            var childSet = Set<Int>()
            for nodeJSON in nodesJSON {
                if let children = nodeJSON["children"] as? [NSNumber] {
                    for c in children { childSet.insert(c.intValue) }
                }
            }
            for i in nodes.indices where !childSet.contains(i) { root.addChildNode(nodes[i]) }
        }
        return root
    }

    private static func appendMesh(_ meshJSON: [String: Any],
                                   to node: SCNNode,
                                   accessors: [[String: Any]],
                                   bufferViews: [[String: Any]],
                                   binary: Data,
                                   materials: [[String: Any]]) {
        guard let primitives = meshJSON["primitives"] as? [[String: Any]] else { return }

        for primitive in primitives {
            guard let attrs = primitive["attributes"] as? [String: Any],
                  let positionAccessor = number(attrs["POSITION"]) else { continue }

            let vertices = decodeVec3(positionAccessor, accessors: accessors, bufferViews: bufferViews, binary: binary)
            guard !vertices.isEmpty else { continue }
            var sources: [SCNGeometrySource] = [SCNGeometrySource(vertices: vertices)]

            if let normalAccessor = number(attrs["NORMAL"]) {
                let normals = decodeVec3(normalAccessor, accessors: accessors, bufferViews: bufferViews, binary: binary)
                if normals.count == vertices.count { sources.append(SCNGeometrySource(normals: normals)) }
            }

            let indices: [UInt32]
            if let indexAccessor = number(primitive["indices"]) {
                indices = decodeIndices(indexAccessor, accessors: accessors, bufferViews: bufferViews, binary: binary)
            } else {
                indices = (0..<vertices.count).map(UInt32.init)
            }
            guard !indices.isEmpty else { continue }

            let mode = number(primitive["mode"]) ?? 4
            let primitiveType: SCNGeometryPrimitiveType
            let primitiveCount: Int
            switch mode {
            case 0:
                primitiveType = .point
                primitiveCount = indices.count
            case 1, 2, 3:
                primitiveType = .line
                primitiveCount = indices.count / 2
            case 5:
                primitiveType = .triangleStrip
                primitiveCount = max(0, indices.count - 2)
            default:
                primitiveType = .triangles
                primitiveCount = indices.count / 3
            }

            let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let element = SCNGeometryElement(data: indexData,
                                             primitiveType: primitiveType,
                                             primitiveCount: primitiveCount,
                                             bytesPerIndex: MemoryLayout<UInt32>.size)
            let geometry = SCNGeometry(sources: sources, elements: [element])
            geometry.name = meshJSON["name"] as? String
            geometry.materials = [material(for: number(primitive["material"]), materials: materials)]

            let meshNode = SCNNode(geometry: geometry)
            meshNode.name = geometry.name
            node.addChildNode(meshNode)
        }
    }

    private static func material(for index: Int?, materials: [[String: Any]]) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(white: 0.93, alpha: 1)
        material.roughness.contents = 0.82
        material.metalness.contents = 0.0

        guard let index, index >= 0, index < materials.count else { return material }
        let source = materials[index]
        material.name = source["name"] as? String
        if let pbr = source["pbrMetallicRoughness"] as? [String: Any] {
            if let color = pbr["baseColorFactor"] as? [NSNumber], color.count >= 3 {
                let a = color.count > 3 ? color[3].doubleValue : 1.0
                material.diffuse.contents = UIColor(red: color[0].doubleValue,
                                                    green: color[1].doubleValue,
                                                    blue: color[2].doubleValue,
                                                    alpha: a)
            }
            if let rough = pbr["roughnessFactor"] as? NSNumber { material.roughness.contents = rough.doubleValue }
            if let metal = pbr["metallicFactor"] as? NSNumber { material.metalness.contents = metal.doubleValue }
        }
        if (source["doubleSided"] as? Bool) == true { material.isDoubleSided = true }
        return material
    }

    private static func decodeVec3(_ accessorIndex: Int,
                                   accessors: [[String: Any]],
                                   bufferViews: [[String: Any]],
                                   binary: Data) -> [SCNVector3] {
        guard let info = accessorInfo(accessorIndex, accessors: accessors, bufferViews: bufferViews) else { return [] }
        let componentCount = components(for: info.type)
        guard componentCount >= 3 else { return [] }
        var result: [SCNVector3] = []
        result.reserveCapacity(info.count)
        for i in 0..<info.count {
            let base = info.offset + i * info.stride
            let x = readComponent(binary, offset: base, componentType: info.componentType, normalized: info.normalized)
            let y = readComponent(binary, offset: base + info.componentBytes, componentType: info.componentType, normalized: info.normalized)
            let z = readComponent(binary, offset: base + info.componentBytes * 2, componentType: info.componentType, normalized: info.normalized)
            result.append(SCNVector3(x, y, z))
        }
        return result
    }

    private static func decodeIndices(_ accessorIndex: Int,
                                      accessors: [[String: Any]],
                                      bufferViews: [[String: Any]],
                                      binary: Data) -> [UInt32] {
        guard let info = accessorInfo(accessorIndex, accessors: accessors, bufferViews: bufferViews) else { return [] }
        var result: [UInt32] = []
        result.reserveCapacity(info.count)
        for i in 0..<info.count {
            let o = info.offset + i * info.stride
            switch info.componentType {
            case 5121:
                if o < binary.count { result.append(UInt32(binary[o])) }
            case 5123:
                if o + 1 < binary.count { result.append(UInt32(u16(binary, o))) }
            case 5125:
                if o + 3 < binary.count { result.append(u32(binary, o)) }
            default:
                result.append(UInt32(i))
            }
        }
        return result
    }

    private struct AccessorInfo {
        let offset: Int
        let stride: Int
        let count: Int
        let type: String
        let componentType: Int
        let componentBytes: Int
        let normalized: Bool
    }

    private static func accessorInfo(_ accessorIndex: Int,
                                     accessors: [[String: Any]],
                                     bufferViews: [[String: Any]]) -> AccessorInfo? {
        guard accessorIndex >= 0, accessorIndex < accessors.count else { return nil }
        let accessor = accessors[accessorIndex]
        guard let bufferViewIndex = number(accessor["bufferView"]),
              bufferViewIndex >= 0, bufferViewIndex < bufferViews.count else { return nil }
        let view = bufferViews[bufferViewIndex]
        let componentType = number(accessor["componentType"]) ?? 5126
        let componentBytes = bytes(for: componentType)
        let type = accessor["type"] as? String ?? "SCALAR"
        let count = number(accessor["count"]) ?? 0
        let elementBytes = componentBytes * components(for: type)
        let offset = (number(view["byteOffset"]) ?? 0) + (number(accessor["byteOffset"]) ?? 0)
        let stride = number(view["byteStride"]) ?? elementBytes
        return AccessorInfo(offset: offset,
                            stride: stride,
                            count: count,
                            type: type,
                            componentType: componentType,
                            componentBytes: componentBytes,
                            normalized: accessor["normalized"] as? Bool ?? false)
    }

    private static func readComponent(_ data: Data, offset: Int, componentType: Int, normalized: Bool) -> Float {
        guard offset >= 0, offset < data.count else { return 0 }
        switch componentType {
        case 5126:
            guard offset + 3 < data.count else { return 0 }
            return Float(bitPattern: u32(data, offset))
        case 5120:
            let v = Int8(bitPattern: data[offset])
            return normalized ? max(-1, Float(v) / 127) : Float(v)
        case 5121:
            let v = data[offset]
            return normalized ? Float(v) / 255 : Float(v)
        case 5122:
            guard offset + 1 < data.count else { return 0 }
            let raw = Int16(bitPattern: u16(data, offset))
            return normalized ? max(-1, Float(raw) / 32767) : Float(raw)
        case 5123:
            guard offset + 1 < data.count else { return 0 }
            let v = u16(data, offset)
            return normalized ? Float(v) / 65535 : Float(v)
        case 5125:
            guard offset + 3 < data.count else { return 0 }
            return Float(u32(data, offset))
        default:
            return 0
        }
    }

    private static func applyTransform(_ json: [String: Any], to node: SCNNode) {
        if let matrix = json["matrix"] as? [NSNumber], matrix.count == 16 {
            let f = matrix.map { Float(truncating: $0) }
            node.simdTransform = simd_float4x4(columns: (
                SIMD4<Float>(f[0], f[1], f[2], f[3]),
                SIMD4<Float>(f[4], f[5], f[6], f[7]),
                SIMD4<Float>(f[8], f[9], f[10], f[11]),
                SIMD4<Float>(f[12], f[13], f[14], f[15])
            ))
            return
        }
        if let t = json["translation"] as? [NSNumber], t.count >= 3 {
            node.simdPosition = SIMD3<Float>(Float(truncating: t[0]), Float(truncating: t[1]), Float(truncating: t[2]))
        }
        if let r = json["rotation"] as? [NSNumber], r.count >= 4 {
            node.simdOrientation = simd_quatf(ix: Float(truncating: r[0]),
                                              iy: Float(truncating: r[1]),
                                              iz: Float(truncating: r[2]),
                                              r: Float(truncating: r[3]))
        }
        if let s = json["scale"] as? [NSNumber], s.count >= 3 {
            node.simdScale = SIMD3<Float>(Float(truncating: s[0]), Float(truncating: s[1]), Float(truncating: s[2]))
        }
    }

    private static func components(for type: String) -> Int {
        switch type {
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT2": return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: return 1
        }
    }

    private static func bytes(for componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        default: return 4
        }
    }

    private static func number(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func trimJSONPadding(_ data: Data) -> Data {
        var end = data.count
        while end > 0 {
            let b = data[end - 1]
            if b == 0 || b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 { end -= 1 } else { break }
        }
        return data.subdata(in: 0..<end)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}
