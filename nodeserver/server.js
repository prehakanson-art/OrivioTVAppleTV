// OrivioTV on-device torrent streaming server.
//
// Runs IN-PROCESS inside the tvOS app via nodejs-mobile (the same technique
// Stremio uses: Node linked as a framework, no subprocess). Exposes a tiny
// HTTP API on 127.0.0.1:11470 that the Swift side drives:
//
//   GET  /health                          -> 200 "ok"
//   POST /add            { "magnet": … }   -> { infoHash, files:[{index,name,length}] }
//   GET  /stream/:hash/:index              -> the file, with HTTP range support
//   POST /drop           { "hash": … }      -> 200 (frees the swarm)
//
// Playback: pick a file from /add, then point the player at
//   http://127.0.0.1:11470/stream/<infoHash>/<index>
//
// Pure Node + torrent-stream (BitTorrent swarm). No native addons, so it runs
// under nodejs-mobile's jitless V8 on tvOS.

'use strict';

const http = require('http');
const torrentStream = require('torrent-stream');

// A bad ORIVIO_STREAM_PORT used to reach server.listen() unvalidated: a
// non-numeric value throws ERR_SOCKET_BAD_PORT synchronously at load (taking the
// in-process app down with it), and a whitespace value silently becomes 0,
// binding an ephemeral port while the Swift side still dials 11470. Clamp to a
// valid TCP port.
const DEFAULT_PORT = 11470;
const configuredPort = Number(process.env.ORIVIO_STREAM_PORT);
const PORT = Number.isInteger(configuredPort) && configuredPort > 0 && configuredPort <= 65535
  ? configuredPort
  : DEFAULT_PORT;
const HOST = '127.0.0.1';
const VIDEO_EXT = ['.mkv', '.mp4', '.avi', '.mov', '.m4v', '.ts', '.webm'];

// infoHash -> { engine, ready }
const engines = new Map();

// Each engine holds up to 60 peer connections and its own disk store. Unbounded
// /add calls with distinct magnets could exhaust the device, so cap how many can
// be live at once. Real playback only ever holds one or two.
const MAX_ENGINES = 8;

function magnetFor(input) {
  if (/^magnet:/i.test(input)) return input;
  if (/^[0-9a-f]{40}$/i.test(input)) return 'magnet:?xt=urn:btih:' + input;
  return input;
}

// The 40-hex infohash out of a magnet URI, lowercased to match
// engine.infoHash. null for a base32 xt (or no xt at all), where we can only
// learn the real hash once metadata arrives.
function infoHashFrom(uri) {
  const m = /xt=urn:btih:([0-9a-fA-F]{40})/.exec(uri);
  return m ? m[1].toLowerCase() : null;
}

function destroyEngine(engine) {
  try { engine.destroy(() => {}); } catch (e) { /* already torn down */ }
}

// Tear down the swarm AND delete the on-disk payload. Only call this for an
// engine we know is the SOLE owner of its infoHash (e.g. /drop, after removing
// it from the map). Never for a duplicate discarded in getEngine: two engines
// for the same infoHash share one temp directory, so removing it would delete
// the surviving engine's data.
function removeEngine(engine) {
  try { engine.destroy(() => {}); } catch (e) { /* already torn down */ }
  try { engine.remove(() => {}); } catch (e) { /* already removed */ }
}

function getEngine(magnet) {
  const uri = magnetFor(magnet);
  // Only a magnet URI may reach torrent-stream. Before this, any string that
  // wasn't a magnet or a bare 40-hex hash was handed straight through, so
  // torrent-stream would happily fetch an arbitrary http(s) URL — an SSRF
  // primitive reachable from any loopback client.
  if (typeof uri !== 'string' || !/^magnet:\?/i.test(uri)) {
    return Promise.reject(new Error('invalid magnet'));
  }
  // A repeat /add for the same magnet used to build a SECOND engine and
  // overwrite the map entry — the first engine's swarm, its 60 connections and
  // its disk store stayed alive with no handle left to destroy them, so /drop
  // could never free them. Reuse the engine we already have.
  const known = infoHashFrom(uri);
  if (known && engines.has(known)) return Promise.resolve(engines.get(known));
  if (engines.size >= MAX_ENGINES) {
    return Promise.reject(new Error('too many active torrents'));
  }

  return new Promise((resolve, reject) => {
    const engine = torrentStream(uri, { connections: 60 });
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      // Destroy before rejecting. Rejecting alone left the swarm (and its DHT /
      // tracker timers) running for the life of the process for every magnet
      // that never resolved its metadata.
      destroyEngine(engine);
      reject(new Error('metadata timeout'));
    }, 30000);
    engine.on('ready', () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const hash = engine.infoHash;
      const existing = engines.get(hash);
      if (existing && existing !== engine) {
        // Raced with another /add for the same torrent (two requests in flight,
        // or a base32 magnet we couldn't match up front): keep the first engine
        // and destroy this one rather than overwriting the map and leaking it.
        destroyEngine(engine);
        resolve(existing);
        return;
      }
      engines.set(hash, engine);
      resolve(engine);
    });
    engine.on('error', (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      destroyEngine(engine);
      reject(e);
    });
  });
}

function fileList(engine) {
  return engine.files.map((f, i) => ({ index: i, name: f.name, length: f.length }));
}

function pickDefault(engine) {
  const videos = engine.files
    .map((f, i) => ({ f, i }))
    .filter(({ f }) => VIDEO_EXT.some((ext) => f.name.toLowerCase().endsWith(ext)));
  const pool = videos.length ? videos : engine.files.map((f, i) => ({ f, i }));
  // `reduce` with no initial value throws on an empty array, so a torrent whose
  // metadata listed no files threw straight out of the /add handler. null says
  // "nothing to play" instead, and the file list is still returned.
  if (!pool.length) return null;
  return pool.reduce((best, cur) => (cur.f.length > best.f.length ? cur : best)).i;
}

function sendJSON(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

// /add takes a magnet and /drop an infohash, so anything past a few KB is a
// mistake or an attack. Uncapped, a single POST could buffer an unbounded
// string inside the app's own process and jetsam it.
const MAX_BODY_BYTES = 64 * 1024;

// Resolves the parsed body, or the BODY_TOO_LARGE sentinel when it blew the cap
// (caller answers 413). The sentinel must be distinct from any valid parsed
// value: a legitimately falsy JSON body (null, 0, false, "") is not an
// overflow, but the old `null` sentinel made every one of them report 413.
// Overflow stops ACCUMULATING but does not destroy the request: the response
// still has to go out, and Node closes the connection itself once we reply
// without having drained the body.
const BODY_TOO_LARGE = Symbol('body too large');

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    let bytes = 0;
    let done = false;
    const settle = (value) => { if (!done) { done = true; resolve(value); } };
    req.on('data', (c) => {
      if (done) return;
      bytes += c.length;
      if (bytes > MAX_BODY_BYTES) return settle(BODY_TOO_LARGE);
      chunks.push(c);
    });
    req.on('end', () => {
      // Decode once at the end: per-chunk `toString()` split any multi-byte
      // character that straddled a chunk boundary into replacement characters.
      const text = Buffer.concat(chunks).toString('utf8');
      try { settle(JSON.parse(text || '{}')); } catch (e) { settle({}); }
    });
    // Without these a client that hung up mid-body left the promise pending
    // forever, holding the handler (and the request) open.
    req.on('error', () => settle({}));
    req.on('aborted', () => settle({}));
  });
}

// `'video/' + ext` produced bogus types — 'video/mkv', and for an
// extension-less file 'video/<whole filename>' — which some players refuse
// outright rather than sniffing the container.
const MIME_BY_EXT = {
  '.mkv': 'video/x-matroska',
  '.mp4': 'video/mp4',
  '.m4v': 'video/x-m4v',
  '.mov': 'video/quicktime',
  '.avi': 'video/x-msvideo',
  '.ts': 'video/mp2t',
  '.webm': 'video/webm'
};

function contentTypeFor(name) {
  const dot = name.lastIndexOf('.');
  const ext = dot >= 0 ? name.slice(dot).toLowerCase() : '';
  return MIME_BY_EXT[ext] || 'application/octet-stream';
}

// Parses a single byte range against the real file size. Returns:
//   { start, end }         -> a satisfiable single range (caller sends 206)
//   { unsatisfiable: true }-> syntactically valid but no overlap (caller 416)
//   null                   -> ignore the header and serve the whole file (200)
//
// The old two-line parser got four things wrong: it never clamped `end` to
// total-1 (so the Content-Range advertised bytes that don't exist), it answered
// `start > total` with a 206 rather than a 416, it could therefore emit a
// NEGATIVE Content-Length, and it read the suffix form `bytes=-500` ("the LAST
// 500 bytes") as start=0/end=500 — the FIRST 501 bytes, i.e. the wrong end of
// the file entirely.
//
// RFC 7233 requires a server to IGNORE a syntactically invalid Range, and lets
// it ignore one it doesn't support, so unsupported/multi-range/garbage input
// now yields null (→ 200 full file) instead of a bogus 416. The unit token is
// also matched case-insensitively (`bytes=`/`Bytes=`).
function parseRange(header, total) {
  if (total <= 0) return null;
  const raw = String(header).trim();
  if (raw.includes(',')) return null;              // multi-range: unsupported
  const m = /^bytes=\s*(\d*)-(\d*)$/i.exec(raw);
  if (!m || (!m[1] && !m[2])) return null;

  let start;
  let end;
  if (!m[1]) {
    // Suffix form: the last N bytes.
    const suffix = parseInt(m[2], 10);
    if (!Number.isFinite(suffix) || suffix <= 0) return null;
    start = Math.max(0, total - suffix);
    end = total - 1;
  } else {
    start = parseInt(m[1], 10);
    end = m[2] ? parseInt(m[2], 10) : total - 1;
  }
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  if (start >= total || end < start) return { unsatisfiable: true };
  return { start, end: Math.min(end, total - 1) };
}

function streamFile(req, res, engine, index) {
  const file = engine.files[index];
  if (!file) { res.writeHead(404); return res.end('no file'); }
  // No explicit prioritization here: file.createReadStream() below already calls
  // engine.select(startPiece, endPiece, /* priority */ true, notify) for the exact
  // requested range and deselects it at end-of-stream. The old
  // `engine.select(index)` was doubly wrong — engine.select takes PIECE indices
  // (from, to, priority, notify), not a file index — and, with `to` left
  // undefined, its selection entry could never be garbage-collected. That leaked
  // a phantom selection on every range request and kept the swarm permanently
  // interested. Removing it fixes both; the range is still prioritized.

  const total = file.length;
  const range = req.headers.range;
  const type = contentTypeFor(file.name);

  let opts = null;
  let head = { 'Content-Length': total, 'Accept-Ranges': 'bytes', 'Content-Type': type };
  let code = 200;

  if (range) {
    const parsed = parseRange(range, total);
    if (parsed && parsed.unsatisfiable) {
      // RFC 7233: unsatisfiable range -> 416 plus the real size, so the player
      // can retry correctly instead of consuming a malformed 206.
      res.writeHead(416, { 'Content-Range': `bytes */${total}`, 'Content-Type': 'text/plain' });
      return res.end();
    }
    if (parsed) {
      opts = { start: parsed.start, end: parsed.end };
      code = 206;
      head = {
        'Content-Range': `bytes ${parsed.start}-${parsed.end}/${total}`,
        'Accept-Ranges': 'bytes',
        'Content-Length': parsed.end - parsed.start + 1,
        'Content-Type': type
      };
    }
    // parsed === null → unsupported/invalid Range: ignore it and serve 200.
  }

  // Build the stream BEFORE writing any header. createReadStream can throw
  // synchronously, and doing it after the 206 meant the outer handler's catch
  // called writeHead(500) on a response whose headers were already sent —
  // ERR_HTTP_HEADERS_SENT thrown from inside an async handler, i.e. an
  // unhandled rejection that took the whole in-process server down with it.
  let stream;
  try {
    stream = opts ? file.createReadStream(opts) : file.createReadStream();
  } catch (e) {
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    return res.end(String((e && e.message) || e));
  }

  res.writeHead(code, head);
  // An async read error is an 'error' event with no listener, which Node turns
  // into an uncaught exception. Headers are already out by now, so the only
  // honest answer is to drop the connection.
  stream.on('error', () => res.destroy());
  stream.pipe(res);
  req.on('close', () => stream.destroy());
}

const server = http.createServer(async (req, res) => {
  // This server runs IN-PROCESS: an unhandled 'error' event on the response
  // (client hung up mid-pipe, socket torn down under a write) would take the
  // whole app down, not just one request.
  res.on('error', (e) => console.error('[orivio-stream] response error:', (e && e.message) || e));
  try {
    const url = new URL(req.url, `http://${HOST}:${PORT}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      return res.end('ok');
    }

    if (req.method === 'POST' && url.pathname === '/add') {
      const body = await readBody(req);
      if (body === BODY_TOO_LARGE) return sendJSON(res, 413, { error: 'request body too large' });
      const magnet = body && typeof body === 'object' ? body.magnet : null;
      if (!magnet) return sendJSON(res, 400, { error: 'magnet required' });
      try {
        const engine = await getEngine(magnet);
        return sendJSON(res, 200, {
          infoHash: engine.infoHash,
          files: fileList(engine),
          defaultIndex: pickDefault(engine)
        });
      } catch (e) {
        return sendJSON(res, 502, { error: String(e && e.message || e) });
      }
    }

    if (req.method === 'POST' && url.pathname === '/drop') {
      const body = await readBody(req);
      if (body === BODY_TOO_LARGE) return sendJSON(res, 413, { error: 'request body too large' });
      const rawHash = body && typeof body === 'object' ? body.hash : null;
      if (!rawHash) return sendJSON(res, 400, { error: 'hash required' });
      // Normalize to match the lowercased keys getEngine stores, otherwise an
      // uppercase hash from the client silently missed (and leaked the engine).
      const hash = String(rawHash).toLowerCase();
      const engine = engines.get(hash);
      if (engine) { engines.delete(hash); removeEngine(engine); }
      return sendJSON(res, 200, { ok: true });
    }

    // GET /stream/:hash/:index
    if (req.method === 'GET' && parts[0] === 'stream' && parts.length === 3) {
      const engine = engines.get(parts[1].toLowerCase());
      if (!engine) return sendJSON(res, 404, { error: 'unknown torrent' });
      return streamFile(req, res, engine, parseInt(parts[2], 10));
    }

    res.writeHead(404);
    res.end('not found');
  } catch (e) {
    // Never write headers twice. streamFile has already sent its 200/206 by the
    // time anything downstream can throw, and writeHead(500) on that response
    // threw ERR_HTTP_HEADERS_SENT out of an async handler — an unhandled
    // rejection that killed the process (and the app hosting it).
    console.error('[orivio-stream] request failed:', (e && e.message) || e);
    if (res.headersSent) { res.destroy(); return; }
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end(String((e && e.message) || e));
  }
});

// listen() reports EADDRINUSE (and similar) asynchronously via an 'error' event.
// With no listener that becomes an uncaught exception, and because this server
// runs in-process inside nodejs-mobile it would take the whole tvOS app down.
server.on('error', (e) => {
  console.error('[orivio-stream] server error:', (e && e.message) || e);
});

server.listen(PORT, HOST, () => {
  console.log(`[orivio-stream] listening on http://${HOST}:${PORT}`);
});
