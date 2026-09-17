import Foundation
import Combine
import RoomPlan
import simd

@MainActor
final class RoomCaptureModel: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var wsStatus: String = "нет связи"

    private var captureView: RoomCaptureView?
    private var session: RoomCaptureSession?
    private let ws = WebSocketClient()
    private var lastSend = Date.distantPast
    private let minInterval: TimeInterval = 0.35

    private lazy var sessionConfig: RoomCaptureSession.Configuration = {
        var c = RoomCaptureSession.Configuration()
        c.isCoachingEnabled = true
        return c
    }()

    func attach(captureView: RoomCaptureView) {
        self.captureView = captureView
        captureView.captureSession.delegate = self
        self.session = captureView.captureSession
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
        ws.disconnect()
        wsStatus = "отключено"
    }

    func start() {
        guard let session else { return }
        session.run(configuration: sessionConfig)
        isScanning = true
    }

    func stop(final: Bool) {
        session?.stop(pauseARSession: true)
        isScanning = false
        if final {
            // final payload may also arrive via captureSession(didEndWith:)
        }
    }

    private func encodeAndSend(room: CapturedRoom, type: String) {
        let now = Date()
        if type == "room_update", now.timeIntervalSince(lastSend) < minInterval {
            return
        }
        lastSend = now

        let walls: [[String: Any]] = room.walls.enumerated().map { idx, surface in
            encodeSurface(surface, id: "wall-\(idx)")
        }

        var doors: [[String: Any]] = []
        var windows: [[String: Any]] = []
        for (idx, door) in room.doors.enumerated() {
            doors.append(encodeSurface(door, id: "door-\(idx)", extraHeight: true))
        }
        for (idx, win) in room.windows.enumerated() {
            windows.append(encodeSurface(win, id: "window-\(idx)", extraHeight: true))
        }

        let objects: [[String: Any]] = room.objects.enumerated().map { idx, obj in
            encodeObject(obj, id: "obj-\(idx)")
        }

        var payload: [String: Any] = [
            "type": type,
            "walls": walls,
            "objects": objects,
            "doors": doors,
            "windows": windows,
        ]
        ws.sendJSON(payload)
    }

    private func encodeSurface(_ surface: CapturedRoom.Surface, id: String, extraHeight: Bool = false) -> [String: Any] {
        let dims = surface.dimensions
        let t = surface.transform
        var dict: [String: Any] = [
            "id": id,
            "width": Double(dims.x),
            "height": Double(dims.y),
            "transform": matrixToArray(t),
        ]
        // Also provide simplified pose for web fallback
        let pos = t.columns.3
        dict["position"] = ["x": Double(pos.x), "y": Double(pos.y), "z": Double(pos.z)]
        dict["rotationY"] = Double(atan2(t.columns.0.z, t.columns.0.x))
        return dict
    }

    private func encodeObject(_ obj: CapturedRoom.Object, id: String) -> [String: Any] {
        let dims = obj.dimensions
        let t = obj.transform
        let pos = t.columns.3
        let category = categoryName(obj.category)
        return [
            "id": id,
            "category": category,
            "width": Double(dims.x),
            "height": Double(dims.y),
            "depth": Double(dims.z),
            "position": ["x": Double(pos.x), "y": Double(pos.y), "z": Double(pos.z)],
            "rotationY": Double(atan2(t.columns.0.z, t.columns.0.x)),
            "transform": matrixToArray(t),
        ]
    }

    private func matrixToArray(_ m: simd_float4x4) -> [Double] {
        // Column-major 16 floats (Three.js Matrix4.fromArray)
        var a: [Double] = []
        a.reserveCapacity(16)
        for col in 0..<4 {
            let c = m[col]
            a.append(Double(c.x))
            a.append(Double(c.y))
            a.append(Double(c.z))
            a.append(Double(c.w))
        }
        return a
    }

    private func categoryName(_ category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .storage: return "storage"
        case .refrigerator: return "refrigerator"
        case .stove: return "stove"
        case .bed: return "bed"
        case .sink: return "sink"
        case .washerDryer: return "washerDryer"
        case .toilet: return "toilet"
        case .bathtub: return "bathtub"
        case .oven: return "oven"
        case .dishwasher: return "dishwasher"
        case .table: return "table"
        case .sofa: return "sofa"
        case .chair: return "chair"
        case .fireplace: return "fireplace"
        case .television: return "television"
        case .stairs: return "stairs"
        @unknown default: return "object"
        }
    }
}

extension RoomCaptureModel: RoomCaptureSessionDelegate {
    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor in
            encodeAndSend(room: room, type: "room_update")
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            isScanning = false
            if let error {
                wsStatus = "ошибка: \(error.localizedDescription)"
                return
            }
            // Build final CapturedRoom if possible
            do {
                let builder = RoomBuilder(options: [.beautifyObjects])
                let room = try await builder.capturedRoom(from: data)
                encodeAndSend(room: room, type: "room_final")
                wsStatus = "финал отправлен"
            } catch {
                wsStatus = "финал: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        Task { @MainActor in
            encodeAndSend(room: room, type: "room_update")
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        Task { @MainActor in
            encodeAndSend(room: room, type: "room_update")
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) {
        // ignore
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        // coaching UI handled by RoomCaptureView
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        Task { @MainActor in
            isScanning = true
        }
    }
}
