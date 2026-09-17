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
    /// True after a successful join send once the socket is open.
    private var didJoin = false
    var onStatus: ((String) -> Void)?

    func connect(hostPort: String, sessionCode: String) throws {
        disconnect()
        self.sessionCode = sessionCode.uppercased()
        self.didJoin = false

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
        // Do NOT join here — URLSessionWebSocketTask may drop/err sends before open.
        // join() runs from didOpenWithProtocol.
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        didJoin = false
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
        guard !sessionCode.isEmpty else { return }
        sendJSON([
            "type": "join",
            "role": "phone",
            "code": sessionCode,
        ])
        didJoin = true
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
                    case "hello":
                        // Server hello can arrive before join; join is gated on didOpen.
                        break
                    case "joined":
                        self.onStatus?("в сессии \(self.sessionCode)")
                    case "ack":
                        if let viewers = json["viewers"] as? Int {
                            self.onStatus?("зрителей: \(viewers)")
                        }
                    case "error":
                        let m = json["message"] as? String ?? "error"
                        self.onStatus?("ошибка: \(m)")
                        // If join was rejected before we were open, retry once socket is joined.
                        if !self.didJoin, m == "unknown_type" || m == "invalid_code" {
                            // leave for didOpen / manual reconnect
                        }
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
        if !didJoin {
            join()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        didJoin = false
        onStatus?("WS закрыт")
    }
}
