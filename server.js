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
let chat = [];     // [ { name, text, ts, quote } ]  (capped, retained 5 days)
let weekKey = null;   // ISO date of the current week's Monday
let lastReport = null; // { forWeek, generatedAt }
let pinnedReport = null; // { forWeek, generatedAt, completed, notDone, commented }
let editLog = [];     // [ { name, text, ts } ]  attributed edit history
const CHAT_MAX = 300;
const EDIT_MAX = 250;
const CHAT_TTL_MS = 5 * 24 * 60 * 60 * 1000; // keep chat ~5 days (the work week)

// Monday (as YYYY-MM-DD) of the week containing d.
function weekKeyOf(d) {
  const x = new Date(d);
  const dow = (x.getDay() + 6) % 7; // 0 = Monday
  x.setHours(0, 0, 0, 0);
  x.setDate(x.getDate() - dow);
  return x.toISOString().slice(0, 10);
}
function pruneChat() {
  const cutoff = Date.now() - CHAT_TTL_MS;
  chat = chat.filter(m => (m.ts || 0) >= cutoff).slice(-CHAT_MAX);
}

try {
  if (fs.existsSync(STORE)) {
    const saved = JSON.parse(fs.readFileSync(STORE, 'utf8'));
    if (saved && Array.isArray(saved.rows)) doc = { rows: saved.rows, rev: saved.rev || 0 };
    if (saved && saved.comments && typeof saved.comments === 'object') comments = saved.comments;
    if (saved && Array.isArray(saved.chat)) chat = saved.chat.slice(-CHAT_MAX);
    if (saved && saved.weekKey) weekKey = saved.weekKey;
    if (saved && saved.lastReport) lastReport = saved.lastReport;
    if (saved && saved.pinnedReport) pinnedReport = saved.pinnedReport;
    if (saved && Array.isArray(saved.editLog)) editLog = saved.editLog.slice(-EDIT_MAX);
  }
} catch (e) { console.error('load store failed:', e.message); }
if (!weekKey) weekKey = weekKeyOf(new Date());
pruneChat();

let saveTimer = null;
function persist() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    fs.writeFile(STORE, JSON.stringify({ rows: doc.rows, rev: doc.rev, comments, chat, weekKey, lastReport, pinnedReport, editLog }),
      (e) => { if (e) console.error('persist failed:', e.message); });
  }, 500);
}

// ---- Weekly report ----
function csvCell(s) { s = String(s == null ? '' : s); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }
function csvRow(a) { return a.map(csvCell).join(','); }

// Classify every data row: completed (all cells filled), not done (any empty),
// and which rows carry comments. Shared by the CSV and the pinned summary.
function analyzeSheet() {
  const rows = doc.rows || [];
  if (rows.length < 1) return { header: [], completed: [], notDone: [], commented: [] };
  const header = rows[0].map((h, c) => (String(h == null ? '' : h).trim() || ('Column ' + (c + 1))));
  const nCols = header.length;
  const completed = [], notDone = [], commented = [];
  for (let i = 1; i < rows.length; i++) {
    const ri = i; // index in doc.rows (matches the app's row # in header mode)
    const cells = [];
    for (let c = 0; c < nCols; c++) cells.push(String(rows[i][c] == null ? '' : rows[i][c]).trim());
    const missing = [];
    for (let c = 0; c < nCols; c++) if (cells[c] === '') missing.push(header[c]);
    (missing.length === 0 ? completed : notDone).push({ ri, cells, missing });
    const cmts = [];
    for (let c = 0; c < nCols; c++) {
      const arr = comments[ri + ',' + c];
      if (arr) for (const cm of arr) cmts.push(`${header[c]} — ${cm.name}: ${cm.text}`);
    }
    if (cmts.length) commented.push({ ri, cells, cmts });
  }
  return { header, completed, notDone, commented };
}

// One report CSV with three sections.
function buildReportCsv() {
  const { header, completed, notDone, commented } = analyzeSheet();
  const out = [];
  out.push(csvRow(['M511 Label Studio — Weekly Report']));
  out.push(csvRow(['Generated', new Date().toISOString()]));
  if (lastReport) out.push(csvRow(['For week beginning (Mon)', lastReport.forWeek]));
  out.push('');
  if (!header.length) { out.push(csvRow(['(no data)'])); return out.join('\n'); }
  out.push(csvRow([`COMPLETED — all cells filled (${completed.length})`]));
  out.push(csvRow(['Row', ...header]));
  completed.forEach(x => out.push(csvRow([x.ri, ...x.cells])));
  out.push('');
  out.push(csvRow([`NOT COMPLETED — missing cells (${notDone.length})`]));
  out.push(csvRow(['Row', ...header, 'Missing columns']));
  notDone.forEach(x => out.push(csvRow([x.ri, ...x.cells, x.missing.join('; ')])));
  out.push('');
  out.push(csvRow([`ROWS WITH COMMENTS (${commented.length})`]));
  out.push(csvRow(['Row', ...header, 'Comments']));
  commented.forEach(x => out.push(csvRow([x.ri, ...x.cells, x.cmts.join(' | ')])));
  return out.join('\n');
}

// On a new week (Monday): snapshot the report, reset the chat, and post the
// report as a pinned message.
function maybeRollWeek() {
  const nowKey = weekKeyOf(new Date());
  if (nowKey !== weekKey) {
    const a = analyzeSheet();
    lastReport = { forWeek: weekKey, generatedAt: Date.now() };
    pinnedReport = {
      forWeek: weekKey,
      generatedAt: lastReport.generatedAt,
      completed: a.completed.length,
      notDone: a.notDone.length,
      commented: a.commented.length,
    };
    weekKey = nowKey;
    chat = []; // start the new work week with a clean chat
    persist();
    if (typeof broadcast === 'function') broadcast({ type: 'pinned', pinned: pinnedReport });
  } else {
    pruneChat();
  }
}

// ---- Static file serving ----
const server = http.createServer((req, res) => {
  let urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
  // Weekly report as a downloadable CSV (built live from the current sheet).
  if (urlPath === '/report.csv') {
    const csv = buildReportCsv();
    res.writeHead(200, {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': 'attachment; filename="m511-weekly-report.csv"',
      'Cache-Control': 'no-cache',
    });
    res.end(csv);
    return;
  }
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
// Presence groups connections by person (first name + last initial); a person
// may have several devices open at once.
function presence() {
  const byName = new Map();
  let devices = 0;
  for (const c of wss.clients) {
    if (c.readyState !== 1) continue;
    devices++;
    const nm = (c._id && c._id.name) || 'Guest';
    byName.set(nm, (byName.get(nm) || 0) + 1);
  }
  const users = [...byName.entries()].map(([name, d]) => ({ name, devices: d }));
  broadcast({ type: 'presence', people: users.length, devices, users });
}

// Attributed edit log (who changed what).
function pushEdit(name, text) {
  const entry = { name: clip(name, 40) || 'Someone', text: clip(text, 200), ts: Date.now() };
  if (!entry.text) return;
  editLog.push(entry);
  if (editLog.length > EDIT_MAX) editLog = editLog.slice(-EDIT_MAX);
  broadcast({ type: 'edit', entry }); // to everyone (incl. author, for their log)
  persist();
}

function normRows(rows) {
  if (!Array.isArray(rows)) return [];
  return rows.map(r => Array.isArray(r) ? r.map(x => (x == null ? '' : String(x))) : []);
}

function clip(s, n) { return String(s == null ? '' : s).slice(0, n); }

let eidSeq = 0;
wss.on('connection', (ws) => {
  ws._eid = 'e' + (++eidSeq);
  ws._editing = new Set();
  maybeRollWeek();
  ws.send(JSON.stringify({ type: 'init', rows: doc.rows, rev: doc.rev, comments, chat, pinnedReport, editLog }));
  presence();

  ws.on('message', (raw) => {
    let m;
    try { m = JSON.parse(raw); } catch { return; }
    if (m.type === 'hello') {
      ws._id = { name: clip(m.name, 40) || 'Guest', deviceId: clip(m.deviceId, 40) };
      presence();
    } else if (m.type === 'cell') {
      const r = m.r | 0, c = m.c | 0;
      if (r < 0 || c < 0) return;
      while (doc.rows.length <= r) doc.rows.push([]);
      while (doc.rows[r].length <= c) doc.rows[r].push('');
      doc.rows[r][c] = m.value == null ? '' : String(m.value);
      doc.rev++;
      broadcast({ type: 'cell', r, c, value: doc.rows[r][c], rev: doc.rev }, ws);
      if (m.commit && m.name && m.detail) pushEdit(m.name, m.detail);
      persist();
    } else if (m.type === 'rows') {
      doc.rows = normRows(m.rows);
      doc.rev++;
      broadcast({ type: 'doc', rows: doc.rows, rev: doc.rev }, ws);
      if (m.name && m.action) pushEdit(m.name, m.action);
      persist();
    } else if (m.type === 'comment') {
      const r = m.r | 0, c = m.c | 0;
      if (r < 0 || c < 0) return;
      const key = r + ',' + c;
      const comment = { name: clip(m.name, 40), text: clip(m.text, 500), ts: Date.now() };
      if (!comment.text) return;
      (comments[key] = comments[key] || []).push(comment);
      broadcast({ type: 'comment', r, c, comment }, ws); // sender already added it locally
      pushEdit(comment.name, `commented on R${r} C${c + 1}`);
      persist();
    } else if (m.type === 'chat') {
      const message = {
        id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
        name: clip(m.name, 40), text: clip(m.text, 1000), ts: Date.now(),
        quote: Array.isArray(m.quote) ? m.quote.slice(0, 60).map(q => ({
          ref: clip(q.ref, 24), value: clip(q.value, 200),
        })) : null,
        replyTo: (m.replyTo && typeof m.replyTo === 'object') ? {
          id: clip(m.replyTo.id, 40), name: clip(m.replyTo.name, 40), text: clip(m.replyTo.text, 140),
        } : null,
      };
      if (!message.text && !(message.quote && message.quote.length)) return;
      chat.push(message);
      pruneChat();
      broadcast({ type: 'chat', message }); // to everyone (incl. author) so ids match
      persist();
    } else if (m.type === 'editing') {
      // Live "who's editing this cell" relay (ephemeral, not persisted).
      const r = m.r | 0, c = m.c | 0;
      if (r < 0 || c < 0) return;
      const key = r + ',' + c;
      ws._editing = ws._editing || new Set();
      if (m.done) {
        ws._editing.delete(key);
        broadcast({ type: 'editing', r, c, editorId: ws._eid, done: true }, ws);
      } else {
        ws._editing.add(key);
        broadcast({ type: 'editing', r, c, name: clip(m.name, 40) || 'Someone', editorId: ws._eid }, ws);
      }
    }
  });

  ws.on('close', () => {
    if (ws._editing) for (const key of ws._editing) {
      const [r, c] = key.split(',');
      broadcast({ type: 'editing', r: +r, c: +c, editorId: ws._eid, done: true });
    }
    presence();
  });
  ws.on('error', () => {});
});

maybeRollWeek();
setInterval(maybeRollWeek, 60 * 60 * 1000); // hourly week-roll / chat prune check

server.listen(PORT, () => console.log('M511 Label Studio (with live sync) on :' + PORT));
