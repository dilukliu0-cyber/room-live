import Foundation
import Combine
import ARKit
import CoreVideo
import CoreGraphics
import simd
import UIKit

/// Streams dense LiDAR scene-reconstruction meshes (vertices / faces / camera-sampled colors) over WebSocket.
@MainActor
final class MeshScanModel: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var wsStatus: String = "нет связи"
    @Published var meshStats: String = ""
    @Published var isJoined = false

    private let ws = WebSocketClient()
    private var session: ARSession?
    private var sendTimer: Timer?
    private var lastSend = Date.distantPast
    private let minInterval: TimeInterval = 0.25
    /// Keep every Nth face when packing (1 = all). Raised automatically if payload is huge.
    private var faceStride = 1
    /// Cap to reduce WS frame failures on phone hotspot / LAN.
    private let maxPayloadBytes = 600_000
    /// start() may race ahead of MeshARViewContainer.attach(session).
    private var pendingStart = false

    /// Last good RGB (0…1) per vertex index, keyed by mesh-anchor UUID.
    private var lastColorsByAnchor: [UUID: [Int: SIMD3<Float>]] = [:]

    /// Per-frame RGB cache (row-major RGB888, size = width*height*3).
    private var rgbCache: [UInt8] = []
    private var rgbWidth = 0
    private var rgbHeight = 0
    private var rgbFrameTimestamp: TimeInterval = -1
    private var rgbIsVideoRange = false

    func attach(session: ARSession) {
        self.session = session
        session.delegate = self
        if pendingStart {
            pendingStart = false
            start()
        }
    }

    func connect(host: String, code: String) throws {
        isJoined = false
        ws.onStatus = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.wsStatus = text
                self.isJoined = self.ws.isJoined || text.contains("в сессии")
            }
        }
        try ws.connect(hostPort: host, sessionCode: code)
    }

    func disconnect() {
        stop()
        ws.disconnect()
        isJoined = false
        wsStatus = "отключено"
    }

    func start() {
        guard let session else {
            pendingStart = true
            return
        }
        pendingStart = false
        let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        let supportsClassified = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        guard supportsMesh || supportsClassified else {
            wsStatus = "устройство без LiDAR / scene reconstruction"
            return
        }

        let config = ARWorldTrackingConfiguration()
        if supportsClassified {
            config.sceneReconstruction = .meshWithClassification
        } else {
            config.sceneReconstruction = .mesh
        }
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
        faceStride = 1
        lastColorsByAnchor.removeAll(keepingCapacity: true)
        invalidateRGBCache()
        startSendTimer()
    }

    func stop() {
        pendingStart = false
        sendTimer?.invalidate()
        sendTimer = nil
        session?.pause()
        isScanning = false
        lastColorsByAnchor.removeAll()
        invalidateRGBCache()
    }

    private func startSendTimer() {
        sendTimer?.invalidate()
        let timer = Timer(timeInterval: minInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.collectAndSend()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sendTimer = timer
    }

    private func collectAndSend() {
        guard isScanning, let session, let frame = session.currentFrame else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSend) >= minInterval * 0.9 else { return }
        lastSend = now

        // Convert camera YCbCr → RGB once per tick for all vertex samples.
        ensureRGBCache(from: frame)

        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else {
            meshStats = "якорей: 0"
            return
        }

        var sent = false
        for _ in 0..<6 {
            var chunks: [[String: Any]] = []
            var totalVerts = 0
            var totalFaces = 0
            var coloredVerts = 0

            for (idx, anchor) in meshAnchors.enumerated() {
                guard let packed = packAnchor(anchor, index: idx, frame: frame, faceStride: faceStride) else { continue }
                totalVerts += packed.vertexCount
                totalFaces += packed.faceCount
                coloredVerts += packed.coloredCount
                chunks.append(packed.dict)
            }

            guard !chunks.isEmpty else { return }

            var attemptChunks = chunks
            while !attemptChunks.isEmpty {
                let payload: [String: Any] = [
                    "type": "mesh_update",
                    "chunks": attemptChunks,
                ]
                guard JSONSerialization.isValidJSONObject(payload),
                      let data = try? JSONSerialization.data(withJSONObject: payload) else {
                    return
                }

                if data.count <= maxPayloadBytes {
                    ws.sendJSON(payload)
                    let pct = totalVerts > 0 ? (coloredVerts * 100) / totalVerts : 0
                    meshStats = "якорей: \(attemptChunks.count)/\(chunks.count) · verts \(totalVerts) · color \(pct)% · stride \(faceStride) · \(data.count / 1024)KB"
                    sent = true
                    break
                }

                if attemptChunks.count > 1 {
                    attemptChunks = Array(attemptChunks.prefix(max(1, attemptChunks.count / 2)))
                    continue
                }
                break
            }

            if sent { break }

            if faceStride < 16 {
                faceStride *= 2
                continue
            }

            let limited = Array(chunks.prefix(1))
            let slim: [String: Any] = ["type": "mesh_update", "chunks": limited]
            ws.sendJSON(slim)
            meshStats = "якорей: 1/\(chunks.count) · ↓stride \(faceStride) (forced)"
            sent = true
            break
        }

        if !sent {
            meshStats = "не удалось упаковать mesh (stride \(faceStride))"
        }
    }

    private struct PackedMesh {
        let dict: [String: Any]
        let vertexCount: Int
        let faceCount: Int
        let coloredCount: Int
    }

    private func packAnchor(_ anchor: ARMeshAnchor, index: Int, frame: ARFrame, faceStride: Int) -> PackedMesh? {
        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count
        let faceCount = geometry.faces.count
        guard vertexCount > 0, faceCount > 0 else { return nil }

        let stride = max(1, faceStride)
        let transform = anchor.transform

        var usedOld: Set<Int> = []
        var keptTris: [(Int, Int, Int)] = []
        keptTris.reserveCapacity((faceCount / stride) + 1)

        for f in 0..<faceCount where f % stride == 0 {
            let tri = faceIndices(at: f, geometry: geometry)
            keptTris.append(tri)
            usedOld.insert(tri.0)
            usedOld.insert(tri.1)
            usedOld.insert(tri.2)
        }
        guard !keptTris.isEmpty else { return nil }

        let sortedOld = usedOld.sorted()
        var oldToNew: [Int: Int] = [:]
        oldToNew.reserveCapacity(sortedOld.count)

        var vertices: [Double] = []
        var colors: [Double] = []
        vertices.reserveCapacity(sortedOld.count * 3)
        colors.reserveCapacity(sortedOld.count * 3)

        var colorMap = lastColorsByAnchor[anchor.identifier] ?? [:]
        var coloredCount = 0

        for (newIdx, oldIdx) in sortedOld.enumerated() {
            oldToNew[oldIdx] = newIdx
            let local = vertex(at: oldIdx, geometry: geometry)
            let world4 = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
            let world = SIMD3<Float>(world4.x, world4.y, world4.z)
            vertices.append(contentsOf: [
                round3(Double(world.x)),
                round3(Double(world.y)),
                round3(Double(world.z)),
            ])

            let chosen: SIMD3<Float>
            if let rgb = sampleColorFromCache(worldPosition: world, frame: frame) {
                chosen = rgb
                colorMap[oldIdx] = rgb
                coloredCount += 1
            } else if let prev = colorMap[oldIdx] {
                // Keep last good color — do NOT paint uniform grey over the mesh.
                chosen = prev
                coloredCount += 1
            } else {
                // Brand-new vertex with no valid sample yet: soft neutral only once.
                chosen = SIMD3(0.52, 0.53, 0.54)
                colorMap[oldIdx] = chosen
            }

            colors.append(contentsOf: [
                round3(Double(chosen.x)),
                round3(Double(chosen.y)),
                round3(Double(chosen.z)),
            ])
        }

        lastColorsByAnchor[anchor.identifier] = colorMap

        var indices: [Int] = []
        indices.reserveCapacity(keptTris.count * 3)
        for tri in keptTris {
            guard let a = oldToNew[tri.0], let b = oldToNew[tri.1], let c = oldToNew[tri.2] else { continue }
            indices.append(contentsOf: [a, b, c])
        }

        let dict: [String: Any] = [
            "id": anchor.identifier.uuidString,
            "vertices": vertices,
            "indices": indices,
            "colors": colors,
        ]
        return PackedMesh(dict: dict, vertexCount: sortedOld.count, faceCount: keptTris.count, coloredCount: coloredCount)
    }

    private func vertex(at index: Int, geometry: ARMeshGeometry) -> SIMD3<Float> {
        let vertices = geometry.vertices
        let ptr = vertices.buffer.contents().advanced(by: vertices.offset + vertices.stride * index)
        let values = ptr.bindMemory(to: Float.self, capacity: 3)
        return SIMD3(values[0], values[1], values[2])
    }

    private func faceIndices(at index: Int, geometry: ARMeshGeometry) -> (Int, Int, Int) {
        let faces = geometry.faces
        let offset = faces.indexCountPerPrimitive * index
        switch faces.bytesPerIndex {
        case 2:
            let ptr = faces.buffer.contents().bindMemory(to: UInt16.self, capacity: faces.count * faces.indexCountPerPrimitive)
            return (Int(ptr[offset]), Int(ptr[offset + 1]), Int(ptr[offset + 2]))
        default:
            let ptr = faces.buffer.contents().bindMemory(to: UInt32.self, capacity: faces.count * faces.indexCountPerPrimitive)
            return (Int(ptr[offset]), Int(ptr[offset + 1]), Int(ptr[offset + 2]))
        }
    }

    // MARK: - Camera RGB cache + sampling

    private func invalidateRGBCache() {
        rgbCache.removeAll(keepingCapacity: true)
        rgbWidth = 0
        rgbHeight = 0
        rgbFrameTimestamp = -1
    }

    /// Convert `capturedImage` YCbCr biplanar → RGB888 once per ARFrame.
    private func ensureRGBCache(from frame: ARFrame) {
        let ts = frame.timestamp
        if ts == rgbFrameTimestamp, !rgbCache.isEmpty, rgbWidth > 0 { return }

        let image = frame.capturedImage
        let w = CVPixelBufferGetWidth(image)
        let h = CVPixelBufferGetHeight(image)
        guard w > 0, h > 0 else {
            invalidateRGBCache()
            return
        }

        let fmt = CVPixelBufferGetPixelFormatType(image)
        let isFull = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let isVideo = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard isFull || isVideo else {
            invalidateRGBCache()
            return
        }
        rgbIsVideoRange = isVideo

        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(image, 1)?.assumingMemoryBound(to: UInt8.self) else {
            invalidateRGBCache()
            return
        }

        let yBPR = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cBPR = CVPixelBufferGetBytesPerRowOfPlane(image, 1)

        let need = w * h * 3
        if rgbCache.count != need {
            rgbCache = [UInt8](repeating: 0, count: need)
        }

        // BT.601 YCbCr → RGB. VideoRange scales Y from 16…235; FullRange uses 0…255.
        rgbCache.withUnsafeMutableBufferPointer { buf in
            guard let out = buf.baseAddress else { return }
            for y in 0..<h {
                let yRow = yBase.advanced(by: y * yBPR)
                let cRow = cbcrBase.advanced(by: (y / 2) * cBPR)
                let outRow = out.advanced(by: y * w * 3)
                for x in 0..<w {
                    var Y = Double(yRow[x])
                    if isVideo {
                        Y = (Y - 16.0) * (255.0 / 219.0)
                    }
                    let cx = x / 2
                    let Cb = Double(cRow[cx * 2]) - 128.0
                    let Cr = Double(cRow[cx * 2 + 1]) - 128.0

                    // Full-range style matrix on (possibly expanded) Y:
                    var R = Y + 1.402 * Cr
                    var G = Y - 0.344136 * Cb - 0.714136 * Cr
                    var B = Y + 1.772 * Cb
                    R = min(255, max(0, R))
                    G = min(255, max(0, G))
                    B = min(255, max(0, B))

                    let o = x * 3
                    outRow[o] = UInt8(R)
                    outRow[o + 1] = UInt8(G)
                    outRow[o + 2] = UInt8(B)
                }
            }
        }

        rgbWidth = w
        rgbHeight = h
        rgbFrameTimestamp = ts
    }

    /// Project world point into camera buffer and read RGB. Returns nil if outside / behind / no cache.
    private func sampleColorFromCache(worldPosition: SIMD3<Float>, frame: ARFrame) -> SIMD3<Float>? {
        guard rgbWidth > 0, rgbHeight > 0, !rgbCache.isEmpty else { return nil }

        let cam = frame.camera
        // Reject points behind the camera (ARKit camera looks down −Z).
        let inv = cam.transform.inverse
        let camLocal = inv * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if camLocal.z >= 0 { return nil }

        let w = rgbWidth
        let h = rgbHeight
        let viewport = CGSize(width: w, height: h)

        // capturedImage is sensor/landscape oriented; landscapeRight + buffer size is the usual match.
        var pt = cam.projectPoint(worldPosition, orientation: .landscapeRight, viewportSize: viewport)
        var x = Int(pt.x.rounded())
        var y = Int(pt.y.rounded())

        if x < 0 || y < 0 || x >= w || y >= h {
            // Retry portrait orientations in case interface/buffer mapping differs.
            for orient: UIInterfaceOrientation in [.portrait, .landscapeLeft, .portraitUpsideDown] {
                pt = cam.projectPoint(worldPosition, orientation: orient, viewportSize: viewport)
                x = Int(pt.x.rounded())
                y = Int(pt.y.rounded())
                if x >= 0, y >= 0, x < w, y < h { break }
            }
        }

        // Small 3×3 search if exactly on the edge / slight mis-project.
        if x < 0 || y < 0 || x >= w || y >= h {
            return nil
        }

        // Clamp inward by 1px to avoid plane-edge artifacts.
        x = min(w - 1, max(0, x))
        y = min(h - 1, max(0, y))

        let base = (y * w + x) * 3
        guard base + 2 < rgbCache.count else { return nil }
        let r = Float(rgbCache[base]) / 255.0
        let g = Float(rgbCache[base + 1]) / 255.0
        let b = Float(rgbCache[base + 2]) / 255.0
        return SIMD3(r, g, b)
    }

    private func round3(_ v: Double) -> Double {
        (v * 1000).rounded() / 1000
    }
}

extension MeshScanModel: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            wsStatus = "AR: \(error.localizedDescription)"
            isScanning = false
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            wsStatus = "AR прервана"
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            if isScanning { start() }
        }
    }
}
