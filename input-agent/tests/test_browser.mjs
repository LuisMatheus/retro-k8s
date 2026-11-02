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

test('diagnostics tracks acknowledgments, rejects unknown replies and expires bounded pending messages', () => {
  const c = client(); c.diagnostics = true;
  c.send({ type: 'button', button: 'south', pressed: true });
  const seq = c.messages.at(-1).seq;
  c.receive('bad json');
  c.receive(JSON.stringify({ type: 'ack', seq: seq + 10 }));
  assert.equal(c.ackCount, 0);
  c.receive(JSON.stringify({ type: 'ack', seq, status: 'accepted', state: {}, counters: {} }));
  assert.equal(c.ackCount, 1);
  assert.equal(c.pending.size, 0);
  assert.equal(c.events[0].button, 'south');
  assert.ok(c.diagnosticsSnapshot().p95 >= 0);
  c.rtts = Array.from({ length: 100 }, (_, i) => i + 1);
  assert.equal(c.diagnosticsSnapshot().p95, 95);
  c.send({ type: 'heartbeat' });
  c.expirePending(performance.now() + 6000);
  assert.equal(c.expiredCount, 1);
  const oldSeq = c.seq; c.resetDiagnostics();
  c.send({ type: 'heartbeat' });
  assert.ok(c.seq > oldSeq);
  for (let i = 0; i < 1100; i++) c.send({ type: 'heartbeat' });
  assert.equal(c.pending.size, 1024);
});

test('diagnostics disabled preserves legacy wire format', () => {
  const c = client(); c.send({ type: 'heartbeat' });
  assert.equal(c.messages[0].seq, undefined);
  assert.equal(c.pending.size, 0);
});
