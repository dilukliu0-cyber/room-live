import SwiftUI
import ARKit
import RealityKit

/// Live AR mesh scan UI — primary LiDAR dense-mesh capture path.
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
                HStack {
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

                Spacer()

                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Text("LiDAR mesh · сканируйте комнату медленно")
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

/// RealityKit ARView with scene understanding mesh visualization.
struct MeshARViewContainer: UIViewRepresentable {
    @ObservedObject var model: MeshScanModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        // Show reconstructed mesh with camera coloring on device
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
        arView.environment.sceneUnderstanding.options.insert(.receivesLighting)
        arView.debugOptions.insert(.showSceneUnderstanding)

        model.attach(session: arView.session)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
