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
    /// Join frame was sent (may not be confirmed yet).
    private var joinSent = false
    /// Server confirmed `joined`.
    private var joinConfirmed = false
    private var joinAttempts = 0
    private var joinRetryTimer: Timer?
    var onStatus: ((String) -> Void)?

    func connect(hostPort: String, sessionCode: String) throws {
        disconnect()
        self.sessionCode = sessionCode.uppercased()
        self.joinSent = false
        self.joinConfirmed = false
        self.joinAttempts = 0

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
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        onStatus?("подключение к \(raw)…")
        task.resume()
        listen()
        startJoinRetries()
    }

    func disconnect() {
        joinRetryTimer?.invalidate()
        joinRetryTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        joinSent = false
        joinConfirmed = false
        joinAttempts = 0
    }

    var isJoined: Bool { joinConfirmed }

    func sendJSON(_ object: [String: Any]) {
        guard let task else {
            onStatus?("нет соединения — проверь IP и Локальную сеть")
            return
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            onStatus?("отправка: JSON invalid")
            return
        }
        task.send(.string(text)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.onStatus?("не достучался до сервера: \(error.localizedDescription)")
                }
            }
        }
    }

    private func join() {
        guard !sessionCode.isEmpty, !joinConfirmed else { return }
        joinAttempts += 1
        sendJSON([
            "type": "join",
            "role": "phone",
            "code": sessionCode,
        ])
        joinSent = true
        onStatus?("join \(sessionCode) #\(joinAttempts)…")
    }

    private func startJoinRetries() {
        joinRetryTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.joinConfirmed {
                self.joinRetryTimer?.invalidate()
                self.joinRetryTimer = nil
                return
            }
            if self.joinAttempts >= 15 {
                self.onStatus?("не достучался до сервера")
                self.joinRetryTimer?.invalidate()
                self.joinRetryTimer = nil
                return
            }
            self.join()
        }
        RunLoop.main.add(timer, forMode: .common)
        joinRetryTimer = timer
        // First attempt soon
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.join() }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.onStatus?("не достучался до сервера: \(error.localizedDescription)")
                }
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String {
                    DispatchQueue.main.async {
                        switch type {
                        case "hello":
                            if !self.joinConfirmed { self.join() }
                        case "joined":
                            self.joinConfirmed = true
                            self.joinSent = true
                            self.joinRetryTimer?.invalidate()
                            self.joinRetryTimer = nil
                            let viewers = json["viewers"] as? Int ?? 0
                            self.onStatus?("в сессии \(self.sessionCode) · зрителей: \(viewers)")
                        case "ack":
                            if let of = json["of"] as? String, (of == "mesh_update" || of == "mesh_tiles"),
                               let viewers = json["viewers"] as? Int {
                                if viewers == 0 {
                                    self.onStatus?("сайт не в сессии — открой тот же код")
                                } else {
                                    self.onStatus?("стрим ок · зрителей: \(viewers)")
                                }
                            } else if let viewers = json["viewers"] as? Int {
                                self.onStatus?("зрителей: \(viewers)")
                            }
                        case "error":
                            let m = json["message"] as? String ?? "error"
                            self.onStatus?("ошибка: \(m)")
                            if m == "not_phone" || m == "invalid_code" {
                                self.joinConfirmed = false
                                self.joinSent = false
                            }
                        default:
                            break
                        }
                    }
                }
                self.listen()
            }
        }
    }
}

extension WebSocketClient: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onStatus?("WS открыт")
        if !joinConfirmed { join() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        joinConfirmed = false
        joinSent = false
        onStatus?("WS закрыт")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onStatus?("не достучался до сервера: \(error.localizedDescription)")
        }
    }
}
