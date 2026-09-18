import SwiftUI
import ARKit
import RealityKit

/// Live AR mesh scan UI — primary LiDAR dense-mesh capture path (tile grid).
struct MeshScanView: View {
    let host: String
    let sessionCode: String
    var onClose: () -> Void

    @StateObject private var model = MeshScanModel()
    @State private var errorText: String?

    private var notInSession: Bool { !model.isJoined }

    var body: some View {
        ZStack {
            MeshARViewContainer(model: model)
                .ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    Button("Закрыть") {
                        model.stop()
                        onClose()
                    }
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(model.wsStatus)
                            .font(.caption)
                        if !model.meshStats.isEmpty {
                            Text(model.meshStats)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()

                if notInSession {
                    Text("НЕТ СЕССИИ — телефон не в комнате сервера")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }

                HStack(alignment: .top) {
                    TileGridOverlay(model: model)
                        .padding(.leading, 12)
                    Spacer()
                }

                Spacer()

                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Text("LiDAR · квадраты 1 м · тап = перескан")
                    .font(.footnote)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 16) {
                    Button(model.isScanning ? "Остановить" : "Старт") {
                        if model.isScanning {
                            model.stop()
                        } else {
                            model.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Готово") {
                        model.stop()
                        onClose()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            do {
                try model.connect(host: host, code: sessionCode)
                model.start()
            } catch {
                errorText = error.localizedDescription
            }
        }
        .onDisappear {
            model.stop()
            model.disconnect()
        }
    }
}

/// Mini top-down 7×7 tile grid around the player.
struct TileGridOverlay: View {
    @ObservedObject var model: MeshScanModel
    private let radius = 3 // 7×7

    var body: some View {
        let center = MeshScanModel.parseTileId(model.activeTileId) ?? (0, 0)
        VStack(alignment: .leading, spacing: 6) {
            Text("Квадраты")
                .font(.caption.weight(.semibold))
            Text("Тап = перескан")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("готово \(model.readyCount) · пусто \(model.emptyNearbyCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                ForEach((-radius...radius).reversed(), id: \.self) { dz in
                    HStack(spacing: 2) {
                        ForEach(-radius...radius, id: \.self) { dx in
                            let tx = center.0 + dx
                            let tz = center.1 + dz
                            let id = "\(tx)_\(tz)"
                            let state = model.tileStates[id] ?? .empty
                            let isActive = id == model.activeTileId
                            Button {
                                model.requestRegen(tileId: id)
                            } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color(for: state))
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(isActive ? Color.white : Color.clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                legend(Color.gray.opacity(0.55), "пусто")
                legend(Color.blue.opacity(0.85), "скан")
                legend(Color.green.opacity(0.85), "готово")
                legend(Color.orange.opacity(0.9), "перескан")
            }
            .font(.system(size: 9))
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func color(for state: TileScanState) -> Color {
        switch state {
        case .empty: return Color.gray.opacity(0.45)
        case .scanning: return Color.blue.opacity(0.85)
        case .ready: return Color.green.opacity(0.85)
        case .regen: return Color.orange.opacity(0.9)
        }
    }

    private func legend(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

/// RealityKit ARView with scene understanding mesh visualization.
struct MeshARViewContainer: UIViewRepresentable {
    @ObservedObject var model: MeshScanModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
        arView.environment.sceneUnderstanding.options.insert(.receivesLighting)
        arView.debugOptions.insert(.showSceneUnderstanding)

        model.attach(session: arView.session)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
