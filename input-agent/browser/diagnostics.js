import { StreamMetrics } from './stream-metrics.js';

const fields = {
  rtt: ['Input RTT', 'ms'], p95: ['Input RTT p95 · last 120', 'ms'],
  processing: ['Agent handling', 'ms'], ackAge: ['Last agent reply age', 'ms'],
  sent: ['Input messages sent', ''], acknowledged: ['Agent replies', ''],
  pending: ['Awaiting reply', ''], expired: ['Unacknowledged >5s / evicted', ''],
  received: ['Agent received', ''], accepted: ['Agent accepted', ''], invalid: ['Agent invalid', ''], rate_limited: ['Agent rate limited', ''],
  fps: ['Video decoded FPS', 'fps'], bitrateKbps: ['Video receive bitrate', 'kb/s'],
  resolution: ['Video resolution', ''], networkRttMs: ['WebRTC network RTT', 'ms'],
  framesReceived: ['Video frames received', ''], framesDecoded: ['Video frames decoded', ''],
  framesDropped: ['WebRTC frames dropped', ''], packetsLost: ['Video RTP packets lost', ''],
  packetLossPercent: ['Video packet loss · cumulative', '%'], jitterMs: ['Video RTP jitter', 'ms'],
  jitterBufferMs: ['Jitter buffer · interval average', 'ms'], decodeMs: ['Frame decode · interval average', 'ms'],
  freezes: ['Video freezes', ''], freezeSeconds: ['Freeze time', 's'],
  playbackDropped: ['Player frames dropped', ''], playbackTotal: ['Player frames total', ''],
};

export function mountDiagnostics({ getClient, getPeer, video, getSession }) {
  const panel = document.getElementById('diagnostics');
  const grid = document.getElementById('metrics');
  const enabled = document.getElementById('debug-enabled');
  const health = document.getElementById('diagnostic-health');
  const buttons = document.getElementById('agent-buttons');
  const axes = document.getElementById('agent-axes');
  const pendingReleases = document.getElementById('agent-pending');
  const rows = document.getElementById('input-events');
  const cells = new Map();
  for (const [key, [label, unit]] of Object.entries(fields)) {
    const card = document.createElement('div'); card.className = 'metric';
    const title = document.createElement('span'); title.textContent = label;
    const value = document.createElement('strong'); value.textContent = '—';
    card.append(title, value); grid.append(card); cells.set(key, { value, unit });
  }
  let peer = null, collector = new StreamMetrics(), stream = null, sampling = false;
  let latest = null, lastEvents = null, lastAck = null;
  enabled.addEventListener('change', () => {
    const c = getClient();
    if (c) { c.diagnostics = enabled.checked; c.resetDiagnostics(); }
    stream = null;
    collector = new StreamMetrics();
  });
  // One request at a time, discard late reports after reconnect/session switches.
  const samplingTimer = setInterval(async () => {
    const current = getPeer();
    if (current !== peer) { peer = current; collector = new StreamMetrics(); stream = null; }
    if (!enabled.checked || !peer || peer.connectionState !== 'connected') { stream = null; return; }
    if (sampling) return;
    sampling = true;
    const sampledPeer = peer, sampledCollector = collector;
    try {
      const report = await sampledPeer.getStats();
      if (sampledPeer === getPeer() && sampledCollector === collector) {
        stream = sampledCollector.sample(report, video.getVideoPlaybackQuality?.());
      }
    } catch { stream = null; }
    finally { sampling = false; }
  }, 1000);
  const renderTimer = setInterval(() => {
    const c = getClient();
    const input = c?.diagnosticsSnapshot();
    const active = enabled.checked && c?.ws?.readyState === WebSocket.OPEN;
    const remote = active ? input?.remote : null;
    health.textContent = !enabled.checked ? 'Collection paused'
      : !active ? 'Input disconnected; waiting for a session connection'
      : input?.ackAge === null ? input?.expired > 0
        ? 'No diagnostic replies. Rebuild the agent container if it is still running an older version.'
        : 'Waiting for agent acknowledgment'
      : input.ackAge > 5000 ? 'Agent replies are stale; check connection health or background-tab throttling'
      : 'Agent replies are current';
    latest = { session: getSession(), capturedAt: new Date().toISOString(),
      input: enabled.checked ? input : null,
      stream: enabled.checked && getPeer()?.connectionState === 'connected' && peer === getPeer() ? stream : null };
    const metrics = enabled.checked ? { ...latest.stream, ...input,
      rtt: active ? input?.rtt : null, p95: active ? input?.p95 : null,
      processing: remote?.processing_ms, ...remote?.counters } : {};
    for (const [key, { value, unit }] of cells) {
      const x = metrics[key];
      value.textContent = x === null || x === undefined || (typeof x === 'number' && !Number.isFinite(x))
        ? '—' : `${typeof x === 'number' ? Number.isInteger(x) ? x : x.toFixed(2) : x}${unit ? ` ${unit}` : ''}`;
    }
    const stale = !active || input?.ackAge === null || input?.ackAge > 5000;
    buttons.textContent = !remote ? 'Waiting for agent reply' : `${remote.state.buttons.join(', ') || 'neutral'}${stale ? ' (stale)' : ''}`;
    axes.textContent = remote ? Object.entries(remote.state.axes).map(([k, v]) => `${k}: ${v}`).join(' · ') : '—';
    pendingReleases.textContent = remote?.state.pending_releases.join(', ') || 'none';
    // Rebuild at most 50 text-only rows when an acknowledgment changes.
    if (lastEvents !== input?.events || lastAck !== c?.lastAck) {
      lastEvents = input?.events; lastAck = c?.lastAck;
      rows.replaceChildren();
      for (const event of input?.events ?? []) {
        const row = document.createElement('tr');
        const description = event.type === 'button' ? `${event.button} ${event.pressed ? 'press' : 'release'}`
          : event.type === 'axis' ? `${event.axis} = ${event.value}` : event.type;
        for (const text of [event.time, event.seq, description, event.status, `${event.rtt.toFixed(2)} ms`]) {
          const cell = document.createElement('td'); cell.textContent = text; row.append(cell);
        }
        rows.append(row);
      }
    }
  }, 250);
  document.getElementById('export-diagnostics').addEventListener('click', (e) => {
    e.target.blur();
    const url = URL.createObjectURL(new Blob([JSON.stringify(latest, null, 2)], { type: 'application/json' }));
    const a = document.createElement('a'); a.href = url; a.download = `retro-k8s-${getSession()}-diagnostics.json`; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  // Avoid retaining timers when the page leaves; normal reload recreates them.
  addEventListener('pagehide', () => { clearInterval(samplingTimer); clearInterval(renderTimer); }, { once: true });
  panel.hidden = false;
}
