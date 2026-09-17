# Room Live — iOS

Два режима:
- **LiDAR mesh** — ARKit `sceneReconstruction = .meshWithColor`, стрим плотного цветного меша (`mesh_update`).
- **RoomPlan** — схематические стены/мебель (`room_update`).

## Скачать готовый IPA (без Xcode у себя)

1. GitHub → **Actions** → **Build IPA**
2. Artifacts → `RoomLive-unsigned-ipa`
3. Sideloadly / AltStore (подпись своим Apple ID)

> Нужен **реальный iPhone с LiDAR** (12/13/14/15/16 Pro / Pro Max или iPad Pro с LiDAR).

## Если есть Mac + Xcode

Открой `RoomLive.xcodeproj` → Team → Run на iPhone.

## Сервер

На ПК: `cd server && npm start` (порт **8787**).  
В приложении: `IP-ПК:8787` + код с сайта. По умолчанию подсказка хоста: `172.20.10.3:8787`.
