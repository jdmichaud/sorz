// A small client of the Chrome DevTools Protocol for the page's checks: it starts a Chromium
// without a window, opens pages and drives them. It needs Node.js (22 or later, for its
// WebSocket) and a Chromium; nothing else.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';

// The browser's executable: the one named, else the first of the usual names on the PATH.
export function findChromium(named) {
  if (named) return named;
  if (process.env.CHROME) return process.env.CHROME;
  const names = ['chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable', 'chrome', 'chrome-headless-shell'];
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    for (const name of names) {
      const candidate = path.join(dir, name);
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
        return candidate;
      } catch (e) { /* Not there. */ }
    }
  }
  return null;
}

// Serves the files of `dir` (the browser build) on 127.0.0.1, on a port the system chooses.
export function serve(dir) {
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm' };
  const server = http.createServer((request, response) => {
    const name = decodeURIComponent(new URL(request.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html';
    const file = path.join(dir, path.normalize(name));
    if (!file.startsWith(path.resolve(dir) + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      response.writeHead(404);
      response.end();
      return;
    }
    response.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(file).pipe(response);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

// A Chromium without a window, with its own profile in `profile`, and its DevTools endpoint. It runs
// in a process group of its own, so that `stop` ends its helper processes too: they write into the
// profile until they exit.
export async function launch(executable, profile, extraArgs = []) {
  const args = [
    '--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + profile,
    '--no-first-run', '--no-default-browser-check', '--mute-audio', '--disable-extensions',
    '--disable-component-update', '--disable-sync', ...extraArgs, 'about:blank',
  ];
  const child = spawn(executable, args, { stdio: ['ignore', 'ignore', 'pipe'], detached: true });
  const endpoint = await new Promise((resolve, reject) => {
    let text = '';
    const timer = setTimeout(() => reject(new Error('the browser did not start: ' + text.slice(-400))), 30000);
    child.stderr.on('data', (chunk) => {
      text += chunk;
      const found = /DevTools listening on (ws:\/\/\S+)/.exec(text);
      if (found) {
        clearTimeout(timer);
        resolve(found[1]);
      }
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error('the browser exited (' + code + '): ' + text.slice(-400)));
    });
  });
  child.stderr.resume();
  const cdp = new Cdp(endpoint);
  await cdp.open();
  return { child, cdp, stop: () => stopGroup(child, cdp) };
}

// Ends the browser's process group: politely, then, after five seconds, by force. Returns once no
// process of the group is left.
async function stopGroup(child, cdp) {
  cdp.close();
  const alive = () => {
    try {
      process.kill(-child.pid, 0);
      return true;
    } catch (e) {
      return false;
    }
  };
  const signal = (name) => {
    try { process.kill(-child.pid, name); } catch (e) { /* Gone. */ }
  };
  signal('SIGTERM');
  for (let waited = 0; alive(); waited += 100) {
    if (waited === 5000) signal('SIGKILL');
    await sleep(100);
  }
}

export class Cdp {
  constructor(url) {
    this.url = url;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Set();
  }

  open() {
    this.ws = new WebSocket(this.url);
    this.ws.onmessage = (event) => this.receive(JSON.parse(event.data));
    return new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = () => reject(new Error('cannot reach ' + this.url));
    });
  }

  send(method, params = {}, sessionId = undefined) {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject, method }));
  }

  receive(message) {
    if (message.id !== undefined) {
      const call = this.pending.get(message.id);
      if (!call) return;
      this.pending.delete(message.id);
      if (message.error) call.reject(new Error(call.method + ': ' + message.error.message));
      else call.resolve(message.result);
      return;
    }
    for (const listener of this.listeners) listener(message);
  }

  close() {
    try { this.ws.close(); } catch (e) { /* Closed. */ }
  }
}

// One tab, attached through a flat session. A tab behind another of its window is hidden (no
// animation frames); `newWindow` gives it a window of its own, where it stays visible.
export class Page {
  static async open(cdp, url = 'about:blank', { newWindow = false } = {}) {
    const { targetId } = await cdp.send('Target.createTarget', { url, newWindow });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    const page = new Page(cdp, targetId, sessionId);
    await page.send('Page.enable');
    await page.send('Runtime.enable');
    return page;
  }

  constructor(cdp, targetId, sessionId) {
    this.cdp = cdp;
    this.targetId = targetId;
    this.sessionId = sessionId;
    this.console = [];
    cdp.listeners.add((message) => {
      if (message.sessionId !== sessionId) return;
      if (message.method === 'Runtime.consoleAPICalled') {
        const text = message.params.args.map((a) => a.value !== undefined ? String(a.value) : (a.description || '')).join(' ');
        this.console.push({ type: message.params.type, text });
      } else if (message.method === 'Runtime.exceptionThrown') {
        const d = message.params.exceptionDetails;
        this.console.push({ type: 'exception', text: (d.exception && d.exception.description) || d.text });
      }
    });
  }

  send(method, params = {}) {
    return this.cdp.send(method, params, this.sessionId);
  }

  async evaluate(expression, awaitPromise = false) {
    const result = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise });
    if (result.exceptionDetails) {
      const d = result.exceptionDetails;
      throw new Error('in the page: ' + ((d.exception && d.exception.description) || d.text));
    }
    return result.result.value;
  }

  // Polls `expression` until it is true, for at most `ms`. While a page loads, its context can
  // go away under an evaluation: that is a false.
  async waitFor(expression, ms, what) {
    const until = Date.now() + ms;
    for (;;) {
      if (await this.evaluate(expression).catch(() => false)) return;
      if (Date.now() > until) throw new Error('timed out waiting for ' + what);
      await sleep(100);
    }
  }

  async navigate(url) {
    await this.send('Page.navigate', { url });
  }

  // Gives the page's file input `selector` the files `paths`, as the player's choice does.
  async setFiles(selector, paths) {
    const { root } = await this.send('DOM.getDocument', { depth: 0 });
    const { nodeId } = await this.send('DOM.querySelector', { nodeId: root.nodeId, selector });
    if (!nodeId) throw new Error('no element ' + selector);
    await this.send('DOM.setFileInputFiles', { nodeId, files: paths });
  }

  // A click of the left button at (x, y), a gesture as the player's is.
  async click(x, y) {
    for (const type of ['mousePressed', 'mouseReleased']) {
      await this.send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 });
    }
  }

  async screenshot(file) {
    const { data } = await this.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(file, Buffer.from(data, 'base64'));
  }

  async close() {
    await this.cdp.send('Target.closeTarget', { targetId: this.targetId }).catch(() => {});
  }
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
