// `zig build browser-check`: the browser build in Chromium, against the agent host, and pages
// through the relay.
//
//   node browser_check.mjs --web DIR --agent SORZ_AGENT --server SORZ_SERVER [--content DIR]
//                          [--chromium PATH] [--ticks N] [--seconds S] [--keep DIR]
//                          [--only relay | --only page | --only netplay]
//
// Every page is served by a native program, which sends it the game's files of a game directory
// (DESIGN.md 5.3); nothing else feeds the page game data. The directory is a small tree made here
// (no content: the game shows its test pattern), the same for the agent host; with --content (a
// content tree extracted from the user's ROM), the real game. The pages open in a Chromium without
// a window. The page has no menu of its own: once its files are in, the game runs its own front
// end (DESIGN.md 5.3, 9). A page opened at `#manual` leaves its updates to the check (`sorz.step`,
// one tick each with `sorz.setPacing(true)`), from the game's first tick.
//
//   page: served without the game's files (the page's three files from DIR, by a plain server), the
//      page says so and stops, in its own text in the game's colours; served by the relay over a
//      slow network, it says LOADING and its share of the files, then runs the game, with no menu
//      of its own. The small tree has no art: the module cannot draw its screens, and the page's
//      text stands in, as it does for a tree without the game's font and menu.
//   screens (with --content: the content's font, menu and sound added to the small tree): over
//      the slow network, the module draws the loading screen once it has the font and the menu,
//      which come first; then the game runs.
//   flow (with --content): the page of a relay that serves the whole content tree, one tick per
//      update: the network variant's own front end (DESIGN.md 10.7): START on the intro and the
//      title, its game menu a host's (the relay's first page): 1 PLAYER, NETWORK PLAY and OPTIONS;
//      OPTIONS' ADVANCED SETTINGS opens the settings (one player's), the game held, and Escape
//      saves and leaves; F1 is the browser's.
//   steps: one tick per update from the game's first, N ticks: the canvas's pixels and the
//      frame's hash at the ticks the agent host wrote pictures of must equal the agent host's, and
//      so must the state's hash and the frame's hash at the end, and every block of sound the game
//      queued (the agent host's WAV).
//   settings: a settings record kept by the browser for the page (pad 1's Start on P, the volume at
//      30, the scale at 1) is read at the start and applied: the output's gain, the picture's whole
//      multiple; P (a game's key) never reaches the browser, F1, F2 and Escape do.
//   realtime: the game as the player runs it, paced by the sound, for S seconds: every frame it
//      shows must be the frame of the same tick in the steps part, the ticks must come at the
//      console's rate (59.92 a second), and the sound must not run dry.
//   hidden: the page hidden (another tab in front) then shown again: the game waits, its sound is
//      suspended, and it goes on from where it was.
//   input: Start pressed through the keyboard (P, the record's), then through a gamepad, against
//      the agent host pressing Enter (its default) at the same ticks.
//   netplay (with --content): the agent host hosts (`--netplay`) and serves the page and the whole
//      content tree; its player chooses NETWORK PLAY (the network options' START), Axel, and plays
//      round 1 alone. The page, opened at the host's address, is its client: its player gives its
//      name, chooses JOIN, a character on its own select (Axel taken), and joins the host's game
//      mid-round. One tick per update, the two games' states must be the same at the session's
//      tick 600, both in the round with two players.
//   relay (with --content): two pages of the relay (`sorz-server DIR --server`), in two Chromiums
//      with their own profiles, each on the relay as it loads: the first is the host (player 1)
//      and plays round 1 alone; the second, its client, chooses JOIN later, its character on
//      its own select, and joins the first's game mid-round: one tick per update, the same state at
//      the session's tick 600. Then the relay's rules, in real time: a third page is a client too,
//      and the three play on; the guest leaves, and the host plays on without player 2, told so;
//      the host leaves, and the third, connecting again, hosts.
//
// The agent host's frames are ticks: its picture at frame F is the page's after F + 1 updates of
// one tick. The report is one JSON line per part, and the exit status says whether every part
// passed. Everything made here stays in a temporary directory that is removed at the end (with
// --keep, the pictures and screenshots are copied there). `--only relay` runs the relay's parts
// alone, `--only page` the page's look (and with --content its flow), `--only netplay` network
// play with the agent host.
import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { findChromium, serve, launch, Page, sleep } from './cdp.mjs';

const options = { ticks: 2400, seconds: 40 };
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i].replace(/^--/, '');
  const value = process.argv[i + 1];
  if (value === undefined) usage();
  options[key] = ['ticks', 'seconds'].includes(key) ? Number(value) : value;
}
if (!options.web || !options.agent || !options.server) usage();

function usage() {
  console.error('usage: node browser_check.mjs --web DIR --agent SORZ_AGENT --server SORZ_SERVER [--content DIR] [--chromium PATH] [--ticks N] [--seconds S] [--keep DIR] [--only relay|page|netplay]');
  process.exit(2);
}

let failed = false;
function report(part, pass, fields) {
  if (!pass) failed = true;
  console.log(JSON.stringify({ part, pass, ...fields }));
}

// --- the game's files -------------------------------------------------------------------------

// A small game directory: a manifest of its own at the tree's root, and enough files that their
// loading takes a moment over the slow network of part `page`.
function makeTree(dir) {
  fs.mkdirSync(path.join(dir, 'art'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'manifest.json'), '{"format": 1}\n');
  for (let i = 0; i < 40; i++) {
    fs.writeFileSync(path.join(dir, 'art', `blob-${String(i).padStart(2, '0')}.bin`), crypto.randomBytes(64 * 1024));
  }
}

// The small tree with the content's sets that the page's screens are drawn from, and its sound.
function makeScreensTree(dir) {
  makeTree(dir);
  for (const sub of ['fonts', 'menu', 'sound']) fs.cpSync(path.join(options.content, sub), path.join(dir, sub), { recursive: true });
}

// --- the agent host's reference -------------------------------------------------------------

// The pictures: every 250th frame, and ten frames in a row.
function shotFrames(ticks) {
  const frames = new Set();
  for (let f = 249; f < ticks; f += 250) frames.add(f);
  for (let f = 1000; f < Math.min(1010, ticks); f++) frames.add(f);
  return [...frames].sort((a, b) => a - b);
}

function runAgent(scratch, ticks) {
  const args = ['--frames', String(ticks), '--wav', path.join(scratch, 'agent.wav')];
  for (const f of shotFrames(ticks)) args.push('--shot', `${f}:${path.join(scratch, `agent-${f}.png`)}`);
  return runAgentWith(args);
}

// A run of the agent host on the game's files: its JSON line.
function runAgentWith(args) {
  const run = spawnSync(options.agent, [...args, options.data], { encoding: 'utf8', maxBuffer: 1 << 20 });
  if (run.status !== 0) throw new Error('sorz-agent failed: ' + run.stderr);
  return JSON.parse(run.stdout.trim().split('\n').pop());
}

// An 8-bit RGBA PNG as the agent host writes it: its pixels.
function readRgbaPng(file) {
  const bytes = fs.readFileSync(file);
  let at = 8;
  let width = 0;
  let height = 0;
  const idat = [];
  while (at < bytes.length) {
    const length = bytes.readUInt32BE(at);
    const type = bytes.toString('latin1', at + 4, at + 8);
    const body = bytes.subarray(at + 8, at + 8 + length);
    if (type === 'IHDR') {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      if (body[8] !== 8 || body[9] !== 6) throw new Error(file + ': not an 8-bit RGBA PNG');
    } else if (type === 'IDAT') {
      idat.push(body);
    }
    at += 12 + length;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const row = width * 4;
  const pixels = Buffer.alloc(row * height);
  for (let y = 0; y < height; y++) {
    if (raw[y * (row + 1)] !== 0) throw new Error(file + ': a filtered row');
    raw.copy(pixels, y * row, y * (row + 1) + 1, (y + 1) * (row + 1));
  }
  return { width, height, pixels };
}

// The game's frame hash: FNV-1a (64 bits) of the frame's RGBA bytes (picture.zig).
function fnv64(bytes) {
  let lo = 0x84222325;
  let hi = 0xcbf29ce4;
  for (let i = 0; i < bytes.length; i++) {
    lo = (lo ^ bytes[i]) >>> 0;
    // (hi, lo) * 0x100000001b3, in 32-bit halves: lo * 0x1b3 and its carry, and lo << 40.
    const l = lo * 0x1b3;
    const carry = Math.floor(l / 0x100000000);
    const h = (hi * 0x1b3 + (lo << 8 >>> 0) + carry) >>> 0;
    lo = l >>> 0;
    hi = h;
  }
  return hi.toString(16).padStart(8, '0') + lo.toString(16).padStart(8, '0');
}

// FNV-1a (32 bits) of the bytes of a block of samples, as the page's tap computes it.
function fnv32(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

function wavData(file) {
  const bytes = fs.readFileSync(file);
  let at = 12;
  while (at < bytes.length) {
    const id = bytes.toString('latin1', at, at + 4);
    const length = bytes.readUInt32LE(at + 4);
    if (id === 'data') return bytes.subarray(at + 8, at + 8 + length);
    at += 8 + length;
  }
  throw new Error(file + ': no data');
}

// The page's blocks of sound against the agent host's stream: the first block that differs.
function compareSound(tap, stream) {
  let offset = 0;
  for (let i = 0; i < tap.frames.length; i++) {
    const bytes = tap.frames[i] * 4;
    if (offset + bytes > stream.length) return { blocks: i, frames: offset / 4, first_difference: null };
    if (fnv32(stream.subarray(offset, offset + bytes)) !== tap.hashes[i]) {
      return { blocks: i, frames: offset / 4, first_difference: { block: i, frame: offset / 4, seconds: offset / 4 / 48000 } };
    }
    offset += bytes;
  }
  return { blocks: tap.frames.length, frames: offset / 4, first_difference: null };
}

// --- the page -------------------------------------------------------------------------------

// The sound tap: a hash of each block of samples the game queues, in order.
const installTap = `(() => {
  window.__tap = { frames: [], hashes: [] };
  sorz.audioTap = (ptr, frames, channels) => {
    const s = sorz.samples(ptr, frames, channels);
    const b = new Uint8Array(s.buffer, s.byteOffset, s.byteLength);
    let h = 0x811c9dc5;
    for (let i = 0; i < b.length; i++) { h ^= b[i]; h = Math.imul(h, 0x01000193); }
    __tap.frames.push(frames);
    __tap.hashes.push(h >>> 0);
  };
})()`;

const canvasBase64 = `(() => {
  const d = sorz.canvasPixels();
  let s = '';
  for (let i = 0; i < d.length; i += 0x8000) s += String.fromCharCode.apply(null, d.subarray(i, i + 0x8000));
  return btoa(s);
})()`;

// The page at `url`, its files loaded from its server, its game running (with `manual`, the
// check's to step from its first tick).
async function openGame(page, url, manual = false) {
  // A blank page first: the same address with its `#manual` again would only move to the anchor.
  await page.navigate('about:blank');
  // The document before the navigation is marked, so that its state is not taken for the new one's.
  await page.evaluate('window.__stale = true').catch(() => {});
  await page.navigate(url + (manual ? '#manual' : ''));
  await page.waitFor(`window.__stale === undefined && window.sorz !== undefined && (sorz.phase === 'playing' || sorz.phase === 'stopped')`, 120000, 'the game to run');
  const phase = await page.evaluate('sorz.phase');
  if (phase !== 'playing') throw new Error('the page did not run its game: ' + await page.evaluate('sorz.message'));
  if (manual) await page.evaluate('sorz.setPacing(true)');
}

const keyEvents = {
  enter: { code: 'Enter', key: 'Enter', windowsVirtualKeyCode: 13 },
  up: { code: 'ArrowUp', key: 'ArrowUp', windowsVirtualKeyCode: 38 },
  down: { code: 'ArrowDown', key: 'ArrowDown', windowsVirtualKeyCode: 40 },
  right: { code: 'ArrowRight', key: 'ArrowRight', windowsVirtualKeyCode: 39 },
  escape: { code: 'Escape', key: 'Escape', windowsVirtualKeyCode: 27 },
  f1: { code: 'F1', key: 'F1', windowsVirtualKeyCode: 112 },
  f2: { code: 'F2', key: 'F2', windowsVirtualKeyCode: 113 },
  p: { code: 'KeyP', key: 'p', windowsVirtualKeyCode: 80 },
  z: { code: 'KeyZ', key: 'z', windowsVirtualKeyCode: 90 },
};

async function tap(page, key) {
  if (!key || !key.code) throw new Error('tap: not a key of keyEvents');
  await page.send('Input.dispatchKeyEvent', { type: 'keyDown', ...key });
  await page.send('Input.dispatchKeyEvent', { type: 'keyUp', ...key });
}

// A manual page's game: its tick, and its session's (null without one).
const ticksOf = `(() => { const s = sorz.inspect(); return s ? [s.ticks, s.net && s.net.phase === 'playing' ? s.net.tick : null] : [0, null]; })()`;

// Steps manual pages in turn, one tick per update, until `done([tick, session tick], i)` holds for
// each page (`limit` real seconds at most). Every page steps at each turn, as every page runs on
// in a browser (a page's messages come in at its updates); with `freeze`, a page whose condition
// holds steps no more (the session's last tick, where both stop). Outside a session a page steps
// `stride` updates at a time (its condition may hold a few ticks late), in a session one, so that
// the pages' sockets deliver between the steps.
async function stepUntil(pages, done, { limit = 300, stride = 1, freeze = false } = {}) {
  const began = Date.now();
  let at = await Promise.all(pages.map((p) => p.evaluate(ticksOf)));
  while (!at.every((t, i) => done(t, i))) {
    if (Date.now() - began > limit * 1000) {
      const states = await Promise.all(pages.map((p) => p.evaluate('(() => { const s = sorz.inspect(); return { ticks: s.ticks, scene: s.scene, net: s.net, message: s.message }; })()')));
      throw new Error('the pages did not get there: ' + JSON.stringify(states));
    }
    for (let i = 0; i < pages.length; i++) {
      if (freeze && done(at[i], i)) continue;
      const n = at[i][1] === null ? stride : 1;
      const r = await pages[i].evaluate(`sorz.step(${n})`);
      if (r !== 0) throw new Error('a page\'s game stopped: ' + JSON.stringify(await pages[i].evaluate('sorz.message')));
    }
    at = await Promise.all(pages.map((p) => p.evaluate(ticksOf)));
    await sleep(0);
  }
  return at;
}

// A manual page's key held from its tick `at` for `held` updates of every page (a key that makes
// the game hold, a choice that waits to join, holds no tick).
async function holdAt(pages, i, key, at, held = 3) {
  await stepUntil(pages, (t, k) => k !== i || t[0] >= at - 10, { stride: 10 });
  await stepUntil(pages, (t, k) => k !== i || t[0] >= at);
  await pages[i].send('Input.dispatchKeyEvent', { type: 'keyDown', ...key });
  for (let n = 0; n < held; n++) for (const p of pages) await p.evaluate('sorz.step(1)');
  await pages[i].send('Input.dispatchKeyEvent', { type: 'keyUp', ...key });
}

// Steps manual pages, one update each at a time, until `cond` (an expression of `s`, page i's
// `sorz.inspect()`) holds (`limit` real seconds at most): through a hold too, where no tick runs
// (a screen of this machine's, whose fades count real time).
async function stepUntilState(pages, i, cond, limit = 60) {
  const began = Date.now();
  while (!await pages[i].evaluate(`(() => { const s = sorz.inspect(); return ${cond}; })()`)) {
    if (Date.now() - began > limit * 1000) throw new Error(`the page did not get to ${cond}: ` + JSON.stringify(await pages[i].evaluate('sorz.inspect()')));
    for (const p of pages) await p.evaluate('sorz.step(1)');
    await sleep(5);
  }
}

// A manual page's key held now for `held` updates of every page.
async function press(pages, i, key, held = 3) {
  await pages[i].send('Input.dispatchKeyEvent', { type: 'keyDown', ...key });
  for (let n = 0; n < held; n++) for (const p of pages) await p.evaluate('sorz.step(1)');
  await pages[i].send('Input.dispatchKeyEvent', { type: 'keyUp', ...key });
}

// A host's page, one tick per update: START on the intro and on the title, then the game menu's
// NETWORK PLAY (down, A) and the network options' START: the session opens, and its player goes to
// the character select alone, where it chooses Axel (right, A). The agent host's keys for the
// same, by update (the network options hold the game a while: the updates of their fades).
async function hostNetworkPlay(pages, i) {
  for (const [t, k] of [[500, 'enter'], [560, 'enter'], [620, 'down'], [640, 'z']]) await holdAt(pages, i, keyEvents[k], t);
  await stepUntilState(pages, i, `s.modal === 'net_options'`);
  await press(pages, i, keyEvents.enter);
  await stepUntilState(pages, i, `s.modal === '' && s.scene === 'select'`);
  await holdAt(pages, i, keyEvents.right, 860);
  await holdAt(pages, i, keyEvents.z, 880);
}
const agentHostKeys = ['500:enter:3', '560:enter:3', '620:down:3', '640:z:3', '800:enter:3', '1160:right:3', '1180:z:3'];

// A client's page, one tick per update: START on the intro and on the title; its name entry opens
// over its menu (a profile of its own has none), and START keeps it; then the menu's JOIN, where
// its arrow is once the host takes a player: its character select.
async function clientJoins(pages, i) {
  await holdAt(pages, i, keyEvents.enter, 500);
  await holdAt(pages, i, keyEvents.enter, 560);
  await stepUntilState(pages, i, `s.modal === 'name_entry'`);
  await press(pages, i, keyEvents.enter);
  await stepUntilState(pages, i, `s.modal === '' && s.menu_at === 'join'`);
  await holdAt(pages, i, keyEvents.z, await pages[i].evaluate('sorz.inspect().ticks') + 80);
  await stepUntilState(pages, i, `s.scene === 'select'`);
}

// A port on 127.0.0.1 that no one listens on now.
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

// --- network play with the agent host ----------------------------------------------------------

// The agent host (player 1, `--netplay`) serves the page and the whole content tree at its port
// once its session opens; its player chooses NETWORK PLAY, START, Axel and plays round 1 alone. A
// new tab opens the page, the host's client: one tick per update, its player gives its name and
// chooses JOIN at its own pace, then a character on its own select once the host plays (Axel
// taken: the cursor starts on Adam), and joins the host's game mid-round. At the session's tick
// 600 both stop: the same state.
async function netplaySession(browser) {
  const ticks = 600;
  const port = await freePort();
  const hostKeys = [...agentHostKeys, '1800:right:60', '2000:x:3'];
  const host = spawn(options.agent, [options.content, '--netplay', `127.0.0.1:${port}`, '--delay', '3',
    '--frames', '200000', '--until-session', String(ticks), ...hostKeys.flatMap((k) => ['--key', k])], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  let log = '';
  host.stdout.on('data', (d) => { out += d; });
  host.stderr.on('data', (d) => { log += d; });
  const hostDone = new Promise((resolve) => host.on('exit', resolve));
  const page = await Page.open(browser.cdp);
  try {
    for (let tries = 0; !log.includes('hosting at'); tries++) {
      if (tries > 300 || host.exitCode !== null) throw new Error('the agent host did not start: ' + log.slice(-400));
      await sleep(100);
    }
    await openGame(page, `http://127.0.0.1:${port}/`, true);
    const mode = await page.evaluate('sorz.netMode');
    const began = Date.now();
    const pages = [page];
    await clientJoins(pages, 0);
    // Its own select, the host's game in play by then: Adam (the cursor's first, Axel taken).
    await stepUntil(pages, (t) => t[0] >= 1300, { stride: 10 });
    const select = await page.evaluate('sorz.inspect()');
    await holdAt(pages, 0, keyEvents.z, 1300);
    const [, joinedAt] = (await stepUntil(pages, (t) => t[1] !== null))[0];
    // Up to the session's last tick, without passing it.
    await stepUntil(pages, (t) => t[1] !== null && t[1] >= ticks, { freeze: true });
    const state = await page.evaluate('sorz.inspect()');
    const code = await Promise.race([hostDone, sleep(30000).then(() => 'timeout')]);
    const result = JSON.parse(out.trim().split('\n').pop() || '{}');
    const hostGame = result.host || {};
    const errors = page.console.filter((m) => m.type === 'error' || m.type === 'exception');
    return {
      pass: code === 0 && result.verdict === 'ok' && mode === 'native' && select.scene === 'select' && joinedAt !== null &&
        state.state_hash === hostGame.state_hash && state.net.tick === ticks && hostGame.session_tick === ticks &&
        hostGame.scene === 'round' && state.scene === 'round' && state.players === 'two' && hostGame.players === 'two' &&
        state.variant === 'network' && state.net.sessions === 1 && hostGame.ticks > 1500 + ticks && errors.length === 0,
      fields: {
        mode,
        ticks,
        seconds: Math.round((Date.now() - began) / 100) / 10,
        host: hostGame,
        host_verdict: result.verdict,
        guest: { ticks: state.ticks, state_hash: state.state_hash, net: state.net, scene: state.scene, players: state.players, select_before: select.scene },
        host_log: log.trim().split('\n').filter((line) => line.includes('netplay')).slice(-6),
        errors: errors.slice(0, 5),
      },
    };
  } finally {
    await page.close();
    if (host.exitCode === null) host.kill();
    await hostDone;
  }
}

// --- server mode -----------------------------------------------------------------------------

// The relay on a free port of 127.0.0.1, serving the page and the game's files of the tree; it says
// so on standard error.
async function startRelay(data = options.data) {
  const port = await freePort();
  const child = spawn(options.server, [data, '--server', `127.0.0.1:${port}`], { stdio: ['ignore', 'ignore', 'pipe'] });
  const relay = { child, url: `http://127.0.0.1:${port}/`, log: '', done: new Promise((resolve) => child.on('exit', resolve)) };
  child.stderr.on('data', (d) => { relay.log += d; });
  for (let tries = 0; !relay.log.includes('relaying'); tries++) {
    if (tries > 100 || child.exitCode !== null) throw new Error('the relay did not start: ' + relay.log.slice(-400));
    await sleep(100);
  }
  return relay;
}

// A page of the relay's in a window of its own (a tab behind another would be hidden).
async function relayPage(browser, relay, manual) {
  const page = await Page.open(browser.cdp, 'about:blank', { newWindow: true });
  await openGame(page, relay.url, manual);
  return page;
}

// The tick counts of pages, once and again a second later.
async function advancing(pages) {
  const before = await Promise.all(pages.map((p) => p.evaluate('sorz.inspect().ticks')));
  await sleep(1000);
  const after = await Promise.all(pages.map((p) => p.evaluate('sorz.inspect().ticks')));
  return before.map((v, i) => after[i] - v);
}

// Two pages through the relay, the whole content tree. Each connects to the relay as it loads: the
// first is the host, the second its client. The first page's player chooses NETWORK PLAY, START,
// Axel and plays round 1 alone; the second's gives its name and chooses JOIN later, and a
// character on its own select once the host plays: it joins the host's game mid-round. One tick per update, the
// same state at the session's tick 600. Then in real time: a third page is a client too, and the
// three play on; the guest leaves, and the host plays on without player 2; the host leaves, and
// the third hosts once it has connected again. The host's page is in `browser`, the guest's in a
// second Chromium with its own profile (`profile`). Returns the parts' reports.
async function relayCheck(browser, chromium, profile) {
  const reports = [];
  const ticks = 600;
  const relay = await startRelay(options.content);
  let second = null;
  const pages = [];
  try {
    second = await launch(chromium, profile);
    const host = await relayPage(browser, relay, true);
    pages.push(host);
    const guest = await relayPage(second, relay, true);
    pages.push(guest);
    const mode = await host.evaluate('sorz.netMode');
    const both = [host, guest];
    const began = Date.now();
    // The host's player: NETWORK PLAY, Axel, round 1 alone; the guest's page has not started its
    // game's front end yet (it waits unstepped: its connection's messages wait for its updates).
    const first = [host];
    await hostNetworkPlay(first, 0);
    const hostRole = await host.evaluate('sorz.relayState');
    await stepUntil(first, (t) => t[0] >= 1800, { stride: 10 });
    const alone = await host.evaluate('sorz.inspect()');
    // The guest's player: its name, JOIN, then Adam on its own select, the host playing.
    await clientJoins(both, 1);
    await stepUntil(both, (t, i) => i !== 1 || t[0] >= 1300, { stride: 10 });
    const guestRole = await guest.evaluate('sorz.relayState');
    await holdAt(both, 1, keyEvents.z, 1300);
    await stepUntil(both, (t) => t[1] !== null);
    await stepUntil(both, (t) => t[1] !== null && t[1] >= ticks, { freeze: true });
    const [h, g] = await Promise.all(both.map((p) => p.evaluate('sorz.inspect()')));
    reports.push(['relay', mode === 'relay' && hostRole === 'host' && guestRole === 'client' && alone.scene === 'round' &&
      alone.players === 'one' && h.state_hash === g.state_hash && h.net.tick === ticks && g.net.tick === ticks &&
      h.scene === 'round' && h.players === 'two' && h.net.phase === 'playing' && !h.net.difference && !g.net.difference, {
      mode,
      roles: [hostRole, guestRole],
      host_alone: { ticks: alone.ticks, scene: alone.scene, players: alone.players, connected: alone.net.connected },
      seconds: Math.round((Date.now() - began) / 100) / 10,
      host: { ticks: h.ticks, state_hash: h.state_hash, net: h.net, players: h.players },
      guest: { ticks: g.ticks, state_hash: g.state_hash, net: g.net },
    }]);

    // The relay's rules, in real time. A third page is a client of the host too, as it loads (the
    // relay turns no page away), and the three play on. What its game offers its player (JOIN
    // dimmed, OBSERVE) is the game's, for its own checks.
    for (const p of both) await p.evaluate('sorz.manual = false');
    const third = await relayPage(browser, relay, false);
    pages.push(third);
    await third.waitFor(`sorz.relayState !== null`, 20000, 'the relay\'s answer to the third');
    const thirdRole = await third.evaluate('sorz.relayState');
    const playingOn = await advancing([host, guest, third]);
    // The guest leaves: the host waits a few seconds for it, then plays on without player 2.
    await guest.close();
    pages.splice(pages.indexOf(guest), 1);
    await host.waitFor(`sorz.inspect().message.startsWith('PLAYER 2 DISCONNECTED')`, 10000, 'the host to wait for its guest');
    await host.waitFor(`sorz.inspect().notice_text === 'PLAYER 2 LEFT'`, 15000, 'the host to give its guest up');
    const hostAlone = await host.evaluate('sorz.inspect()');
    if (options.keep) await host.screenshot(path.join(options.keep, 'page-guest-left.png'));
    const hostPlays = (await advancing([host]))[0];
    // The host leaves: its clients' connections end, they connect again, and the first hosts.
    const errors = host.console.filter((m) => m.type === 'error' || m.type === 'exception');
    await host.close();
    pages.splice(pages.indexOf(host), 1);
    const thirdHosts = await third.waitFor(`sorz.relayState === 'host'`, 10000, 'the third to host').then(() => true, () => false);
    reports.push(['relay_rules', thirdRole === 'client' && playingOn.every((n) => n > 30) &&
      hostAlone.scene === 'round' && hostAlone.net.phase !== 'playing' && hostPlays > 30 && thirdHosts, {
      third: { relay: thirdRole, the_three_play_on: playingOn, hosts_once_the_host_left: thirdHosts },
      guest_left: { notice: hostAlone.notice_text, scene: hostAlone.scene, net: hostAlone.net, ticks_in_1_s: hostPlays },
      relay_log: relay.log.trim().split('\n').slice(-12),
    }]);
    errors.push(...pages.flatMap((p) => p.console.filter((m) => m.type === 'error' || m.type === 'exception')));
    reports.push(['relay_console', errors.length === 0, { errors: errors.slice(0, 5) }]);
  } finally {
    for (const page of pages) await page.close();
    if (second) await second.stop();
    if (relay.child.exitCode === null) relay.child.kill();
    await relay.done;
  }
  return reports;
}

// --- the settings ---------------------------------------------------------------------------------

// The picture's multiple of the game's pixels, in device pixels, from the page's view.
function multiple(view) {
  return view.canvas[0] * view.device_pixel_ratio / 320;
}

// The record the browser keeps for the page (base64 under `sorz:settings.json`): pad 1's Start on
// P, the volume at 30, the scale at 1, as the game writes a record.
const buttons = { a: 'x', b: 'a', c: 'b', start: 'start' };
const noKeys = { up: 'none', down: 'none', left: 'none', right: 'none', a: 'none', b: 'none', c: 'none', start: 'none' };
const keptRecord = JSON.stringify({
  version: 5,
  players: {
    player1: { input: 'gamepad 1', keys: { up: 'up', down: 'down', left: 'left', right: 'right', a: 'z', b: 'x', c: 'c', start: 'p' }, autofire: false },
    player2: { input: 'keyboard', keys: { up: 'w', down: 's', left: 'a', right: 'd', a: 'f', b: 'g', c: 'h', start: 'tab' }, autofire: false },
    player3: { input: 'keyboard', keys: noKeys, autofire: false },
    player4: { input: 'keyboard', keys: noKeys, autofire: false },
  },
  gamepads: [{ label: 1, model: '2dc8-3106-8BitDo Receiver', name: '8BitDo Receiver', buttons }],
  settings_key: 'f1',
  sound: { volume: 30, mute: false },
  window: { scale: 1, fullscreen: false },
  rules: { lives: 3, continues: 3, friendly_hit: true },
  name: 'BOB',
  network_stats: false,
}, null, 2);

// Part `settings`: the record kept before the page loads is the game's at the start, and the page
// applies it; the keys the game takes never reach the browser, and the others do.
async function settingsCheck(page, url) {
  await page.navigate('about:blank');
  await openGame(page, url, true);
  await page.evaluate(`localStorage.setItem('sorz:settings.json', btoa(${JSON.stringify(keptRecord)}))`);
  await openGame(page, url, true);
  // What the page's keydown left for the browser: a listener added after the page's sees it.
  await page.evaluate(`(() => {
    window.__keys = [];
    window.addEventListener('keydown', (e) => __keys.push([e.code, e.defaultPrevented]));
  })()`);
  await page.evaluate('sorz.step(3)');
  // P is the game's; F1 (no settings key outside the original), F2 and Escape the browser's.
  for (const key of [keyEvents.f1, keyEvents.p, keyEvents.f2, keyEvents.escape]) await tap(page, key);
  await page.evaluate('sorz.step(1)');
  const kept = await page.evaluate(`({ state: sorz.inspect(), view: sorz.view, gain: sorz.stats().audio_gain, keys: __keys })`);
  const prevented = (code) => kept.keys.filter(([c]) => c === code).map(([, p]) => p);
  const s = kept.state.settings;
  const pass = kept.state.loads_done === 1 && kept.state.notice === 'none' && s.volume === 30 && s.scale === 1 && s.start_key === 'p' &&
    Math.abs(kept.gain - 0.09) < 1e-6 && Math.abs(kept.view.gain - 0.09) < 1e-9 &&
    multiple(kept.view) === Math.max(1, Math.round(kept.view.device_pixel_ratio)) &&
    prevented('F1').length === 1 && !prevented('F1')[0] && prevented('KeyP').length === 1 && prevented('KeyP')[0] &&
    prevented('F2').length === 1 && !prevented('F2')[0] && prevented('Escape').length === 1 && !prevented('Escape')[0];
  return [pass, {
    record: { loads: kept.state.loads_done, notice: kept.state.notice, volume: s.volume, scale: s.scale, start_key: s.start_key },
    applied: { gain: kept.gain, view_gain: kept.view.gain, multiple: multiple(kept.view) },
    browser_gets: { F1: prevented('F1').map((p) => !p), P: prevented('KeyP').map((p) => !p), F2: prevented('F2').map((p) => !p), Escape: prevented('Escape').map((p) => !p) },
  }];
}

// --- the page's own look --------------------------------------------------------------------------

// Part `page`: the page without the game's files, then the page of the relay over a slow network:
// its own text, in the game's colours, while the files come; then its game runs, no menu of its
// own.
async function pageCheck(browser, bareUrl) {
  const relay = await startRelay();
  const page = await Page.open(browser.cdp);
  try {
    const style = `(() => {
      const m = getComputedStyle(document.getElementById('message'));
      return { message: sorz.message, phase: sorz.phase, screens: sorz.screens, color: m.color, font_style: m.fontStyle,
        overlay: getComputedStyle(document.getElementById('overlay')).backgroundColor,
        overlay_shown: getComputedStyle(document.getElementById('overlay')).display !== 'none' };
    })()`;
    await page.navigate(bareUrl);
    await page.waitFor(`window.sorz !== undefined && sorz.phase === 'stopped'`, 30000, 'the page without files to stop');
    const bare = await page.evaluate(style);
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-no-files.png'));
    const bareOk = bare.message.startsWith('THIS PAGE HAS NO GAME FILES\n') && !bare.screens && bare.color === 'rgb(255, 255, 255)' &&
      bare.font_style === 'italic' && bare.overlay === 'rgb(0, 0, 0)';

    // Over a slow network: the page's text while the files come, with their share.
    await page.send('Network.enable');
    await page.send('Network.emulateNetworkConditions', { offline: false, latency: 20, downloadThroughput: 1 << 20, uploadThroughput: 1 << 20 });
    await page.navigate(relay.url);
    await page.waitFor(`window.sorz !== undefined && sorz.files.done > 5`, 60000, 'the files to come');
    const loading = await page.evaluate(`({ ...${style}, files: sorz.files })`);
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-loading.png'));
    const loadingOk = /^LOADING \d{1,3}%$/.test(loading.message) && !loading.screens && loading.color === 'rgb(255, 255, 255)' &&
      loading.overlay === 'rgb(0, 0, 0)' && loading.files.total === 41;

    // Then the game runs, its own front end: no menu of the page's, its overlay down.
    await page.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await page.waitFor(`sorz.phase === 'playing'`, 120000, 'the game');
    await page.waitFor(`sorz.inspect().ticks > 30`, 10000, 'the game\'s ticks');
    const running = await page.evaluate(`({ ...${style}, state: sorz.inspect() })`);
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-running.png'));
    // The small tree has no content: the game's test pattern, the page's one player.
    const runningOk = running.message === '' && !running.overlay_shown && running.state.settings.players === 1;
    return [bareOk && loadingOk && runningOk && relay.log.includes('(directory, 41 files'), {
      served: relay.log.trim().split('\n')[0],
      no_files: { message: bare.message.split('\n')[0], color: bare.color, font_style: bare.font_style, overlay: bare.overlay },
      loading: { message: loading.message, files: loading.files, screens: loading.screens },
      running: { message: running.message, overlay: running.overlay_shown, variant: running.state.variant, ticks: running.state.ticks },
    }];
  } finally {
    await page.close();
    if (relay.child.exitCode === null) relay.child.kill();
    await relay.done;
  }
}

// Part `flow`: the page of a relay that serves the whole content tree, one tick per update
// (DESIGN.md 10.7: the network variant's own front end, its OPTIONS' ADVANCED SETTINGS).
async function flowCheck(browser) {
  const relay = await startRelay(options.content);
  const page = await Page.open(browser.cdp);
  const white = [255, 255, 255];
  const whiteIn = (pixels, row) => {
    let n = 0;
    for (let y = row * 8; y < row * 8 + 8; y++) for (let x = 0; x < 320; x++) {
      const i = (y * 320 + x) * 4;
      if (pixels[i] === white[0] && pixels[i + 1] === white[1] && pixels[i + 2] === white[2]) n += 1;
    }
    return n;
  };
  try {
    await openGame(page, relay.url, true);
    const pages = [page];
    // START on the intro and on the title: the game's menu.
    await holdAt(pages, 0, keyEvents.enter, 500);
    await holdAt(pages, 0, keyEvents.enter, 560);
    await stepUntil(pages, (t) => t[0] >= 720, { stride: 10 });
    const inMenu = await page.evaluate('sorz.inspect()');
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-flow-game-menu.png'));
    // OPTIONS (down to it, a choice), then up twice to ADVANCED SETTINGS (a tick after each move), A.
    for (let at = 720; at < 760 && (await page.evaluate('sorz.inspect().menu_at')) !== 'options'; at += 8) await holdAt(pages, 0, keyEvents.down, at, 2);
    const onOptions = await page.evaluate('sorz.inspect().menu_at');
    await holdAt(pages, 0, keyEvents.enter, (await page.evaluate('sorz.inspect().ticks')) + 4, 2);
    await stepUntil(pages, (t) => t[0] >= 900, { stride: 10 });
    const inOptions = await page.evaluate('sorz.inspect()');
    await holdAt(pages, 0, keyEvents.up, 900, 2);
    await holdAt(pages, 0, keyEvents.up, 910, 2);
    // A on ADVANCED SETTINGS: the options fade out (64 ticks), then the settings hold the game
    // from then on (no tick runs) and fade in (in time: a second).
    await stepUntil(pages, (t) => t[0] >= 920);
    await page.send('Input.dispatchKeyEvent', { type: 'keyDown', ...keyEvents.z });
    await page.evaluate('sorz.step(2)');
    await page.send('Input.dispatchKeyEvent', { type: 'keyUp', ...keyEvents.z });
    await page.evaluate('sorz.step(70)');
    const held = await page.evaluate('sorz.inspect()');
    await new Promise((r) => setTimeout(r, 1300));
    await page.evaluate('sorz.step(30)');
    const still = await page.evaluate('sorz.inspect()');
    const settingsPixels = Buffer.from(await page.evaluate(canvasBase64), 'base64');
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-flow-settings.png'));
    const settingsTitle = whiteIn(settingsPixels, 2);
    // Escape saves and leaves: the settings fade out (in time), then OPTIONS go on.
    await tap(page, keyEvents.escape);
    for (let i = 0; i < 100 && (await page.evaluate('sorz.inspect()')).settings_open; i++) {
      await page.evaluate('sorz.step(1)');
      await new Promise((r) => setTimeout(r, 20));
    }
    await page.evaluate('sorz.step(5)');
    const after = await page.evaluate('sorz.inspect()');
    const errors = page.console.filter((m) => m.type === 'error' || m.type === 'exception');
    const pass = inMenu.variant === 'network' && inMenu.scene === 'menu' && inMenu.menu === 'one_player,network_play,options' &&
      inOptions.scene === 'options' && held.settings_open && still.ticks === held.ticks && settingsTitle > 20 &&
      held.settings.players === 1 && !after.settings_open && after.ticks > still.ticks && after.scene === 'options' &&
      after.saves_written === held.saves_written + 1 && errors.length === 0;
    return [pass, {
      game: { variant: inMenu.variant, scene: inMenu.scene, menu: inMenu.menu, ticks: inMenu.ticks, chose: onOptions },
      options: inOptions.scene,
      settings: { open: held.settings_open, held: still.ticks === held.ticks, title: settingsTitle, players: held.settings.players },
      after: { settings_open: after.settings_open, scene: after.scene, saves: after.saves_written },
      errors: errors.slice(0, 3),
    }];
  } finally {
    await page.close();
    if (relay.child.exitCode === null) relay.child.kill();
    await relay.done;
  }
}

// Part `screens`: the page of the relay over a slow network, its tree with the content's font,
// menu and sound: the module draws the loading screen in the game's style; then the game runs.
async function screensCheck(browser, data) {
  const relay = await startRelay(data);
  const page = await Page.open(browser.cdp);
  // The canvas's pixels: those of the cell (column, row) in the colour `rgb`.
  const cellHas = (pixels, column, row, rgb) => {
    let n = 0;
    for (let y = row * 8; y < row * 8 + 8; y++) for (let x = column * 8; x < column * 8 + 8; x++) {
      const i = (y * 320 + x) * 4;
      if (pixels[i] === rgb[0] && pixels[i + 1] === rgb[1] && pixels[i + 2] === rgb[2]) n += 1;
    }
    return n;
  };
  const look = `({ message: sorz.message, phase: sorz.phase, screens: sorz.screens, files: sorz.files,
    overlay: document.getElementById('overlay').className, size: [sorz.canvasPixels().length] })`;
  try {
    await page.send('Network.enable');
    await page.send('Network.emulateNetworkConditions', { offline: false, latency: 20, downloadThroughput: 1 << 20, uploadThroughput: 1 << 20 });
    await page.navigate(relay.url);
    await page.waitFor(`window.sorz !== undefined && sorz.screens && sorz.files.done > 15`, 60000, 'the module\'s loading screen');
    const loading = await page.evaluate(look);
    const loadingPixels = Buffer.from(await page.evaluate(canvasBase64), 'base64');
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-screens-loading.png'));
    // LOADING on row 13, from column 14 to 26 or so: the font's white in its cells; the bar's
    // dashes two rows below.
    const white = [255, 255, 255];
    const loadingLit = [15, 16, 17, 18].reduce((n, c) => n + cellHas(loadingPixels, c, 13, white), 0);
    const loadingOk = loading.screens && /^LOADING \d{1,3}%$/.test(loading.message) && loading.overlay.includes('screen') &&
      loadingPixels.length === 320 * 224 * 4 && loadingLit > 20;

    await page.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await page.waitFor(`sorz.phase === 'playing'`, 120000, 'the game');
    const running = await page.evaluate(look);
    return [loadingOk && running.message === '' && running.overlay.includes('hidden'), {
      loading: { message: loading.message, files: loading.files, screens: loading.screens, lit: loadingLit },
      running: { phase: running.phase, overlay: running.overlay },
    }];
  } finally {
    await page.close();
    if (relay.child.exitCode === null) relay.child.kill();
    await relay.done;
  }
}

async function main() {
  const chromium = findChromium(options.chromium);
  if (!chromium) {
    console.error('browser-check needs a Chromium: -Dchromium=PATH, $CHROME, or chromium on the PATH');
    process.exit(2);
  }
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'sorz-browser-check-'));
  if (options.keep) fs.mkdirSync(options.keep, { recursive: true });
  options.data = path.join(scratch, 'game');
  makeTree(options.data);
  // The page's own three files alone, on a plain server: no game's files there.
  const server = await serve(options.web);
  const bareUrl = `http://127.0.0.1:${server.address().port}/index.html`;
  let browser = null;
  let relay = null;
  try {
    if (options.only === 'relay') {
      if (!options.content) throw new Error('the relay\'s parts need the content (--content)');
      browser = await launch(chromium, path.join(scratch, 'profile'));
      for (const [part, pass, fields] of await relayCheck(browser, chromium, path.join(scratch, 'profile-relay'))) report(part, pass, fields);
      return;
    }
    if (options.content) makeScreensTree(path.join(scratch, 'game-screens'));
    if (options.only === 'netplay') {
      if (!options.content) throw new Error('network play\'s part needs the content (--content)');
      browser = await launch(chromium, path.join(scratch, 'profile'));
      const result = await netplaySession(browser);
      report('netplay', result.pass, result.fields);
      return;
    }
    if (options.only === 'page') {
      browser = await launch(chromium, path.join(scratch, 'profile'));
      report('page', ...await pageCheck(browser, bareUrl));
      if (options.content) report('screens', ...await screensCheck(browser, path.join(scratch, 'game-screens')));
      if (options.content) report('flow', ...await flowCheck(browser));
      return;
    }
    const began = Date.now();
    const agent = runAgent(scratch, options.ticks);
    report('agent', true, { ticks: options.ticks, seconds: (Date.now() - began) / 1000, frame_hash: agent.frame_hash, state_hash: agent.state_hash });
    const stream = wavData(path.join(scratch, 'agent.wav'));

    browser = await launch(chromium, path.join(scratch, 'profile'));
    const version = await browser.cdp.send('Browser.getVersion');
    // The relay serves the page and the game's files to the parts where the page's player plays
    // alone.
    relay = await startRelay();
    const url = relay.url;

    report('page', ...await pageCheck(browser, bareUrl));
    if (options.content) report('screens', ...await screensCheck(browser, path.join(scratch, 'game-screens')));
    if (options.content) report('flow', ...await flowCheck(browser));

    const page = await Page.open(browser.cdp);

    // One tick per update from the game's first, against the agent host's frames and sound.
    await openGame(page, url, true);
    const start = await page.evaluate('sorz.stats()');
    await page.evaluate(installTap);
    const hashes = [];
    const pictures = { compared: 0, first_difference: null };
    const shots = shotFrames(options.ticks);
    let done = 0;
    for (const target of [...shots.map((f) => f + 1), options.ticks]) {
      while (done < target) {
        const n = Math.min(target - done, 500);
        const got = await page.evaluate(`(() => { const out = []; for (let i = 0; i < ${n}; i++) { if (sorz.step(1) !== 0) break; out.push(sorz.inspect().frame_hash); } return out; })()`);
        if (got.length !== n) throw new Error('the game stopped at tick ' + (done + got.length) + ': ' + JSON.stringify(await page.evaluate('sorz.inspect()')));
        hashes.push(...got);
        done += n;
      }
      const frame = target - 1;
      if (!shots.includes(frame)) continue;
      const png = readRgbaPng(path.join(scratch, `agent-${frame}.png`));
      const pixels = Buffer.from(await page.evaluate(canvasBase64), 'base64');
      let differing = Math.abs(pixels.length - png.pixels.length);
      for (let i = 0; i < Math.min(pixels.length, png.pixels.length); i++) if (pixels[i] !== png.pixels[i]) differing += 1;
      const hashDiffers = fnv64(png.pixels) !== hashes[frame];
      pictures.compared += 1;
      if ((differing !== 0 || hashDiffers) && !pictures.first_difference) pictures.first_difference = { tick: target, bytes: differing, hash: hashes[frame], agent_hash: fnv64(png.pixels) };
      if (options.keep && frame % 1000 === 999) await page.screenshot(path.join(options.keep, `page-tick-${target}.png`));
    }
    const end = await page.evaluate('sorz.inspect()');
    const tapped = await page.evaluate('__tap');
    const sound = compareSound(tapped, stream);
    const soundWhole = sound.first_difference === null && sound.frames * 4 === stream.length && sound.blocks === tapped.frames.length;
    report('steps', pictures.first_difference === null && pictures.compared === shots.length && end.frame_hash === agent.frame_hash &&
      end.state_hash === agent.state_hash && soundWhole, {
      browser: version.product,
      ticks: end.ticks,
      files_ms: Math.round(start.files_ms),
      start_ms: Math.round(start.start_ms),
      memory_mib: start.memory_bytes / 1048576,
      frame_hash: end.frame_hash,
      state_hash: end.state_hash,
      pictures,
      sound: { ...sound, agent_frames: stream.length / 4 },
    });

    // The settings record kept by the browser, applied at the start.
    report('settings', ...await settingsCheck(page, url));

    // A reload: the files from the server again, the settings kept and applied, and the game as the
    // player runs it, from its first tick: the tap in, a click (the gesture that starts the sound),
    // then the page's own updates.
    await openGame(page, url, true);
    const reloaded = await page.evaluate('sorz.stats()');
    await page.evaluate(installTap);
    await page.evaluate('sorz.setPacing(false)');
    await page.click(20, 20);
    await page.evaluate('sorz.manual = false');
    const tappedFrom = 0;
    // The machine's load (1-minute average) before and after: other work on it slows the page.
    const loadBefore = os.loadavg()[0];
    const shown = { compared: 0, beyond_reference: 0, first_difference: null };
    const until = Date.now() + options.seconds * 1000;
    let last = 0;
    while (Date.now() < until) {
      await sleep(200);
      const s = await page.evaluate('sorz.inspect()');
      if (s.ticks === last) continue;
      last = s.ticks;
      if (s.ticks > hashes.length) {
        shown.beyond_reference += 1;
        continue;
      }
      shown.compared += 1;
      if (s.frame_hash !== hashes[s.ticks - 1] && !shown.first_difference) shown.first_difference = { tick: s.ticks, hash: s.frame_hash, reference: hashes[s.ticks - 1] };
    }
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-realtime.png'));
    const run = await page.evaluate('sorz.stats()');
    const rate = run.ticks / run.seconds;
    // The sound from where the tap began (the ticks before it sounded at the page's start).
    const realtimeSound = tappedFrom === 0 ? compareSound(await page.evaluate('__tap'), stream) : { blocks: 0, first_difference: null, skipped_ticks: tappedFrom };
    report('realtime', shown.first_difference === null && shown.compared > 0 && Math.abs(rate / 59.9227 - 1) < 0.005 &&
      run.audio_state === 'running' && run.audio_underruns === 0 && realtimeSound.first_difference === null, {
      machine_load: [Math.round(loadBefore * 10) / 10, Math.round(os.loadavg()[0] * 10) / 10, os.cpus().length + ' cores'],
      module_bytes: fs.statSync(path.join(options.web, 'sorz.wasm')).size,
      page_to_ready_ms: Math.round(reloaded.ready_ms),
      files_ms: Math.round(reloaded.files_ms),
      load_ms: Math.round(reloaded.start_ms),
      seconds: Math.round(run.seconds * 10) / 10,
      ticks: run.ticks,
      ticks_per_second: Math.round(rate * 1000) / 1000,
      updates_per_second: Math.round(run.updates / run.seconds * 100) / 100,
      mean_update_ms: Math.round(run.mean_update_ms * 100) / 100,
      longest_update_ms: Math.round(run.longest_update_ms * 10) / 10,
      updates_over_16ms: run.slow_updates,
      slow_updates: run.slow_log.slice(0, 20).map(([ms, tick]) => ({ ms, tick })),
      audio: { state: run.audio_state, rate: run.audio_rate, underruns: run.audio_underruns, dropped: run.audio_dropped, base_latency_ms: Math.round(run.audio_base_latency * 10000) / 10 },
      shown,
      sound: realtimeSound,
    });

    // Hidden, then shown again.
    const before = await page.evaluate('sorz.inspect().ticks');
    const underrunsBefore = (await page.evaluate('sorz.stats()')).audio_underruns;
    const other = await Page.open(browser.cdp);
    await browser.cdp.send('Target.activateTarget', { targetId: other.targetId });
    await sleep(300);
    const hiddenAt = await page.evaluate('({ t: sorz.inspect().ticks, visibility: document.visibilityState, audio: sorz.stats().audio_state })');
    await sleep(3000);
    const hiddenAfter = await page.evaluate('sorz.inspect().ticks');
    await other.close();
    await browser.cdp.send('Target.activateTarget', { targetId: page.targetId });
    await sleep(3000);
    const back = await page.evaluate('({ t: sorz.inspect().ticks, visibility: document.visibilityState, stats: sorz.stats() })');
    const hiddenSound = tappedFrom === 0 ? compareSound(await page.evaluate('__tap'), stream) : { first_difference: null };
    const resumedTicks = back.t - hiddenAfter;
    report('hidden', hiddenAt.visibility === 'hidden' && hiddenAt.audio === 'suspended' && hiddenAfter === hiddenAt.t &&
      back.visibility === 'visible' && back.stats.audio_state === 'running' && resumedTicks > 150 && resumedTicks < 210 &&
      back.stats.audio_underruns === underrunsBefore && hiddenSound.first_difference === null, {
      before,
      hidden: hiddenAt,
      ticks_while_hidden: hiddenAfter - hiddenAt.t,
      ticks_in_3_s_after: resumedTicks,
      audio_state: back.stats.audio_state,
      underruns: back.stats.audio_underruns - underrunsBefore,
      sound: hiddenSound,
    });

    // Input: Start pressed through the keyboard (P: the kept record's), then through a gamepad (its
    // Start button), each for five ticks, one tick per update, against the agent host pressing
    // Enter (its default layout) at the same ticks. The gamepad is a stand-in for
    // `navigator.getGamepads()`, with the standard mapping: the page's polling and the module's
    // mapping are the ones checked.
    const presses = [700, 1000];
    const hold = 5;
    const keyed = [
      runAgentWith(['--frames', String(presses[1]), '--key', `${presses[0]}:enter:${hold}`]),
      runAgentWith(['--frames', '1400', '--key', `${presses[0]}:enter:${hold}`, '--key', `${presses[1]}:enter:${hold}`]),
    ];
    await openGame(page, url, true);
    await page.evaluate(`(() => {
      const buttons = Array.from({ length: 17 }, () => ({ pressed: false, touched: false, value: 0 }));
      window.__pad = { id: 'browser-check pad', index: 0, connected: true, mapping: 'standard', timestamp: 0, axes: [0, 0, 0, 0], buttons };
      navigator.getGamepads = () => [window.__pad];
    })()`);
    const padButton = (b, pressed) => page.evaluate(`window.__pad.buttons[${b}] = { pressed: ${pressed}, touched: ${pressed}, value: ${pressed ? 1 : 0} }`);
    const stepTo = (tick) => page.evaluate(`sorz.step(${tick} - (sorz.inspect() ? sorz.inspect().ticks : 0))`);
    const key = async (type) => {
      await page.send('Input.dispatchKeyEvent', { type, ...keyEvents.p, nativeVirtualKeyCode: 80 });
    };
    const padStart = (pressed) => padButton(9, pressed);
    await stepTo(presses[0]);
    await key('keyDown');
    await stepTo(presses[0] + hold);
    await key('keyUp');
    await stepTo(presses[1]);
    const afterKey = await page.evaluate('sorz.inspect()');
    await padStart(true);
    await stepTo(presses[1] + hold);
    await padStart(false);
    await stepTo(1400);
    const afterPad = await page.evaluate('sorz.inspect()');
    report('input', afterKey.state_hash === keyed[0].state_hash && afterKey.frame_hash === keyed[0].frame_hash &&
      afterPad.state_hash === keyed[1].state_hash && afterPad.frame_hash === keyed[1].frame_hash &&
      afterKey.state_hash !== runAgentWith(['--frames', String(presses[1])]).state_hash, {
      keyboard: { key: keyEvents.p.code, ticks: afterKey.ticks, state_hash: afterKey.state_hash, agent: keyed[0].state_hash },
      gamepad: { ticks: afterPad.ticks, state_hash: afterPad.state_hash, agent: keyed[1].state_hash },
    });

    // Network play on the real game: a page joining the agent host's round, two pages through the
    // relay.
    if (options.content) {
      const result = await netplaySession(browser);
      report('netplay', result.pass, result.fields);
      for (const [part, pass, fields] of await relayCheck(browser, chromium, path.join(scratch, 'profile-relay'))) report(part, pass, fields);
    }

    const errors = page.console.filter((m) => m.type === 'error' || m.type === 'exception');
    report('console', errors.length === 0, { errors: errors.slice(0, 5) });
  } finally {
    // The browser and every process it started, before its profile is removed.
    if (browser) await browser.stop();
    if (relay) {
      if (relay.child.exitCode === null) relay.child.kill();
      await relay.done;
    }
    server.close();
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

main().then(() => process.exit(failed ? 1 : 0), (e) => {
  console.error('browser-check: ' + (e && e.stack || e));
  process.exit(1);
});
