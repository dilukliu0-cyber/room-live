# Room Live — iOS (RoomPlan)

SwiftUI-приложение, которое сканирует комнату через **RoomPlan** и стримит упрощённую геометрию на веб-вьюер по WebSocket.

## Требования

- Физический **iPhone / iPad** с LiDAR (iPhone 12 Pro и новее, iPad Pro с LiDAR)
- **macOS** + **Xcode 15+** (RoomPlan, iOS 16+)
- iPhone и компьютер с сервером в одной Wi‑Fi сети
- Разрешение камеры / сканирования комнаты

> Симулятор Apple **не подходит** — RoomPlan требует реальное устройство.

## Создание проекта в Xcode

1. File → New → Project → **App** (iOS), Product Name: `RoomLive`, Interface: **SwiftUI**, Language: **Swift**
2. Deployment Target: **iOS 16.0+**
3. Скопируйте файлы из папки `RoomLive/` в target:
   - `RoomLiveApp.swift`
   - `ContentView.swift`
   - `ScanView.swift`
   - `RoomCaptureModel.swift`
   - `WebSocketClient.swift`
4. В Target → General → Frameworks добавьте **RoomPlan.framework** (Link)
5. Signing: выберите свою Team

## Info.plist / Privacy

В Target → Info добавьте (или правьте `Info.plist`):

| Key | Value (пример) |
|-----|----------------|
| `NSCameraUsageDescription` | Нужна камера для сканирования комнаты |
| `NSLocalNetworkUsageDescription` | Нужен доступ к локальной сети для стрима на Room Live сервер |
| `NSBonjourServices` (опционально) | `_http._tcp.` |
| App Transport / ATS | Для `ws://` и `http://` в LAN: добавьте исключение или используйте Info ключ `NSAppTransportSecurity` → `NSAllowsLocalNetworking` = `YES` |

Рекомендуется:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key>
  <true/>
</dict>
```

WebSocket: **`ws://HOST:8787`** (не wss), пока сервер без TLS.

## Запуск

1. На Mac/PC: `cd server && npm install && npm start` (порт **8787**)
2. Откройте в браузере `http://<IP-сервера>:8787` — появится 4-символьный код
3. На iPhone в приложении укажите хост `192.168.x.x:8787` и код сессии
4. Нажмите «Начать скан» — стены и объекты появятся на сайте в реальном времени

## Схема сообщений

См. корневой `README.md`. Телефон шлёт `join` (role: phone), затем `room_update` / `room_final`.

## English (short)

Physical LiDAR iPhone required. Create an Xcode SwiftUI app, add sources + RoomPlan, set camera + local network privacy strings, allow local networking ATS. Connect to `ws://LAN-IP:8787` with the 4-char session code from the website.
