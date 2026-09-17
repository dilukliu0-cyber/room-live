import SwiftUI

struct ContentView: View {
    @State private var host: String = "172.20.10.3:8787"
    @State private var code: String = ""
    @State private var showMeshScan = false
    @State private var showRoomPlan = false
    @State private var status: String = "Введите IP сервера и код с сайта"

    var body: some View {
        NavigationStack {
            Form {
                Section("Сервер") {
                    TextField("192.168.x.x:8787", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                    TextField("Код сессии (4 символа)", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("Статус") {
                    Text(status)
                        .foregroundStyle(.secondary)
                }

                Section("Сканирование") {
                    Button("LiDAR mesh (плотный скан)") {
                        guard validate() else { return }
                        showMeshScan = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button("RoomPlan (схема стен/мебели)") {
                        guard validate() else { return }
                        showRoomPlan = true
                    }
                    .buttonStyle(.bordered)
                }

                Section("Подсказка") {
                    Text("Откройте сайт Room Live в браузере — там появится код. iPhone и компьютер должны быть в одной Wi‑Fi сети. Нужен iPhone с LiDAR. Режим mesh показывает реальный цветной скан; RoomPlan — схематические боксы.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Room Live")
            .fullScreenCover(isPresented: $showMeshScan) {
                MeshScanView(host: host, sessionCode: code) {
                    showMeshScan = false
                    status = "Mesh-скан завершён или отменён"
                }
            }
            .fullScreenCover(isPresented: $showRoomPlan) {
                ScanView(host: host, sessionCode: code) {
                    showRoomPlan = false
                    status = "RoomPlan завершён или отменён"
                }
            }
        }
    }

    private func validate() -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedHost.isEmpty else {
            status = "Укажите хост, например 172.20.10.3:8787"
            return false
        }
        guard trimmedCode.count == 4 else {
            status = "Код должен быть из 4 символов"
            return false
        }
        host = trimmedHost
        code = trimmedCode
        return true
    }
}

#Preview {
    ContentView()
}
