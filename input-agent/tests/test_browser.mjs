import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(new URL('../browser/input-client.js', import.meta.url), 'utf8');
const { InputClient } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
let pads = [];
let focused = true;
Object.defineProperty(globalThis, 'navigator', { value: { getGamepads: () => pads }, configurable: true });
globalThis.document = { hidden: false, hasFocus: () => focused };
globalThis.requestAnimationFrame = () => 1;
globalThis.WebSocket = class {
  static OPEN = 1;
  constructor() { this.readyState = 1; }
};
function client() {
  const c = new InputClient({ url: 'ws://test', getToken: async () => 'token' });
  c.messages = [];
  c.ws = { readyState: 1, send: (s) => c.messages.push(JSON.parse(s)) };
  pads = []; focused = true; document.hidden = false;
  return c;
}
function pad(id = 'Physical controller', mapping = 'standard') {
  return { id, mapping, connected: true, buttons: Array.from({ length: 16 }, () => ({ pressed: false })), axes: [0, 0, 0, 0] };
}
function key(c, code, down) { c.key({ code, preventDefault() {} }, down); }

test('ignores nonstandard and virtual pads, preserving keyboard Start release', () => {
  const c = client();
  pads = [pad('Odd HID', ''), pad('Retro-K8s Pad snes')];
  for (const p of pads) { p.buttons[9].pressed = true; p.buttons[14].pressed = true; }
  c.pollPad();
  assert.equal(c.messages.length, 0);
  key(c, 'Enter', true); key(c, 'Enter', false);
  assert.deepEqual(c.messages.map((m) => m.pressed), [true, false]);
});
test('unplugging releases buttons and axes while preserving held keyboard input', () => {
  const c = client(); const p = pad(); pads = [p];
  p.buttons[14].pressed = true; p.buttons[9].pressed = true; p.axes[0] = 0.8;
  key(c, 'ArrowLeft', true); c.pollPad(); pads = []; c.pollPad();
  assert.equal(c.sent.buttons.start, false);
  assert.equal(c.sent.axes.left_x, 0);
  assert.equal(c.sent.buttons.left, true);
  key(c, 'ArrowLeft', false);
  assert.equal(c.sent.buttons.left, false);
});
test('unfocused polling cannot reassert released gamepad input', () => {
  const c = client(); const p = pad(); pads = [p]; p.buttons[9].pressed = true;
  c.pollPad(); focused = false; c.releaseAll(); c.pollPad();
  assert.equal(c.sent.buttons.start ?? false, false);
  assert.equal(c.messages.at(-1).type, 'release_all');
});
test('stopping during token fetch does not open a late socket', async () => {
  const c = client(); let resolve;
  c.getToken = () => new Promise((r) => { resolve = r; });
  const old = c.ws; const connecting = c.connect(); c.stopped = true; resolve('token');
  await connecting; assert.equal(c.ws, old);
});
