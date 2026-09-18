# Room Live

**Живое сканирование комнаты:** iPhone (LiDAR) → WebSocket → сайт с Three.js.

Два режима на телефоне:
1. **LiDAR mesh** (основной) — плотный цветной меш как «сфотографированный» скан, собирается на сайте кусок за куском (`mesh_update`).
2. **RoomPlan** — схематические стены / двери / окна / мебель (`room_update`).

Нужен **iPhone с LiDAR** (Pro / Pro Max или iPad Pro с LiDAR).

---

## Быстрый старт

```bash
cd server
npm install
npm start
```

Откройте в браузере: **http://localhost:8787** (или `http://<LAN-IP>:8787`).

Нажмите **«Демо»** — схематичная комната без iPhone.

Порт по умолчанию: **8787**.



## Редактор объектов (веб)

Справа панель **«Каталог»**: MacBook, стол, стул, лампа, монитор, растение (процедурные меши Three.js).

1. Выбери предмет в каталоге → режим размещения.
2. Кликни по полу / LiDAR-мешу (raycast, snap по Y).
3. Кликни объект — выделение; **Q/E** или кнопки — поворот; **Delete** / «Удалить» — удалить.
4. **Сохранить** / **Загрузить** — `localStorage`; **Скачать JSON** / **Загрузить JSON** — файл.

Меш комнаты (LiDAR) в MVP **не удаляется** — только объекты каталога. Поток `mesh_update` не затрагивается.

### iOS

См. [`ios/README.md`](ios/README.md). В приложении: хост `IP:8787` (подсказка `172.20.10.3:8787`) + 4-символьный код с сайта. Выберите **LiDAR mesh** для реального скана или **RoomPlan** для схемы.

---

## Структура

```
room-live/
  README.md
  package.json
  server/          Express + WS-реле (до ~8MB на сообщение)
  web/             Three.js вьюер (mesh + RoomPlan)
  ios/RoomLive/    SwiftUI + ARKit mesh / RoomPlan
```

## Сервер

- Статика из `../web`
- WebSocket на том же порту, `maxPayload` 8MB (плотный mesh)
- Роли: `phone` / `web`
- Типы: `room_update` / `room_final` / **`mesh_update`**

### WS API (кратко)

| type | кто | описание |
|------|-----|----------|
| `create_session` | web | создать код |
| `join` `{role, code}` | phone/web | войти в сессию |
| `room_update` / `room_final` | phone | схематичная геометрия RoomPlan |
| `mesh_update` | phone | плотный LiDAR mesh |
| `ping` | любой | → `pong` |

### mesh_update

```json
{
  "type": "mesh_update",
  "chunks": [
    {
      "id": "mesh-0",
      "vertices": [x,y,z, ...],
      "indices": [i0,i1,i2, ...],
      "colors": [r,g,b, ...]
    }
  ]
}
```

На вебе: `THREE.BufferGeometry` + `MeshStandardMaterial` с `vertexColors`, чанки обновляются по `id`.

---

## English (short)

Live room scan: **ARKit scene reconstruction** (`mesh (+ camera color sampling)`) streams dense colored meshes over WebSocket; browser rebuilds them with Three.js. RoomPlan parametric boxes remain as a secondary mode. Run `npm install && npm start` in `server/`, open port **8787**. Needs a physical **LiDAR iPhone**. Use **LiDAR mesh** in the app for a photographed/scanned look; **Demo** still shows the schematic room without a phone.

## Скачать IPA для iPhone

GitHub Actions → **Build IPA** → артефакт **RoomLive-unsigned.ipa**.  
Установка: Sideloadly / AltStore (подпись своим Apple ID).
