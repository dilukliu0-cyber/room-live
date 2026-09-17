# Room Live — iOS

Скан комнаты (RoomPlan) → стрим на сайт по WebSocket.

## Скачать готовый IPA (без Xcode у себя)

1. Открой репо на GitHub → вкладка **Actions**
2. Workflow **Build IPA** → дождись зелёной галочки (или запусти **Run workflow**)
3. Внизу run → **Artifacts** → скачай `RoomLive-unsigned-ipa`
4. Поставь через **Sideloadly** / AltStore / 3uTools и т.п. (подпись твоим Apple ID на компьютере)

> IPA **unsigned**: подпись делает Sideloadly при установке. Нужен обычный Apple ID. Срок на бесплатном ID обычно ~7 дней, потом переподписать.
> Нужен **реальный iPhone с LiDAR** (12 Pro / 13 Pro / 14 Pro / 15 Pro / Pro Max или iPad Pro с LiDAR).

## Если есть Mac + Xcode

Открой `RoomLive.xcodeproj` → Team → Run на iPhone.

## Сервер

На ПК: `cd server && npm start` (порт **8787**).  
В приложении: `IP-ПК:8787` + код с сайта `http://IP:8787`.
