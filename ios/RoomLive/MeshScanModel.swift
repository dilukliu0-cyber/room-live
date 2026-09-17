import Foundation
import Combine
import ARKit
import simd

/// Streams dense LiDAR scene-reconstruction meshes (vertices / faces / optional colors) over WebSocket.
@MainActor
final class MeshScanModel: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var wsStatus: String = "нет связи"
    @Published var meshStats: String = ""

    private let ws = WebSocketClient()
    private var session: ARSession?
    private var sendTimer: Timer?
    private var lastSend = Date.distantPast
    private let minInterval: TimeInterval = 0.4
    /// Keep every Nth face when packing (1 = all). Raised automatically if payload is huge.
    private var faceStride = 1
    private let maxPayloadBytes = 1_800_000

    func attach(session: ARSession) {
        self.session = session
        session.delegate = self
    }

    func connect(host: String, code: String) throws {
        ws.onStatus = { [weak self] text in
            Task { @MainActor in
                self?.wsStatus = text
            }
        }
        try ws.connect(hostPort: host, sessionCode: code)
    }

    func disconnect() {
        stop()
        ws.disconnect()
        wsStatus = "отключено"
    }

    func start() {
        guard let session else { return }
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithColor)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            wsStatus = "устройство без LiDAR / scene reconstruction"
            return
        }

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithColor) {
            config.sceneReconstruction = .meshWithColor
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
        startSendTimer()
    }

    func stop() {
        sendTimer?.invalidate()
        sendTimer = nil
        session?.pause()
        isScanning = false
    }

    private func startSendTimer() {
        sendTimer?.invalidate()
        sendTimer = Timer.scheduledTimer(withTimeInterval: minInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.collectAndSend()
            }
        }
    }

    private func collectAndSend() {
        guard isScanning, let session, let frame = session.currentFrame else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSend) >= minInterval * 0.9 else { return }
        lastSend = now

        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else {
            meshStats = "якорей: 0"
            return
        }

        var chunks: [[String: Any]] = []
        var totalVerts = 0
        var totalFaces = 0

        for (idx, anchor) in meshAnchors.enumerated() {
            guard let packed = packAnchor(anchor, index: idx, frame: frame, faceStride: faceStride) else { continue }
            totalVerts += packed.vertexCount
            totalFaces += packed.faceCount
            chunks.append(packed.dict)
        }

        guard !chunks.isEmpty else { return }

        let payload: [String: Any] = [
            "type": "mesh_update",
            "chunks": chunks,
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        if data.count > maxPayloadBytes && faceStride < 8 {
            faceStride *= 2
            meshStats = "якорей: \(chunks.count) · ↓faceStride \(faceStride) (\(data.count / 1024)KB)"
            return
        }

        if data.count > maxPayloadBytes {
            let limited = Array(chunks.prefix(max(1, chunks.count / 2)))
            let slim: [String: Any] = ["type": "mesh_update", "chunks": limited]
            ws.sendJSON(slim)
            meshStats = "якорей: \(limited.count)/\(chunks.count) · verts \(totalVerts) · \(data.count / 1024)KB"
            return
        }

        ws.sendJSON(payload)
        meshStats = "якорей: \(chunks.count) · verts \(totalVerts) · faces \(totalFaces) · \(data.count / 1024)KB"
    }

    private struct PackedMesh {
        let dict: [String: Any]
        let vertexCount: Int
        let faceCount: Int
    }

    private func packAnchor(_ anchor: ARMeshAnchor, index: Int, frame: ARFrame, faceStride: Int) -> PackedMesh? {
        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count
        let faceCount = geometry.faces.count
        guard vertexCount > 0, faceCount > 0 else { return nil }

        let stride = max(1, faceStride)
        let transform = anchor.transform

        // Collect unique vertex indices referenced by kept faces
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

        for (newIdx, oldIdx) in sortedOld.enumerated() {
            oldToNew[oldIdx] = newIdx
            let local = vertex(at: oldIdx, geometry: geometry)
            let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
            vertices.append(contentsOf: [
                round3(Double(world.x)),
                round3(Double(world.y)),
                round3(Double(world.z)),
            ])
            let rgb = sampleColor(worldPosition: SIMD3(world.x, world.y, world.z), frame: frame)
            colors.append(contentsOf: [round3(rgb.0), round3(rgb.1), round3(rgb.2)])
        }

        var indices: [Int] = []
        indices.reserveCapacity(keptTris.count * 3)
        for tri in keptTris {
            guard let a = oldToNew[tri.0], let b = oldToNew[tri.1], let c = oldToNew[tri.2] else { continue }
            indices.append(contentsOf: [a, b, c])
        }

        let dict: [String: Any] = [
            "id": "mesh-\(index)",
            "vertices": vertices,
            "indices": indices,
            "colors": colors,
        ]
        return PackedMesh(dict: dict, vertexCount: sortedOld.count, faceCount: keptTris.count)
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

    /// Project world vertex into camera image and sample RGB (photographed LiDAR look).
    private func sampleColor(worldPosition: SIMD3<Float>, frame: ARFrame) -> (Double, Double, Double) {
        let cam = frame.camera
        let image = frame.capturedImage
        let w = CVPixelBufferGetWidth(image)
        let h = CVPixelBufferGetHeight(image)
        guard w > 0, h > 0 else { return (0.55, 0.55, 0.55) }

        let viewport = CGSize(width: w, height: h)
        let pt = cam.projectPoint(worldPosition, orientation: .landscapeRight, viewportSize: viewport)
        let x = Int(pt.x.rounded())
        let y = Int(pt.y.rounded())
        guard x >= 0, y >= 0, x < w, y < h else {
            return (0.45, 0.48, 0.5)
        }

        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }

        let fmt = CVPixelBufferGetPixelFormatType(image)
        guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return (0.55, 0.55, 0.55)
        }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else {
            return (0.55, 0.55, 0.55)
        }

        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let yVal = Double(yBase.advanced(by: y * yBytesPerRow + x).assumingMemoryBound(to: UInt8.self).pointee)
        let cx = x / 2
        let cy = y / 2
        let cbcr = cbcrBase.advanced(by: cy * cBytesPerRow + cx * 2).assumingMemoryBound(to: UInt8.self)
        let cb = Double(cbcr[0])
        let cr = Double(cbcr[1])

        let r = min(255, max(0, yVal + 1.402 * (cr - 128))) / 255.0
        let g = min(255, max(0, yVal - 0.344136 * (cb - 128) - 0.714136 * (cr - 128))) / 255.0
        let b = min(255, max(0, yVal + 1.772 * (cb - 128))) / 255.0
        return (r, g, b)
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
