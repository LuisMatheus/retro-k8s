import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
const source = readFileSync(new URL('../browser/stream-metrics.js', import.meta.url), 'utf8');
const { StreamMetrics } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
function report(overrides = {}) {
  return new Map([
    ['v', { id: 'v', type: 'inbound-rtp', kind: 'video', timestamp: 1000, transportId: 't',
      framesDecoded: 60, bytesReceived: 100000, jitterBufferDelay: 3, jitterBufferEmittedCount: 60,
      totalDecodeTime: 0.12, packetsReceived: 990, packetsLost: 10, framesDropped: 2, jitter: 0.005, ...overrides }],
    ['t', { selectedCandidatePairId: 'p' }], ['p', { currentRoundTripTime: 0.02 }],
  ]);
}
test('converts units and computes deltas from receiver counters', () => {
  const m = new StreamMetrics();
  const first = m.sample(report());
  assert.equal(first.fps, null);
  assert.equal(first.networkRttMs, 20);
  assert.equal(first.jitterMs, 5);
  assert.equal(first.packetLossPercent, 1);
  const next = m.sample(report({ timestamp: 2000, framesDecoded: 120, bytesReceived: 200000,
    jitterBufferDelay: 6, jitterBufferEmittedCount: 120, totalDecodeTime: 0.24 }));
  assert.equal(next.fps, 60);
  assert.equal(next.bitrateKbps, 800);
  assert.equal(next.decodeMs, 2);
  assert.equal(next.jitterBufferMs, 50);
  assert.equal(next.framesDropped, 2);
});
test('missing fields, counter resets, stream replacement and zero intervals stay unavailable', () => {
  const m = new StreamMetrics();
  m.sample(report());
  assert.equal(m.sample(report()).fps, null);
  assert.equal(m.sample(report({ timestamp: 2000, framesDecoded: 0 })).fps, null);
  assert.equal(m.sample(report({ id: 'new', timestamp: 3000 })).fps, null);
  assert.equal(m.sample(new Map()), null);
  const onlyVideo = new Map([['v', { id: 'v', type: 'inbound-rtp', kind: 'video', timestamp: 1 }]]);
  const r = m.sample(onlyVideo);
  for (const key of ['fps', 'bitrateKbps', 'networkRttMs', 'packetsLost', 'jitterMs', 'framesDropped']) assert.equal(r[key], null);
});
