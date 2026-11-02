// Receiver-side WebRTC metrics. Missing browser fields stay unavailable.
export class StreamMetrics {
  constructor() { this.previous = null; }

  sample(report, playback = null) {
    const values = [...report.values()];
    const video = values.find((s) => s.type === 'inbound-rtp' && (s.kind ?? s.mediaType) === 'video');
    if (!video) { this.previous = null; return null; }
    const transport = report.get(video.transportId);
    const pair = report.get(transport?.selectedCandidatePairId);
    const prev = this.previous;
    const same = prev && prev.id === video.id && video.timestamp > prev.timestamp;
    const delta = (key) => same && Number.isFinite(video[key]) && Number.isFinite(prev[key])
      && video[key] >= prev[key] ? video[key] - prev[key] : null;
    const perSecond = (key) => {
      const d = delta(key);
      return d === null ? null : d * 1000 / (video.timestamp - prev.timestamp);
    };
    const averageMs = (total, count) => {
      const n = delta(count), d = delta(total);
      return n > 0 && d !== null ? d / n * 1000 : null;
    };
    const received = video.packetsReceived, lost = video.packetsLost;
    const result = {
      fps: perSecond('framesDecoded'),
      bitrateKbps: perSecond('bytesReceived') === null ? null : perSecond('bytesReceived') * 8 / 1000,
      framesReceived: video.framesReceived ?? null, framesDecoded: video.framesDecoded ?? null,
      framesDropped: video.framesDropped ?? null,
      packetsLost: lost ?? null,
      packetLossPercent: Number.isFinite(lost) && Number.isFinite(received) && received + lost > 0
        ? Math.max(0, lost) / (received + Math.max(0, lost)) * 100 : null,
      jitterMs: Number.isFinite(video.jitter) ? video.jitter * 1000 : null,
      networkRttMs: Number.isFinite(pair?.currentRoundTripTime) ? pair.currentRoundTripTime * 1000 : null,
      jitterBufferMs: averageMs('jitterBufferDelay', 'jitterBufferEmittedCount'),
      decodeMs: averageMs('totalDecodeTime', 'framesDecoded'),
      freezes: video.freezeCount ?? null,
      freezeSeconds: video.totalFreezesDuration ?? null,
      resolution: video.frameWidth && video.frameHeight ? `${video.frameWidth} × ${video.frameHeight}` : null,
      playbackDropped: playback?.droppedVideoFrames ?? null,
      playbackTotal: playback?.totalVideoFrames ?? null,
    };
    this.previous = { ...video };
    return result;
  }
}
