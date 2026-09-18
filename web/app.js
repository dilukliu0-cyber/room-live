import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const $ = (id) => document.getElementById(id);
const statusEl = $('status');
const codeEl = $('sessionCode');
const metaEl = $('meta');
const btnDemo = $('btnDemo');
const btnClear = $('btnClear');
const btnNew = $('btnNew');

const WALL_COLOR = 0x5dffb1;
const DOOR_COLOR = 0xffc857;
const WINDOW_COLOR = 0x7ec8ff;
const FURN_COLOR = 0x3d5a4c;
const OPENING_CATEGORIES = new Set(['door', 'opening', 'window']);

let ws = null;
let sessionCode = null;
let demoTimer = null;
let demoRunning = false;

// --- Three.js scene ---
const viewport = $('viewport');
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x050706);
scene.fog = null; // was Fog — hid dark LiDAR meshes

const camera = new THREE.PerspectiveCamera(55, 1, 0.05, 100);
camera.position.set(4.5, 3.2, 5.5);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.shadowMap.enabled = true;
viewport.appendChild(renderer.domElement);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.target.set(0, 1, 0);
controls.maxPolarAngle = Math.PI * 0.49;

const hemi = new THREE.HemisphereLight(0xb8fff0, 0x0a1210, 0.55);
scene.add(hemi);
const dir = new THREE.DirectionalLight(0xffffff, 0.85);
dir.position.set(5, 10, 4);
dir.castShadow = true;
scene.add(dir);
const fill = new THREE.DirectionalLight(0x5dffb1, 0.2);
fill.position.set(-4, 3, -2);
scene.add(fill);

const grid = new THREE.GridHelper(20, 40, 0x1a3d30, 0x0f1f18);
grid.position.y = 0;
scene.add(grid);

const roomGroup = new THREE.Group();
scene.add(roomGroup);

/** @type {Map<string, THREE.Object3D>} */
const entityMap = new Map();

/** @type {Map<string, THREE.Mesh>} */
const meshChunkMap = new Map();
const meshGroup = new THREE.Group();
scene.add(meshGroup);
/** @type {Map<string, THREE.Mesh>} */
const meshChunkMap = new Map();
const meshGroup = new THREE.Group();
scene.add(meshGroup);

/** Faint world-XZ tile grid helper (matches iOS tileSize). */
let tileGridHelper = null;
let currentTileSize = 1.0;

function ensureTileGridHelper(tileSize = 1.0) {
  const size = Number(tileSize) || 1.0;
  if (tileGridHelper && currentTileSize === size) return;
  if (tileGridHelper) {
    scene.remove(tileGridHelper);
    disposeObject(tileGridHelper);
    tileGridHelper = null;
  }
  currentTileSize = size;
  const extent = 20; // meters
  const divisions = Math.max(2, Math.round(extent / size));
  tileGridHelper = new THREE.GridHelper(extent, divisions, 0x2a4a3a, 0x152820);
  tileGridHelper.material.opacity = 0.35;
  tileGridHelper.material.transparent = true;
  tileGridHelper.position.y = 0.01;
  scene.add(tileGridHelper);
}

function removeTileMeshes(ids) {
  if (!Array.isArray(ids)) return;
  for (const id of ids) {
    const mesh = meshChunkMap.get(id);
    if (!mesh) continue;
    meshGroup.remove(mesh);
    disposeObject(mesh);
    meshChunkMap.delete(id);
  }
}

function applyMeshTilesPayload(msg) {
  const tileSize = msg.tileSize ?? 1.0;
  ensureTileGridHelper(tileSize);
  if (Array.isArray(msg.cleared) && msg.cleared.length) {
    removeTileMeshes(msg.cleared);
  }
  const tiles = msg.tiles || [];
  let applied = 0;
  for (const tile of tiles) {
    // Normalize to upsertMeshChunk shape (positions alias already supported).
    const chunk = {
      id: tile.id,
      positions: tile.positions || tile.vertices,
      vertices: tile.positions || tile.vertices,
      indices: tile.indices,
      colors: tile.colors,
    };
    if (upsertMeshChunk(chunk)) applied += 1;
  }
  meshUpdateCount += 1;
  scene.fog = null;

  const nV = [...meshChunkMap.values()].reduce((acc, m) => {
    const attr = m.geometry?.getAttribute('position');
    return acc + (attr ? attr.count : 0);
  }, 0);
  metaEl.textContent = `LiDAR квадраты · тайлов: ${meshChunkMap.size} · вершин: ${nV} · size ${tileSize}m`;
  setStatus(`квадраты live · in=${tiles.length} ok=${applied} · ${nV} verts`, 'ok');
  setDebug('mesh_tiles', tiles.length);
  const now = performance.now();
  if (meshUpdateCount <= 30 || now - lastFitAt > 600) {
    lastFitAt = now;
    fitCameraToMeshes();
  }
}


/** Catalog props (editor) — never mixed into LiDAR meshGroup */
const propsGroup = new THREE.Group();
scene.add(propsGroup);
let lastFitAt = 0;
let meshUpdateCount = 0;

function clearMeshes() {
  for (const mesh of meshChunkMap.values()) {
    meshGroup.remove(mesh);
    disposeObject(mesh);
  }
  meshChunkMap.clear();
  meshUpdateCount = 0;
  // Restore default fog when mesh cleared
  if (!scene.fog) {
    scene.fog = null; // was Fog — hid dark LiDAR meshes
  } else {
    scene.fog.near = 18;
    scene.fog.far = 45;
  }
}

function upsertMeshChunk(chunk) {
  const id = chunk.id || chunk.uuid || `mesh-${meshChunkMap.size}`;
  // Accept alternate field names from older/newer clients.
  const verts = chunk.vertices || chunk.positions || chunk.verts;
  const indices = chunk.indices || chunk.faces || chunk.tris;
  const colors = chunk.colors || chunk.vertexColors;
  if (!Array.isArray(verts) || verts.length < 9) {
    console.warn('[room-live] skip chunk', id, 'verts', verts && verts.length);
    return false;
  }

  const positions = new Float32Array(verts.length);
  for (let i = 0; i < verts.length; i++) positions[i] = Number(verts[i]) || 0;

  let root = meshChunkMap.get(id);
  if (!root) {
    const geo = new THREE.BufferGeometry();
    // White base * vertexColors — do NOT set a grey material color (it flattens).
    const mat = new THREE.MeshBasicMaterial({
      color: 0xffffff,
      vertexColors: true,
      side: THREE.DoubleSide,
    });
    root = new THREE.Mesh(geo, mat);
    root.frustumCulled = false;
    root.castShadow = false;
    root.receiveShadow = false;
    meshGroup.add(root);
    meshChunkMap.set(id, root);
  } else if (root.material) {
    root.material.vertexColors = true;
    root.material.color.set(0xffffff);
    root.material.needsUpdate = true;
  }

  const geo = root.geometry;
  geo.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  geo.attributes.position.needsUpdate = true;

  const cols = new Float32Array(positions.length);
  if (Array.isArray(colors) && colors.length >= positions.length) {
    for (let i = 0; i < positions.length; i += 3) {
      // Brighten slightly but preserve hue (no per-channel floor → grey crush).
      let r = Number(colors[i]) || 0;
      let g = Number(colors[i + 1]) || 0;
      let b = Number(colors[i + 2]) || 0;
      r *= 1.18; g *= 1.18; b *= 1.18;
      const maxC = Math.max(r, g, b, 1e-6);
      if (maxC > 1) { r /= maxC; g /= maxC; b /= maxC; }
      cols[i] = Math.min(1, Math.max(0, r));
      cols[i + 1] = Math.min(1, Math.max(0, g));
      cols[i + 2] = Math.min(1, Math.max(0, b));
    }
  } else {
    for (let i = 0; i < cols.length; i += 3) {
      cols[i] = 0.35; cols[i + 1] = 0.9; cols[i + 2] = 0.7; // mint = missing colors array
    }
  }
  geo.setAttribute('color', new THREE.BufferAttribute(cols, 3));
  geo.attributes.color.needsUpdate = true;

  // Detect near-zero variance (all ~grey) — camera sampling failed.
  let sum = 0, sum2 = 0, n = cols.length / 3;
  let minL = 1, maxL = 0;
  for (let i = 0; i < cols.length; i += 3) {
    const lum = 0.2126 * cols[i] + 0.7152 * cols[i + 1] + 0.0722 * cols[i + 2];
    sum += lum; sum2 += lum * lum;
    if (lum < minL) minL = lum;
    if (lum > maxL) maxL = lum;
  }
  const mean = sum / Math.max(1, n);
  const variance = sum2 / Math.max(1, n) - mean * mean;
  root.userData.colorVariance = variance;
  root.userData.colorRange = maxL - minL;
  root.userData.flatGrey = variance < 0.0008 && (maxL - minL) < 0.06;

  if (Array.isArray(indices) && indices.length >= 3) {
    const maxIndex = positions.length / 3 - 1;
    const safe = [];
    for (let i = 0; i + 2 < indices.length; i += 3) {
      const a = indices[i] | 0, b = indices[i + 1] | 0, c = indices[i + 2] | 0;
      if (a > maxIndex || b > maxIndex || c > maxIndex || a < 0 || b < 0 || c < 0) continue;
      safe.push(a, b, c);
    }
    if (safe.length >= 3) {
      const IndexArray = maxIndex > 65535 ? Uint32Array : Uint16Array;
      geo.setIndex(new THREE.BufferAttribute(new IndexArray(safe), 1));
      if (geo.index) geo.index.needsUpdate = true;
    } else {
      geo.setIndex(null);
    }
  } else {
    geo.setIndex(null);
  }

  geo.computeBoundingBox();
  geo.computeBoundingSphere();
  return true;
}

function applyMeshPayload(msg) {
  const chunks = msg.chunks || msg.meshes || [];
  let applied = 0;
  for (const ch of chunks) {
    if (upsertMeshChunk(ch)) applied += 1;
  }
  meshUpdateCount += 1;

  // Fog can hide mesh; disable while LiDAR is present.
  scene.fog = null;

  const nV = [...meshChunkMap.values()].reduce((acc, m) => {
    const attr = m.geometry?.getAttribute('position');
    return acc + (attr ? attr.count : 0);
  }, 0);
  const sample = chunks[0]?.vertices || chunks[0]?.positions;
  const sampleTxt = sample && sample.length >= 3
    ? ` · p0=(${Number(sample[0]).toFixed(2)},${Number(sample[1]).toFixed(2)},${Number(sample[2]).toFixed(2)})`
    : '';
  const flat = [...meshChunkMap.values()].filter((m) => m.userData.flatGrey).length;
  const colorWarn = flat > 0 && flat >= Math.ceil(meshChunkMap.size * 0.6);
  metaEl.textContent = colorWarn
    ? `LiDAR mesh · чанков: ${meshChunkMap.size} · вершин: ${nV} · цвет камеры не пришёл${sampleTxt}`
    : `LiDAR mesh · чанков: ${meshChunkMap.size} · вершин: ${nV}${sampleTxt}`;
  if (colorWarn) {
    setStatus('цвет камеры не пришёл', 'warn');
  } else {
    setStatus(`LiDAR live · in=${chunks.length} ok=${applied} · ${nV} verts`, 'ok');
  }
  setDebug('mesh_update', chunks.length);
  // Fit aggressively so first packets are on screen.
  const now = performance.now();
  if (meshUpdateCount <= 30 || now - lastFitAt > 600) {
    lastFitAt = now;
    fitCameraToMeshes();
  }
}

function fitCameraToMeshes() {
  if (meshChunkMap.size === 0) return;
  const box = new THREE.Box3();
  for (const m of meshChunkMap.values()) box.expandByObject(m);
  if (box.isEmpty()) return;
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  const radius = Math.max(size.length() * 0.5, 0.5);
  controls.target.copy(center);
  camera.position.set(center.x + radius * 1.2, center.y + radius * 0.8, center.z + radius * 1.2);
  camera.near = Math.max(0.05, radius / 100);
  camera.far = Math.max(100, radius * 20);
  camera.updateProjectionMatrix();
  controls.update();
}


function setStatus(text, kind = '') {
  statusEl.textContent = text;
  statusEl.className = 'status' + (kind ? ` ${kind}` : '');
}

const debugEl = $('debugLine');
const phoneBannerEl = $('phoneBanner');
let phoneConnected = false;

function setPhoneBanner(connected) {
  phoneConnected = !!connected;
  if (!phoneBannerEl) return;
  if (connected) {
    phoneBannerEl.textContent = 'Телефон подключён';
    phoneBannerEl.className = 'phone-banner ok';
  } else {
    phoneBannerEl.textContent = 'Телефон не подключён';
    phoneBannerEl.className = 'phone-banner warn';
  }
}

function setDebug(type, chunks) {
  if (!debugEl) return;
  const n = typeof chunks === 'number' ? chunks : '—';
  debugEl.textContent = `dbg: last=${type || '—'} · chunks=${n} · map=${meshChunkMap.size}`;
}

function resize() {
  const w = viewport.clientWidth;
  const h = viewport.clientHeight;
  camera.aspect = w / Math.max(h, 1);
  camera.updateProjectionMatrix();
  renderer.setSize(w, h, false);
}
window.addEventListener('resize', resize);
resize();

function animate() {
  requestAnimationFrame(animate);
  controls.update();
  renderer.render(scene, camera);
}
animate();

function disposeObject(obj) {
  obj.traverse((child) => {
    if (child.geometry) child.geometry.dispose();
    if (child.material) {
      if (Array.isArray(child.material)) child.material.forEach((m) => m.dispose());
      else child.material.dispose();
    }
  });
}

function clearRoom() {
  for (const obj of entityMap.values()) {
    roomGroup.remove(obj);
    disposeObject(obj);
  }
  entityMap.clear();
  clearMeshes();
  metaEl.textContent = 'сцена очищена';
}

function makeLabel(text) {
  const canvas = document.createElement('canvas');
  canvas.width = 256;
  canvas.height = 64;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = 'rgba(5,7,6,0.75)';
  ctx.roundRect?.(8, 8, 240, 48, 8);
  if (!ctx.roundRect) {
    ctx.fillRect(8, 8, 240, 48);
  } else {
    ctx.fill();
  }
  ctx.fillStyle = '#5dffb1';
  ctx.font = 'bold 28px system-ui, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(String(text).slice(0, 18), 128, 34);
  const tex = new THREE.CanvasTexture(canvas);
  const mat = new THREE.SpriteMaterial({ map: tex, transparent: true, depthTest: false });
  const sprite = new THREE.Sprite(mat);
  sprite.scale.set(1.2, 0.3, 1);
  return sprite;
}

function applyTransform(mesh, item) {
  if (Array.isArray(item.transform) && item.transform.length >= 16) {
    const m = new THREE.Matrix4();
    m.fromArray(item.transform);
    mesh.matrixAutoUpdate = false;
    mesh.matrix.copy(m);
    return;
  }
  mesh.matrixAutoUpdate = true;
  const p = item.position || {};
  mesh.position.set(p.x || 0, p.y || 0, p.z || 0);
  if (typeof item.rotationY === 'number') {
    mesh.rotation.set(0, item.rotationY, 0);
  }
}

function upsertWall(wall) {
  const id = wall.id || `wall-${entityMap.size}`;
  const width = wall.width || 1;
  const height = wall.height || 2.5;
  const thickness = wall.thickness || 0.08;

  let root = entityMap.get(id);
  if (!root) {
    const geo = new THREE.BoxGeometry(1, 1, 1);
    const mat = new THREE.MeshStandardMaterial({
      color: WALL_COLOR,
      metalness: 0.05,
      roughness: 0.7,
      transparent: true,
      opacity: 0.55,
      side: THREE.DoubleSide,
    });
    const mesh = new THREE.Mesh(geo, mat);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    root = new THREE.Group();
    root.add(mesh);
    root.userData.mesh = mesh;
    roomGroup.add(root);
    entityMap.set(id, root);
  }

  const mesh = root.userData.mesh;
  mesh.scale.set(width, height, thickness);
  // RoomPlan wall transform is typically center; if only position+rotationY, lift by half height
  if (!Array.isArray(wall.transform)) {
    const p = wall.position || { x: 0, y: height / 2, z: 0 };
    applyTransform(root, {
      position: { x: p.x, y: p.y ?? height / 2, z: p.z },
      rotationY: wall.rotationY || 0,
    });
  } else {
    applyTransform(root, wall);
  }
}

function upsertOpening(item, kind) {
  const id = item.id || `${kind}-${entityMap.size}`;
  const width = item.width || 0.9;
  const height = item.height || (kind === 'window' ? 1.2 : 2.1);
  const depth = item.depth || 0.06;
  const color = kind === 'window' ? WINDOW_COLOR : DOOR_COLOR;

  let root = entityMap.get(id);
  if (!root) {
    const geo = new THREE.BoxGeometry(1, 1, 1);
    const mat = new THREE.MeshStandardMaterial({
      color,
      metalness: 0.1,
      roughness: 0.4,
      transparent: true,
      opacity: 0.75,
      emissive: color,
      emissiveIntensity: 0.15,
    });
    const mesh = new THREE.Mesh(geo, mat);
    root = new THREE.Group();
    root.add(mesh);
    root.userData.mesh = mesh;
    const label = makeLabel(kind === 'window' ? 'окно' : 'дверь');
    label.position.y = 0.7;
    root.add(label);
    roomGroup.add(root);
    entityMap.set(id, root);
  }
  root.userData.mesh.scale.set(width, height, depth);
  if (!Array.isArray(item.transform)) {
    const p = item.position || { x: 0, y: height / 2, z: 0 };
    applyTransform(root, {
      position: { x: p.x, y: p.y ?? height / 2, z: p.z },
      rotationY: item.rotationY || 0,
    });
  } else {
    applyTransform(root, item);
  }
}

function upsertFurniture(obj) {
  const id = obj.id || `obj-${entityMap.size}`;
  const category = (obj.category || 'object').toLowerCase();
  if (OPENING_CATEGORIES.has(category)) {
    upsertOpening(obj, category === 'window' ? 'window' : 'door');
    return;
  }
  const w = obj.width || 0.6;
  const h = obj.height || 0.5;
  const d = obj.depth || 0.6;

  let root = entityMap.get(id);
  if (!root) {
    const geo = new THREE.BoxGeometry(1, 1, 1);
    const mat = new THREE.MeshStandardMaterial({
      color: FURN_COLOR,
      metalness: 0.05,
      roughness: 0.85,
    });
    const mesh = new THREE.Mesh(geo, mat);
    mesh.castShadow = true;
    root = new THREE.Group();
    root.add(mesh);
    root.userData.mesh = mesh;
    const label = makeLabel(category);
    label.position.y = 0.65;
    root.add(label);
    roomGroup.add(root);
    entityMap.set(id, root);
  }
  root.userData.mesh.scale.set(w, h, d);
  const p = obj.position || { x: 0, y: h / 2, z: 0 };
  applyTransform(root, {
    position: { x: p.x, y: p.y ?? h / 2, z: p.z },
    rotationY: obj.rotationY || 0,
    transform: obj.transform,
  });
  // refresh label text if category changed
  const sprite = root.children.find((c) => c.isSprite);
  if (sprite && sprite.material?.map?.image) {
    // keep existing label
  }
}

function applyRoomPayload(msg) {
  const walls = msg.walls || [];
  for (const w of walls) upsertWall(w);

  const doors = msg.doors || [];
  for (const d of doors) upsertOpening(d, 'door');

  const windows = msg.windows || [];
  for (const w of windows) upsertOpening(w, 'window');

  const objects = msg.objects || [];
  for (const o of objects) upsertFurniture(o);

  const nW = walls.length;
  const nO = objects.length + doors.length + windows.length;
  metaEl.textContent = `стены: ${nW} · объекты: ${nO}` +
    (msg.type === 'room_final' ? ' · финал' : '');
}

// --- WebSocket ---
function wsUrl() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${location.host}`;
}

function connect(codeToJoin) {
  if (ws) {
    try { ws.close(); } catch (_) {}
    ws = null;
  }
  setStatus('подключение…');
  setPhoneBanner(false);
  ws = new WebSocket(wsUrl());

  ws.addEventListener('open', () => {
    setStatus('онлайн', 'ok');
    if (codeToJoin) {
      ws.send(JSON.stringify({ type: 'join', role: 'web', code: codeToJoin }));
    } else {
      ws.send(JSON.stringify({ type: 'create_session' }));
    }
  });

  ws.addEventListener('message', (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }

    const t = msg.type;
    switch (t) {
      case 'hello':
        setDebug('hello', 0);
        break;
      case 'session_created':
      case 'session':
      case 'created':
      case 'joined':
        sessionCode = msg.code;
        codeEl.textContent = sessionCode;
        metaEl.textContent = msg.phoneConnected
          ? 'iPhone подключён'
          : 'ожидание iPhone…';
        setPhoneBanner(!!msg.phoneConnected);
        setDebug(t, 0);
        break;
      case 'phone_joined':
        // Clear prior room/mesh for a fresh phone scan; do not clear on unrelated events.
        clearRoom();
        metaEl.textContent = 'iPhone подключён';
        setStatus('сканирование', 'ok');
        setPhoneBanner(true);
        setDebug('phone_joined', 0);
        break;
      case 'phone_left':
        metaEl.textContent = 'iPhone отключён';
        setStatus('онлайн', 'ok');
        setPhoneBanner(false);
        setDebug('phone_left', 0);
        break;
      case 'room_update':
      case 'room_final':
        applyRoomPayload(msg);
        if (t === 'room_final') setStatus('скан завершён', 'ok');
        setDebug(t, 0);
        break;
      case 'mesh_update': {
        const nChunks = Array.isArray(msg.chunks) ? msg.chunks.length : 0;
        applyMeshPayload(msg);
        setDebug('mesh_update', nChunks);
        console.log('[room-live] mesh_update', nChunks, 'chunks');
        break;
      }
      case 'mesh_tiles': {
        const nTiles = Array.isArray(msg.tiles) ? msg.tiles.length : 0;
        applyMeshTilesPayload(msg);
        console.log('[room-live] mesh_tiles', nTiles, 'cleared', (msg.cleared || []).length);
        break;
      }
      case 'error':
        setStatus(`ошибка: ${msg.message}`, 'err');
        setDebug('error', 0);
        break;
      default:
        setDebug(t || '?', 0);
        break;
    }
  });

  ws.addEventListener('close', () => {
    setStatus('переподключение…', 'warn');
    setTimeout(() => connect(sessionCode), 1500);
  });

  ws.addEventListener('error', () => {
    setStatus('ошибка WS', 'err');
  });
}

btnNew.addEventListener('click', () => {
  stopDemo();
  clearRoom();
  sessionCode = null;
  codeEl.textContent = '····';
  connect(null);
});

btnClear.addEventListener('click', () => {
  clearRoom();
});

// --- Demo mode ---
function stopDemo() {
  demoRunning = false;
  if (demoTimer) {
    clearTimeout(demoTimer);
    demoTimer = null;
  }
  btnDemo.textContent = 'Демо';
}

function demoChunks() {
  // Progressive rectangular room ~4x3m with openings + furniture
  const chunks = [
    {
      type: 'room_update',
      walls: [
        { id: 'w1', width: 4, height: 2.5, position: { x: 0, y: 1.25, z: -1.5 }, rotationY: 0 },
      ],
      objects: [],
    },
    {
      type: 'room_update',
      walls: [
        { id: 'w1', width: 4, height: 2.5, position: { x: 0, y: 1.25, z: -1.5 }, rotationY: 0 },
        { id: 'w2', width: 3, height: 2.5, position: { x: 2, y: 1.25, z: 0 }, rotationY: Math.PI / 2 },
      ],
      objects: [],
    },
    {
      type: 'room_update',
      walls: [
        { id: 'w1', width: 4, height: 2.5, position: { x: 0, y: 1.25, z: -1.5 }, rotationY: 0 },
        { id: 'w2', width: 3, height: 2.5, position: { x: 2, y: 1.25, z: 0 }, rotationY: Math.PI / 2 },
        { id: 'w3', width: 4, height: 2.5, position: { x: 0, y: 1.25, z: 1.5 }, rotationY: 0 },
      ],
      doors: [
        { id: 'd1', width: 0.9, height: 2.1, position: { x: -0.8, y: 1.05, z: 1.5 }, rotationY: 0 },
      ],
      objects: [],
    },
    {
      type: 'room_update',
      walls: [
        { id: 'w1', width: 4, height: 2.5, position: { x: 0, y: 1.25, z: -1.5 }, rotationY: 0 },
        { id: 'w2', width: 3, height: 2.5, position: { x: 2, y: 1.25, z: 0 }, rotationY: Math.PI / 2 },
        { id: 'w3', width: 4, height: 2.5, position: { x: 0, y: 1.25, z: 1.5 }, rotationY: 0 },
        { id: 'w4', width: 3, height: 2.5, position: { x: -2, y: 1.25, z: 0 }, rotationY: Math.PI / 2 },
      ],
      doors: [
        { id: 'd1', width: 0.9, height: 2.1, position: { x: -0.8, y: 1.05, z: 1.5 }, rotationY: 0 },
      ],
      windows: [
        { id: 'win1', width: 1.4, height: 1.2, position: { x: 0.5, y: 1.5, z: -1.5 }, rotationY: 0 },
      ],
      objects: [
        { id: 't1', category: 'table', width: 1.2, height: 0.75, depth: 0.7, position: { x: 0.2, y: 0.375, z: 0.1 }, rotationY: 0.15 },
      ],
    },
    {
      type: 'room_final',
      walls: [
        { id: 'w1', width: 4, height: 2.5, position: { x: 0, y: 1.25, z: -1.5 }, rotationY: 0 },
        { id: 'w2', width: 3, height: 2.5, position: { x: 2, y: 1.25, z: 0 }, rotationY: Math.PI / 2 },
        { id: 'w3', width: 4, height: 2.5, position: { x: 0, y: 1.25, z: 1.5 }, rotationY: 0 },
        { id: 'w4', width: 3, height: 2.5, position: { x: -2, y: 1.25, z: 0 }, rotationY: Math.PI / 2 },
      ],
      doors: [
        { id: 'd1', width: 0.9, height: 2.1, position: { x: -0.8, y: 1.05, z: 1.5 }, rotationY: 0 },
      ],
      windows: [
        { id: 'win1', width: 1.4, height: 1.2, position: { x: 0.5, y: 1.5, z: -1.5 }, rotationY: 0 },
      ],
      objects: [
        { id: 't1', category: 'table', width: 1.2, height: 0.75, depth: 0.7, position: { x: 0.2, y: 0.375, z: 0.1 }, rotationY: 0.15 },
        { id: 'c1', category: 'chair', width: 0.45, height: 0.9, depth: 0.5, position: { x: 0.2, y: 0.45, z: 0.75 }, rotationY: Math.PI },
        { id: 's1', category: 'sofa', width: 1.8, height: 0.8, depth: 0.85, position: { x: -1.1, y: 0.4, z: -0.3 }, rotationY: Math.PI / 2 },
        { id: 'st1', category: 'storage', width: 1.0, height: 1.8, depth: 0.4, position: { x: 1.5, y: 0.9, z: -0.9 }, rotationY: 0 },
      ],
    },
  ];
  return chunks;
}

function runDemo() {
  if (demoRunning) {
    stopDemo();
    return;
  }
  demoRunning = true;
  btnDemo.textContent = 'Стоп демо';
  clearRoom();
  setStatus('демо', 'ok');
  metaEl.textContent = 'симуляция скана…';

  const chunks = demoChunks();
  let i = 0;

  const step = () => {
    if (!demoRunning) return;
    if (i >= chunks.length) {
      stopDemo();
      setStatus('демо завершено', 'ok');
      return;
    }
    applyRoomPayload(chunks[i]);
    i += 1;
    demoTimer = setTimeout(step, 700);
  };
  step();
}

btnDemo.addEventListener('click', runDemo);

// =============================================================================
// Catalog / room editor (props only — LiDAR mesh is not deletable)
// =============================================================================

const PROPS_STORAGE_KEY = 'room-live-props-v1';
const ROTATE_STEP = Math.PI / 8;

const CATALOG = [
  { id: 'macbook', name: 'MacBook', icon: '💻', desc: 'ноутбук' },
  { id: 'table', name: 'Стол', icon: '🪑', desc: 'письменный стол' },
  { id: 'chair', name: 'Стул', icon: '💺', desc: 'офисный стул' },
  { id: 'lamp', name: 'Лампа', icon: '💡', desc: 'настольная лампа' },
  { id: 'monitor', name: 'Монитор', icon: '🖥️', desc: 'экран' },
  { id: 'plant', name: 'Растение', icon: '🌿', desc: 'горшок' },
];

const raycaster = new THREE.Raycaster();
const pointerNdc = new THREE.Vector2();
const _box = new THREE.Box3();
const _size = new THREE.Vector3();

let placeCatalogId = null;
/** @type {THREE.Object3D | null} */
let selectedProp = null;
let pointerDown = null;

const catalogGrid = $('catalogGrid');
const selectionInfo = $('selectionInfo');
const placeHintEl = $('placeHint');
const btnRotateLeft = $('btnRotateLeft');
const btnRotateRight = $('btnRotateRight');
const btnDeleteProp = $('btnDeleteProp');
const btnCancelPlace = $('btnCancelPlace');
const btnSaveProps = $('btnSaveProps');
const btnLoadProps = $('btnLoadProps');
const btnDownloadJson = $('btnDownloadJson');
const btnUploadJson = $('btnUploadJson');
const jsonFileInput = $('jsonFileInput');

function mat(color, opts = {}) {
  return new THREE.MeshStandardMaterial({
    color,
    metalness: opts.metalness ?? 0.15,
    roughness: opts.roughness ?? 0.55,
    emissive: opts.emissive ?? 0x000000,
    emissiveIntensity: opts.emissiveIntensity ?? 0,
  });
}

function buildCatalogMesh(catalogId) {
  const root = new THREE.Group();
  root.userData.kind = 'catalog-prop';
  root.userData.catalogId = catalogId;

  switch (catalogId) {
    case 'macbook': {
      const base = new THREE.Mesh(new THREE.BoxGeometry(0.32, 0.012, 0.22), mat(0xc8ccd0, { metalness: 0.55, roughness: 0.35 }));
      base.position.y = 0.006;
      const screen = new THREE.Mesh(new THREE.BoxGeometry(0.32, 0.2, 0.008), mat(0x1a1f24, { metalness: 0.4, roughness: 0.4 }));
      screen.position.set(0, 0.11, -0.105);
      screen.rotation.x = -0.18;
      const display = new THREE.Mesh(new THREE.PlaneGeometry(0.28, 0.17), mat(0x4aa3ff, { emissive: 0x2266aa, emissiveIntensity: 0.35, roughness: 0.3 }));
      display.position.set(0, 0.11, -0.1);
      display.rotation.x = -0.18;
      root.add(base, screen, display);
      break;
    }
    case 'table': {
      const top = new THREE.Mesh(new THREE.BoxGeometry(1.2, 0.04, 0.7), mat(0x8b5a2b, { roughness: 0.75 }));
      top.position.y = 0.74;
      root.add(top);
      const legGeo = new THREE.BoxGeometry(0.05, 0.72, 0.05);
      const legMat = mat(0x3a2a1a, { roughness: 0.85 });
      for (const [x, z] of [[-0.52, -0.28], [0.52, -0.28], [-0.52, 0.28], [0.52, 0.28]]) {
        const leg = new THREE.Mesh(legGeo, legMat);
        leg.position.set(x, 0.36, z);
        root.add(leg);
      }
      break;
    }
    case 'chair': {
      const seat = new THREE.Mesh(new THREE.BoxGeometry(0.45, 0.05, 0.45), mat(0x2c4a3e));
      seat.position.y = 0.45;
      const back = new THREE.Mesh(new THREE.BoxGeometry(0.45, 0.45, 0.05), mat(0x2c4a3e));
      back.position.set(0, 0.7, -0.2);
      const legGeo = new THREE.CylinderGeometry(0.02, 0.02, 0.45, 8);
      const legMat = mat(0x222222, { metalness: 0.5, roughness: 0.4 });
      for (const [x, z] of [[-0.16, -0.16], [0.16, -0.16], [-0.16, 0.16], [0.16, 0.16]]) {
        const leg = new THREE.Mesh(legGeo, legMat);
        leg.position.set(x, 0.225, z);
        root.add(leg);
      }
      root.add(seat, back);
      break;
    }
    case 'lamp': {
      const base = new THREE.Mesh(new THREE.CylinderGeometry(0.08, 0.1, 0.03, 16), mat(0x333333, { metalness: 0.6 }));
      base.position.y = 0.015;
      const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.012, 0.012, 0.45, 8), mat(0x888888, { metalness: 0.7 }));
      pole.position.y = 0.25;
      const shade = new THREE.Mesh(new THREE.CylinderGeometry(0.12, 0.16, 0.14, 16, 1, true), mat(0xffe0a0, { emissive: 0xffaa44, emissiveIntensity: 0.45, roughness: 0.6, metalness: 0 }));
      shade.position.y = 0.52;
      const bulb = new THREE.Mesh(new THREE.SphereGeometry(0.04, 12, 12), mat(0xfff2c8, { emissive: 0xffcc66, emissiveIntensity: 0.8 }));
      bulb.position.y = 0.48;
      root.add(base, pole, shade, bulb);
      break;
    }
    case 'monitor': {
      const stand = new THREE.Mesh(new THREE.BoxGeometry(0.18, 0.02, 0.12), mat(0x222222));
      stand.position.y = 0.01;
      const neck = new THREE.Mesh(new THREE.BoxGeometry(0.04, 0.18, 0.03), mat(0x222222));
      neck.position.y = 0.11;
      const bezel = new THREE.Mesh(new THREE.BoxGeometry(0.55, 0.34, 0.03), mat(0x1a1a1a, { metalness: 0.3 }));
      bezel.position.y = 0.35;
      const screen = new THREE.Mesh(new THREE.PlaneGeometry(0.5, 0.29), mat(0x3d7eff, { emissive: 0x1a4aaa, emissiveIntensity: 0.4 }));
      screen.position.set(0, 0.35, 0.017);
      root.add(stand, neck, bezel, screen);
      break;
    }
    case 'plant': {
      const pot = new THREE.Mesh(new THREE.CylinderGeometry(0.1, 0.08, 0.14, 12), mat(0xb5674a, { roughness: 0.9 }));
      pot.position.y = 0.07;
      const soil = new THREE.Mesh(new THREE.CylinderGeometry(0.09, 0.09, 0.02, 12), mat(0x3a2a1a));
      soil.position.y = 0.14;
      const leafMat = mat(0x3d9b5f, { roughness: 0.7 });
      for (let i = 0; i < 5; i++) {
        const leaf = new THREE.Mesh(new THREE.SphereGeometry(0.08, 10, 10), leafMat);
        const a = (i / 5) * Math.PI * 2;
        leaf.position.set(Math.cos(a) * 0.07, 0.28 + (i % 2) * 0.06, Math.sin(a) * 0.07);
        leaf.scale.set(1, 1.35, 0.7);
        root.add(leaf);
      }
      const top = new THREE.Mesh(new THREE.SphereGeometry(0.1, 10, 10), leafMat);
      top.position.y = 0.4;
      root.add(pot, soil, top);
      break;
    }
    default: {
      const box = new THREE.Mesh(new THREE.BoxGeometry(0.4, 0.4, 0.4), mat(0x5dffb1));
      box.position.y = 0.2;
      root.add(box);
    }
  }

  root.traverse((c) => {
    if (c.isMesh) {
      c.castShadow = true;
      c.receiveShadow = true;
      c.userData.propRoot = root;
    }
  });
  return root;
}

function getPropRootFromHit(obj) {
  let o = obj;
  while (o) {
    if (o.userData?.kind === 'catalog-prop') return o;
    o = o.parent;
  }
  return null;
}

function setPlaceMode(catalogId) {
  placeCatalogId = catalogId;
  if (catalogId) {
    selectProp(null);
    viewport.classList.add('placing');
    placeHintEl?.classList.remove('hidden');
    placeHintEl.textContent = `Размещение: ${CATALOG.find((c) => c.id === catalogId)?.name || catalogId} — клик по полу / мешу`;
  } else {
    viewport.classList.remove('placing');
    placeHintEl?.classList.add('hidden');
  }
  refreshCatalogButtons();
}

function refreshCatalogButtons() {
  if (!catalogGrid) return;
  for (const btn of catalogGrid.querySelectorAll('.catalog-item')) {
    btn.classList.toggle('selected', btn.dataset.id === placeCatalogId);
  }
}

function setSelectionHighlight(prop, on) {
  if (!prop) return;
  prop.traverse((c) => {
    if (!c.isMesh || !c.material) return;
    const mats = Array.isArray(c.material) ? c.material : [c.material];
    for (const m of mats) {
      if (!m.emissive) continue;
      if (on) {
        if (c.userData._savedEmissive == null) {
          c.userData._savedEmissive = m.emissive.getHex();
          c.userData._savedEmissiveIntensity = m.emissiveIntensity ?? 0;
        }
        m.emissive.setHex(0x5dffb1);
        m.emissiveIntensity = Math.max(0.45, (c.userData._savedEmissiveIntensity || 0) + 0.35);
      } else if (c.userData._savedEmissive != null) {
        m.emissive.setHex(c.userData._savedEmissive);
        m.emissiveIntensity = c.userData._savedEmissiveIntensity || 0;
        delete c.userData._savedEmissive;
        delete c.userData._savedEmissiveIntensity;
      }
    }
  });
}

function selectProp(prop) {
  if (selectedProp && selectedProp !== prop) setSelectionHighlight(selectedProp, false);
  selectedProp = prop;
  if (selectedProp) setSelectionHighlight(selectedProp, true);
  if (selectionInfo) {
    if (!selectedProp) {
      selectionInfo.textContent = 'ничего не выбрано';
    } else {
      const cat = CATALOG.find((c) => c.id === selectedProp.userData.catalogId);
      selectionInfo.textContent = cat ? `${cat.name} · поворот ${(selectedProp.rotation.y * 180 / Math.PI).toFixed(0)}°` : selectedProp.userData.catalogId;
    }
  }
}

function floorSnapY(prop, hitY) {
  _box.setFromObject(prop);
  _box.getSize(_size);
  // After setFromObject, min.y is world; we want bottom on hitY
  const worldMinY = _box.min.y;
  const dy = hitY - worldMinY;
  prop.position.y += dy;
}

function placePropAt(point, catalogId) {
  const prop = buildCatalogMesh(catalogId);
  prop.position.set(point.x, point.y, point.z);
  propsGroup.add(prop);
  // First place at hit, then snap bottom to hit Y (floor snap)
  floorSnapY(prop, point.y);
  selectProp(prop);
  persistPropsLocal();
  return prop;
}

function deleteSelectedProp() {
  if (!selectedProp) return;
  const p = selectedProp;
  selectProp(null);
  propsGroup.remove(p);
  disposeObject(p);
  persistPropsLocal();
}

function rotateSelected(dir) {
  if (!selectedProp) return;
  selectedProp.rotation.y += dir * ROTATE_STEP;
  selectProp(selectedProp); // refresh label
  persistPropsLocal();
}

function serializeProps() {
  const items = [];
  for (const child of propsGroup.children) {
    if (child.userData?.kind !== 'catalog-prop') continue;
    items.push({
      catalogId: child.userData.catalogId,
      position: { x: child.position.x, y: child.position.y, z: child.position.z },
      rotationY: child.rotation.y,
    });
  }
  return { version: 1, props: items };
}

function clearAllProps() {
  selectProp(null);
  for (const child of [...propsGroup.children]) {
    propsGroup.remove(child);
    disposeObject(child);
  }
}

function loadPropsData(data) {
  if (!data || !Array.isArray(data.props)) throw new Error('Неверный формат JSON');
  clearAllProps();
  for (const item of data.props) {
    const id = item.catalogId;
    if (!id) continue;
    const prop = buildCatalogMesh(id);
    const p = item.position || {};
    prop.position.set(Number(p.x) || 0, Number(p.y) || 0, Number(p.z) || 0);
    prop.rotation.y = Number(item.rotationY) || 0;
    propsGroup.add(prop);
  }
}

function persistPropsLocal() {
  try {
    localStorage.setItem(PROPS_STORAGE_KEY, JSON.stringify(serializeProps()));
  } catch (_) { /* ignore quota */ }
}

function loadPropsLocal() {
  try {
    const raw = localStorage.getItem(PROPS_STORAGE_KEY);
    if (!raw) {
      setStatus('нет сохранённых объектов', 'warn');
      return;
    }
    loadPropsData(JSON.parse(raw));
    setStatus('объекты загружены', 'ok');
  } catch (e) {
    setStatus('ошибка загрузки', 'err');
  }
}

function downloadPropsJson() {
  const blob = new Blob([JSON.stringify(serializeProps(), null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'room-live-props.json';
  a.click();
  URL.revokeObjectURL(a.href);
}

function setPointerFromEvent(ev) {
  const rect = renderer.domElement.getBoundingClientRect();
  pointerNdc.x = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
  pointerNdc.y = -((ev.clientY - rect.top) / rect.height) * 2 + 1;
}

function pickPlacementPoint() {
  raycaster.setFromCamera(pointerNdc, camera);
  // Prefer floor/mesh: ignore existing props
  const meshTargets = [...meshChunkMap.values()];
  const roomTargets = [...entityMap.values()];
  const groundTargets = [grid, ...meshTargets, ...roomTargets];
  const hits = raycaster.intersectObjects(groundTargets, true);
  // Filter out anything under propsGroup just in case
  const usable = hits.filter((h) => {
    let o = h.object;
    while (o) {
      if (o === propsGroup || o.userData?.kind === 'catalog-prop') return false;
      o = o.parent;
    }
    return true;
  });
  if (usable.length) return usable[0].point.clone();
  // Fallback: intersect y=0 plane
  const plane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);
  const pt = new THREE.Vector3();
  if (raycaster.ray.intersectPlane(plane, pt)) return pt;
  return null;
}

function pickProp() {
  raycaster.setFromCamera(pointerNdc, camera);
  const hits = raycaster.intersectObjects(propsGroup.children, true);
  if (!hits.length) return null;
  return getPropRootFromHit(hits[0].object);
}

function onPointerDown(ev) {
  if (ev.button !== 0) return;
  pointerDown = { x: ev.clientX, y: ev.clientY, t: performance.now() };
}

function onPointerUp(ev) {
  if (ev.button !== 0 || !pointerDown) return;
  const dx = ev.clientX - pointerDown.x;
  const dy = ev.clientY - pointerDown.y;
  const dist = Math.hypot(dx, dy);
  pointerDown = null;
  if (dist > 6) return; // orbit drag

  setPointerFromEvent(ev);

  if (placeCatalogId) {
    const pt = pickPlacementPoint();
    if (pt) {
      placePropAt(pt, placeCatalogId);
      setPlaceMode(null);
    }
    return;
  }

  const prop = pickProp();
  selectProp(prop);
}

function buildCatalogUI() {
  if (!catalogGrid) return;
  catalogGrid.innerHTML = '';
  for (const item of CATALOG) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'catalog-item';
    btn.dataset.id = item.id;
    btn.innerHTML = `<span class="cat-icon">${item.icon}</span><span class="cat-name">${item.name}</span><span class="cat-desc">${item.desc}</span>`;
    btn.addEventListener('click', () => {
      if (placeCatalogId === item.id) setPlaceMode(null);
      else setPlaceMode(item.id);
    });
    catalogGrid.appendChild(btn);
  }
}

btnRotateLeft?.addEventListener('click', () => rotateSelected(1));
btnRotateRight?.addEventListener('click', () => rotateSelected(-1));
btnDeleteProp?.addEventListener('click', () => deleteSelectedProp());
btnCancelPlace?.addEventListener('click', () => setPlaceMode(null));
btnSaveProps?.addEventListener('click', () => {
  persistPropsLocal();
  setStatus('объекты сохранены', 'ok');
});
btnLoadProps?.addEventListener('click', () => loadPropsLocal());
btnDownloadJson?.addEventListener('click', () => downloadPropsJson());
btnUploadJson?.addEventListener('click', () => jsonFileInput?.click());
jsonFileInput?.addEventListener('change', async () => {
  const file = jsonFileInput.files?.[0];
  jsonFileInput.value = '';
  if (!file) return;
  try {
    const text = await file.text();
    loadPropsData(JSON.parse(text));
    persistPropsLocal();
    setStatus('JSON загружен', 'ok');
  } catch (e) {
    setStatus('ошибка JSON', 'err');
  }
});

window.addEventListener('keydown', (ev) => {
  const tag = (ev.target && ev.target.tagName) || '';
  if (tag === 'INPUT' || tag === 'TEXTAREA') return;
  if (ev.key === 'Escape') {
    setPlaceMode(null);
    return;
  }
  if (ev.key === 'Delete' || ev.key === 'Backspace') {
    if (selectedProp) {
      ev.preventDefault();
      deleteSelectedProp();
    }
    return;
  }
  if (ev.key === 'q' || ev.key === 'Q') rotateSelected(1);
  if (ev.key === 'e' || ev.key === 'E') rotateSelected(-1);
});

renderer.domElement.addEventListener('pointerdown', onPointerDown);
renderer.domElement.addEventListener('pointerup', onPointerUp);

buildCatalogUI();
// Restore last session props (does not affect mesh stream)
try {
  const raw = localStorage.getItem(PROPS_STORAGE_KEY);
  if (raw) loadPropsData(JSON.parse(raw));
} catch (_) { /* ignore */ }

connect(null);
