import Foundation
import Combine
import ARKit
import CoreVideo
import CoreGraphics
import simd
import UIKit

/// World-grid tile payload (vertices in world space).
struct TilePayload: Codable {
    var positions: [Double]
    var indices: [Int]
    var colors: [Double]
    var faceCount: Int
}

enum TileScanState: String, Codable {
    case empty
    case scanning
    case ready
    case regen
}

/// Streams dense LiDAR meshes as persistent world-XZ tiles over WebSocket.
@MainActor
final class MeshScanModel: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var wsStatus: String = "нет связи"
    @Published var meshStats: String = ""
    @Published var isJoined = false
    /// Tile id → UI state for overlay grid.
    @Published var tileStates: [String: TileScanState] = [:]
    /// Camera / device tile id (XZ).
    @Published var activeTileId: String = "0_0"
    @Published var readyCount: Int = 0
    @Published var emptyNearbyCount: Int = 0

    static let tileSize: Float = 1.0
    /// Faces needed before a tile freezes as ready.
    private let minFacesForReady = 24
    private let persistFileName = "scan_tiles.json"

    private let ws = WebSocketClient()
    private var session: ARSession?
    private var sendTimer: Timer?
    private var lastSend = Date.distantPast
    private let minInterval: TimeInterval = 0.25
    private var faceStride = 1
    private let maxPayloadBytes = 600_000
    private var pendingStart = false

    private var tileMeshes: [String: TilePayload] = [:]
    private var regenRequested: Set<String> = []
    /// Tiles whose geometry changed this tick (for WS delta).
    private var dirtyTiles: Set<String> = []
    private var clearedThisTick: [String] = []

    private var lastColorsByAnchor: [UUID: [Int: SIMD3<Float>]] = [:]
    private var rgbCache: [UInt8] = []
    private var rgbWidth = 0
    private var rgbHeight = 0
    private var rgbFrameTimestamp: TimeInterval = -1
    private var rgbIsVideoRange = false

    private var bgObserver: NSObjectProtocol?

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

        loadPersistedTiles()

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
        // Keep existing map alignment if we reloaded tiles; still reset ARKit mesh anchors.
        // Keep world origin if reloading persisted tiles so squares stay aligned.
        let runOpts: ARSession.RunOptions = tileMeshes.isEmpty
            ? [.resetTracking, .removeExistingAnchors]
            : [.removeExistingAnchors]
        session.run(config, options: runOpts)
        isScanning = true
        faceStride = 1
        lastColorsByAnchor.removeAll(keepingCapacity: true)
        invalidateRGBCache()
        dirtyTiles.removeAll()
        clearedThisTick.removeAll()
        observeBackground()
        startSendTimer()
        // Push already-ready tiles so web catches up after reload.
        if !tileMeshes.isEmpty {
            sendTileSnapshot(forceAllReady: true)
        }
        publishCounts()
    }

    func stop() {
        pendingStart = false
        sendTimer?.invalidate()
        sendTimer = nil
        persistTiles()
        session?.pause()
        isScanning = false
        lastColorsByAnchor.removeAll()
        invalidateRGBCache()
        if let bgObserver {
            NotificationCenter.default.removeObserver(bgObserver)
            self.bgObserver = nil
        }
    }

    /// User tapped a square → clear only that tile and allow fresh capture.
    func requestRegen(tileId: String) {
        regenRequested.insert(tileId)
        tileMeshes.removeValue(forKey: tileId)
        tileStates[tileId] = .regen
        clearedThisTick.append(tileId)
        dirtyTiles.remove(tileId)
        publishCounts()
        // Immediate clear notice to web.
        let payload: [String: Any] = [
            "type": "mesh_tiles",
            "tileSize": Double(Self.tileSize),
            "tiles": [],
            "cleared": [tileId],
        ]
        ws.sendJSON(payload)
    }

    static func tileId(x: Float, z: Float) -> String {
        let tx = Int(floor(x / tileSize))
        let tz = Int(floor(z / tileSize))
        return "\(tx)_\(tz)"
    }

    static func parseTileId(_ id: String) -> (Int, Int)? {
        let parts = id.split(separator: "_")
        guard parts.count == 2, let tx = Int(parts[0]), let tz = Int(parts[1]) else { return nil }
        return (tx, tz)
    }

    // MARK: - Timer / collect

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

        ensureRGBCache(from: frame)

        let camPos = frame.camera.transform.columns.3
        let activeId = Self.tileId(x: camPos.x, z: camPos.z)
        activeTileId = activeId

        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if meshAnchors.isEmpty {
            meshStats = "квадраты: готово \(readyCount) · якорей 0"
            flushClearedOnly()
            publishCounts()
            return
        }

        // Bin triangles into candidate tile builders (world space).
        var builders: [String: TileBuilder] = [:]
        for anchor in meshAnchors {
            binAnchorIntoTiles(anchor, frame: frame, builders: &builders)
        }

        // Merge policy per tile.
        for (tid, builder) in builders {
            let state = tileStates[tid] ?? .empty
            let wantsRegen = regenRequested.contains(tid)
            let isUnderfoot = (tid == activeId)
            let lockedReady = (state == .ready && !wantsRegen)

            if lockedReady {
                continue
            }

            let canAccept = state == .empty || wantsRegen || state == .scanning || state == .regen || isUnderfoot
            guard canAccept else { continue }
            guard builder.faceCount > 0 else { continue }

            let packed = builder.pack(stride: faceStride)
            guard packed.faceCount > 0 else { continue }

            tileMeshes[tid] = packed
            dirtyTiles.insert(tid)

            if packed.faceCount >= minFacesForReady {
                tileStates[tid] = .ready
                regenRequested.remove(tid)
            } else {
                tileStates[tid] = isUnderfoot || wantsRegen ? .scanning : .scanning
            }
        }

        // Mark underfoot empty tile as scanning for UI even before geometry arrives.
        if tileStates[activeId] == nil || tileStates[activeId] == .empty {
            tileStates[activeId] = .scanning
        } else if tileStates[activeId] == .ready {
            // stay ready
        } else if regenRequested.contains(activeId) {
            tileStates[activeId] = .regen
        }

        publishCounts()
        sendChangedTiles()
    }

    private struct TileBuilder {
        var positions: [Float] = []
        var colors: [Float] = []
        var indices: [Int] = []
        var faceCount = 0
        private var vertMap: [SIMD3<Int32>: Int] = [:]

        mutating func addTriangle(
            a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>,
            ca: SIMD3<Float>, cb: SIMD3<Float>, cc: SIMD3<Float>
        ) {
            let ia = index(for: a, color: ca)
            let ib = index(for: b, color: cb)
            let ic = index(for: c, color: cc)
            indices.append(contentsOf: [ia, ib, ic])
            faceCount += 1
        }

        private mutating func index(for p: SIMD3<Float>, color: SIMD3<Float>) -> Int {
            // Quantize to ~1mm to weld near-duplicates within a tile.
            let key = SIMD3<Int32>(
                Int32((p.x * 1000).rounded()),
                Int32((p.y * 1000).rounded()),
                Int32((p.z * 1000).rounded())
            )
            if let existing = vertMap[key] { return existing }
            let i = positions.count / 3
            positions.append(contentsOf: [p.x, p.y, p.z])
            colors.append(contentsOf: [color.x, color.y, color.z])
            vertMap[key] = i
            return i
        }

        func pack(stride: Int) -> TilePayload {
            let s = max(1, stride)
            var outPos: [Double] = []
            var outCol: [Double] = []
            var outIdx: [Int] = []
            var used: Set<Int> = []
            var kept: [(Int, Int, Int)] = []

            var f = 0
            while f < faceCount {
                if f % s == 0 {
                    let base = f * 3
                    guard base + 2 < indices.count else { break }
                    let tri = (indices[base], indices[base + 1], indices[base + 2])
                    kept.append(tri)
                    used.insert(tri.0); used.insert(tri.1); used.insert(tri.2)
                }
                f += 1
            }

            let sorted = used.sorted()
            var remap: [Int: Int] = [:]
            for (newI, oldI) in sorted.enumerated() {
                remap[oldI] = newI
                let o = oldI * 3
                outPos.append(contentsOf: [
                    round3(Double(positions[o])),
                    round3(Double(positions[o + 1])),
                    round3(Double(positions[o + 2])),
                ])
                outCol.append(contentsOf: [
                    round3(Double(colors[o])),
                    round3(Double(colors[o + 1])),
                    round3(Double(colors[o + 2])),
                ])
            }
            for tri in kept {
                guard let a = remap[tri.0], let b = remap[tri.1], let c = remap[tri.2] else { continue }
                outIdx.append(contentsOf: [a, b, c])
            }
            return TilePayload(positions: outPos, indices: outIdx, colors: outCol, faceCount: kept.count)
        }
    }

    private func binAnchorIntoTiles(
        _ anchor: ARMeshAnchor,
        frame: ARFrame,
        builders: inout [String: TileBuilder]
    ) {
        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count
        let faceCount = geometry.faces.count
        guard vertexCount > 0, faceCount > 0 else { return }

        let transform = anchor.transform
        var colorMap = lastColorsByAnchor[anchor.identifier] ?? [:]

        // Cache world positions + colors for used verts lazily.
        var worldCache: [Int: SIMD3<Float>] = [:]
        var colorCache: [Int: SIMD3<Float>] = [:]

        func worldVert(_ idx: Int) -> SIMD3<Float> {
            if let w = worldCache[idx] { return w }
            let local = vertex(at: idx, geometry: geometry)
            let w4 = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
            let w = SIMD3<Float>(w4.x, w4.y, w4.z)
            worldCache[idx] = w
            return w
        }

        func colorVert(_ idx: Int, world: SIMD3<Float>) -> SIMD3<Float> {
            if let c = colorCache[idx] { return c }
            let chosen: SIMD3<Float>
            if let rgb = sampleColorFromCache(worldPosition: world, frame: frame) {
                chosen = rgb
                colorMap[idx] = rgb
            } else if let prev = colorMap[idx] {
                chosen = prev
            } else {
                chosen = SIMD3(0.52, 0.53, 0.54)
                colorMap[idx] = chosen
            }
            colorCache[idx] = chosen
            return chosen
        }

        for f in 0..<faceCount {
            let tri = faceIndices(at: f, geometry: geometry)
            let wa = worldVert(tri.0)
            let wb = worldVert(tri.1)
            let wc = worldVert(tri.2)
            let cx = (wa.x + wb.x + wc.x) / 3
            let cz = (wa.z + wb.z + wc.z) / 3
            let tid = Self.tileId(x: cx, z: cz)

            // Early skip locked ready tiles (avoid building huge temps).
            let st = tileStates[tid] ?? .empty
            if st == .ready && !regenRequested.contains(tid) { continue }

            let ca = colorVert(tri.0, world: wa)
            let cb = colorVert(tri.1, world: wb)
            let cc = colorVert(tri.2, world: wc)
            var builder = builders[tid] ?? TileBuilder()
            builder.addTriangle(a: wa, b: wb, c: wc, ca: ca, cb: cb, cc: cc)
            builders[tid] = builder
        }

        lastColorsByAnchor[anchor.identifier] = colorMap
    }

    private func sendChangedTiles() {
        let cleared = clearedThisTick
        clearedThisTick.removeAll()

        var tilesToSend: [String] = Array(dirtyTiles)
        dirtyTiles.removeAll()

        // Prefer ready + active scanning tiles; cap payload.
        tilesToSend.sort { a, b in
            let sa = tileStates[a] == .ready ? 0 : 1
            let sb = tileStates[b] == .ready ? 0 : 1
            return sa < sb
        }

        for _ in 0..<6 {
            var attemptIds = tilesToSend
            while true {
                let tileDicts: [[String: Any]] = attemptIds.compactMap { tid in
                    guard let payload = tileMeshes[tid] else { return nil }
                    let state = tileStates[tid]?.rawValue ?? "scanning"
                    return [
                        "id": tid,
                        "state": state,
                        "positions": payload.positions,
                        "indices": payload.indices,
                        "colors": payload.colors,
                    ]
                }

                let payload: [String: Any] = [
                    "type": "mesh_tiles",
                    "tileSize": Double(Self.tileSize),
                    "tiles": tileDicts,
                    "cleared": cleared,
                ]
                guard JSONSerialization.isValidJSONObject(payload),
                      let data = try? JSONSerialization.data(withJSONObject: payload) else {
                    return
                }

                if data.count <= maxPayloadBytes || attemptIds.isEmpty {
                    if !tileDicts.isEmpty || !cleared.isEmpty {
                        ws.sendJSON(payload)
                    }
                    let ready = tileStates.values.filter { $0 == .ready }.count
                    meshStats = "квадраты: готово \(ready) · Δ\(tileDicts.count) · stride \(faceStride) · \(data.count / 1024)KB"
                    return
                }

                if attemptIds.count > 1 {
                    attemptIds = Array(attemptIds.prefix(max(1, attemptIds.count / 2)))
                    continue
                }
                break
            }

            if faceStride < 16 {
                faceStride *= 2
                // Re-pack dirty-ish: mark all non-ready for next tick; for now bump stride and retry empty.
                continue
            }
            // Force single smallest tile.
            if let one = tilesToSend.first, let payload = tileMeshes[one] {
                let slim: [String: Any] = [
                    "type": "mesh_tiles",
                    "tileSize": Double(Self.tileSize),
                    "tiles": [[
                        "id": one,
                        "state": tileStates[one]?.rawValue ?? "scanning",
                        "positions": payload.positions,
                        "indices": payload.indices,
                        "colors": payload.colors,
                    ]],
                    "cleared": cleared,
                ]
                ws.sendJSON(slim)
                meshStats = "квадраты: forced 1 · stride \(faceStride)"
            }
            return
        }
    }

    private func flushClearedOnly() {
        guard !clearedThisTick.isEmpty else { return }
        let cleared = clearedThisTick
        clearedThisTick.removeAll()
        ws.sendJSON([
            "type": "mesh_tiles",
            "tileSize": Double(Self.tileSize),
            "tiles": [],
            "cleared": cleared,
        ])
    }

    private func sendTileSnapshot(forceAllReady: Bool) {
        let ids = tileMeshes.keys.filter { forceAllReady ? (tileStates[$0] == .ready) : true }
        guard !ids.isEmpty else { return }
        dirtyTiles.formUnion(ids)
        sendChangedTiles()
    }

    private func publishCounts() {
        readyCount = tileStates.values.filter { $0 == .ready }.count
        // Nearby empties in 7×7 around active
        guard let (ax, az) = Self.parseTileId(activeTileId) else {
            emptyNearbyCount = 0
            return
        }
        var empty = 0
        for dx in -3...3 {
            for dz in -3...3 {
                let id = "\(ax + dx)_\(az + dz)"
                let st = tileStates[id] ?? .empty
                if st == .empty { empty += 1 }
            }
        }
        emptyNearbyCount = empty
    }

    // MARK: - Persistence

    private func persistURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(persistFileName)
    }

    private struct PersistBlob: Codable {
        var tileSize: Float
        var tiles: [String: TilePayload]
        var states: [String: TileScanState]
    }

    func persistTiles() {
        let blob = PersistBlob(tileSize: Self.tileSize, tiles: tileMeshes, states: tileStates)
        do {
            let data = try JSONEncoder().encode(blob)
            try data.write(to: persistURL(), options: .atomic)
        } catch {
            // Non-fatal for MVP
        }
    }

    private func loadPersistedTiles() {
        let url = persistURL()
        guard let data = try? Data(contentsOf: url) else { return }
        guard let blob = try? JSONDecoder().decode(PersistBlob.self, from: data) else { return }
        tileMeshes = blob.tiles
        tileStates = blob.states
        // Frozen ready tiles stay ready; scanning → empty so they can refill.
        for (id, st) in tileStates {
            if st == .scanning || st == .regen {
                tileStates[id] = tileMeshes[id] != nil ? .ready : .empty
            }
        }
        regenRequested.removeAll()
    }

    private func observeBackground() {
        if bgObserver != nil { return }
        bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.persistTiles()
            }
        }
    }

    // MARK: - Geometry helpers

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

    private func sampleColorFromCache(worldPosition: SIMD3<Float>, frame: ARFrame) -> SIMD3<Float>? {
        guard rgbWidth > 0, rgbHeight > 0, !rgbCache.isEmpty else { return nil }

        let cam = frame.camera
        let inv = cam.transform.inverse
        let camLocal = inv * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        if camLocal.z >= 0 { return nil }

        let w = rgbWidth
        let h = rgbHeight
        let viewport = CGSize(width: w, height: h)

        var pt = cam.projectPoint(worldPosition, orientation: .landscapeRight, viewportSize: viewport)
        var x = Int(pt.x.rounded())
        var y = Int(pt.y.rounded())

        if x < 0 || y < 0 || x >= w || y >= h {
            for orient: UIInterfaceOrientation in [.portrait, .landscapeLeft, .portraitUpsideDown] {
                pt = cam.projectPoint(worldPosition, orientation: orient, viewportSize: viewport)
                x = Int(pt.x.rounded())
                y = Int(pt.y.rounded())
                if x >= 0, y >= 0, x < w, y < h { break }
            }
        }

        if x < 0 || y < 0 || x >= w || y >= h {
            return nil
        }

        x = min(w - 1, max(0, x))
        y = min(h - 1, max(0, y))

        let base = (y * w + x) * 3
        guard base + 2 < rgbCache.count else { return nil }
        let r = Float(rgbCache[base]) / 255.0
        let g = Float(rgbCache[base + 1]) / 255.0
        let b = Float(rgbCache[base + 2]) / 255.0
        return SIMD3(r, g, b)
    }
}

private func round3(_ v: Double) -> Double {
    (v * 1000).rounded() / 1000
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
            persistTiles()
            wsStatus = "AR прервана"
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            if isScanning { start() }
        }
    }
}
