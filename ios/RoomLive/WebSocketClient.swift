import Foundation

enum WebSocketError: LocalizedError {
    case badURL
    case notConnected

    var errorDescription: String? {
        switch self {
        case .badURL: return "Некорректный адрес сервера"
        case .notConnected: return "WebSocket не подключён"
        }
    }
}

final class WebSocketClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sessionCode: String = ""
    var onStatus: ((String) -> Void)?

    func connect(hostPort: String, sessionCode: String) throws {
        disconnect()
        self.sessionCode = sessionCode.uppercased()

        var raw = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("http://") { raw = String(raw.dropFirst(7)) }
        if raw.hasPrefix("https://") { raw = String(raw.dropFirst(8)) }
        if raw.hasPrefix("ws://") { raw = String(raw.dropFirst(5)) }
        if raw.hasPrefix("wss://") { raw = String(raw.dropFirst(6)) }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "ws://\(raw)") else {
            throw WebSocketError.badURL
        }

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        onStatus?("подключение…")
        task.resume()
        listen()
        join()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func sendJSON(_ object: [String: Any]) {
        guard let task else {
            onStatus?("нет соединения")
            return
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.onStatus?("отправка: \(error.localizedDescription)")
            }
        }
    }

    private func join() {
        sendJSON([
            "type": "join",
            "role": "phone",
            "code": sessionCode,
        ])
        onStatus?("код \(sessionCode)")
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.onStatus?("связь: \(error.localizedDescription)")
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String {
                    switch type {
                    case "joined":
                        self.onStatus?("в сессии \(self.sessionCode)")
                    case "ack":
                        if let viewers = json["viewers"] as? Int {
                            self.onStatus?("зрителей: \(viewers)")
                        }
                    case "error":
                        let m = json["message"] as? String ?? "error"
                        self.onStatus?("ошибка: \(m)")
                    default:
                        break
                    }
                }
                self.listen()
            }
        }
    }
}

extension WebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onStatus?("WS открыт")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onStatus?("WS закрыт")
    }
}
