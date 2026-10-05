// `zig build browser-check`: the browser build in Chromium, against the agent host, and two pages
// through the relay.
//
//   node browser_check.mjs --web DIR --agent SORZ_AGENT --server SORZ_SERVER [--content DIR]
//                          [--chromium PATH] [--ticks N] [--seconds S] [--keep DIR]
//                          [--only relay | --only page | --only netplay]
//
// Every page is served by a native program, which sends it the game's files of a game directory
// (DESIGN.md 5.3); nothing else feeds the page game data. The directory is a small tree made here
// (the game reads no content yet: PLAN item 06), the same for the agent host. The pages open in a
// Chromium without a window.
//
//   page: served without the game's files (the page's three files from DIR, by a plain server), the
//      page says so and stops, in its own text in the game's colours; served by the relay over a
//      slow network, it says LOADING and its share of the files, then shows the choice that starts
//      the game: 1 PLAYER, 2 PLAYERS, and SETTINGS dimmed (the settings screen is PLAN item 19).
//      The small tree has no art: the module cannot draw its screens, and the page's text stands
//      in, as it does for a tree without the game's font and menu.
//   screens (with --content, a content tree extracted from the user's ROM): its font, its menu and
//      its sound added to the small tree, over the slow network: the module draws the loading
//      screen once it has the font and the menu, which come first, then the menu, in the game's
//      font and colours, the arrow where the game's menu has it and SETTINGS dimmed; its sounds
//      are made from the content.
//   flow (with --content): the page of a relay that serves the whole content tree: the menu's
//      sounds are made before the menu shows; SETTINGS opens the game's settings screen before
//      the game, and Escape comes back to the menu; 1 PLAYER plays the network variant
//      (DESIGN.md 10.7): after the title, the game's own menu is START, SETTINGS, OPTIONS, not 1
//      PLAYER and 2 PLAYERS again; the settings key opens the settings over the game, which
//      holds, and Escape closes them.
//   steps: 1 PLAYER, one tick per update (`sorz.step`), N ticks: the canvas's pixels and the
//      frame's hash at the ticks the agent host wrote pictures of must equal the agent host's, and
//      so must the state's hash and the frame's hash at the end, and every block of sound the game
//      queued (the agent host's WAV).
//   settings: a settings record kept by the browser for the page (pad 1's Start on P, the volume at
//      30, the scale at 1) is read at the start and applied: the output's gain, the picture's whole
//      multiple; F1 (the settings key) never reaches the browser, F2 and Escape do.
//   realtime: the game as the player runs it, paced by the sound, for S seconds: every frame it
//      shows must be the frame of the same tick in the steps part, the ticks must come at the
//      console's rate (59.92 a second), and the sound must not run dry.
//   hidden: the page hidden (another tab in front) then shown again: the game waits, its sound is
//      suspended, and it goes on from where it was.
//   input: 1 PLAYER chosen with a gamepad's A, which the game never gets; Start pressed through the
//      keyboard (P, the record's), then through the gamepad, against the agent host pressing Enter
//      (its default) at the same ticks.
//   netplay: the agent host hosts a session (`--netplay`) and serves the page and its files; the
//      page, opened at the host's address, offers 2 PLAYERS only, joins as player 2 and plays from
//      power-on, the host pressing Enter on pad 1 and the page on pad 2. One tick per update, the
//      two games' states must be the same at the last tick; then in real time, paced by the page's
//      sound, the session's own checks (every 30 ticks) must find no difference.
//   netplay_round (with --content): the same with the whole content tree, the real game: the agent
//      host's START on the intro, the title and the network variant's menu (the host's variant is
//      the page's), each player's character chosen, round 1 played; the two states the same at
//      tick 2400, both in the round.
//   relay: two pages of the relay (`sorz-server DIR --server`), in two Chromiums with their own
//      profiles, each choosing 2 PLAYERS, play through it from power-on: the first to choose hosts
//      (player 1), the second joins (player 2). One tick per update, the two states must be the
//      same at tick 1500 (and not the state without their keys); then in real time, the session's
//      checks must find no difference. Then the relay's rules, the pages in real time: a third page
//      is turned away while two play (its menu comes back without 2 PLAYERS, and says why); the
//      guest leaves, the host holds and says so over its picture, and the next page is its new guest
//      (a new session from power-on); the host leaves, its guest's game ends and says why, and the
//      next page hosts.
//
// The agent host's frames are ticks: its picture at frame F is the page's after F + 1 updates of
// one tick. The report is one JSON line per part, and the exit status says whether every part
// passed. Everything made here stays in a temporary directory that is removed at the end (with
// --keep, the pictures and screenshots are copied there). `--only relay` runs the relay's parts
// alone, `--only page` the page's look (and with --content its flow), `--only netplay` network
// play with the agent host (and with --content the real game's).
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

// The page at `url`, its files loaded from its server, on the choice that starts the game.
async function openGame(page, url) {
  // The document before the navigation is marked, so that its state is not taken for the new one's.
  await page.evaluate('window.__stale = true').catch(() => {});
  await page.navigate(url);
  await page.waitFor(`window.__stale === undefined && window.sorz !== undefined && (sorz.phase === 'ready' || sorz.phase === 'stopped')`, 120000, 'the game to be ready');
  const phase = await page.evaluate('sorz.phase');
  if (phase !== 'ready') throw new Error('the page did not get ready: ' + await page.evaluate('sorz.message'));
}

// The arrow keys move the menu's arrow, as on the game's menu; Enter chooses (a gesture).
const keyEvents = {
  enter: { code: 'Enter', key: 'Enter', windowsVirtualKeyCode: 13 },
  up: { code: 'ArrowUp', key: 'ArrowUp', windowsVirtualKeyCode: 38 },
  down: { code: 'ArrowDown', key: 'ArrowDown', windowsVirtualKeyCode: 40 },
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

// One session: the agent host (player 1, Enter at tick 700) serves the page and its files at its
// port, and a new tab opens it and joins (player 2, Enter at tick 1000). One tick per update, the
// page stops at the host's last tick and the states are compared; in real time, the page plays as
// the player does and the session's checks decide. With `game` (the whole content tree), the real
// game from power-on to round 1: the host's START on the intro, the title and the network
// variant's menu, Axel chosen; the page's player chooses too, and the host walks.
async function netplaySession(browser, realtime, game = null) {
  const ticks = game ? 2400 : realtime ? 1800 : 1500;
  const hostKeys = game
    ? ['500:enter:3', '560:enter:3', '640:enter:3', '860:right:3', '880:z:3', '1500:right:60', '1700:x:3']
    : ['700:enter:5'];
  // The page's keys, by tick: [tick, key, ticks held].
  const guestKeys = game ? [[900, keyEvents.z, 3], [1600, keyEvents.up, 30]] : [[1000, keyEvents.enter, 5]];
  const port = await freePort();
  const host = spawn(options.agent, [game || options.data, '--netplay', `127.0.0.1:${port}`, '--delay', '3',
    '--frames', String(ticks), ...hostKeys.flatMap((k) => ['--key', k])], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  let log = '';
  host.stdout.on('data', (d) => { out += d; });
  host.stderr.on('data', (d) => { log += d; });
  const hostDone = new Promise((resolve) => host.on('exit', resolve));
  const page = await Page.open(browser.cdp);
  try {
    const url = `http://127.0.0.1:${port}/`;
    for (let tries = 0; !log.includes('hosting at'); tries++) {
      if (tries > 300 || host.exitCode !== null) throw new Error('the agent host did not start: ' + log.slice(-400));
      await sleep(100);
    }
    await openGame(page, url);
    const mode = await page.evaluate('sorz.netMode');
    // The menu offers 2 PLAYERS only, the arrow on it; the click anywhere chooses it.
    const invitation = await page.evaluate('sorz.message');
    if (!realtime) await page.evaluate('sorz.manual = true');
    await page.click(20, 20);
    await page.waitFor(`sorz.phase === 'playing'`, 5000, 'the click to join');
    const began = Date.now();
    let state = null;
    if (!realtime) {
      await page.evaluate('sorz.setPacing(true)');
      // Each key goes down at its tick and up the ticks it is held later (a tick runs only when
      // both pads are in, so the key is held for ticks, not for updates).
      const keys = guestKeys.map(([at, key, held]) => ({ at, key, held, down: null, up: false }));
      for (let t = 0; t < ticks;) {
        if (Date.now() - began > 300000) throw new Error('the session did not reach tick ' + ticks);
        for (const k of keys) {
          if (k.down === null && t >= k.at) {
            k.down = t;
            await page.send('Input.dispatchKeyEvent', { type: 'keyDown', ...k.key });
          } else if (k.down !== null && !k.up && t >= k.down + k.held) {
            k.up = true;
            await page.send('Input.dispatchKeyEvent', { type: 'keyUp', ...k.key });
          }
        }
        // At most the ticks left, and a few at a time, so the page's socket delivers the host's pads
        // between the steps; the page never passes the host's last tick.
        const step = keys.some((k) => k.down !== null && !k.up) || keys.some((k) => k.down === null && k.at - t < 20) ? 1 : 20;
        state = await page.evaluate(`(() => { sorz.step(Math.min(${ticks} - sorz.inspect().ticks, ${step})); return sorz.inspect(); })()`);
        t = state.ticks;
        await sleep(1);
      }
    } else {
      let pressed = false;
      while (host.exitCode === null && Date.now() - began < 120000) {
        await sleep(100);
        state = await page.evaluate('sorz.inspect()');
        if (!pressed && state.ticks >= 1000) {
          pressed = true;
          await page.send('Input.dispatchKeyEvent', { type: 'keyDown', ...keyEvents.enter });
          await sleep(100);
          await page.send('Input.dispatchKeyEvent', { type: 'keyUp', ...keyEvents.enter });
        }
      }
    }
    const seconds = (Date.now() - began) / 1000;
    const code = await Promise.race([hostDone, sleep(30000).then(() => 'timeout')]);
    const result = JSON.parse(out.trim().split('\n').pop() || '{}');
    const guest = await page.evaluate('sorz.inspect()');
    const stats = await page.evaluate('sorz.stats()');
    const hostGame = result.host || {};
    const errors = page.console.filter((m) => m.type === 'error' || m.type === 'exception');
    const inStep = realtime
      ? !guest.net.difference && !log.includes('differ')
      : state.state_hash === hostGame.state_hash && state.ticks === hostGame.ticks && state.net.phase === 'playing';
    // With the game's content: the host's variant, network play's, on both, and round 1 reached.
    const inRound = !game || (hostGame.variant === 'network' && hostGame.scene === 'round' && guest.variant === 'network' && guest.scene === 'round');
    return {
      pass: code === 0 && result.verdict === 'ok' && mode === 'native' && invitation === '1 PLAYER (not here)\n▶ 2 PLAYERS\nSETTINGS' + (game ? '' : ' (not here)') &&
        inStep && inRound && errors.length === 0,
      fields: {
        mode,
        invitation,
        ticks,
        seconds: Math.round(seconds * 10) / 10,
        host: hostGame,
        host_verdict: result.verdict,
        guest: realtime
          ? { ticks: guest.ticks, net: guest.net, ticks_per_second: Math.round(guest.ticks / seconds * 100) / 100, audio_underruns: stats.audio_underruns }
          : { ticks: state.ticks, state_hash: state.state_hash, net: state.net, variant: guest.variant, scene: guest.scene },
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

// A page of the relay's in a window of its own (a tab behind another would be hidden), on the
// choice that starts the game.
async function relayPage(browser, relay) {
  const page = await Page.open(browser.cdp, 'about:blank', { newWindow: true });
  await openGame(page, relay.url);
  return page;
}

// 2 PLAYERS chosen (the arrow down, then a click anywhere), one tick per update with `manual`; the
// relay's answer.
async function joinRelay(page, manual) {
  if (manual) await page.evaluate('sorz.manual = true');
  await tap(page, keyEvents.down);
  await page.click(20, 20);
  await page.waitFor(`sorz.relayState !== null`, 10000, 'the relay\'s answer');
  return page.evaluate('sorz.relayState');
}

async function pressEnter(page) {
  await page.send('Input.dispatchKeyEvent', { type: 'keyDown', ...keyEvents.enter });
  await sleep(100);
  await page.send('Input.dispatchKeyEvent', { type: 'keyUp', ...keyEvents.enter });
}

// What the page means to show (`sorz.message`), and what it shows: its own text, and whether its
// overlay is up and over the picture.
const pageText = `({ message: sorz.message, phase: sorz.phase, relay: sorz.relayState,
  text: document.getElementById('message').textContent,
  overlay: getComputedStyle(document.getElementById('overlay')).display !== 'none',
  over: document.getElementById('overlay').classList.contains('over') })`;

// The tick counts of pages, once and again a second later.
async function advancing(pages) {
  const before = await Promise.all(pages.map((p) => p.evaluate('sorz.inspect().ticks')));
  await sleep(1000);
  const after = await Promise.all(pages.map((p) => p.evaluate('sorz.inspect().ticks')));
  return before.map((v, i) => after[i] - v);
}

// Two pages through the relay, one tick per update, then in real time, then the relay's rules.
// The host's page is in `browser`, the guest's in a second Chromium with its own profile
// (`profile`), each loading the files from the relay; the later pages open in the first browser.
// Returns the parts' reports.
async function relayCheck(browser, chromium, profile) {
  const reports = [];
  const ticks = 1500;
  const presses = [700, 1000];
  // The state at the last tick without the pages' keys, which their keys must have changed.
  const alone = runAgentWith(['--frames', String(ticks)]);
  const relay = await startRelay();
  let second = null;
  // The pages open (closed ones leave), and every page for the console's errors.
  const pages = [];
  const all = [];
  const open = async (inBrowser = browser) => {
    const page = await relayPage(inBrowser, relay);
    pages.push(page);
    all.push(page);
    return page;
  };
  try {
    second = await launch(chromium, profile);
    let host = await open();
    let guest = await open(second);
    const mode = await host.evaluate('sorz.netMode');
    // Both lines, the arrow on 1 PLAYER, and SETTINGS dimmed.
    const invitation = await host.evaluate('sorz.message');
    const roles = [await joinRelay(host, true), await joinRelay(guest, true)];
    if (roles[0] !== 'host' || roles[1] !== 'guest') throw new Error('the relay gave the roles ' + roles.join(', '));
    const both = [host, guest];
    for (const p of both) await p.evaluate('sorz.setPacing(true)');
    const pressed = [null, null];
    const released = [false, false];
    let states = await Promise.all(both.map((p) => p.evaluate('sorz.inspect()')));
    const began = Date.now();
    while (!states.every((s) => s.ticks >= ticks)) {
      if (Date.now() - began > 300000) throw new Error('the pages did not reach tick ' + ticks + ': ' + JSON.stringify(states.map((s) => s.ticks)));
      for (let i = 0; i < 2; i++) {
        const t = states[i].ticks;
        if (pressed[i] === null && t >= presses[i]) {
          pressed[i] = t;
          await both[i].send('Input.dispatchKeyEvent', { type: 'keyDown', ...keyEvents.enter });
        } else if (pressed[i] !== null && !released[i] && t >= pressed[i] + 5) {
          released[i] = true;
          await both[i].send('Input.dispatchKeyEvent', { type: 'keyUp', ...keyEvents.enter });
        }
      }
      states = await Promise.all(both.map((p, i) => {
        const t = states[i].ticks;
        const until = pressed[i] === null ? presses[i] : ticks;
        const step = pressed[i] !== null && !released[i] ? 1 : Math.min(20, until - t);
        return p.evaluate(`(() => { sorz.step(${Math.max(0, step)}); return sorz.inspect(); })()`);
      }));
      await sleep(1);
    }
    const [h, g] = states;
    reports.push(['relay', h.state_hash === g.state_hash && h.ticks === ticks && g.ticks === ticks &&
      h.net.phase === 'playing' && g.net.phase === 'playing' && !h.net.difference && !g.net.difference &&
      h.state_hash !== alone.state_hash && mode === 'relay' && invitation === '▶ 1 PLAYER\n2 PLAYERS\nSETTINGS (not here)', {
      mode,
      invitation,
      roles,
      ticks,
      seconds: Math.round((Date.now() - began) / 100) / 10,
      presses: pressed,
      host: { state_hash: h.state_hash, net: h.net },
      guest: { state_hash: g.state_hash, net: g.net },
      changed_the_game: h.state_hash !== alone.state_hash,
    }]);

    // In real time: the pages again, each paced by its own sound.
    await openGame(host, relay.url);
    await openGame(guest, relay.url);
    const realtimeRoles = [await joinRelay(host, false), await joinRelay(guest, false)];
    const start = Date.now();
    const keys = [false, false];
    let live = null;
    while (Date.now() - start < 120000) {
      await sleep(200);
      live = await Promise.all(both.map((p) => p.evaluate('sorz.inspect()')));
      for (let i = 0; i < 2; i++) {
        if (!keys[i] && live[i].ticks >= presses[i]) {
          keys[i] = true;
          await pressEnter(both[i]);
        }
      }
      if (live.every((s) => s.ticks >= 1800) || live.some((s) => s.net.phase === 'desynced' || s.net.phase === 'ended')) break;
    }
    const seconds = (Date.now() - start) / 1000;
    const stats = await Promise.all(both.map((p) => p.evaluate('sorz.stats()')));
    reports.push(['relay_realtime', realtimeRoles[0] === 'host' && realtimeRoles[1] === 'guest' &&
      live.every((s) => s.ticks >= 1800 && s.net.phase === 'playing' && s.net.connected && !s.net.difference && s.net.epoch === 1), {
      roles: realtimeRoles,
      seconds: Math.round(seconds * 10) / 10,
      pages: live.map((s, i) => ({
        ticks: s.ticks,
        ticks_per_second: Math.round(s.ticks / seconds * 100) / 100,
        net: s.net,
        audio_underruns: stats[i].audio_underruns,
      })),
    }]);

    // The relay's rules, the two pages playing on. A third page is turned away: its menu again,
    // 1 PLAYER only, and why.
    let third = await open();
    const thirdState = await joinRelay(third, false);
    await third.waitFor(`sorz.phase === 'ready'`, 5000, 'the third page\'s menu');
    const turnedAway = await third.evaluate(pageText);
    if (options.keep) await third.screenshot(path.join(options.keep, 'page-busy.png'));
    const playingOn = await advancing(both);
    // The guest leaves: the host holds and says why.
    await guest.close();
    pages.splice(pages.indexOf(guest), 1);
    await host.waitFor(`sorz.inspect().net.connected === false`, 5000, 'the host to hear that its guest left');
    await sleep(600);
    const hostAlone = { ...(await host.evaluate(pageText)), ticks_in_1_s: (await advancing([host]))[0] };
    if (options.keep) await host.screenshot(path.join(options.keep, 'page-guest-left.png'));
    // The next page is the host's new guest: a new session from power-on.
    await openGame(third, relay.url);
    const newGuestState = await joinRelay(third, false);
    guest = third;
    third = null;
    await host.waitFor(`sorz.inspect().net.epoch === 2 && sorz.inspect().net.phase === 'playing'`, 15000, 'the host\'s new session');
    await guest.waitFor(`sorz.inspect().ticks > 120`, 15000, 'the new guest to play');
    const newSession = await Promise.all([host, guest].map((p) => p.evaluate('sorz.inspect()')));
    const newPlaying = await advancing([host, guest]);
    // The host leaves: its guest's game ends, and the next page hosts.
    await host.close();
    pages.splice(pages.indexOf(host), 1);
    await guest.waitFor(`sorz.phase === 'stopped'`, 10000, 'the guest to hear that its host left');
    const guestAlone = await guest.evaluate(pageText);
    if (options.keep) await guest.screenshot(path.join(options.keep, 'page-host-left.png'));
    const next = await open();
    const nextState = await joinRelay(next, false);
    reports.push(['relay_rules', thirdState === 'busy' && turnedAway.phase === 'ready' &&
      turnedAway.message === '▶ 1 PLAYER\n2 PLAYERS (not here)\nSETTINGS (not here)\nTWO PLAYERS ARE PLAYING HERE' && playingOn.every((n) => n > 30) &&
      hostAlone.message === 'PLAYER 2 LEFT\nWAITING FOR PLAYER 2' && hostAlone.text === hostAlone.message && hostAlone.overlay && hostAlone.over &&
      hostAlone.ticks_in_1_s === 0 &&
      newGuestState === 'guest' && newSession.every((s) => s.net.phase === 'playing') &&
      newSession[0].net.epoch === 2 && newSession[1].net.epoch === 1 && newPlaying.every((n) => n > 30) &&
      guestAlone.relay === 'host_left' && guestAlone.phase === 'stopped' &&
      guestAlone.message === 'PLAYER 1 LEFT\nRELOAD THE PAGE TO PLAY AGAIN' && guestAlone.text === guestAlone.message && guestAlone.overlay &&
      !guestAlone.over && nextState === 'host', {
      third: { relay: thirdState, message: turnedAway.message, the_two_play_on: playingOn },
      guest_left: { host: hostAlone },
      new_guest: { relay: newGuestState, epochs: newSession.map((s) => s.net.epoch), ticks: newSession.map((s) => s.ticks), playing: newPlaying },
      host_left: { guest: guestAlone, next_page: nextState },
      relay_log: relay.log.trim().split('\n').slice(-12),
    }]);
    const errors = all.flatMap((p) => p.console.filter((m) => m.type === 'error' || m.type === 'exception'));
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
const keptRecord = JSON.stringify({
  version: 1,
  keys: {
    pad1: { up: 'up', down: 'down', left: 'left', right: 'right', a: 'z', b: 'x', c: 'c', start: 'p' },
    pad2: { up: 'w', down: 's', left: 'a', right: 'd', a: 'f', b: 'g', c: 'h', start: 'tab' },
    settings: 'f1',
  },
  controllers: { first_pad: 1, buttons: { a: 'x', b: 'a', c: 'b', start: 'start' } },
  sound: { volume: 30, mute: false },
  window: { scale: 1, fullscreen: false },
}, null, 2);

// Part `settings`: the record kept before the page loads is the game's at the start, and the page
// applies it; the keys the game takes never reach the browser, and the others do. Leaves the page
// playing, one tick per update.
async function settingsCheck(page, url) {
  await page.navigate('about:blank');
  await openGame(page, url);
  await page.evaluate(`localStorage.setItem('sorz:settings.json', btoa(${JSON.stringify(keptRecord)}))`);
  await openGame(page, url);
  // What the page's keydown left for the browser: a listener added after the page's sees it.
  await page.evaluate(`(() => {
    window.__keys = [];
    window.addEventListener('keydown', (e) => __keys.push([e.code, e.defaultPrevented]));
    sorz.manual = true;
  })()`);
  const menu = await page.evaluate('sorz.message');
  // On the menu, F1 is the game's (its settings screen, PLAN item 19), F2 the browser's.
  await tap(page, keyEvents.f2);
  await tap(page, keyEvents.f1);
  const onMenu = await page.evaluate('sorz.phase');
  await page.click(20, 20);
  await page.waitFor(`sorz.phase === 'playing'`, 5000, 'the click to start the game');
  await page.evaluate('sorz.setPacing(true); sorz.step(3)');
  // In play: F1 and P are the game's, F2 and Escape the browser's.
  for (const key of [keyEvents.f1, keyEvents.p, keyEvents.f2, keyEvents.escape]) await tap(page, key);
  await page.evaluate('sorz.step(1)');
  const kept = await page.evaluate(`({ state: sorz.inspect(), view: sorz.view, gain: sorz.stats().audio_gain, keys: __keys })`);
  const prevented = (code) => kept.keys.filter(([c]) => c === code).map(([, p]) => p);
  const s = kept.state.settings;
  const pass = menu === '▶ 1 PLAYER\n2 PLAYERS\nSETTINGS (not here)' && onMenu === 'ready' &&
    kept.state.loads_done === 1 && kept.state.notice === 'none' && s.volume === 30 && s.scale === 1 && s.start_key === 'p' &&
    Math.abs(kept.gain - 0.09) < 1e-6 && Math.abs(kept.view.gain - 0.09) < 1e-9 &&
    multiple(kept.view) === Math.max(1, Math.round(kept.view.device_pixel_ratio)) &&
    prevented('F1').length === 2 && prevented('F1').every((p) => p) && prevented('KeyP').length === 1 && prevented('KeyP')[0] &&
    prevented('F2').length === 2 && prevented('F2').every((p) => !p) && prevented('Escape').length === 1 && !prevented('Escape')[0];
  return [pass, {
    menu,
    record: { loads: kept.state.loads_done, notice: kept.state.notice, volume: s.volume, scale: s.scale, start_key: s.start_key },
    applied: { gain: kept.gain, view_gain: kept.view.gain, multiple: multiple(kept.view) },
    browser_gets: { F1: prevented('F1').map((p) => !p), P: prevented('KeyP').map((p) => !p), F2: prevented('F2').map((p) => !p), Escape: prevented('Escape').map((p) => !p) },
    pending: 'the settings screen (PLAN item 19): changing the settings on the page, and the menu\'s SETTINGS',
  }];
}

// --- the page's own look --------------------------------------------------------------------------

// Part `page`: the page without the game's files, then the page of the relay over a slow network:
// its own text, in the game's colours, from the loading to the menu.
async function pageCheck(browser, bareUrl) {
  const relay = await startRelay();
  const page = await Page.open(browser.cdp);
  try {
    const style = `(() => {
      const m = getComputedStyle(document.getElementById('message'));
      return { message: sorz.message, phase: sorz.phase, screens: sorz.screens, color: m.color, font_style: m.fontStyle,
        overlay: getComputedStyle(document.getElementById('overlay')).backgroundColor };
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

    // The menu, in the page's text: SETTINGS dimmed until the game has its settings screen.
    await page.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await page.waitFor(`sorz.phase === 'ready'`, 120000, 'the menu');
    const menu = await page.evaluate(style);
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-menu.png'));
    const menuOk = menu.message === '▶ 1 PLAYER\n2 PLAYERS\nSETTINGS (not here)' && !menu.screens &&
      menu.color === 'rgb(255, 255, 255)' && menu.font_style === 'italic';
    return [bareOk && loadingOk && menuOk && relay.log.includes('(directory, 41 files'), {
      served: relay.log.trim().split('\n')[0],
      no_files: { message: bare.message.split('\n')[0], color: bare.color, font_style: bare.font_style, overlay: bare.overlay },
      loading: { message: loading.message, files: loading.files, screens: loading.screens },
      menu: { message: menu.message, screens: menu.screens },
    }];
  } finally {
    await page.close();
    if (relay.child.exitCode === null) relay.child.kill();
    await relay.done;
  }
}

// Part `flow`: the page of a relay that serves the whole content tree (DESIGN.md 10.7: the
// network variant's flow, the settings before and in the game).
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
    await openGame(page, relay.url);
    // The menu's sounds were made before the menu showed: they are there at once.
    const atReady = await page.evaluate('sorz.stats().menu_sounds');
    const menu = await page.evaluate('sorz.message');
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-flow-menu.png'));
    // SETTINGS: the game's settings screen, before the game; its title on row 2.
    await tap(page, keyEvents.down);
    await tap(page, keyEvents.down);
    await tap(page, keyEvents.enter);
    await page.waitFor(`sorz.phase === 'settings'`, 5000, 'the settings screen');
    await sleep(300);
    const settingsPixels = Buffer.from(await page.evaluate(canvasBase64), 'base64');
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-flow-settings.png'));
    const settingsTitle = whiteIn(settingsPixels, 2);
    await tap(page, keyEvents.escape);
    await page.waitFor(`sorz.phase === 'ready'`, 5000, 'the menu again');
    const back = await page.evaluate('sorz.message');
    // 1 PLAYER, one tick per update: START on the intro and on the title, then the game's menu.
    await tap(page, keyEvents.up);
    await tap(page, keyEvents.up);
    await page.evaluate('sorz.manual = true');
    await tap(page, keyEvents.enter);
    await page.waitFor(`sorz.phase === 'playing'`, 5000, 'the game');
    await page.evaluate('sorz.setPacing(true)');
    // A key held for two ticks, as the pads read it.
    const hold = async (key) => {
      await page.send('Input.dispatchKeyEvent', { type: 'keyDown', ...key });
      await page.evaluate('sorz.step(2)');
      await page.send('Input.dispatchKeyEvent', { type: 'keyUp', ...key });
      await page.evaluate('sorz.step(1)');
    };
    await page.evaluate('sorz.step(500)');
    await hold(keyEvents.enter);
    await page.evaluate('sorz.step(60)');
    await hold(keyEvents.enter);
    await page.evaluate('sorz.step(160)');
    const inMenu = await page.evaluate('sorz.inspect()');
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-flow-game-menu.png'));
    // The settings key: the settings over the game, which holds; Escape closes them.
    await hold(keyEvents.f1);
    await page.evaluate('sorz.step(30)');
    const held = await page.evaluate('sorz.inspect()');
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-flow-game-settings.png'));
    await hold(keyEvents.escape);
    await page.evaluate('sorz.step(5)');
    const after = await page.evaluate('sorz.inspect()');
    const errors = page.console.filter((m) => m.type === 'error' || m.type === 'exception');
    const pass = atReady.every((n) => n > 1000) && menu === '▶ 1 PLAYER\n2 PLAYERS\nSETTINGS' && settingsTitle > 20 &&
      back === '1 PLAYER\n2 PLAYERS\n▶ SETTINGS' && inMenu.variant === 'network' && inMenu.scene === 'menu' &&
      inMenu.menu === 'start,settings,options' && held.settings_open && held.ticks <= inMenu.ticks + 4 &&
      !after.settings_open && after.ticks > held.ticks && errors.length === 0;
    return [pass, {
      menu_sounds_at_menu: atReady, menu, settings_title: settingsTitle, back,
      game: { variant: inMenu.variant, scene: inMenu.scene, menu: inMenu.menu, ticks: inMenu.ticks },
      held: { settings_open: held.settings_open, ticks: held.ticks }, after: { settings_open: after.settings_open, ticks: after.ticks },
      errors: errors.slice(0, 3),
    }];
  } finally {
    await page.close();
    if (relay.child.exitCode === null) relay.child.kill();
    await relay.done;
  }
}

// Part `screens`: the page of the relay over a slow network, its tree with the content's font,
// menu and sound: the module draws the loading screen, then the menu, in the game's style.
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
    await page.waitFor(`sorz.phase === 'ready'`, 120000, 'the menu');
    await page.waitFor(`sorz.stats().menu_sounds.every((n) => n > 0)`, 30000, 'the menu\'s sounds');
    const menu = await page.evaluate(look);
    const sounds = (await page.evaluate('sorz.stats()')).menu_sounds;
    const pixels = Buffer.from(await page.evaluate(canvasBase64), 'base64');
    if (options.keep) await page.screenshot(path.join(options.keep, 'page-screens-menu.png'));
    // The game's menu's places: the lines at column 16 of rows 11, 13 and 15, the arrow two cells
    // left; 1 PLAYER and 2 PLAYERS in the menu's white, SETTINGS dimmed (the menu's one-pad grey).
    const dim = [49, 49, 49];
    const arrow = [11, 13, 15].map((row) => cellHas(pixels, 14, row, white));
    const lines = [11, 13, 15].map((row) => [16, 17, 18, 19].reduce((n, c) => n + cellHas(pixels, c, row, white), 0));
    const dimmed = [16, 17, 18, 19].reduce((n, c) => n + cellHas(pixels, c, 15, dim), 0);
    const menuOk = menu.screens && menu.message === '▶ 1 PLAYER\n2 PLAYERS\nSETTINGS (not here)' && menu.overlay.includes('screen') &&
      arrow[0] > 5 && arrow[1] === 0 && arrow[2] === 0 && lines[0] > 20 && lines[1] > 20 && lines[2] === 0 && dimmed > 20 &&
      sounds.every((n) => n > 1000);
    return [loadingOk && menuOk, {
      loading: { message: loading.message, files: loading.files, screens: loading.screens, lit: loadingLit },
      menu: { message: menu.message, screens: menu.screens, arrow, lines, dimmed },
      menu_sounds: sounds,
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
      browser = await launch(chromium, path.join(scratch, 'profile'));
      for (const [part, pass, fields] of await relayCheck(browser, chromium, path.join(scratch, 'profile-relay'))) report(part, pass, fields);
      return;
    }
    if (options.content) makeScreensTree(path.join(scratch, 'game-screens'));
    if (options.only === 'netplay') {
      browser = await launch(chromium, path.join(scratch, 'profile'));
      for (const realtime of [false, true]) {
        const result = await netplaySession(browser, realtime);
        report(realtime ? 'netplay_realtime' : 'netplay', result.pass, result.fields);
      }
      if (options.content) {
        const result = await netplaySession(browser, false, options.content);
        report('netplay_round', result.pass, result.fields);
      }
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
    // alone (1 PLAYER, the menu's first line).
    relay = await startRelay();
    const url = relay.url;

    report('page', ...await pageCheck(browser, bareUrl));
    if (options.content) report('screens', ...await screensCheck(browser, path.join(scratch, 'game-screens')));
    if (options.content) report('flow', ...await flowCheck(browser));

    const page = await Page.open(browser.cdp);

    // One tick per update, against the agent host's frames and sound.
    await openGame(page, url);
    const start = await page.evaluate('sorz.stats()');
    await page.evaluate(installTap);
    await page.evaluate('sorz.manual = true');
    await page.click(20, 20);
    await page.waitFor(`sorz.phase === 'playing'`, 5000, 'the click to start the game');
    await page.evaluate('sorz.setPacing(true)');
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
    // player runs it.
    await openGame(page, url);
    const reloaded = await page.evaluate('sorz.stats()');
    await page.evaluate(installTap);
    await page.click(20, 20);
    await page.waitFor(`sorz.phase === 'playing'`, 5000, 'the click to start the game');
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
    const realtimeSound = compareSound(await page.evaluate('__tap'), stream);
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
    const hiddenSound = compareSound(await page.evaluate('__tap'), stream);
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
    await openGame(page, url);
    await page.evaluate(`(() => {
      const buttons = Array.from({ length: 17 }, () => ({ pressed: false, touched: false, value: 0 }));
      window.__pad = { id: 'browser-check pad', index: 0, connected: true, mapping: 'standard', timestamp: 0, axes: [0, 0, 0, 0], buttons };
      navigator.getGamepads = () => [window.__pad];
      sorz.manual = true;
    })()`);
    // 1 PLAYER chosen with the gamepad's A (on the menu, a step reads the gamepads); the game never
    // gets that press.
    const padButton = (b, pressed) => page.evaluate(`window.__pad.buttons[${b}] = { pressed: ${pressed}, touched: ${pressed}, value: ${pressed ? 1 : 0} }`);
    await padButton(0, true);
    await page.evaluate('sorz.step(1)');
    await page.waitFor(`sorz.phase === 'playing'`, 5000, 'the gamepad\'s A to start the game');
    await padButton(0, false);
    await page.evaluate('sorz.setPacing(true)');
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

    // Network play: the agent host and the page, from power-on.
    for (const realtime of [false, true]) {
      const result = await netplaySession(browser, realtime);
      report(realtime ? 'netplay_realtime' : 'netplay', result.pass, result.fields);
    }
    // With the game's content, the real game: the front end and round 1.
    if (options.content) {
      const result = await netplaySession(browser, false, options.content);
      report('netplay_round', result.pass, result.fields);
    }

    // Server mode: two pages through the relay.
    for (const [part, pass, fields] of await relayCheck(browser, chromium, path.join(scratch, 'profile-relay'))) report(part, pass, fields);

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
