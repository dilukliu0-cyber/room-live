import SwiftUI
import RoomPlan

struct ScanView: View {
    let host: String
    let sessionCode: String
    var onClose: () -> Void

    @StateObject private var model = RoomCaptureModel()
    @State private var errorText: String?

    var body: some View {
        ZStack {
            RoomCaptureRepresentable(model: model)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button("Закрыть") {
                        model.stop(final: false)
                        onClose()
                    }
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Spacer()

                    Text(model.wsStatus)
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()

                Spacer()

                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 16) {
                    Button(model.isScanning ? "Остановить" : "Старт") {
                        if model.isScanning {
                            model.stop(final: true)
                        } else {
                            model.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Готово") {
                        model.stop(final: true)
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
            model.stop(final: false)
            model.disconnect()
        }
    }
}

/// UIViewRepresentable вокруг RoomCaptureView
struct RoomCaptureRepresentable: UIViewRepresentable {
    @ObservedObject var model: RoomCaptureModel

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        model.attach(captureView: view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
