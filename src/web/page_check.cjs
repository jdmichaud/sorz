// `zig build web-check`: the parts of the browser build that need no browser and no game data,
// under Node.
//
//   node page_check.cjs SORZ_JS SORZ_WASM
//
// The reading of the listing of the game's files that the page's server sends, the transport of
// network play over a WebSocket that this script stands in for, and the module's handling of the
// data it is given: who frees what, a memory that grows under the page's views, the refusals, the
// screens it does not draw yet, and a game that starts on the files it was given.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const { sorzHelpers, sorzListing, sorzTransport } = require(path.resolve(process.argv[2]));
const wasmPath = process.argv[3];

let checks = 0;
function check(name, fn) {
  fn();
  checks += 1;
  console.log('ok ' + name);
}

check('the listing gives the tree\'s files, the screens\' first, and refuses what is not the tree', () => {
  const listing = { files: [
    { name: 'tree/art/art.json', size: 2 }, { name: 'tree/manifest.json', size: 12 },
    { name: 'tree/FONTS/play.json', size: 30 }, { name: 'tree/my mod/a#b.png', size: 4 },
  ] };
  assert.deepEqual(sorzListing(listing, ['fonts/play.json', 'palettes/menu_one_pad.json']), [
    { url: 'assets/tree/FONTS/play.json', name: 'FONTS/play.json', size: 30 },
    { url: 'assets/tree/art/art.json', name: 'art/art.json', size: 2 },
    { url: 'assets/tree/manifest.json', name: 'manifest.json', size: 12 },
    { url: 'assets/tree/my%20mod/a%23b.png', name: 'my mod/a#b.png', size: 4 },
  ]);
  // A directory names every file under it, in the listing's order; `/` alone names none.
  assert.deepEqual(sorzListing(listing, ['my mod/', 'fonts/', '/']).map((f) => f.name),
    ['my mod/a#b.png', 'FONTS/play.json', 'art/art.json', 'manifest.json']);
  for (const bad of [null, {}, { files: [] }, { files: [{ name: 'manifest.json', size: 1 }] },
    { files: [{ name: 'tree/', size: 1 }] }, { files: [{ name: 'tree/a', size: -1 }] }, { files: [{ name: 'tree/a' }] }]) {
    assert.throws(() => sorzListing(bad), Error);
  }
});

// A WebSocket that the test drives.
class FakeSocket {
  constructor(url) {
    if (url.startsWith('bad:')) throw new SyntaxError('bad URL');
    this.url = url;
    this.sent = [];
    this.bufferedAmount = 0;
    this.closed = null;
    FakeSocket.last = this;
  }
  send(data) { this.sent.push(data); }
  close(code) { this.closed = code; }
  // The test's side.
  open() { this.onopen(); }
  message(data) { this.onmessage({ data }); }
  drop() { this.onclose({}); }
}

function recorder() {
  const log = [];
  return {
    log,
    connected: (id, incoming) => log.push(['connected', id, incoming]),
    received: (id, bytes) => log.push(['received', id, bytes.byteLength]),
    disconnected: (id, reason) => log.push(['disconnected', id, reason]),
    relay: (state) => log.push(['relay', state]),
  };
}

check('a connection opens, carries binary messages in order and ends', () => {
  const events = recorder();
  const t = sorzTransport(FakeSocket, events, { maxMessage: 8, maxQueued: 16 });
  const id = t.connect('ws://host/');
  const socket = FakeSocket.last;
  assert.equal(t.send(id, new ArrayBuffer(4)), 'not_connected');
  socket.open();
  assert.equal(t.send(id, new ArrayBuffer(4)), 'sent');
  assert.equal(t.send(id, new ArrayBuffer(9)), 'too_large');
  socket.bufferedAmount = 14;
  assert.equal(t.send(id, new ArrayBuffer(4)), 'queue_full');
  socket.message(new ArrayBuffer(3));
  socket.message(new ArrayBuffer(5));
  socket.drop();
  assert.deepEqual(events.log, [['connected', id, false], ['received', id, 3], ['received', id, 5], ['disconnected', id, 'lost']]);
  assert.equal(socket.sent.length, 1);
});

check('a refused, a malformed and an oversized connection end with their reasons', () => {
  const events = recorder();
  const t = sorzTransport(FakeSocket, events, { maxMessage: 8 });
  const refused = t.connect('ws://nobody/');
  FakeSocket.last.drop();
  const text = t.connect('ws://host/');
  FakeSocket.last.open();
  FakeSocket.last.message('hello');
  assert.equal(FakeSocket.last.closed, 1002);
  const big = t.connect('ws://host/');
  FakeSocket.last.open();
  FakeSocket.last.message(new ArrayBuffer(9));
  assert.deepEqual(events.log, [
    ['disconnected', refused, 'refused'],
    ['connected', text, false], ['disconnected', text, 'protocol'],
    ['connected', big, false], ['disconnected', big, 'too_large'],
  ]);
});

check('nothing follows the game\'s close', () => {
  const events = recorder();
  const t = sorzTransport(FakeSocket, events);
  const id = t.connect('ws://host/');
  const socket = FakeSocket.last;
  socket.open();
  t.close(id);
  assert.equal(socket.closed, 1000);
  socket.message(new ArrayBuffer(2));
  socket.drop();
  assert.deepEqual(events.log, [['connected', id, false]]);
  assert.equal(t.send(id, new ArrayBuffer(1)), 'not_connected');
});

check('a relay\'s guest is connected once its role is known', () => {
  const events = recorder();
  const t = sorzTransport(FakeSocket, events);
  t.joinRelay('ws://relay/');
  const socket = FakeSocket.last;
  socket.open();
  socket.message(new ArrayBuffer(2)); // Before the role: not the game's.
  socket.message('guest');
  socket.message(new ArrayBuffer(3));
  socket.drop();
  const id = events.log[1][1];
  assert.deepEqual(events.log, [
    ['relay', 'guest'], ['connected', id, false], ['received', id, 3], ['disconnected', id, 'lost'], ['relay', 'lost'],
  ]);
});

check('a relay\'s host sees each guest as an incoming connection, and answers each \'left\'', () => {
  const events = recorder();
  const t = sorzTransport(FakeSocket, events);
  t.joinRelay('ws://relay/');
  const socket = FakeSocket.last;
  socket.open();
  socket.message('host');
  socket.message('peer');
  const first = events.log[1][1];
  socket.message(new ArrayBuffer(4));
  assert.equal(t.send(first, new ArrayBuffer(4)), 'sent');
  socket.message('left');
  assert.equal(t.send(first, new ArrayBuffer(4)), 'not_connected');
  socket.message('peer');
  const second = events.log[4][1];
  assert.notEqual(first, second);
  socket.drop();
  assert.deepEqual(events.log, [
    ['relay', 'host'], ['connected', first, true], ['received', first, 4], ['disconnected', first, 'closed'],
    ['connected', second, true], ['disconnected', second, 'lost'], ['relay', 'lost'],
  ]);
  assert.deepEqual(socket.sent.filter((m) => typeof m === 'string'), ['left']);
});

check('a relay that cannot be reached, or where two play, gives no role', () => {
  const events = recorder();
  const t = sorzTransport(FakeSocket, events);
  t.joinRelay('ws://relay/');
  FakeSocket.last.drop();
  t.joinRelay('ws://relay/');
  FakeSocket.last.open();
  FakeSocket.last.message('busy');
  FakeSocket.last.drop();
  assert.deepEqual(events.log, [['relay', 'unreachable'], ['relay', 'busy']]);
});

check('a relay\'s guest hears that its host left', () => {
  const events = recorder();
  const t = sorzTransport(FakeSocket, events);
  t.joinRelay('ws://relay/');
  const socket = FakeSocket.last;
  socket.open();
  socket.message('guest');
  const id = events.log[1][1];
  socket.message('left');
  socket.drop();
  assert.deepEqual(events.log, [['relay', 'guest'], ['connected', id, false], ['disconnected', id, 'closed'], ['relay', 'host_left']]);
  assert.deepEqual(socket.sent, []);
});

check('a host\'s game lets its guest go and stays with the relay; a guest\'s game leaves it', () => {
  const events = recorder();
  const t = sorzTransport(FakeSocket, events);
  t.joinRelay('ws://relay/');
  const host = FakeSocket.last;
  host.open();
  host.message('host');
  host.message('peer');
  const first = events.log[1][1];
  t.close(first);
  assert.equal(host.closed, null);
  host.message(new ArrayBuffer(5)); // From the guest let go: dropped.
  host.message('left');
  host.message('peer');
  const second = events.log[2][1];
  host.message(new ArrayBuffer(6));
  assert.deepEqual(events.log, [['relay', 'host'], ['connected', first, true], ['connected', second, true], ['received', second, 6]]);
  assert.deepEqual(host.sent, ['left']);

  const guestEvents = recorder();
  const g = sorzTransport(FakeSocket, guestEvents);
  g.joinRelay('ws://relay/');
  const guest = FakeSocket.last;
  guest.open();
  guest.message('guest');
  g.close(guestEvents.log[1][1]);
  assert.equal(guest.closed, 1000);
  guest.drop();
  assert.deepEqual(guestEvents.log, [['relay', 'guest'], ['connected', guestEvents.log[1][1], false]]);

  // The page leaves the relay: its connection ends, and nothing follows.
  t.leaveRelay();
  assert.equal(host.closed, 1000);
  host.message(new ArrayBuffer(7));
  host.drop();
  assert.equal(events.log.length, 4);
});

// The module, with the page's functions stubbed: no game data, no canvas, no sound.
function instantiateModule() {
  // The limits that build.zig gives the module: 16 MiB, growing to 1 GiB.
  const memory = new WebAssembly.Memory({ initial: 256, maximum: 16384 });
  const logs = [];
  const text = (ptr, len) => new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
  const stubs = {
    js_now: () => 0, js_set_resolution: () => {}, js_present: () => {}, js_audio_open: () => 0,
    js_audio_queue: () => 0, js_audio_queued: () => 0, js_audio_state: () => 0, js_audio_clear: () => {},
    js_audio_close: () => {}, js_set_relative_mouse: () => 0, js_log: (level, ptr, len) => logs.push(text(ptr, len)),
    js_storage_save: () => 1, js_storage_delete: () => 1,
    js_net_connect: () => 0, js_net_send: () => 2, js_net_close: () => {}, js_settings: () => {},
  };
  const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { env: { memory, ...stubs, ...sorzHelpers(memory) } });
  const wasm = instance.exports;
  assert.equal(wasm.gp_init(), 0);
  const place = (bytes) => {
    const ptr = wasm.gp_alloc(bytes.length);
    assert.notEqual(ptr, 0);
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  };
  const error = () => text(wasm.gp_scratch(), wasm.gp_error());
  return { wasm, memory, place, error, logs };
}

check('the module refuses to start without data', () => {
  const { wasm, error } = instantiateModule();
  assert.equal(wasm.gp_frame(), -1);
  assert.equal(wasm.gp_inspect(), 0);
  assert.equal(wasm.gp_start(), -1);
  assert.match(error(), /no game data/);
  assert.equal(wasm.gp_start_netplay(0, 0), -1);
  assert.match(error(), /has not started/);
  // Without a game, leaving the full screen changes nothing.
  wasm.gp_fullscreen_left();
  // A freed allocation comes back.
  const ptr = wasm.gp_alloc(0x80000);
  wasm.gp_free(ptr, 0x80000);
  assert.equal(wasm.gp_alloc(0x80000), ptr);
});

// The module draws the page's screens from the content's font and menu, whose directories it names
// for the page to fetch first. Without them its screens refuse, naming the file they lack, and the
// page's own text stands in; without the sound content, its menu has no sound.
check('the module names its screens\' directories; without their files it draws none, and says why', () => {
  const { wasm, memory, error } = instantiateModule();
  const len = wasm.gp_screen_files();
  assert.equal(new TextDecoder().decode(new Uint8Array(memory.buffer, wasm.gp_scratch(), len)), 'fonts/\nmenu/');
  assert.equal(wasm.gp_screen_open(), -1);
  assert.match(error(), /the page's screens: fonts\/art\.json/);
  assert.equal(wasm.gp_screen_message(0, 1), -1);
  assert.equal(wasm.gp_screen_pick(100, 90), -1);
  assert.equal(wasm.gp_menu_sound(0), 0);
  assert.match(error(), /the menu's sound: sound\//);
  assert.equal(wasm.gp_menu_sound(1), 0);
  assert.equal(wasm.gp_menu_sound(2), 0);
});

check('the memory grows under the page, which makes its views again', () => {
  const { wasm, memory } = instantiateModule();
  const before = memory.buffer.byteLength;
  const size = 64 << 20;
  const ptr = wasm.gp_alloc(size);
  assert.notEqual(ptr, 0);
  assert.ok(memory.buffer.byteLength >= before + size);
  const view = new Uint8Array(memory.buffer, ptr, size);
  view[size - 1] = 0x5a;
  assert.equal(new Uint8Array(memory.buffer)[ptr + size - 1], 0x5a);
  wasm.gp_free(ptr, size);
  // More than the memory can hold is refused, not a crash.
  assert.equal(wasm.gp_alloc(0xffffff00), 0);
});

check('a file with an invalid name is refused with the file named; the game starts on the others', () => {
  const { wasm, memory, place, error } = instantiateModule();
  const name = (s) => new TextEncoder().encode(s);
  const bad = name('../escape.json');
  const body = name('{}');
  assert.equal(wasm.gp_add_asset(place(bad), bad.length, place(body), body.length), -1);
  assert.match(error(), /^\.\.\/escape\.json: InvalidName/);
  const manifest = name('manifest.json');
  assert.equal(wasm.gp_add_asset(place(manifest), manifest.length, place(body), body.length), 0);
  assert.equal(wasm.gp_start(), 0);
  // One tick an update, as the agent host's: the test pattern's ticks and frames.
  wasm.gp_set_pacing(1);
  for (let i = 0; i < 3; i++) assert.equal(wasm.gp_frame(), 0);
  const state = JSON.parse(new TextDecoder().decode(new Uint8Array(memory.buffer, wasm.gp_scratch(), wasm.gp_inspect())));
  assert.equal(state.phase, 'playing');
  assert.equal(state.ticks, 3);
  assert.equal(state.frames_presented, 3);
  assert.match(state.frame_hash, /^[0-9a-f]{16}$/);
  assert.equal(state.settings.players, 1);
  assert.equal(state.net, null);
  // Network play starts before the first update only.
  assert.equal(wasm.gp_start_netplay(0, 0), -1);
  assert.match(error(), /before the first update/);
});

check('the page keeps only its player\'s keys (pad 1\'s) from the browser, and never Escape', () => {
  const { wasm, memory } = instantiateModule();
  const key = (code) => {
    const bytes = new TextEncoder().encode(code);
    new Uint8Array(memory.buffer, wasm.gp_scratch(), bytes.length).set(bytes);
    return wasm.gp_key(bytes.length, 1, 0);
  };
  assert.equal(key('ArrowLeft'), 1);
  assert.equal(key('KeyZ'), 1);
  // Pad 2's keys: a page has one player.
  assert.equal(key('Tab'), 0);
  assert.equal(key('KeyW'), 0);
  // The settings key: the browser's F1 opens no help.
  assert.equal(key('F1'), 1);
  assert.equal(key('F5'), 0);
  assert.equal(key('Escape'), 0);
  assert.equal(key('MetaLeft'), 0);
});

check('the settings key is F1 before the game reads its record; there is no settings screen yet', () => {
  const { wasm, memory } = instantiateModule();
  const code = (text) => {
    const bytes = new TextEncoder().encode(text);
    new Uint8Array(memory.buffer, wasm.gp_scratch(), bytes.length).set(bytes);
    return bytes.length;
  };
  assert.equal(wasm.gp_settings_key(code('F1')), 1);
  assert.equal(wasm.gp_settings_key(code('F2')), 0);
  assert.equal(wasm.gp_settings_key(code('Escape')), 0);
  // The menu's SETTINGS opens the game's screen (PLAN item 19): the page dims the line until then.
  assert.equal(wasm.gp_settings_available(), 0);
  assert.equal(wasm.gp_settings_open(), -1);
  assert.equal(wasm.gp_settings_frame(), 0);
});

console.log(`the page's ${checks} checks pass`);
