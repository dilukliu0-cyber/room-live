'use strict';

const path = require('path');
const http = require('http');
const express = require('express');
const cors = require('cors');
const { WebSocketServer } = require('ws');

const PORT = Number(process.env.PORT) || 8787;
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
/** Allow dense LiDAR mesh JSON (~1–2 MB per tick). */
const MAX_WS_PAYLOAD = 8 * 1024 * 1024;

const app = express();
app.use(cors());
app.use(express.json({ limit: '8mb' }));

const webRoot = path.join(__dirname, '..', 'web');
app.use(express.static(webRoot));

app.get('/health', (_req, res) => {
  res.json({ ok: true, sessions: sessions.size });
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server, maxPayload: MAX_WS_PAYLOAD });

/** @type {Map<string, { phone: import('ws').WebSocket | null, webs: Set<import('ws').WebSocket> }>} */
const sessions = new Map();

function generateCode() {
  let code = '';
  for (let i = 0; i < 4; i++) {
    code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
  }
  if (sessions.has(code)) return generateCode();
  return code;
}

function getOrCreateSession(code) {
  const key = String(code || '').toUpperCase();
  if (!sessions.has(key)) {
    sessions.set(key, { phone: null, webs: new Set() });
  }
  return { key, session: sessions.get(key) };
}

function cleanupSession(key) {
  const s = sessions.get(key);
  if (!s) return;
  if (!s.phone && s.webs.size === 0) {
    sessions.delete(key);
  }
}

function send(ws, obj) {
  if (ws && ws.readyState === 1) {
    ws.send(JSON.stringify(obj));
  }
}

function broadcastToWebs(session, obj, except = null) {
  const raw = JSON.stringify(obj);
  for (const client of session.webs) {
    if (client !== except && client.readyState === 1) {
      client.send(raw);
    }
  }
}

wss.on('connection', (ws) => {
  /** @type {{ role: string | null, code: string | null }} */
  const meta = { role: null, code: null };

  send(ws, { type: 'hello', message: 'room-live relay' });

  ws.on('message', (data) => {
    let msg;
    let rawText;
    try {
      rawText = typeof data === 'string' ? data : Buffer.isBuffer(data) ? data.toString('utf8') : String(data);
      msg = JSON.parse(rawText);
    } catch {
      send(ws, { type: 'error', message: 'invalid_json' });
      return;
    }

    const type = msg.type;

    if (type === 'create_session') {
      const code = generateCode();
      const { key, session } = getOrCreateSession(code);
      meta.role = 'web';
      meta.code = key;
      session.webs.add(ws);
      send(ws, { type: 'session_created', code: key, role: 'web' });
      return;
    }

    if (type === 'join') {
      const role = msg.role === 'phone' ? 'phone' : 'web';
      let code = String(msg.code || '').toUpperCase().trim();

      if (role === 'web' && !code) {
        code = generateCode();
      }

      if (!code || code.length !== 4) {
        send(ws, { type: 'error', message: 'invalid_code' });
        return;
      }

      if (meta.code) {
        leaveCurrent();
      }

      const { key, session } = getOrCreateSession(code);
      meta.role = role;
      meta.code = key;

      if (role === 'phone') {
        if (session.phone && session.phone !== ws && session.phone.readyState === 1) {
          send(session.phone, { type: 'error', message: 'replaced_by_new_phone' });
          try { session.phone.close(); } catch (_) {}
        }
        session.phone = ws;
        send(ws, {
          type: 'joined',
          code: key,
          role: 'phone',
          viewers: session.webs.size,
        });
        broadcastToWebs(session, { type: 'phone_joined', code: key });
      } else {
        session.webs.add(ws);
        send(ws, {
          type: 'joined',
          code: key,
          role: 'web',
          phoneConnected: !!(session.phone && session.phone.readyState === 1),
        });
        if (session.phone && session.phone.readyState === 1) {
          send(session.phone, { type: 'viewer_joined', viewers: session.webs.size });
        }
      }
      return;
    }

    if (type === 'room_update' || type === 'room_final') {
      if (meta.role !== 'phone' || !meta.code) {
        send(ws, { type: 'error', message: 'not_phone' });
        return;
      }
      const { session } = getOrCreateSession(meta.code);
      const payload = {
        type,
        walls: Array.isArray(msg.walls) ? msg.walls : [],
        objects: Array.isArray(msg.objects) ? msg.objects : [],
        floors: Array.isArray(msg.floors) ? msg.floors : undefined,
        doors: Array.isArray(msg.doors) ? msg.doors : undefined,
        windows: Array.isArray(msg.windows) ? msg.windows : undefined,
        ts: Date.now(),
      };
      broadcastToWebs(session, payload);
      send(ws, { type: 'ack', of: type, viewers: session.webs.size });
      return;
    }

    if (type === 'mesh_update') {
      if (meta.role !== 'phone' || !meta.code) {
        send(ws, { type: 'error', message: 'not_phone' });
        return;
      }
      const { session } = getOrCreateSession(meta.code);
      const chunkCount = Array.isArray(msg.chunks) ? msg.chunks.length : 0;
      // Forward raw phone JSON to webs — avoids double JSON.stringify memory blow.
      for (const client of session.webs) {
        if (client.readyState === 1) client.send(rawText);
      }
      console.log(`[room-live] mesh_update relay chunks=${chunkCount} viewers=${session.webs.size} code=${meta.code}`);
      send(ws, {
        type: 'ack',
        of: type,
        viewers: session.webs.size,
        chunks: chunkCount,
      });
      return;
    }

    if (type === 'ping') {
      send(ws, { type: 'pong', t: Date.now() });
      return;
    }

    send(ws, { type: 'error', message: 'unknown_type', got: type });
  });

  function leaveCurrent() {
    if (!meta.code) return;
    const s = sessions.get(meta.code);
    if (!s) {
      meta.code = null;
      meta.role = null;
      return;
    }
    if (meta.role === 'phone' && s.phone === ws) {
      s.phone = null;
      broadcastToWebs(s, { type: 'phone_left', code: meta.code });
    } else if (meta.role === 'web') {
      s.webs.delete(ws);
      if (s.phone && s.phone.readyState === 1) {
        send(s.phone, { type: 'viewer_left', viewers: s.webs.size });
      }
    }
    cleanupSession(meta.code);
    meta.code = null;
    meta.role = null;
  }

  ws.on('close', () => {
    leaveCurrent();
  });

  ws.on('error', () => {
    leaveCurrent();
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[room-live] http://0.0.0.0:${PORT}`);
  console.log(`[room-live] serving ${webRoot}`);
  console.log(`[room-live] WebSocket on same port (maxPayload ${MAX_WS_PAYLOAD})`);
});
