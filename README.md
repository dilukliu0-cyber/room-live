# Room Live

**Живое сканирование комнаты:** iPhone (RoomPlan) → WebSocket → сайт с Three.js.

Сайт показывает 3D-комнату в реальном времени. Приложение на iPhone стримит стены, двери, окна и мебель.

---

## Быстрый старт

```bash
cd /workspace/room-live/server
npm install
npm start
```

Откройте в браузере: **http://localhost:8787** (или `http://<LAN-IP>:8787` с телефона/других устройств).

Нажмите **«Демо»** — комната соберётся по частям без iPhone.

Порт по умолчанию: **8787** (`PORT=8787`).

### iOS

См. [`ios/README.md`](ios/README.md): нужен физический iPhone с LiDAR, Xcode на Mac, камера + локальная сеть. В приложении введите `192.168.x.x:8787` и 4-символьный код с сайта. WebSocket: `ws://…`.

---

## Структура

```
room-live/
  README.md
  package.json
  server/          Express + WS-реле
  web/             Three.js вьюер
  ios/RoomLive/    SwiftUI + RoomPlan
```

## Сервер

- Статика из `../web`
- WebSocket на том же порту
- CORS включён
- Роли: `phone` / `web`
- 4-символьные коды сессий
- `room_update` / `room_final` с телефона → всем web в сессии

### WS API (кратко)

| type | кто | описание |
|------|-----|----------|
| `create_session` | web | создать код |
| `join` `{role, code}` | phone/web | войти в сессию |
| `room_update` / `room_final` | phone | геометрия комнаты |
| `ping` | любой | → `pong` |

## Схема комнаты

```json
{
  "type": "room_update",
  "walls": [
    {
      "id": "wall-0",
      "width": 4.0,
      "height": 2.5,
      "transform": [16 floats, column-major],
      "position": { "x": 0, "y": 1.25, "z": -1.5 },
      "rotationY": 0
    }
  ],
  "doors": [{ "id": "door-0", "width": 0.9, "height": 2.1, "position": {...}, "rotationY": 0 }],
  "windows": [{ "id": "window-0", "width": 1.4, "height": 1.2, "position": {...}, "rotationY": 0 }],
  "objects": [
    {
      "id": "obj-0",
      "category": "table",
      "width": 1.2,
      "height": 0.75,
      "depth": 0.7,
      "position": { "x": 0, "y": 0.375, "z": 0 },
      "rotationY": 0.1
    }
  ]
}
```

`transform` — опционально (16 float, column-major для Three.js). Иначе достаточно `position` + `rotationY`.

На вебе: стены — тонкие боксы, двери/окна — цветные панели, мебель — боксы с подписями.

---

## English (short)

Live room scan MVP: RoomPlan on iPhone streams JSON over WebSocket; browser rebuilds the room with Three.js. Run `npm install && npm start` in `server/`, open port **8787**, use **Demo** without a phone. Physical LiDAR iPhone + Xcode required for real scans (`ios/README.md`). Session codes are 4 characters; roles `phone` / `web`.
