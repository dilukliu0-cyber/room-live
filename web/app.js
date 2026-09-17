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
scene.fog = new THREE.Fog(0x050706, 18, 45);

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
    scene.fog = new THREE.Fog(0x050706, 18, 45);
  } else {
    scene.fog.near = 18;
    scene.fog.far = 45;
  }
}

function upsertMeshChunk(chunk) {
  const id = chunk.id || `mesh-${meshChunkMap.size}`;
  const verts = chunk.vertices;
  const indices = chunk.indices;
  const colors = chunk.colors;
  if (!Array.isArray(verts) || verts.length < 9) return;

  const positions = new Float32Array(verts.length);
  for (let i = 0; i < verts.length; i++) positions[i] = verts[i];

  let root = meshChunkMap.get(id);
  if (!root) {
    const geo = new THREE.BufferGeometry();
    const mat = new THREE.MeshBasicMaterial({
      vertexColors: true,
      side: THREE.DoubleSide,
    });
    root = new THREE.Mesh(geo, mat);
    root.castShadow = false;
    root.receiveShadow = true;
    meshGroup.add(root);
    meshChunkMap.set(id, root);
  }

  const geo = root.geometry;
  // Dispose previous GPU buffers so setAttribute does not leave stale data.
  const prevPos = geo.getAttribute('position');
  const prevCol = geo.getAttribute('color');
  const prevIdx = geo.getIndex();
  if (prevPos) geo.deleteAttribute('position');
  if (prevCol) geo.deleteAttribute('color');
  if (prevIdx) geo.setIndex(null);
  if (prevPos && prevPos.array !== positions) prevPos.array = null;
  if (prevCol) prevCol.array = null;

  geo.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  geo.attributes.position.needsUpdate = true;

  if (Array.isArray(colors) && colors.length >= positions.length) {
    const cols = new Float32Array(colors.length);
    for (let i = 0; i < colors.length; i++) cols[i] = colors[i];
    geo.setAttribute('color', new THREE.BufferAttribute(cols, 3));
  } else {
    const cols = new Float32Array(positions.length);
    for (let i = 0; i < cols.length; i += 3) {
      cols[i] = 0.55;
      cols[i + 1] = 0.58;
      cols[i + 2] = 0.6;
    }
    geo.setAttribute('color', new THREE.BufferAttribute(cols, 3));
  }
  geo.attributes.color.needsUpdate = true;

  if (Array.isArray(indices) && indices.length >= 3) {
    const maxIndex = positions.length / 3 - 1;
    const safe = [];
    for (let i = 0; i + 2 < indices.length; i += 3) {
      const a = indices[i], b = indices[i + 1], c = indices[i + 2];
      if (a > maxIndex || b > maxIndex || c > maxIndex) continue;
      safe.push(a, b, c);
    }
    if (safe.length >= 3) {
      const IndexArray = maxIndex > 65535 ? Uint32Array : Uint16Array;
      geo.setIndex(new IndexArray(safe));
      if (geo.index) geo.index.needsUpdate = true;
    } else {
      geo.setIndex(null);
    }
  } else {
    geo.setIndex(null);
  }

  geo.computeVertexNormals();
  geo.computeBoundingBox();
  geo.computeBoundingSphere();
}

function applyMeshPayload(msg) {
  const chunks = msg.chunks || [];
  for (const ch of chunks) upsertMeshChunk(ch);
  meshUpdateCount += 1;

  // Fog can hide mesh; disable while LiDAR is present.
  if (meshChunkMap.size > 0 && scene.fog) {
    scene.fog = null;
  }

  const nV = [...meshChunkMap.values()].reduce((acc, m) => {
    const attr = m.geometry?.getAttribute('position');
    return acc + (attr ? attr.count : 0);
  }, 0);
  metaEl.textContent = `LiDAR mesh · чанков: ${meshChunkMap.size} · вершин: ${nV}`;
  const now = performance.now();
  // First update: fit immediately; then first few aggressively; then ~1.2s.
  const isFirst = meshUpdateCount <= 1;
  const fitEvery = isFirst ? 0 : (meshUpdateCount < 8 ? 400 : 1200);
  if (isFirst || now - lastFitAt > fitEvery) {
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

    switch (msg.type) {
      case 'session_created':
      case 'joined':
        sessionCode = msg.code;
        codeEl.textContent = sessionCode;
        metaEl.textContent = msg.phoneConnected
          ? 'iPhone подключён'
          : 'ожидание iPhone…';
        break;
      case 'phone_joined':
        clearRoom();
        metaEl.textContent = 'iPhone подключён';
        setStatus('сканирование', 'ok');
        break;
      case 'phone_left':
        metaEl.textContent = 'iPhone отключён';
        setStatus('онлайн', 'ok');
        break;
      case 'room_update':
      case 'room_final':
        applyRoomPayload(msg);
        if (msg.type === 'room_final') setStatus('скан завершён', 'ok');
        break;
      case 'mesh_update':
        meshUpdateCount += 1;
        applyMeshPayload(msg);
        setStatus(`LiDAR live · ${meshChunkMap.size} chunks · #${meshUpdateCount}`, 'ok');
        console.log('[room-live] mesh_update', (msg.chunks||[]).length, 'chunks');
        break;
      case 'error':
        setStatus(`ошибка: ${msg.message}`, 'err');
        break;
      default:
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

connect(null);
