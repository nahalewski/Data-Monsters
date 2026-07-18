// Minimal static server + WebSocket sync for the M511 Label Studio.
// Serves label-app/ and keeps one shared CSV document that every connected
// client edits in real time. No logins — whoever opens the page joins the doc.
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 3000;
const ROOT = path.join(__dirname, 'label-app');
const STORE = path.join(__dirname, 'shared-doc.json'); // best-effort persistence

const MIME = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript',
  '.csv': 'text/csv', '.png': 'image/png', '.svg': 'image/svg+xml',
  '.json': 'application/json', '.ico': 'image/x-icon', '.txt': 'text/plain',
};

// ---- Shared state: doc rows, per-cell comments, and chat ----
let doc = { rows: [], rev: 0 };
let comments = {}; // { "r,c": [ { name, text, ts } ] }
let chat = [];     // [ { name, text, ts, quote } ]  (capped)
const CHAT_MAX = 300;
try {
  if (fs.existsSync(STORE)) {
    const saved = JSON.parse(fs.readFileSync(STORE, 'utf8'));
    if (saved && Array.isArray(saved.rows)) doc = { rows: saved.rows, rev: saved.rev || 0 };
    if (saved && saved.comments && typeof saved.comments === 'object') comments = saved.comments;
    if (saved && Array.isArray(saved.chat)) chat = saved.chat.slice(-CHAT_MAX);
  }
} catch (e) { console.error('load store failed:', e.message); }

let saveTimer = null;
function persist() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    fs.writeFile(STORE, JSON.stringify({ rows: doc.rows, rev: doc.rev, comments, chat }),
      (e) => { if (e) console.error('persist failed:', e.message); });
  }, 500);
}

// ---- Static file serving ----
const server = http.createServer((req, res) => {
  let urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
  if (urlPath === '/') urlPath = '/index.html';
  const filePath = path.join(ROOT, path.normalize(urlPath));
  if (!filePath.startsWith(ROOT)) { res.writeHead(403); res.end('Forbidden'); return; }
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('Not found'); return; }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream',
      'Permissions-Policy': 'bluetooth=(self)',
      'Cache-Control': 'no-cache',
    });
    res.end(data);
  });
});

// ---- WebSocket sync ----
const wss = new WebSocketServer({ server, path: '/ws' });

function broadcast(obj, except) {
  const msg = JSON.stringify(obj);
  for (const c of wss.clients) if (c !== except && c.readyState === 1) c.send(msg);
}
function presence() { broadcast({ type: 'presence', count: wss.clients.size }); }

function normRows(rows) {
  if (!Array.isArray(rows)) return [];
  return rows.map(r => Array.isArray(r) ? r.map(x => (x == null ? '' : String(x))) : []);
}

function clip(s, n) { return String(s == null ? '' : s).slice(0, n); }

wss.on('connection', (ws) => {
  ws.send(JSON.stringify({ type: 'init', rows: doc.rows, rev: doc.rev, comments, chat }));
  presence();

  ws.on('message', (raw) => {
    let m;
    try { m = JSON.parse(raw); } catch { return; }
    if (m.type === 'cell') {
      const r = m.r | 0, c = m.c | 0;
      if (r < 0 || c < 0) return;
      while (doc.rows.length <= r) doc.rows.push([]);
      while (doc.rows[r].length <= c) doc.rows[r].push('');
      doc.rows[r][c] = m.value == null ? '' : String(m.value);
      doc.rev++;
      broadcast({ type: 'cell', r, c, value: doc.rows[r][c], rev: doc.rev }, ws);
      persist();
    } else if (m.type === 'rows') {
      doc.rows = normRows(m.rows);
      doc.rev++;
      broadcast({ type: 'doc', rows: doc.rows, rev: doc.rev }, ws);
      persist();
    } else if (m.type === 'comment') {
      const r = m.r | 0, c = m.c | 0;
      if (r < 0 || c < 0) return;
      const key = r + ',' + c;
      const comment = { name: clip(m.name, 40), text: clip(m.text, 500), ts: Date.now() };
      if (!comment.text) return;
      (comments[key] = comments[key] || []).push(comment);
      broadcast({ type: 'comment', r, c, comment }, ws); // sender already added it locally
      persist();
    } else if (m.type === 'chat') {
      const message = {
        name: clip(m.name, 40), text: clip(m.text, 1000), ts: Date.now(),
        quote: Array.isArray(m.quote) ? m.quote.slice(0, 60).map(q => ({
          ref: clip(q.ref, 24), value: clip(q.value, 200),
        })) : null,
      };
      if (!message.text && !(message.quote && message.quote.length)) return;
      chat.push(message);
      if (chat.length > CHAT_MAX) chat = chat.slice(-CHAT_MAX);
      broadcast({ type: 'chat', message }, ws); // sender already added it locally
      persist();
    }
  });

  ws.on('close', presence);
  ws.on('error', () => {});
});

server.listen(PORT, () => console.log('M511 Label Studio (with live sync) on :' + PORT));
