// Browser input client: keyboard + Gamepad API -> logical protocol over WebSocket.
// Usage:
//   const client = new InputClient({
//     url: "wss://games.example.com/sessions/session-123/input",
//     getToken: async () => (await fetch("/api/sessions/session-123/input-token")).text(),
//   });
//   client.start();

const KEYMAP = {
  ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right",
  KeyX: "south", KeyZ: "east", KeyS: "west", KeyA: "north",
  Enter: "start", ShiftRight: "select", KeyQ: "l", KeyW: "r",
};
// Standard Gamepad API layout
const PAD_BUTTONS = {
  0: "south", 1: "east", 2: "west", 3: "north", 4: "l", 5: "r",
  8: "select", 9: "start", 12: "up", 13: "down", 14: "left", 15: "right",
};
const PAD_AXES = { 0: "left_x", 1: "left_y", 2: "right_x", 3: "right_y" };
const DEADZONE = 0.15;

export class InputClient {
  constructor({ url, getToken, onStatus = () => {}, onGamepad = () => {} }) {
    Object.assign(this, { url, getToken, onStatus, onGamepad });
    this.ws = null;
    this.retry = 0;
    this.stopped = false;
    this.keys = new Set();        // held keyboard buttons
    this.padButtons = {};          // last sent state from gamepad
    this.padAxes = {};
    this.sent = { buttons: {}, axes: {} }; // merged, what the server believes
  }

  start() {
    this.stopped = false;
    this.connect();
    addEventListener("keydown", this.onKeyDown = (e) => this.key(e, true));
    addEventListener("keyup", this.onKeyUp = (e) => this.key(e, false));
    addEventListener("blur", this.onBlur = () => this.releaseAll());
    document.addEventListener("visibilitychange", this.onVis = () => {
      if (document.hidden) this.releaseAll();
    });
    this.hb = setInterval(() => this.send({ type: "heartbeat" }), 2000);
    this.pollPad();
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.reconnectTimer);
    cancelAnimationFrame(this.padFrame);
    clearInterval(this.hb);
    removeEventListener("keydown", this.onKeyDown);
    removeEventListener("keyup", this.onKeyUp);
    removeEventListener("blur", this.onBlur);
    document.removeEventListener("visibilitychange", this.onVis);
    this.releaseAll();
    this.ws?.close();
  }

  async connect() {
    if (this.stopped) return;
    this.onStatus("connecting");
    try {
      const token = await this.getToken();          // fresh short-lived token each attempt
      if (this.stopped) return;
      this.ws = new WebSocket(`${this.url}?token=${encodeURIComponent(token)}`);
    } catch {
      return this.reconnect();
    }
    this.ws.onopen = () => { this.retry = 0; this.releaseAll(); this.onStatus("connected"); };
    this.ws.onclose = (ev) => {
      if (this.stopped) return;
      this.onStatus(ev.code === 4409 ? "another-controller-active" : "disconnected");
      this.reconnect();
    };
    this.ws.onerror = () => {};
  }

  reconnect() {
    if (this.stopped) return;
    const delay = Math.min(10000, 500 * 2 ** this.retry++);
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
  }

  send(msg) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ version: 1, ...msg }));
    }
  }

  // Send a button only if its merged (keyboard OR gamepad) state changed.
  setButton(name, pressed) {
    if ((this.sent.buttons[name] ?? false) === pressed) return;
    this.sent.buttons[name] = pressed;
    this.send({ type: "button", button: name, pressed });
  }

  setAxis(name, value) {
    value = Math.abs(value) < DEADZONE ? 0 : Math.round(value * 100) / 100;
    if ((this.sent.axes[name] ?? 0) === value) return;
    this.sent.axes[name] = value;
    this.send({ type: "axis", axis: name, value });
  }

  key(e, down) {
    const name = KEYMAP[e.code];
    if (!name) return;
    e.preventDefault();
    if (down) this.keys.add(name); else this.keys.delete(name);
    this.setButton(name, this.keys.has(name) || !!this.padButtons[name]);
  }

  pollPad() {
    if (this.stopped) return;
    const pads = [...(navigator.getGamepads?.() ?? [])].filter((p) => p && p.connected);
    // The host can expose our own uinput output back through the browser API.
    const pad = pads.find((p) => p.mapping === "standard" && !/retro-k8s/i.test(p.id));
    const label = pad ? pad.id : pads.length
      ? `ignored: ${pads.map((p) => `${p.id} (mapping "${p.mapping || "none"}")`).join(", ")}`
      : "none (press a button on it)";
    if (label !== this.padLabel) {
      this.padLabel = label;
      this.onGamepad(label);
    }
    const active = !document.hidden && document.hasFocus();
    for (const [idx, name] of Object.entries(PAD_BUTTONS)) {
      const pressed = active && !!pad?.buttons[idx]?.pressed;
      this.padButtons[name] = pressed;
      this.setButton(name, pressed || this.keys.has(name));
    }
    for (const [idx, name] of Object.entries(PAD_AXES)) {
      this.setAxis(name, active ? (pad?.axes[idx] ?? 0) : 0);
    }
    this.padFrame = requestAnimationFrame(() => this.pollPad());
  }

  releaseAll() {
    this.keys.clear();
    this.padButtons = {};
    this.sent = { buttons: {}, axes: {} };
    this.send({ type: "release_all" });
  }
}
