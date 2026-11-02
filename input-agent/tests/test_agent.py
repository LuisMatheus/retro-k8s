import json
import unittest

from agent.auth import mint_token, verify_token
from agent.protocol import Axis, Button, ProtocolError, ReleaseAll, parse
from agent.state import ControllerState


class FakeSink:
    def __init__(self):
        self.log = []
    def set_button(self, n, p): self.log.append(("btn", n, p))
    def set_axis(self, n, v): self.log.append(("axis", n, v))
    def set_hat(self, x, y): self.log.append(("hat", x, y))
    def flush(self): self.log.append(("syn",))


def msg(**kw):
    return json.dumps({"version": 1, **kw})


class ProtocolTests(unittest.TestCase):
    def test_valid_button(self):
        self.assertEqual(parse(msg(type="button", button="south", pressed=True)), Button("south", True))

    def test_axis_clamped(self):
        self.assertEqual(parse(msg(type="axis", axis="left_x", value=5)), Axis("left_x", 1.0))

    def test_large_integer_axis_is_clamped(self):
        self.assertEqual(parse(msg(type="axis", axis="left_x", value=10**350)), Axis("left_x", 1.0))

    def test_rejects(self):
        bad = ["not json", "[]", msg(type="nope"),
               msg(type="button", button=[], pressed=True),
               msg(type="axis", axis={}, value=0),
               '{"version":true,"type":"heartbeat"}',
               msg(type="button", button="BTN_SOUTH", pressed=True),
               msg(type="button", button="south", pressed="yes"),
               msg(type="axis", axis="left_x", value="1"),
               msg(type="axis", axis="left_x", value=True),
               '{"version":2,"type":"heartbeat"}',
               '{"version":1,"type":"axis","axis":"left_x","value":NaN}']
        for raw in bad:
            with self.assertRaises(ProtocolError, msg=raw):
                parse(raw)

    def test_size_limit(self):
        with self.assertRaises(ProtocolError):
            parse(msg(type="heartbeat", pad="x" * 1000))


class StateTests(unittest.TestCase):
    def test_dedupes_and_releases(self):
        s = FakeSink(); st = ControllerState(s)
        st.apply(Button("south", True)); st.apply(Button("south", True))
        self.assertEqual(s.log, [("btn", "south", True), ("syn",)])
        st.apply(Axis("left_x", 0.5))
        s.log.clear(); st.release_all()
        self.assertIn(("btn", "south", False), s.log)
        self.assertIn(("axis", "left_x", 0), s.log)
        s.log.clear(); st.release_all()
        self.assertEqual(s.log, [])

    def test_dpad_becomes_hat(self):
        s = FakeSink(); st = ControllerState(s)
        st.apply(Button("left", True)); st.apply(Button("up", True))
        self.assertIn(("hat", -1, 0), s.log); self.assertIn(("hat", -1, -1), s.log)
        s.log.clear(); st.apply(ReleaseAll())
        self.assertIn(("hat", 0, 0), s.log)


class FakeLoop:
    def __init__(self):
        self.jobs = []
    def call_later(self, delay, fn, *args):
        job = {"delay": delay, "fn": fn, "args": args, "cancelled": False}
        job["cancel"] = lambda: job.__setitem__("cancelled", True)
        self.jobs.append(job)
        class H:
            def cancel(_self): job["cancelled"] = True
        return H()
    def fire(self):
        for j in self.jobs:
            if not j["cancelled"]:
                j["fn"](*j["args"])
        self.jobs.clear()


class MinHoldTests(unittest.TestCase):
    def make(self):
        self.now = 100.0
        self.loop = FakeLoop(); self.sink = FakeSink()
        return ControllerState(self.sink, min_hold=0.04, call_later=self.loop.call_later, clock=lambda: self.now)

    def test_short_tap_release_is_deferred(self):
        st = self.make()
        st.apply(Button("south", True)); self.now += 0.005
        st.apply(Button("south", False))
        self.assertNotIn(("btn", "south", False), self.sink.log)
        self.assertAlmostEqual(self.loop.jobs[0]["delay"], 0.035)
        self.loop.fire()
        self.assertIn(("btn", "south", False), self.sink.log)

    def test_long_press_releases_immediately(self):
        st = self.make()
        st.apply(Button("south", True)); self.now += 0.2
        st.apply(Button("south", False))
        self.assertIn(("btn", "south", False), self.sink.log)
        self.assertEqual(self.loop.jobs, [])

    def test_repress_cancels_pending_release(self):
        st = self.make()
        st.apply(Button("south", True)); self.now += 0.005
        st.apply(Button("south", False)); st.apply(Button("south", True))
        self.loop.fire()
        self.assertNotIn(("btn", "south", False), self.sink.log)

    def test_release_all_cancels_pending(self):
        st = self.make()
        st.apply(Button("south", True)); self.now += 0.005
        st.apply(Button("south", False)); st.release_all()
        self.assertIn(("btn", "south", False), self.sink.log)
        n = len(self.sink.log); self.loop.fire()
        self.assertEqual(len(self.sink.log), n)

    def test_dpad_short_tap(self):
        st = self.make()
        st.apply(Button("left", True)); self.now += 0.005
        st.apply(Button("left", False))
        self.assertNotIn(("hat", 0, 0), self.sink.log)
        self.loop.fire()
        self.assertIn(("hat", 0, 0), self.sink.log)


class AuthTests(unittest.TestCase):
    def test_token(self):
        t = mint_token("k", "s1", ttl=60, now=1000)
        self.assertTrue(verify_token(t, "k", "s1", now=1030))
        self.assertFalse(verify_token(t, "k", "s1", now=1100))
        self.assertFalse(verify_token(t, "k", "s2", now=1030))
        self.assertFalse(verify_token(t, "other", "s1", now=1030))
        self.assertFalse(verify_token("garbage", "k", "s1"))


if __name__ == "__main__":
    unittest.main()
