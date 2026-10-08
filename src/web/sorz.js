// The host of the browser build. It loads the WebAssembly module and the game's files from the
// server that sent this page (the native game, from the user's own copy: DESIGN.md 5.3), then
// runs the game, its own front end first (the page has no menu of its own): one update for each
// animation frame, the frames to the canvas, the keys, the gamepads and the sound to the module and
// back. The player never picks or uploads a file. The module keeps the tables of keys and buttons
// and all game logic, network play's messages included, and draws the page's loading screen in the
// game's style once its first files are in (`gp_screen_*`, src/web/main.zig); this script only
// moves data, and its own text stands in, in the game's colours, until then and for an error the
// module cannot draw (a tree without the game's font and menu). The game's settings record is the
// page's only settings: the game's screen is to change it, and the script applies it as a browser
// does (the gain, the scale, the full screen).
'use strict';

// --- the helpers that the module imports in place of compiler-rt ------------------------------

// The module links no compiler-rt (DESIGN.md 5.3), so the functions of it that the game calls are
// imports, and these give the same results to the bit. `__multi3` is the product of two 128-bit
// integers: BigInt is exact. A 128-bit value crosses as two 64-bit halves, low first, and the
// result goes to the address in the first argument. `zig build web-check` compares each helper
// with compiler-rt's. A game that calls another (a 128-bit quotient, `exp`) adds its helper here,
// as a previous port's script did for `__udivti3` and `exp`.
function sorzHelpers(memory) {
  const mask64 = (1n << 64n) - 1n;

  function wide(lo, hi) {
    return (BigInt.asUintN(64, hi) << 64n) | BigInt.asUintN(64, lo);
  }

  function store(at, value) {
    const view = new DataView(memory.buffer);
    view.setBigUint64(at, value & mask64, true);
    view.setBigUint64(at + 8, (value >> 64n) & mask64, true);
  }

  return {
    __multi3(at, aLo, aHi, bLo, bHi) {
      store(at, wide(aLo, aHi) * wide(bLo, bHi));
    },
  };
}

// The game's files, as the page's server lists them in `assets/manifest.json`: `{"files": [{"name",
// "size"}]}`, each file at `assets/NAME`. The asset tree is under `tree/` (its own `manifest.json`
// would collide with the listing's path: src/native/served.zig), and the module takes each file
// under its name in the tree. The result is `[{ url, name, size }]`, the files named in `first`
// (by their names in the tree, in any case; a name ending in `/` names the files under that
// directory) first and in that order, then the others in the listing's. A listing without files, a malformed entry or a file outside the tree is an error:
// the page does not run a game without its files.
function sorzListing(listing, first = []) {
  const files = listing && Array.isArray(listing.files) ? listing.files : null;
  if (!files || files.length === 0) throw new Error('the listing names no file');
  const out = files.map((f, i) => {
    if (!f || typeof f.name !== 'string' || !Number.isInteger(f.size) || f.size < 0) throw new Error('entry ' + i + ' of the listing is malformed');
    if (!f.name.startsWith('tree/') || f.name.length === 5) throw new Error(f.name + ' is not a file of the asset tree');
    const name = f.name.slice(5);
    // Each part of the name is escaped, and the separators stay.
    const url = 'assets/' + f.name.split('/').map(encodeURIComponent).join('/');
    const rank = sorzFirst(name, first);
    return { url, name, size: f.size, order: rank < 0 ? first.length : rank, at: i };
  });
  out.sort((a, b) => a.order - b.order || a.at - b.at);
  return out.map(({ url, name, size }) => ({ url, name, size }));
}

// Where the tree's file `name` is in `first` (names, in any case, or directories ending in `/`),
// or -1.
function sorzFirst(name, first) {
  const lower = name.toLowerCase();
  return first.findIndex((w) => {
    const want = w.toLowerCase();
    return want.endsWith('/') ? want.length > 1 && lower.startsWith(want) : want === lower;
  });
}

// The page's side of network play's transport (DESIGN.md 9, PLAN A1, A2 and 26): whole binary
// messages over WebSockets, by connection, reported to `events` as the platform contract's events:
// `connected(id, incoming)`, `received(id, bytes)` (an ArrayBuffer) and `disconnected(id,
// reason)`, the reason one of 'closed', 'lost', 'refused', 'protocol' and 'too_large'. Per
// connection: connected, then its messages in order, then disconnected; nothing follows a close
// by the game.
//
// `connect(url)` is the game's connection to a native host. `joinRelay(url)` is the page's own
// connection to a server's relay (src/native/relay.zig), whose text messages go to
// `events.relay(state)`: first the page's role, 'host' or 'client'; then, once, why the page is off
// the relay, unless `leaveRelay` took it off: 'unreachable' (no role came), 'host_left' (a client's
// host left), 'lost' (the connection ended), or 'closed' (a client's game closed its connection to
// the host). A client's socket is its connection to the host. A host's socket is not a connection
// at all: each client that the relay announces ('peer N') is an incoming connection of its own,
// until the relay says it has 'left N' (DESIGN.md 9: the game's host logic needs no listening
// socket). Between a host and its clients a binary message carries the client's number, two bytes,
// little-endian, before the game's: the host's page takes a client's number off what comes from it
// and puts it before what the game sends to it. When the host's game closes a client's connection,
// the page lets that client go and stays on the relay: what comes from the client is dropped.
// `leaveRelay()` ends the page's relay connection, and nothing follows.
//
// The module's side is `js_net_connect`, `js_net_send` and `js_net_close` over `connect`, `send`
// and `close`, and `gp_net_connected`, `gp_net_received` and `gp_net_disconnected` from the events.
// The page learns the mode from `netplay.json`, which the native host and the relay serve
// (`{"mode": "native" | "relay", "websocket": "/"}`), and gives the module its network play
// (`gp_start_netplay`) as it loads: a native host's page is its client, whose game connects to
// `ws://<the page's host>/` itself; a relay's page connects to the relay, and gives the module the
// role the relay gives it, again each time it connects anew.
function sorzTransport(Socket, events, limits = {}) {
  const maxMessage = limits.maxMessage || 64 * 1024;
  const maxQueued = limits.maxQueued || 1024 * 1024;
  // Connections by id: { socket, open, closedByGame } for a socket of the game's; one over the
  // relay's socket is { relay, number, open, closedByGame }, `number` the client's on a host's
  // page (0 on a client's page, whose one connection is to the host).
  const connections = new Map();
  let nextId = 1;
  let relay = null;
  // The bytes of a client's number between a host and its clients.
  const numberLen = 2;

  function socketFor(url, onOpen, onMessage, onClose) {
    let socket;
    try {
      socket = new Socket(url);
    } catch (e) {
      return null;
    }
    socket.binaryType = 'arraybuffer';
    socket.onopen = onOpen;
    socket.onmessage = (event) => onMessage(event.data);
    socket.onclose = onClose;
    socket.onerror = () => {}; // A close follows.
    return socket;
  }

  function end(id, reason) {
    const c = connections.get(id);
    if (!c) return;
    connections.delete(id);
    if (!c.closedByGame) events.disconnected(id, reason);
  }

  // A message of the game's: binary and within the size limit, else the connection ends (a relay's
  // client from a host's page: its messages are dropped from then on).
  function deliver(id, data) {
    const c = connections.get(id);
    if (!c || !c.open) return;
    const reason = typeof data === 'string' ? 'protocol' : data.byteLength > maxMessage ? 'too_large' : null;
    if (reason === null) {
      events.received(id, data);
      return;
    }
    if (c.socket) c.socket.close(1002);
    else if (c.relay.role === 'client') c.relay.socket.close(1002);
    end(id, reason);
  }

  function connect(url) {
    const id = nextId++;
    const c = { socket: null, open: false, closedByGame: false };
    connections.set(id, c);
    c.socket = socketFor(url, () => {
      c.open = true;
      events.connected(id, false);
    }, (data) => deliver(id, data), () => end(id, c.open ? 'lost' : 'refused'));
    if (!c.socket) Promise.resolve().then(() => end(id, 'refused'));
    return id;
  }

  // A client's number in the relay's word `word N`, or 0.
  function numberIn(text, word) {
    if (!text.startsWith(word + ' ')) return 0;
    const digits = text.slice(word.length + 1);
    const n = /^[1-9][0-9]{0,4}$/.test(digits) ? Number(digits) : 0;
    return n <= 0xffff ? n : 0;
  }

  function joinRelay(url) {
    // `clients`: on a host's page, the id of each client's connection by its number, until the
    // relay says it left. `host`: on a client's page, the id of its connection to the host.
    const r = { socket: null, role: null, clients: new Map(), host: 0, hostLeft: false, ended: false };
    relay = r;
    // The page is off the relay: once, and not after `leaveRelay`.
    const finish = (state) => {
      if (r.ended) return;
      r.ended = true;
      if (relay === r) relay = null;
      events.relay(state);
    };
    r.finish = finish;
    const fromHost = (data) => {
      if (typeof data !== 'string') {
        if (r.host !== 0) deliver(r.host, data);
      } else if (data === 'left') {
        // Its host left: the relay ends the connection next.
        r.hostLeft = true;
        const id = r.host;
        r.host = 0;
        end(id, 'closed');
      }
    };
    const fromClients = (data) => {
      if (typeof data !== 'string') {
        if (data.byteLength < numberLen) return;
        const id = r.clients.get(new DataView(data).getUint16(0, true));
        if (id !== undefined) deliver(id, data.slice(numberLen));
        return;
      }
      const came = numberIn(data, 'peer');
      if (came !== 0 && !r.clients.has(came)) {
        const id = nextId++;
        r.clients.set(came, id);
        connections.set(id, { relay: r, number: came, open: true, closedByGame: false });
        events.connected(id, true);
        return;
      }
      const went = numberIn(data, 'left');
      if (went !== 0 && r.clients.has(went)) {
        const id = r.clients.get(went);
        r.clients.delete(went);
        end(id, 'closed');
      }
    };
    r.socket = socketFor(url, () => {}, (data) => {
      if (r.ended) return;
      if (r.role === 'host') return fromClients(data);
      if (r.role === 'client') return fromHost(data);
      if (data !== 'host' && data !== 'client') return;
      r.role = data;
      events.relay(data);
      // The page may have left the relay meanwhile (its game could not start network play).
      if (relay !== r || data !== 'client') return;
      r.host = nextId++;
      connections.set(r.host, { relay: r, number: 0, open: true, closedByGame: false });
      events.connected(r.host, false);
    }, () => {
      if (r.ended) return;
      const id = r.host;
      r.host = 0;
      if (id !== 0) end(id, 'lost');
      for (const client of r.clients.values()) end(client, 'lost');
      r.clients.clear();
      if (r.role === null) finish('unreachable');
      else finish(r.hostLeft ? 'host_left' : 'lost');
    });
    if (!r.socket) Promise.resolve().then(() => finish('unreachable'));
  }

  // The page leaves the relay: its connection ends, its connections over it go without an event,
  // and nothing follows.
  function leaveRelay() {
    const r = relay;
    if (!r) return;
    relay = null;
    r.ended = true;
    for (const id of [r.host, ...r.clients.values()]) {
      const c = connections.get(id);
      if (c) c.closedByGame = true;
      connections.delete(id);
    }
    r.host = 0;
    r.clients.clear();
    if (r.socket) r.socket.close(1000);
  }

  // 'sent', 'queue_full', 'not_connected' or 'too_large'; a message is queued whole or not at all.
  function send(id, bytes) {
    const c = connections.get(id);
    if (!c || !c.open) return 'not_connected';
    if (bytes.byteLength > maxMessage) return 'too_large';
    const socket = c.socket || c.relay.socket;
    let data = bytes;
    if (c.number) {
      const framed = new Uint8Array(numberLen + bytes.byteLength);
      new DataView(framed.buffer).setUint16(0, c.number, true);
      framed.set(new Uint8Array(bytes), numberLen);
      data = framed.buffer;
    }
    if (socket.bufferedAmount + data.byteLength > maxQueued) return 'queue_full';
    socket.send(data);
    return 'sent';
  }

  // The game's close: the socket closes after what it has queued, and no event follows. On a
  // relay, a client's game leaves the relay ('closed'); a host's game lets its client go and stays.
  function close(id) {
    const c = connections.get(id);
    if (!c) return;
    c.closedByGame = true;
    connections.delete(id);
    if (c.socket) {
      c.socket.close(1000);
    } else if (c.relay.role === 'client') {
      const r = c.relay;
      r.host = 0;
      r.socket.close(1000);
      r.finish('closed');
    }
  }

  return { connect, joinRelay, leaveRelay, send, close };
}

(() => {
  // Under Node, which `zig build web-check` uses for the helpers above, there is no page.
  if (typeof document === 'undefined') return;
  const canvas = document.getElementById('screen');
  const overlay = document.getElementById('overlay');
  const message = document.getElementById('message');
  const detail = document.getElementById('detail');
  const context = canvas.getContext('2d', { alpha: false });
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  let memory = null;
  let wasm = null;
  let code = null;
  let image = null;
  // The page's phases: `loading` (the module and the game's files), `playing` (the game, its own
  // front end first: the page has no menu of its own), `stopped`.
  let phase = 'loading';
  let started = false;
  // Whether the module draws the page's screens (its first files are in).
  let screens = false;

  // --- text through the module's scratch buffer ---------------------------------------------

  function writeScratch(text) {
    const bytes = encoder.encode(text);
    const n = Math.min(bytes.length, wasm.gp_scratch_len());
    new Uint8Array(memory.buffer, wasm.gp_scratch(), n).set(bytes.subarray(0, n));
    return n;
  }

  function readScratch(len) {
    return decoder.decode(new Uint8Array(memory.buffer, wasm.gp_scratch(), len));
  }

  function readString(ptr, len) {
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
  }

  function errorText() {
    return readScratch(wasm.gp_error()) || 'unknown error';
  }

  // --- the memory that the module imports ---------------------------------------------------

  // The module declares the limits of the memory that it imports. The script reads them from the
  // import section, so the build is the one place that sets them.
  function memoryLimits(buffer) {
    const bytes = new Uint8Array(buffer);
    let at = 8;
    const leb = () => {
      let value = 0;
      let scale = 1;
      for (;;) {
        const b = bytes[at++];
        value += (b & 0x7f) * scale;
        if ((b & 0x80) === 0) return value;
        scale *= 128;
      }
    };
    // Two steps: `at += leb()` would add the length to the position from before the length.
    const skipName = () => {
      const length = leb();
      at += length;
    };
    while (at < bytes.length) {
      const id = bytes[at++];
      const size = leb();
      const end = at + size;
      if (id === 2) {
        const count = leb();
        for (let i = 0; i < count; i++) {
          skipName();
          skipName();
          const kind = bytes[at++];
          if (kind === 0) {
            leb();
          } else if (kind === 1) {
            at++;
            const flags = bytes[at++];
            leb();
            if (flags & 1) leb();
          } else if (kind === 2) {
            const flags = bytes[at++];
            const initial = leb();
            const maximum = (flags & 1) ? leb() : undefined;
            return { initial, maximum };
          } else if (kind === 3) {
            at += 2;
          }
        }
      }
      at = end;
    }
    return null;
  }

  // --- the game's settings, as a browser does them ----------------------------------------------

  // The game's settings record (`settings.json`, kept with the game's other records below) is the
  // page's only settings: the player changes them on the game's settings screen (OPTIONS' ADVANCED
  // SETTINGS, START during play). The module tells the page the record's sound and window when the
  // game starts and whenever they change (`js_settings`), and the page applies them:
  //
  // - the sound: the gain of the output (the game's volume curve, 0 with the sound off). The game
  //   queues its sound at its own level, so this gain is the only one.
  // - the scale: the picture's whole multiple, in the page's pixels made whole device pixels; the
  //   largest that fits when the window is smaller (`fit`).
  // - full screen: the page's. A browser gives it only at a click or a key: the player's first one,
  //   the key that turns it on on the settings screen, or a later click. Until then the picture
  //   fills the window. Leaving it (Escape is the browser's) turns the setting off, as the player
  //   chose.
  const view = { gain: 1, scale: 3, fullscreen: false };

  function applySettings(gain, scale, fullscreen) {
    view.gain = gain;
    view.scale = scale;
    view.fullscreen = fullscreen !== 0;
    if (audio.gain) audio.gain.gain.value = gain;
    if (!view.fullscreen && document.fullscreenElement) document.exitFullscreen().catch(() => {});
    if (view.fullscreen && started) enterFullscreen();
    fit();
  }

  function enterFullscreen() {
    if (document.fullscreenElement || !document.documentElement.requestFullscreen) return;
    // Without a gesture the browser refuses: the picture fills the window, and a click asks again.
    document.documentElement.requestFullscreen().catch(() => {});
  }

  document.addEventListener('fullscreenchange', () => {
    fit();
    if (!document.fullscreenElement && view.fullscreen && wasm) wasm.gp_fullscreen_left();
  });

  // --- presentation -------------------------------------------------------------------------

  // The canvas has the size of the game's picture (320x224). CSS scales it to the window: by the
  // settings' scale in whole device pixels, so every pixel of the game has the same size, or by
  // the largest whole multiple that fits when that is smaller; in full screen, or when the window
  // is smaller than the picture, as large as it fits.
  function fit() {
    const ratio = window.devicePixelRatio || 1;
    const room = Math.min(window.innerWidth * ratio / canvas.width, window.innerHeight * ratio / canvas.height);
    const scale = (!view.fullscreen && room >= 1) ? Math.min(Math.max(1, Math.round(view.scale * ratio)), Math.floor(room)) : room;
    canvas.style.width = (canvas.width * scale / ratio) + 'px';
    canvas.style.height = (canvas.height * scale / ratio) + 'px';
  }

  function setResolution(width, height) {
    // The module's screens and the game share the size: an unchanged one keeps the canvas.
    if (image && canvas.width === width && canvas.height === height) return;
    canvas.width = width;
    canvas.height = height;
    image = context.createImageData(width, height);
    fit();
  }

  function present(ptr, width, height, stride) {
    if (!image || image.width !== width || image.height !== height) setResolution(width, height);
    const row = width * 4;
    const pixels = new Uint8Array(memory.buffer, ptr, stride * (height - 1) + row);
    if (stride === row) {
      image.data.set(pixels);
    } else {
      for (let y = 0; y < height; y++) image.data.set(pixels.subarray(y * stride, y * stride + row), y * row);
    }
    context.putImageData(image, 0, 0);
  }

  window.addEventListener('resize', () => {
    fit();
    if (started) {
      const ratio = window.devicePixelRatio || 1;
      wasm.gp_resized(Math.round(window.innerWidth * ratio), Math.round(window.innerHeight * ratio));
    }
  });

  // --- sound --------------------------------------------------------------------------------

  // The module queues interleaved 16-bit frames. Each block becomes an AudioBuffer that starts
  // where the previous block ends, on the output's own clock, through the volume's gain. The queue
  // is at most one second. The context is made when the game opens its sound, at the rate that the
  // game asks for (48 kHz), and runs from the player's first click or key (a browser starts sound
  // only after a gesture); until then the game runs on the clock.
  //
  // Suspension is state (DESIGN.md 3.4): while the output does not run, the game runs on the
  // clock and the blocks it queues are dropped, so no backlog plays late when the sound comes
  // back. A hidden page suspends the output; the page runs no update until it runs again, so the
  // music resumes where it stopped.
  const audio = {
    context: null, gain: null, open: false, rate: 0, next: 0, nodes: [],
    // Counters for the page's checks: the frames dropped while suspended, and the times the queue
    // ran dry while the game played.
    dropped: 0, underruns: 0,
    // The page's own suspension (a hidden page), the wait for the output to run again, and
    // whether the page hid since the last block.
    suspendedByPage: false, resuming: null, hid: false,
  };

  function makeAudioContext(rate) {
    const Context = window.AudioContext || window.webkitAudioContext;
    if (!Context) return null;
    try {
      return new Context({ sampleRate: rate, latencyHint: 'interactive' });
    } catch (e) {
      try {
        return new Context({ latencyHint: 'interactive' });
      } catch (e2) {
        return null;
      }
    }
  }

  function ensureAudioContext(rate) {
    if (audio.context && audio.context.sampleRate === rate) return audio.context;
    const made = makeAudioContext(rate);
    if (!made) return audio.context;
    if (audio.context) audio.context.close().catch(() => {});
    audio.context = made;
    audio.gain = made.createGain();
    audio.gain.gain.value = view.gain;
    audio.gain.connect(made.destination);
    return made;
  }

  function audioOpen(rate, channels) {
    if (channels < 1 || channels > 2) return 0;
    if (!ensureAudioContext(rate)) return 0;
    audio.context.resume().catch(() => {});
    audio.open = true;
    audio.rate = audio.context.sampleRate;
    audio.next = 0;
    audio.nodes = [];
    return audio.rate;
  }

  function audioRunning() {
    return audio.open && audio.context && audio.context.state === 'running';
  }

  function clockFrames() {
    return audio.context.currentTime * audio.rate;
  }

  function audioQueued() {
    if (!audioRunning()) return 0;
    return Math.max(0, audio.next - clockFrames());
  }

  function audioQueue(ptr, frames, channels) {
    if (!audio.open) return 0;
    if (checks.audioTap) checks.audioTap(ptr, frames, channels);
    if (!audioRunning()) {
      audio.dropped += frames;
      return frames;
    }
    const now = clockFrames();
    // A queue that ran dry starts again five milliseconds ahead of the clock, not in the past. One
    // that ran dry while the page was being hidden (its updates stop before its output does) is
    // the hiding's, not a break in the sound of the game being played.
    if (audio.next < now) {
      if (audio.next !== 0 && !audio.hid) audio.underruns += 1;
      audio.next = Math.ceil(now + audio.rate * 0.005);
    }
    audio.hid = false;
    const room = Math.floor(audio.rate - (audio.next - now));
    const n = Math.min(frames, Math.max(room, 0));
    if (n <= 0) return 0;
    const buffer = audio.context.createBuffer(channels, n, audio.rate);
    const samples = new Int16Array(memory.buffer, ptr, n * channels);
    for (let c = 0; c < channels; c++) {
      const out = buffer.getChannelData(c);
      for (let i = 0; i < n; i++) out[i] = samples[i * channels + c] / 32768;
    }
    const node = audio.context.createBufferSource();
    node.buffer = buffer;
    node.connect(audio.gain);
    node.onended = () => {
      const i = audio.nodes.indexOf(node);
      if (i >= 0) audio.nodes.splice(i, 1);
    };
    node.start(audio.next / audio.rate);
    audio.nodes.push(node);
    audio.next += n;
    return n;
  }

  function audioState() {
    if (!audio.open || !audio.context) return 0;
    return audio.context.state === 'running' ? 1 : 2;
  }

  function audioClear() {
    for (const node of audio.nodes) {
      try { node.stop(); } catch (e) { /* It has already stopped. */ }
    }
    audio.nodes = [];
    if (audio.context) audio.next = Math.ceil(clockFrames());
  }

  function audioClose() {
    audioClear();
    audio.open = false;
  }

  // A hidden page suspends the output, and a visible one resumes it. The updates wait for it (at
  // most half a second), so the game does not run on the clock in between.
  function onVisibility() {
    if (!audio.context || !started) return;
    if (document.hidden) {
      audio.suspendedByPage = true;
      audio.hid = true;
      audio.context.suspend().catch(() => {});
    } else if (audio.suspendedByPage) {
      audio.suspendedByPage = false;
      const until = performance.now() + 500;
      audio.resuming = until;
      audio.context.resume().then(() => {
        if (audio.resuming === until) audio.resuming = null;
      }, () => {
        audio.resuming = null;
      });
    }
  }
  document.addEventListener('visibilitychange', onVisibility);

  // --- the pointer --------------------------------------------------------------------------

  // A game that reads the mouse as relative counts asks for the pointer lock. A browser gives the
  // lock only for a click: the click that takes the lock belongs to the page, not to the game.
  const pointer = { wanted: false, locked: false, swallowUp: false, x: 0, y: 0, restX: 0, restY: 0 };

  // The plain lock, without `unadjustedMovement`: with it, the motion stopped at the window's
  // border in Chrome and Edge on a Windows PC (docs/lessons.md). The plain lock is the one that
  // brings the hidden cursor back to the middle of the window, at the price of the system's
  // pointer acceleration.
  function requestLock() {
    try {
      const request = canvas.requestPointerLock();
      if (request && request.catch) request.catch(() => {});
    } catch (e) { /* The browser refused; the next click asks again. */ }
  }

  function setRelativeMouse(enabled) {
    pointer.wanted = enabled !== 0;
    if (pointer.wanted && !pointer.locked) requestLock();
    if (!pointer.wanted && pointer.locked) document.exitPointerLock();
    return pointer.locked ? 1 : 0;
  }

  document.addEventListener('pointerlockchange', () => {
    pointer.locked = document.pointerLockElement === canvas;
    if (started) wasm.gp_capture(pointer.locked ? 1 : 0);
  });

  // A position on the canvas in page pixels, clamped to the page.
  function pagePoint(event) {
    const box = canvas.getBoundingClientRect();
    const x = Math.floor((event.clientX - box.left) * canvas.width / Math.max(box.width, 1));
    const y = Math.floor((event.clientY - box.top) * canvas.height / Math.max(box.height, 1));
    return [Math.min(Math.max(x, 0), canvas.width - 1), Math.min(Math.max(y, 0), canvas.height - 1)];
  }

  // --- the game's records, kept in the browser ----------------------------------------------

  // Each record that the game saves is kept in the browser's storage for this page's address, as
  // base64 under `sorz:NAME`, and goes back to the module at the next load, before the game
  // starts. A browser that refuses (no storage, or a full one) fails the save, as a disk would.
  const recordPrefix = 'sorz:';

  function toBase64(bytes) {
    let text = '';
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(text);
  }

  function fromBase64(text) {
    const raw = atob(text);
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }

  function storageSave(namePtr, nameLen, bytesPtr, len) {
    try {
      localStorage.setItem(recordPrefix + readString(namePtr, nameLen), toBase64(new Uint8Array(memory.buffer, bytesPtr, len)));
      return 1;
    } catch (e) {
      console.warn('[sorz] the browser did not keep a record: ' + e.message);
      return 0;
    }
  }

  function storageDelete(namePtr, nameLen) {
    try {
      localStorage.removeItem(recordPrefix + readString(namePtr, nameLen));
      return 1;
    } catch (e) {
      return 0;
    }
  }

  // The records of earlier loads. A damaged one is left out; without storage there are none.
  function storedRecords() {
    const records = [];
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (!key || !key.startsWith(recordPrefix)) continue;
        try {
          records.push([key.slice(recordPrefix.length), fromBase64(localStorage.getItem(key))]);
        } catch (e) { /* Not base64: left out. */ }
      }
    } catch (e) { /* No storage for this page. */ }
    return records;
  }

  // --- network play ---------------------------------------------------------------------------

  // The page's WebSockets for network play (sorzTransport, above), and the module's side of them:
  // the game connects, sends and closes through the imports below, and each opening, message and
  // end goes to the module (`gp_net_*`). A message crosses as bytes that the module takes.
  const netReasons = { closed: 0, lost: 1, refused: 2, protocol: 3, too_large: 4 };
  const netResults = { sent: 0, queue_full: 1, not_connected: 2, too_large: 3 };
  const net = {
    // The mode that the server of this page announces in `netplay.json`: 'native' (a native game
    // hosts here: this page is its client), 'relay' (server mode: this page is on the relay, the
    // host or a client) or null (this page plays alone).
    mode: null,
    manifest: null,
    transport: sorzTransport(window.WebSocket, {
      connected(id, incoming) { if (wasm) wasm.gp_net_connected(id, incoming ? 1 : 0); },
      received(id, data) {
        if (!wasm) return;
        const bytes = new Uint8Array(data);
        wasm.gp_net_received(id, place(bytes), bytes.length);
      },
      disconnected(id, reason) { if (wasm) wasm.gp_net_disconnected(id, netReasons[reason] ?? 1); },
      relay(state) {
        net.relayState = state;
        if (net.onRelay) net.onRelay(state);
      },
    }),
    onRelay: null,
    // The relay's last word to this page (`sorzTransport`'s `relay` states), for the checks.
    relayState: null,
    // The timer of the page's next connection to the relay, once it is off it.
    again: 0,
  };

  // The page's own words, in the game's capitals: the loading screen's, until the module draws it.
  const words = { loading: 'LOADING' };

  function netConnect(ptr, len) {
    if (!window.WebSocket) return 0;
    return net.transport.connect(readString(ptr, len));
  }

  function netSend(id, ptr, len) {
    // The page's copy: the module's memory can move before the socket sends.
    return netResults[net.transport.send(id, new Uint8Array(memory.buffer, ptr, len).slice().buffer)];
  }

  function netClose(id) {
    net.transport.close(id);
  }

  // The WebSocket at this page's own address (with its port, which the game's URLs need).
  function netUrl() {
    const path = (net.manifest && typeof net.manifest.websocket === 'string') ? net.manifest.websocket : '/';
    return 'ws://' + location.hostname + ':' + (location.port || '80') + path;
  }

  // What the server of this page says about network play.
  async function netMode() {
    try {
      const response = await fetch('netplay.json', { cache: 'no-store' });
      if (!response.ok) return;
      const manifest = await response.json();
      if (manifest.mode === 'native' || manifest.mode === 'relay') {
        net.mode = manifest.mode;
        net.manifest = manifest;
      }
    } catch (e) { /* No network play here. */ }
  }

  function log(level, ptr, len) {
    const text = '[sorz] ' + readString(ptr, len);
    if (level === 0) console.error(text);
    else if (level === 1) console.warn(text);
    else console.log(text);
  }

  const imports = {
    js_now: () => performance.now(),
    js_set_resolution: setResolution,
    js_present: present,
    js_audio_open: audioOpen,
    js_audio_queue: audioQueue,
    js_audio_queued: audioQueued,
    js_audio_state: audioState,
    js_audio_clear: audioClear,
    js_audio_close: audioClose,
    js_set_relative_mouse: setRelativeMouse,
    js_log: log,
    js_storage_save: storageSave,
    js_storage_delete: storageDelete,
    js_net_connect: netConnect,
    js_net_send: netSend,
    js_net_close: netClose,
    js_settings: applySettings,
  };

  // --- input --------------------------------------------------------------------------------

  function onKey(event, down) {
    if (!started) return;
    if (down) firstGesture();
    const used = wasm.gp_key(writeScratch(event.code), down ? 1 : 0, event.repeat ? 1 : 0);
    // A key that types a character also gives the text, after the key, as the native host does.
    // AltGr types the characters of the keyboard's third level.
    const altGraph = event.getModifierState && event.getModifierState('AltGraph');
    if (down && event.key.length === 1 && !event.ctrlKey && !event.metaKey && (!event.altKey || altGraph)) {
      wasm.gp_text(writeScratch(event.key));
    }
    // The game's keys do not reach the browser: the arrows do not scroll. The browser keeps its
    // own keys (F1, F5, F11, F12, Escape) and those the page's player does not use.
    if (used) event.preventDefault();
  }

  // The player's first click or key, the gesture after which a browser gives sound and the full
  // screen that the settings want.
  let gestured = false;

  function firstGesture() {
    if (gestured) return;
    gestured = true;
    if (audio.context) audio.context.resume().catch(() => {});
    if (view.fullscreen) enterFullscreen();
  }

  // A click asks again for the full screen that the settings want and the browser did not give.
  function onPageDown() {
    if (!started) return;
    firstGesture();
    if (view.fullscreen) enterFullscreen();
  }

  function onMouseDown(event) {
    if (!started) return;
    event.preventDefault();
    canvas.focus();
    if (pointer.wanted && !pointer.locked) {
      requestLock();
      pointer.swallowUp = true;
      return;
    }
    const [x, y] = pointer.locked ? [pointer.x, pointer.y] : pagePoint(event);
    wasm.gp_button(event.button, 1, x, y);
  }

  function onMouseUp(event) {
    if (!started) return;
    if (pointer.swallowUp) {
      pointer.swallowUp = false;
      return;
    }
    const [x, y] = pointer.locked ? [pointer.x, pointer.y] : pagePoint(event);
    wasm.gp_button(event.button, 0, x, y);
  }

  function onMouseMove(event) {
    if (!started) return;
    // Whole counts only; each axis keeps its remainder, so a slow motion on a display with
    // fractional device pixels does not round to zero.
    pointer.restX += event.movementX || 0;
    pointer.restY += event.movementY || 0;
    const dx = Math.trunc(pointer.restX);
    const dy = Math.trunc(pointer.restY);
    pointer.restX -= dx;
    pointer.restY -= dy;
    if (pointer.locked) {
      pointer.x = Math.min(Math.max(pointer.x + dx, 0), canvas.width - 1);
      pointer.y = Math.min(Math.max(pointer.y + dy, 0), canvas.height - 1);
    } else {
      [pointer.x, pointer.y] = pagePoint(event);
    }
    if (dx !== 0 || dy !== 0 || !pointer.locked) wasm.gp_motion(dx, dy, pointer.x, pointer.y);
  }

  function onWheel(event) {
    if (!started) return;
    event.preventDefault();
    // One step for each event. Up, away from the player, is positive, as the native host has it.
    wasm.gp_wheel(Math.sign(event.deltaX), -Math.sign(event.deltaY));
  }

  // The gamepads, polled at each animation frame (the Gamepad API has no events for buttons). Each
  // change goes to the module by the gamepad's index and the standard mapping's numbers; the
  // module maps them (src/web/gamepad.zig). A browser shows a gamepad only after one of its
  // buttons is pressed.
  const pads = [];

  function gamepads() {
    return navigator.getGamepads ? Array.from(navigator.getGamepads()) : [];
  }

  function pollGamepads() {
    const list = gamepads();
    const count = Math.max(list.length, pads.length);
    for (let i = 0; i < count; i++) {
      const pad = list[i];
      let seen = pads[i];
      if (!pad || !pad.connected) {
        if (seen) {
          wasm.gp_pad(i, 0, 0);
          pads[i] = null;
        }
        continue;
      }
      if (!seen) {
        // Its id names it for the game (its model; the module takes a name from it).
        wasm.gp_pad(i, 1, writeScratch(pad.id || ''));
        seen = pads[i] = { buttons: [], axes: [] };
      }
      for (let b = 0; b < pad.buttons.length; b++) {
        const button = pad.buttons[b];
        // The triggers (6, 7) are axes: their pressure. The others are pressed or not.
        const value = (b === 6 || b === 7) ? Math.round(button.value * 32767) : (button.pressed ? 1 : 0);
        if (seen.buttons[b] === value) continue;
        if (button.pressed) firstGesture();
        seen.buttons[b] = value;
        wasm.gp_pad_button(i, b, button.pressed ? 1 : 0, value);
      }
      for (let a = 0; a < Math.min(pad.axes.length, 4); a++) {
        const value = Math.round(Math.max(-1, Math.min(1, pad.axes[a])) * 32767);
        if (seen.axes[a] === value) continue;
        seen.axes[a] = value;
        wasm.gp_pad_axis(i, a, value);
      }
    }
  }

  function installInput() {
    window.addEventListener('keydown', (event) => onKey(event, true));
    window.addEventListener('keyup', (event) => onKey(event, false));
    canvas.addEventListener('mousedown', onMouseDown);
    window.addEventListener('mousedown', onPageDown);
    window.addEventListener('mouseup', onMouseUp);
    document.addEventListener('mousemove', onMouseMove);
    canvas.addEventListener('wheel', onWheel, { passive: false });
    canvas.addEventListener('contextmenu', (event) => event.preventDefault());
    window.addEventListener('blur', () => { if (started) wasm.gp_focus(0); });
    window.addEventListener('focus', () => { if (started) wasm.gp_focus(1); });
  }

  // --- running ------------------------------------------------------------------------------

  // What the player sees now, for the checks: the text of the module's screen or of the page's
  // own ('' while the game plays without a message).
  let shown = '';

  // The page's own text: until the module draws its screens, and for what it cannot draw. `more`
  // is a finer line below (an error's reason, what to do).
  function say(text, more = '') {
    shown = more === '' ? text : text + '\n' + more;
    message.textContent = text;
    detail.textContent = more;
    detail.classList.toggle('hidden', more === '');
    overlay.classList.remove('hidden', 'screen', 'over');
  }

  // A message on the module's screen, over the game's picture once it has one; the page's own text
  // when the module cannot draw it.
  function showMessage(text, more = '') {
    if (!screens) {
      say(text, more);
      return;
    }
    shown = more === '' ? text : text + '\n' + more;
    wasm.gp_screen_message(writeScratch(shown), 1);
    overlay.classList.remove('hidden');
    overlay.classList.add('screen');
  }

  function stop(text, more = '') {
    started = false;
    phase = 'stopped';
    net.onRelay = null;
    clearTimeout(net.again);
    // A page that no longer plays leaves the relay: a host's clients hear that it left.
    net.transport.leaveRelay();
    if (document.pointerLockElement) document.exitPointerLock();
    overlay.onclick = null;
    overlay.dataset.state = 'stopped';
    showMessage(text, more);
  }

  // Timing of the updates, for the page's checks and for anyone who looks (`sorz.stats()`).
  const stats = { updates: 0, since: 0, slow: 0, slowLog: [], longest: 0, total: 0, filesMs: 0, startMs: 0, readyMs: 0 };

  function frame() {
    if (!started) return;
    if (!checks.manual) requestAnimationFrame(frame);
    // The output is coming back after a hidden page: the updates wait for it.
    if (audio.resuming !== null) {
      if (performance.now() < audio.resuming && !audioRunning()) return;
      audio.resuming = null;
    }
    update();
  }

  function update() {
    pollGamepads();
    const before = performance.now();
    let result;
    try {
      result = wasm.gp_frame();
    } catch (e) {
      stop('THE GAME STOPPED', e.message);
      return result;
    }
    const took = performance.now() - before;
    stats.updates += 1;
    stats.total += took;
    stats.longest = Math.max(stats.longest, took);
    if (took > 1000 / 60) {
      stats.slow += 1;
      // The first slow updates, with where the game was: [ms, tick].
      if (stats.slowLog.length < 50) {
        const state = window.sorz.inspect();
        stats.slowLog.push([Math.round(took * 10) / 10, state.ticks]);
      }
    }
    if (result === 1) stop('THE GAME HAS ENDED', 'Reload the page to play again.');
    else if (result !== 0) stop('THE GAME STOPPED', errorText());
    return result;
  }

  // On a relay: the page connects to it as it loads, and the relay gives it its role, which the
  // game takes (`gp_start_netplay`, the page bringing the connections): the first page hosts
  // (player 1), every other is its client. Once the page is off the relay (its host left, the
  // connection ended or never opened, its game closed its connection to the host), it connects
  // again a second later, and the game takes the role it then gets: the host, maybe, its host gone.
  function joinRelay() {
    net.onRelay = (state) => {
      if (state === 'host' || state === 'client') {
        startNetplay(state === 'host' ? 1 : 0, '');
        return;
      }
      clearTimeout(net.again);
      net.again = setTimeout(joinRelay, 1000);
    };
    net.transport.joinRelay(netUrl());
  }

  function startNetplay(role, url) {
    if (wasm.gp_start_netplay(role, writeScratch(url)) === 0) return true;
    stop('NETWORK PLAY CANNOT START', errorText());
    return false;
  }

  // The game runs: its own front end, one update for each animation frame (or `sorz.step`'s).
  function run() {
    phase = 'playing';
    started = true;
    shown = '';
    overlay.classList.add('hidden');
    canvas.focus();
    stats.since = performance.now();
    if (!checks.manual) requestAnimationFrame(frame);
  }

  // A request whose answer stops coming (nothing for `stallMs`) is asked again, three times at
  // most: a connection that the server never answers must not stop the load for good.
  const stallMs = 10000;

  async function fetchBytes(url) {
    for (let attempt = 1; ; attempt += 1) {
      try {
        return await fetchOnce(url);
      } catch (e) {
        if (attempt === 3 || e.stalled !== true) throw e;
        console.warn('[sorz] ' + url + ': no answer for ' + stallMs / 1000 + ' s, asked again');
      }
    }
  }

  async function fetchOnce(url) {
    const abort = new AbortController();
    let stalled = false;
    let timer = 0;
    const rearm = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        stalled = true;
        abort.abort();
      }, stallMs);
    };
    rearm();
    try {
      const response = await fetch(url, { signal: abort.signal });
      if (!response.ok) throw new Error(url + ': ' + response.status + ' ' + response.statusText);
      const reader = response.body.getReader();
      const chunks = [];
      let size = 0;
      for (;;) {
        rearm();
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        size += value.length;
      }
      const bytes = new Uint8Array(size);
      let at = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, at);
        at += chunk.length;
      }
      return bytes.buffer;
    } catch (e) {
      if (!stalled) throw e;
      const late = new Error(url + ': no answer for ' + stallMs / 1000 + ' s');
      late.stalled = true;
      throw late;
    } finally {
      clearTimeout(timer);
    }
  }

  // Bytes into memory that `gp_alloc` gives.
  function place(bytes) {
    const ptr = wasm.gp_alloc(bytes.length);
    if (!ptr) throw new Error('the browser gave the game no more memory');
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  }

  function giveNamed(name, bytes, add) {
    const encoded = encoder.encode(name);
    const namePtr = place(encoded);
    const dataPtr = place(bytes);
    const result = add(namePtr, encoded.length, dataPtr, bytes.length);
    return { result, namePtr, nameLen: encoded.length, dataPtr, dataLen: bytes.length };
  }

  async function instantiate() {
    const limits = memoryLimits(code);
    if (!limits) throw new Error('the module imports no memory');
    memory = new WebAssembly.Memory(limits.maximum === undefined
      ? { initial: limits.initial }
      : { initial: limits.initial, maximum: limits.maximum });
    const { instance } = await WebAssembly.instantiate(code, { env: { memory, ...imports, ...sorzHelpers(memory) } });
    wasm = instance.exports;
    wasm.gp_init();
  }

  // Lets the page draw its last screen before a long step (at the next frame, or after a tenth of
  // a second in a hidden page, which draws no frames).
  function paint() {
    return new Promise((resolve) => {
      let done = false;
      const go = () => {
        if (done) return;
        done = true;
        setTimeout(resolve, 0);
      };
      requestAnimationFrame(go);
      setTimeout(go, 100);
    });
  }

  // The game's files from the page's server, six at a time, into the module: first those the
  // module draws its screens from, which then show the count of the others. A file of another
  // size than the listed one stops the load: a server's error page is not a game file.
  const loading = { done: 0, total: 0 };

  async function loadFiles(listing) {
    const first = readScratch(wasm.gp_screen_files()).split('\n').filter((name) => name !== '');
    const files = sorzListing(listing, first);
    const firstCount = files.filter((f) => sorzFirst(f.name, first) >= 0).length;
    loading.total = files.length;
    let next = 0;
    let drawn = 0;
    const progress = (last) => {
      // The module draws from here on, once it has its files (or, without them, never).
      if (!screens && (loading.done === firstCount || last)) screens = wasm.gp_screen_open() === 0;
      const now = performance.now();
      if (!last && now - drawn < 50) return;
      drawn = now;
      const percent = loading.total === 0 ? 100 : Math.min(100, Math.floor((loading.done * 100) / loading.total));
      if (!screens) {
        say(words.loading + ' ' + percent + '%');
        return;
      }
      shown = words.loading + ' ' + percent + '%';
      wasm.gp_screen_loading(loading.done, loading.total);
      overlay.classList.add('screen');
    };
    const fetchSome = async (limit) => {
      while (next < limit) {
        const file = files[next++];
        const bytes = new Uint8Array(await fetchBytes(file.url));
        if (bytes.length !== file.size) throw new Error(file.name + ': ' + bytes.length + ' bytes, not ' + file.size);
        const given = giveNamed(file.name, bytes, wasm.gp_add_asset);
        if (given.result !== 0) {
          wasm.gp_free(given.namePtr, given.nameLen);
          wasm.gp_free(given.dataPtr, given.dataLen);
          throw new Error(errorText());
        }
        loading.done += 1;
        progress(loading.done === loading.total);
      }
    };
    const workers = (limit) => Promise.all(Array.from({ length: 6 }, () => fetchSome(limit)));
    await workers(firstCount);
    progress(firstCount === files.length);
    await workers(files.length);
  }

  // --- the page's checks ----------------------------------------------------------------------

  // For the page's automated checks (`zig build browser-check`) and for debugging from the
  // console. `manual` leaves the updates to `step` (from the start with the address's `#manual`,
  // which the server never sees); `audioTap` sees every block that the game queues, before the
  // output takes it.
  const checks = { manual: location.hash === '#manual', audioTap: null };

  window.sorz = {
    get phase() { return phase; },
    // Network play's mode here (null, 'native' or 'relay'), from `netplay.json`.
    get netMode() { return net.mode; },
    // On a relay: the page's role ('host', 'client'), or why it is off the relay ('unreachable',
    // 'host_left', 'lost', 'closed'); null before the relay answered.
    get relayState() { return net.relayState; },
    // The text the player sees now: the module's screen's, or the page's own.
    get message() { return shown; },
    // The game's files the page has, and the listing's count.
    get files() { return { done: loading.done, total: loading.total }; },
    // Whether the module draws the page's screens.
    get screens() { return screens; },
    inspect() {
      const n = wasm ? wasm.gp_inspect() : 0;
      return n ? JSON.parse(readScratch(n)) : null;
    },
    stats() {
      const now = performance.now();
      const state = this.inspect();
      return {
        updates: stats.updates,
        seconds: (now - stats.since) / 1000,
        ticks: state ? state.ticks : 0,
        slow_updates: stats.slow,
        slow_log: stats.slowLog,
        longest_update_ms: stats.longest,
        mean_update_ms: stats.updates ? stats.total / stats.updates : 0,
        total_update_ms: stats.total,
        files_ms: stats.filesMs,
        start_ms: stats.startMs,
        ready_ms: stats.readyMs,
        memory_bytes: memory ? memory.buffer.byteLength : 0,
        audio_state: audio.context ? audio.context.state : 'none',
        audio_rate: audio.rate,
        audio_dropped: audio.dropped,
        audio_underruns: audio.underruns,
        audio_base_latency: audio.context ? audio.context.baseLatency : 0,
        // The gain the output has now (null before the game opens its sound).
        audio_gain: audio.gain ? audio.gain.gain.value : null,
      };
    },
    // The settings as the page applies them (`js_settings`), the full screen the browser gives,
    // and the canvas's size on the page, in CSS pixels.
    get view() {
      return {
        ...view,
        in_fullscreen: !!document.fullscreenElement,
        canvas: [parseFloat(canvas.style.width), parseFloat(canvas.style.height)],
        device_pixel_ratio: window.devicePixelRatio || 1,
      };
    },
    // The checks drive the updates themselves (`step`): set as soon as the page is ready; the
    // animation frames that were going on stop at the next.
    set manual(value) {
      const was = checks.manual;
      checks.manual = !!value;
      if (was && !checks.manual && started) {
        // The page's own updates from now: its timing counts from here.
        Object.assign(stats, { updates: 0, since: performance.now(), slow: 0, slowLog: [], longest: 0, total: 0 });
        requestAnimationFrame(frame);
      }
    },
    get manual() { return checks.manual; },
    setPacing(perUpdate) { wasm.gp_set_pacing(perUpdate ? 1 : 0); },
    step(count) {
      // A page that stopped runs nothing more.
      if (phase === 'stopped') return 1;
      if (!started) return -1;
      let result = 0;
      for (let i = 0; i < count && result === 0; i++) result = update();
      return result;
    },
    set audioTap(fn) { checks.audioTap = fn; },
    samples(ptr, frames, channels) { return new Int16Array(memory.buffer, ptr, frames * channels); },
    canvasPixels() { return context.getImageData(0, 0, canvas.width, canvas.height).data; },
  };

  // --- start-up -----------------------------------------------------------------------------

  async function load() {
    say(words.loading);
    const began = performance.now();
    await netMode();
    let listing;
    try {
      listing = JSON.parse(decoder.decode(await fetchBytes('assets/manifest.json')));
    } catch (e) {
      stop('THIS PAGE HAS NO GAME FILES', 'Its server sends none. Open the page from the game, which ' +
        'serves it with its files: sorz-server DIR --server PORT, or sorz-sdl DIR --netplay PORT.');
      return;
    }
    code = await fetchBytes('sorz.wasm');
    await instantiate();
    installInput();
    try {
      await loadFiles(listing);
    } catch (e) {
      stop('THE GAME\'S FILES DID NOT ARRIVE', e.message);
      return;
    }
    stats.filesMs = performance.now() - began;
    await paint();
    // The records of earlier loads, before the game reads them.
    for (const [name, bytes] of storedRecords()) {
      if (giveNamed(name, bytes, wasm.gp_add_record).result !== 0) console.warn('[sorz] a kept record was left out: ' + name);
    }
    const loaded = performance.now();
    if (wasm.gp_start() !== 0) {
      stop('THE GAME CANNOT START ON THESE FILES', errorText());
      return;
    }
    stats.startMs = performance.now() - loaded;
    stats.readyMs = performance.now();
    // A native game hosts here: this page is its client, its game connecting to the host itself.
    // A relay: the page connects to it now, and its game takes the role it gets.
    if (net.mode === 'native' && !startNetplay(0, netUrl())) return;
    if (net.mode === 'relay') joinRelay();
    // The checks may take the updates over before the first frame.
    await Promise.resolve();
    run();
  }

  load().catch((e) => stop('THE PAGE CANNOT START', e.message));
})();

if (typeof module === 'object') module.exports = { sorzHelpers, sorzListing, sorzTransport };
