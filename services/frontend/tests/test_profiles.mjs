import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(new URL('../browser/profiles.js', import.meta.url), 'utf8');
const { mountProfiles } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

test('creates a profile, remembers it, and restores selection', async () => {
  const stored = new Map();
  const storage = {getItem: key => stored.get(key), setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key)};
  globalThis.Option = class { constructor(text, value) { this.text = text; this.value = value; } };
  const profiles = [];
  globalThis.fetch = async (path, options) => {
    if (options?.method === 'POST') {
      const profile = {id: 'id-1', display_name: JSON.parse(options.body).display_name};
      profiles.push(profile);
      return {ok: true, json: async () => profile};
    }
    return {ok: true, json: async () => ({profiles})};
  };
  function elements() {
    const nodes = {};
    for (const id of ['profile-select', 'profile-name', 'profile-status', 'profile-rename', 'profile-create']) {
      nodes[id] = {value: '', disabled: false, textContent: '', events: {}, addEventListener(name, callback) { this.events[name] = callback; }};
    }
    nodes['profile-select'].replaceChildren = function (...options) { this.options = options; };
    nodes['profile-select'].add = function (option) { this.options.push(option); };
    return {nodes, querySelector: selector => nodes[selector.slice(1)]};
  }
  const first = elements();
  mountProfiles(first, storage);
  await tick();
  first.nodes['profile-name'].value = 'Alice';
  await first.nodes['profile-create'].events.click();
  assert.equal(first.nodes['profile-select'].value, 'id-1');
  assert.equal(stored.get('retro-k8s-profile-id'), 'id-1');
  const second = elements();
  mountProfiles(second, storage);
  await tick();
  assert.equal(second.nodes['profile-select'].value, 'id-1');
  assert.equal(second.nodes['profile-rename'].disabled, false);
});
