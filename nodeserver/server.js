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

const PORT = Number(process.env.ORIVIO_STREAM_PORT || 11470);
const HOST = '127.0.0.1';
const VIDEO_EXT = ['.mkv', '.mp4', '.avi', '.mov', '.m4v', '.ts', '.webm'];

// infoHash -> { engine, ready }
const engines = new Map();

function magnetFor(input) {
  if (/^magnet:/i.test(input)) return input;
  if (/^[0-9a-f]{40}$/i.test(input)) return 'magnet:?xt=urn:btih:' + input;
  return input;
}

function getEngine(magnet) {
  return new Promise((resolve, reject) => {
    const uri = magnetFor(magnet);
    const engine = torrentStream(uri, { connections: 60 });
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) { settled = true; reject(new Error('metadata timeout')); }
    }, 30000);
    engine.on('ready', () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const hash = engine.infoHash;
      engines.set(hash, engine);
      resolve(engine);
    });
    engine.on('error', (e) => {
      if (!settled) { settled = true; clearTimeout(timer); reject(e); }
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
  return pool.reduce((best, cur) => (cur.f.length > best.f.length ? cur : best)).i;
}

function sendJSON(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => (data += c));
    req.on('end', () => {
      try { resolve(JSON.parse(data || '{}')); } catch { resolve({}); }
    });
  });
}

function streamFile(req, res, engine, index) {
  const file = engine.files[index];
  if (!file) { res.writeHead(404); return res.end('no file'); }
  // Prioritize sequential download so the swarm fills toward the play head.
  if (engine.select) engine.select(index);

  const total = file.length;
  const range = req.headers.range;
  const type = 'video/' + (file.name.split('.').pop() || 'mp4');

  if (range) {
    const m = /bytes=(\d*)-(\d*)/.exec(range);
    const start = m && m[1] ? parseInt(m[1], 10) : 0;
    const end = m && m[2] ? parseInt(m[2], 10) : total - 1;
    res.writeHead(206, {
      'Content-Range': `bytes ${start}-${end}/${total}`,
      'Accept-Ranges': 'bytes',
      'Content-Length': end - start + 1,
      'Content-Type': type
    });
    const stream = file.createReadStream({ start, end });
    stream.pipe(res);
    req.on('close', () => stream.destroy());
  } else {
    res.writeHead(200, { 'Content-Length': total, 'Accept-Ranges': 'bytes', 'Content-Type': type });
    const stream = file.createReadStream();
    stream.pipe(res);
    req.on('close', () => stream.destroy());
  }
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${HOST}:${PORT}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      return res.end('ok');
    }

    if (req.method === 'POST' && url.pathname === '/add') {
      const { magnet } = await readBody(req);
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
      const { hash } = await readBody(req);
      const engine = engines.get(hash);
      if (engine) { engine.destroy(() => {}); engines.delete(hash); }
      return sendJSON(res, 200, { ok: true });
    }

    // GET /stream/:hash/:index
    if (req.method === 'GET' && parts[0] === 'stream' && parts.length === 3) {
      const engine = engines.get(parts[1]);
      if (!engine) return sendJSON(res, 404, { error: 'unknown torrent' });
      return streamFile(req, res, engine, parseInt(parts[2], 10));
    }

    res.writeHead(404);
    res.end('not found');
  } catch (e) {
    res.writeHead(500);
    res.end(String(e && e.message || e));
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[orivio-stream] listening on http://${HOST}:${PORT}`);
});
