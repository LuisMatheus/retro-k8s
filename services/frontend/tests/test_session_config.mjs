import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(new URL("../browser/session-config.js", import.meta.url), "utf8");
const { shouldApplyConfig } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

test("unchanged discovery reconnects a ready session after an outage", () => {
  const config = { sessions: ["snes"] };
  assert.equal(shouldApplyConfig(config, config, "snes", true, false), true);
  assert.equal(shouldApplyConfig(config, config, "snes", true, true), false);
  assert.equal(shouldApplyConfig(config, config, "snes", false, false), false);
});
