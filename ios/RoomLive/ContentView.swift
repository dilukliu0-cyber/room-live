import SwiftUI

struct ContentView: View {
    @State private var host: String = ""
    @State private var code: String = ""
    @State private var showScan = false
    @State private var status: String = "Введите IP сервера и код с сайта"

    var body: some View {
        NavigationStack {
            Form {
                Section("Сервер") {
                    TextField("192.168.x.x:8787", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.ASCIICapable)
                    TextField("Код сессии (4 символа)", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("Статус") {
                    Text(status)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Начать скан") {
                        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                        guard !trimmedHost.isEmpty else {
                            status = "Укажите хост, например 192.168.1.10:8787"
                            return
                        }
                        guard trimmedCode.count == 4 else {
                            status = "Код должен быть из 4 символов"
                            return
                        }
                        host = trimmedHost
                        code = trimmedCode
                        showScan = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section("Подсказка") {
                    Text("Откройте сайт Room Live в браузере — там появится код. iPhone и компьютер должны быть в одной Wi‑Fi сети. Нужен LiDAR.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Room Live")
            .fullScreenCover(isPresented: $showScan) {
                ScanView(host: host, sessionCode: code) {
                    showScan = false
                    status = "Скан завершён или отменён"
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
