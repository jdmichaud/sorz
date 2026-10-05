// The host of the browser build. It loads the WebAssembly module and the game's files from the
// server that sent this page (the native game, from the user's own copy: DESIGN.md 5.3), then
// runs the game: one update for each animation frame, the frames to the canvas, the keys, the
// gamepads and the sound to the module and back. The player never picks or uploads a file. The
// module keeps the tables of keys and buttons and all game logic, and draws the page's screens in
// the game's style once its first files are in (`gp_screen_*`, src/web/main.zig); this script only
// moves data, and its own text stands in, in the game's colours, until then and for an error the
// module cannot draw (a tree without the game's font and menu). The game's settings record is the page's only settings:
// the game's screen is to change it, and the script applies it as a browser does (the gain, the
// scale, the full screen).
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

// The page's side of network play's transport (DESIGN.md 9, PLAN A1 and A2): whole binary
// messages over WebSockets, by connection, reported to `events` as the platform contract's events:
// `connected(id, incoming)`, `received(id, bytes)` (an ArrayBuffer) and `disconnected(id,
// reason)`, the reason one of 'closed', 'lost', 'refused', 'protocol' and 'too_large'. Per
// connection: connected, then its messages in order, then disconnected; nothing follows a close
// by the game.
//
// `connect(url)` is the game's connection to a native host. `joinRelay(url)` is the page's own
// (server mode, src/native/relay.zig): the relay's text messages go to `events.relay(state)`,
// first the page's role, 'host' or 'guest', or why it has none: 'busy' (two players are playing
// there) or 'unreachable'; then, once, why the relay connection ended, if the page did not end
// it: 'host_left' (a guest's host left) or 'lost'. A guest's socket is its connection to the
// host. A host's socket is not a connection at all: each guest that the relay announces ('peer')
// is an incoming connection of its own, until it has 'left' (DESIGN.md 9: the game's host logic
// needs no listening socket). The host's page answers each 'left' with 'left', so that the relay
// knows which of its messages were for the guest that left. When the host's game closes its
// guest's connection, the page lets that guest go but stays with the relay: the guest's messages
// are dropped until the relay says it has left. `leaveRelay()` ends the page's relay connection.
//
// The module's side is `js_net_connect`, `js_net_send` and `js_net_close` over `connect`, `send`
// and `close`, and `gp_net_connected`, `gp_net_received` and `gp_net_disconnected` from the events.
// The page learns the mode from `netplay.json`, which the native host and the relay serve
// (`{"mode": "native" | "relay", "websocket": "/"}`), and starts the session through the module
// (`gp_start_netplay`): a native host's guest connects to `ws://<the page's host>/`; on a relay, a
// page whose player chose 2 PLAYERS joins it and the module takes the first connection as its
// peer, and one whose player chose 1 PLAYER never joins it.
function sorzTransport(Socket, events, limits = {}) {
  const maxMessage = limits.maxMessage || 64 * 1024;
  const maxQueued = limits.maxQueued || 1024 * 1024;
  // Connections by id: { socket, open, closedByGame } for a socket of the game's; a relay's guest
  // (on the host's page) is { relay, open } over the relay's socket.
  const connections = new Map();
  let nextId = 1;
  let relay = null;

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

  // A message of the game's: binary and within the size limit, else the connection ends.
  function deliver(id, data) {
    const c = connections.get(id);
    if (!c || !c.open) return;
    const reason = typeof data === 'string' ? 'protocol' : data.byteLength > maxMessage ? 'too_large' : null;
    if (reason === null) {
      events.received(id, data);
      return;
    }
    if (c.socket) c.socket.close(1002);
    else if (c.relay && c.relay.role === 'guest') c.relay.socket.close(1002);
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

  function joinRelay(url) {
    // `guest`: the id of the guest's connection (the host's, on a guest's page), kept on a
    // host's page until the relay says that guest left, even once the game has closed it.
    const r = { socket: null, role: null, guest: 0, hostLeft: false, ended: false };
    relay = r;
    const finish = (state) => {
      if (r.ended) return;
      r.ended = true;
      events.relay(state);
    };
    const guestJoined = (incoming) => {
      r.guest = nextId++;
      connections.set(r.guest, { relay: r, open: true, closedByGame: false });
      events.connected(r.guest, incoming);
    };
    r.socket = socketFor(url, () => {}, (data) => {
      if (typeof data !== 'string') {
        if (r.guest !== 0) deliver(r.guest, data);
        return;
      }
      if (r.role === null) {
        if (data === 'host' || data === 'guest') {
          r.role = data;
          events.relay(data);
          if (data === 'guest') guestJoined(false);
        } else if (data === 'busy') {
          finish('busy');
        }
      } else if (r.role === 'host' && data === 'peer' && r.guest === 0) {
        guestJoined(true);
      } else if (r.role === 'host' && data === 'left') {
        r.socket.send('left');
        const id = r.guest;
        r.guest = 0;
        end(id, 'closed');
      } else if (r.role === 'guest' && data === 'left') {
        r.hostLeft = true;
      }
    }, () => {
      const id = r.guest;
      r.guest = 0;
      if (id !== 0) end(id, r.hostLeft ? 'closed' : 'lost');
      if (relay === r) relay = null;
      if (r.role === null) finish('unreachable');
      else finish(r.hostLeft ? 'host_left' : 'lost');
    });
    if (!r.socket) Promise.resolve().then(() => finish('unreachable'));
  }

  // The page leaves the relay: its connection ends, and no event follows.
  function leaveRelay() {
    const r = relay;
    if (!r) return;
    relay = null;
    r.ended = true;
    const id = r.guest;
    r.guest = 0;
    const c = connections.get(id);
    if (c) c.closedByGame = true;
    connections.delete(id);
    if (r.socket) r.socket.close(1000);
  }

  // 'sent', 'queue_full', 'not_connected' or 'too_large'; a message is queued whole or not at all.
  function send(id, bytes) {
    const c = connections.get(id);
    if (!c || !c.open) return 'not_connected';
    if (bytes.byteLength > maxMessage) return 'too_large';
    const socket = c.socket || c.relay.socket;
    if (socket.bufferedAmount + bytes.byteLength > maxQueued) return 'queue_full';
    socket.send(bytes);
    return 'sent';
  }

  // The game's close: the socket closes after what it has queued, and no event follows. On a
  // relay, a guest's game leaves the relay; a host's game lets its guest go and stays.
  function close(id) {
    const c = connections.get(id);
    if (!c) return;
    c.closedByGame = true;
    connections.delete(id);
    if (c.socket) c.socket.close(1000);
    else if (c.relay && c.relay.role === 'guest') {
      c.relay.ended = true;
      c.relay.guest = 0;
      c.relay.socket.close(1000);
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
  // The page's phases: `loading` (the module and the game's files), `ready` (the choice that
  // starts the game), `settings` (the game's settings screen, opened from that choice before the
  // game starts), `playing`, `stopped`.
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
  // page's only settings: the player changes them on the game's settings screen, which the menu's
  // SETTINGS line and its key (F1 at first) open. The module tells the page the record's sound and
  // window when the game starts and whenever they change (`js_settings`), and the page applies
  // them:
  //
  // - the sound: the gain of the output (the game's volume curve, 0 with the sound off). The game
  //   queues its sound at its own level, so this gain is the only one.
  // - the scale: the picture's whole multiple, in the page's pixels made whole device pixels; the
  //   largest that fits when the window is smaller (`fit`).
  // - full screen: the page's. A browser gives it only at a click or a key: the click or key that
  //   starts the game, the key that turns it on (on the settings screen, from the menu too), or a
  //   later click. Until then the picture fills the window. Leaving it (Escape is the browser's)
  //   turns the setting off, as the player chose.
  const view = { gain: 1, scale: 3, fullscreen: false };

  function applySettings(gain, scale, fullscreen) {
    view.gain = gain;
    view.scale = scale;
    view.fullscreen = fullscreen !== 0;
    if (audio.gain) audio.gain.gain.value = gain;
    if (!view.fullscreen && document.fullscreenElement) document.exitFullscreen().catch(() => {});
    if (view.fullscreen && (started || phase === 'settings')) enterFullscreen();
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
  // is at most one second. The context is made by the click that starts the game (a browser starts
  // sound only after a gesture), at the rate that the game asks for (48 kHz).
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
    // hosts here: this page joins as player 2), 'relay' (server mode: this page plays alone or
    // joins the relay) or null (this page plays alone).
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
  };

  // The page's words, in the game's: its capitals and its menu's plain lines.
  const again = 'RELOAD THE PAGE TO PLAY AGAIN';
  const words = {
    loading: 'LOADING',
    joining: 'JOINING',
    waiting: 'WAITING FOR PLAYER 2',
    guestLeft: 'PLAYER 2 LEFT\nWAITING FOR PLAYER 2',
    hostAway: 'PLAYER 1 CANNOT BE REACHED\nTRYING AGAIN',
    // The other player opened the settings screen, which holds both games.
    inSettings: ['PLAYER 2 IS IN THE SETTINGS MENU', 'PLAYER 1 IS IN THE SETTINGS MENU'],
    desynced: 'THE TWO GAMES DIFFER\nTHE GAME STOPPED',
    ended: 'THE NETWORK GAME ENDED\n' + again,
    finished: 'THE GAME HAS ENDED\n' + again,
    // The relay's answers before a role: the menu again, with this note and 2 PLAYERS dimmed.
    busy: 'TWO PLAYERS ARE PLAYING HERE',
    unreachable: 'NETWORK PLAY CANNOT START HERE',
    // After a role: the game ends.
    host_left: 'PLAYER 1 LEFT\n' + again,
    lost: 'THE CONNECTION WAS LOST\n' + again,
  };

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

  // What the session's state says to the player over the picture, or '' while it plays (and
  // while the player's own settings screen is open).
  function netMessage() {
    const state = window.sorz.inspect();
    if (!state || !state.net) return '';
    const host = state.net.role === 'host';
    switch (state.net.phase) {
      case 'idle': return host ? words.waiting : words.joining;
      case 'handshake': return words.joining;
      case 'desynced': return words.desynced;
      case 'ended': return words.ended;
      default:
        // A session in play without its connection holds: the host waits for its guest, which
        // comes back (a native game's) or is replaced (a relay's), and a guest of a native host
        // reconnects.
        if (state.net.connected) return state.net.peer_in_settings ? words.inSettings[host ? 0 : 1] : '';
        return host ? words.guestLeft : words.hostAway;
    }
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
    if (!started && phase !== 'settings') {
      if (phase === 'stopped') return;
      // The game's settings key (F1 at first) is the game's from the start: the browser never
      // gets it (its F1 opens no help). On the choice that starts the game, it opens the game's
      // settings screen, as the menu's SETTINGS line does.
      if (wasm.gp_settings_key(writeScratch(event.code)) === 1) {
        event.preventDefault();
        if (down && !event.repeat && phase === 'ready') openSettings();
        return;
      }
      // On the choice that starts the game, the arrows move the arrow, as on the game's menu, and
      // Enter or Space, a gesture as a click is, chooses; not their repeats, so that a key held
      // since the settings screen closed chooses nothing.
      if (!down || phase !== 'ready') return;
      if (event.code === 'ArrowUp' || event.code === 'ArrowDown') {
        event.preventDefault();
        moveChoice(event.code === 'ArrowUp' ? -1 : 1);
      } else if (event.code === 'Enter' || event.code === 'Space') {
        event.preventDefault();
        if (!event.repeat) choose(menu.choice);
      }
      return;
    }
    const used = wasm.gp_key(writeScratch(event.code), down ? 1 : 0, event.repeat ? 1 : 0);
    // A key that types a character also gives the text, after the key, as the native host does.
    // AltGr types the characters of the keyboard's third level.
    const altGraph = event.getModifierState && event.getModifierState('AltGraph');
    if (down && event.key.length === 1 && !event.ctrlKey && !event.metaKey && (!event.altKey || altGraph)) {
      wasm.gp_text(writeScratch(event.key));
    }
    // The game's keys do not reach the browser: the arrows do not scroll, F1 opens no help. The
    // browser keeps its own keys (F5, F11, F12, Escape) and those the page's player does not use.
    if (used) event.preventDefault();
  }

  // A click asks again for the full screen that the settings want and the browser did not give.
  function onPageDown() {
    if ((started || phase === 'settings') && view.fullscreen) enterFullscreen();
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
  // buttons is pressed. The menu reads them itself (`readMenuPads`); a button that chose a line
  // there (`held`, `index:button`) is not given to the module until it is released, so that the
  // A that chose SETTINGS does not choose on the settings screen too.
  const pads = [];
  const held = new Set();

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
          wasm.gp_pad(i, 0);
          pads[i] = null;
        }
        continue;
      }
      if (!seen) {
        wasm.gp_pad(i, 1);
        seen = pads[i] = { buttons: [], axes: [] };
      }
      for (let b = 0; b < pad.buttons.length; b++) {
        const button = pad.buttons[b];
        // The triggers (6, 7) are axes: their pressure. The others are pressed or not.
        const value = (b === 6 || b === 7) ? Math.round(button.value * 32767) : (button.pressed ? 1 : 0);
        if (held.has(i + ':' + b)) {
          if (!button.pressed) held.delete(i + ':' + b);
          seen.buttons[b] = value;
          continue;
        }
        if (seen.buttons[b] === value) continue;
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
    // Network play's messages are over: the stop's own stays.
    session.on = false;
    net.onRelay = null;
    // A page that no longer plays makes room on the relay for the next one.
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

  // Network play's message over the picture, looked up a few times a second and drawn over each
  // picture the game presents while there is one; without the module's screens, the page's own
  // text says it (`shownText`: what it says now).
  const session = { on: false, text: '', at: 0, shownText: '' };

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
    if (result === 1) stop(words.finished);
    else if (result !== 0) stop('THE GAME STOPPED', errorText());
    else if (session.on) {
      if (before - session.at > 250) {
        session.at = before;
        session.text = netMessage();
      }
      shown = session.text;
      if (screens) {
        if (session.text !== '') wasm.gp_screen_message(writeScratch(session.text), 1);
      } else if (session.text !== session.shownText) {
        session.shownText = session.text;
        if (session.text === '') overlay.classList.add('hidden');
        else {
          say(session.text);
          overlay.classList.add('over');
        }
      }
    }
    return result;
  }

  // The choice that starts the game, as the game's menu has it: 1 PLAYER plays alone on this page,
  // 2 PLAYERS with another player over the network, and SETTINGS opens the game's settings screen
  // without starting the game. The game then plays the network variant (DESIGN.md 10.7): its own
  // menu, after the title, has no 1 PLAYER or 2 PLAYERS (this choice made them), but START,
  // SETTINGS and OPTIONS. A relay offers all three; a native game that hosts here, 2 PLAYERS
  // only (its player is player 1); a server without network play, 1 PLAYER only; SETTINGS whenever
  // the game has its settings screen (`gp_settings_available`). `available` has a bit for each
  // line; `note` is a line below. The arrows and Enter choose, or a gamepad's d-pad and A or Start,
  // or a click.
  const menuLines = ['1 PLAYER', '2 PLAYERS', 'SETTINGS'];
  const settingsLine = 2;
  const menu = { choice: 0, available: 1, note: '' };

  function ready(choice, available, note = '') {
    phase = 'ready';
    const settings = wasm.gp_settings_available() !== 0 ? 1 << settingsLine : 0;
    Object.assign(menu, { choice, available: (available & ~(1 << settingsLine)) | settings, note });
    drawMenu();
    overlay.dataset.state = 'ready';
    overlay.onclick = (event) => {
      const line = screens ? wasm.gp_screen_pick(...pagePoint(event)) : -1;
      choose(line < 0 ? menu.choice : line);
    };
    // Only a press from now on chooses: not the button that left the settings screen.
    readMenuPads(false);
    startMenuFrames();
    // The menu's sounds, if they could not be made before it showed.
    setTimeout(prepareMenuSounds, 0);
  }

  function drawMenu() {
    const lines = menuLines.map((word, i) => (i === menu.choice ? '\u25B6 ' : '') + word +
      ((menu.available >> i) & 1 ? '' : ' (not here)'));
    shown = [...lines, menu.note].filter((line) => line !== '').join('\n');
    if (!screens) {
      say(lines.join('\n'), menu.note);
      return;
    }
    wasm.gp_screen_menu(menu.choice, menu.available, writeScratch(menu.note));
    overlay.classList.remove('hidden');
    overlay.classList.add('screen');
  }

  // The arrow to the next line that the menu offers, up or down, round the end, with the game's
  // menu's sound.
  function moveChoice(step) {
    const n = menuLines.length;
    for (let i = 1; i <= n; i++) {
      const line = (menu.choice + step * i + 2 * n) % n;
      if ((menu.available >> line) & 1) {
        if (line !== menu.choice) playMenuSound(0);
        menu.choice = line;
        break;
      }
    }
    drawMenu();
  }

  function choose(line) {
    playMenuSound(1);
    if (line === settingsLine) openSettings();
    else begin(line);
  }

  // The game's menu sounds on the page's menu: the arrow's move and a choice, which the module
  // makes as the game plays them (48 kHz stereo frames), played at the settings' volume. They are
  // made before the menu shows, not when a key wants them: making one takes a while in a debug
  // build, and the first move would wait for it.
  const menuSounds = [];

  function prepareMenuSounds() {
    for (const which of [0, 1]) {
      if (menuSounds[which]) continue;
      const frames = wasm.gp_menu_sound(which);
      if (frames === 0) continue;
      const pcm = new Int16Array(memory.buffer, wasm.gp_menu_sound_ptr(), frames * 2);
      const left = new Float32Array(frames);
      const right = new Float32Array(frames);
      for (let i = 0; i < frames; i++) {
        left[i] = pcm[2 * i] / 32768;
        right[i] = pcm[2 * i + 1] / 32768;
      }
      menuSounds[which] = [left, right];
    }
  }

  function playMenuSound(which) {
    const context = ensureAudioContext(48000);
    if (!context) return;
    context.resume().catch(() => {});
    if (!menuSounds[which]) prepareMenuSounds();
    const sound = menuSounds[which];
    if (!sound) return;
    const buffer = context.createBuffer(2, sound[0].length, 48000);
    buffer.copyToChannel(sound[0], 0);
    buffer.copyToChannel(sound[1], 1);
    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(audio.gain);
    source.start();
  }

  // The menu reads the gamepads itself, by the standard mapping: the d-pad's up and down move the
  // arrow, A (the bottom face button) or Start chooses, each when pressed, not while held. With
  // `act` false, it only takes note of the buttons held now.
  const menuPads = [];
  const menuButtons = { up: 12, down: 13, a: 0, start: 9 };

  function readMenuPads(act) {
    const list = gamepads();
    for (let i = 0; i < list.length; i++) {
      const pad = list[i];
      const before = menuPads[i] || [];
      const now = pad && pad.connected ? pad.buttons.map((button) => button.pressed) : [];
      menuPads[i] = now;
      const pressed = (b) => act && phase === 'ready' && now[b] && !before[b];
      if (pressed(menuButtons.up)) moveChoice(-1);
      if (pressed(menuButtons.down)) moveChoice(1);
      for (const b of [menuButtons.a, menuButtons.start]) {
        if (!pressed(b)) continue;
        choose(menu.choice);
        // The button that chose is the menu's until it is released.
        if (phase !== 'ready') held.add(i + ':' + b);
      }
    }
  }

  // The menu's animation frames, and those of the settings screen opened from it; `sorz.step`
  // runs them when the checks drive the page.
  let menuFrames = false;

  function startMenuFrames() {
    if (menuFrames || checks.manual) return;
    menuFrames = true;
    requestAnimationFrame(menuFrame);
  }

  function menuFrame() {
    if (checks.manual || (phase !== 'ready' && phase !== 'settings')) {
      menuFrames = false;
      return;
    }
    menuTick();
    requestAnimationFrame(menuFrame);
  }

  function menuTick() {
    if (phase === 'ready') readMenuPads(true);
    else if (phase === 'settings') settingsUpdate();
  }

  // SETTINGS, or the settings key, on the menu: the game's settings screen, before the game
  // starts (the module's `gp_settings_open`). It takes the keys and the gamepads as during play;
  // leaving it comes back to the menu, the arrow on SETTINGS.
  function openSettings() {
    if (phase !== 'ready' || wasm.gp_settings_open() !== 0) return;
    phase = 'settings';
    shown = '';
    overlay.onclick = null;
    overlay.classList.add('hidden');
    canvas.focus();
    startMenuFrames();
  }

  function settingsUpdate() {
    pollGamepads();
    let open;
    try {
      open = wasm.gp_settings_frame();
    } catch (e) {
      stop('THE GAME STOPPED', e.message);
      return;
    }
    if (open === 0) ready(settingsLine, menu.available, menu.note);
    else if (open !== 1) stop('THE GAME STOPPED', errorText());
  }

  // The click or the key that chooses is the gesture after which a browser gives sound, the
  // pointer lock and the full screen that the settings want. A dimmed line does nothing.
  function begin(choice) {
    if (phase !== 'ready' || !((menu.available >> choice) & 1)) return;
    phase = 'playing';
    overlay.onclick = null;
    overlay.classList.add('hidden');
    ensureAudioContext(48000);
    if (audio.context) audio.context.resume().catch(() => {});
    if (view.fullscreen) enterFullscreen();
    canvas.focus();
    if (choice === 0) {
      // Alone, with the files of this page's server: a relay's page never joins it.
      run();
      return;
    }
    if (net.mode === 'native') {
      // A native game hosts at this page's address: this page joins it as player 2.
      if (startNetplay(0, netUrl())) run();
      return;
    }
    // The relay says whether this page hosts (player 1) or joins (player 2); the session starts
    // once it has, before the first update. Without a role (two play there, or the relay cannot
    // be reached), the menu comes back without 2 PLAYERS; later, the relay can end the game here.
    showMessage(words.joining);
    net.onRelay = (state) => {
      if (state === 'host' || state === 'guest') {
        if (startNetplay(state === 'host' ? 1 : 0, '')) run();
        return;
      }
      net.onRelay = null;
      if (phase === 'stopped') return;
      if (!started && (state === 'busy' || state === 'unreachable')) ready(0, 1, words[state]);
      else stop(words[state] || words.lost);
    };
    net.transport.joinRelay(netUrl());
  }

  function startNetplay(role, url) {
    if (wasm.gp_start_netplay(role, writeScratch(url)) === 0) {
      session.on = true;
      return true;
    }
    stop('NETWORK PLAY CANNOT START', errorText());
    return false;
  }

  function run() {
    started = true;
    shown = '';
    overlay.classList.add('hidden');
    stats.since = performance.now();
    if (!checks.manual) requestAnimationFrame(frame);
  }

  async function fetchBytes(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(url + ': ' + response.status + ' ' + response.statusText);
    return response.arrayBuffer();
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
  // console. `manual` leaves the updates to `step`; `audioTap` sees every block that the game
  // queues, before the output takes it.
  const checks = { manual: false, audioTap: null };

  window.sorz = {
    get phase() { return phase; },
    // Network play's mode here (null, 'native' or 'relay'), from `netplay.json`.
    get netMode() { return net.mode; },
    // On a relay: the page's role ('host', 'guest'), or why it has none or lost it ('busy',
    // 'unreachable', 'host_left', 'lost'); null before the relay answered.
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
        // The gain the output has now (null before the click that starts the game makes it).
        audio_gain: audio.gain ? audio.gain.gain.value : null,
        // The frames of the menu's sounds the page made (the arrow's move, a choice), 0 before.
        menu_sounds: [0, 1].map((i) => (menuSounds[i] ? menuSounds[i][0].length : 0)),
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
    // The checks drive the updates themselves: set before the click that starts the game. On the
    // menu, a step reads the gamepads; with the settings screen open from it, a step updates it.
    set manual(value) {
      checks.manual = !!value;
      if (!checks.manual) startMenuFrames();
    },
    get manual() { return checks.manual; },
    setPacing(perUpdate) { wasm.gp_set_pacing(perUpdate ? 1 : 0); },
    step(count) {
      // A page that stopped runs nothing more.
      if (phase === 'stopped') return 1;
      let result = 0;
      for (let i = 0; i < count && result === 0; i++) {
        if (phase === 'ready' || phase === 'settings') menuTick();
        else result = update();
      }
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
    // The menu's sounds, made while the loading screen still shows: the first move sounds at once.
    prepareMenuSounds();
    stats.readyMs = performance.now();
    if (net.mode === 'native') ready(1, 2);
    else ready(0, net.mode === 'relay' ? 3 : 1);
  }

  load().catch((e) => stop('THE PAGE CANNOT START', e.message));
})();

if (typeof module === 'object') module.exports = { sorzHelpers, sorzListing, sorzTransport };
