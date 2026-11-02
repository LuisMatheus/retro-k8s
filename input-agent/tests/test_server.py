"""Real local WebSocket connections with a fake kernel event sink."""
import asyncio
import json
import unittest

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from agent.auth import mint_token
from agent.config import Config
from agent.server import make_handler
from agent.state import ControllerState
from tests.test_agent import FakeSink


class ServerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.cfg = Config('127.0.0.1', 0, 'snes', 'test-secret', 0.2,
                          512, 200, 400, 'Test pad', 0x1209, 1, None, 0)
        self.sink = FakeSink()
        self.state = ControllerState(self.sink)
        self.server = await serve(make_handler(self.cfg, self.state), '127.0.0.1', 0)
        self.url = f'ws://127.0.0.1:{self.server.sockets[0].getsockname()[1]}/'

    async def asyncTearDown(self):
        self.server.close()
        await self.server.wait_closed()

    def authorized(self):
        return self.url + '?token=' + mint_token('test-secret', 'snes')

    async def wait_until(self, predicate):
        async with asyncio.timeout(2):
            while not predicate():
                await asyncio.sleep(0.005)

    async def test_auth_session_and_single_controller(self):
        for token in ('bad', mint_token('test-secret', 'gba')):
            async with connect(self.url + '?token=' + token) as ws:
                await ws.wait_closed()
                self.assertEqual(ws.close_code, 4401)
        async with connect(self.authorized()) as first:
            async with connect(self.authorized()) as second:
                await second.wait_closed()
                self.assertEqual(second.close_code, 4409)
            self.assertIsNone(first.close_code)

    async def test_disconnect_and_heartbeat_neutralize_state(self):
        async with connect(self.authorized()) as ws:
            await ws.send(json.dumps(dict(version=1, type='button', button='start', pressed=True)))
            await self.wait_until(lambda: self.state.buttons.get('start'))
        await self.wait_until(lambda: not self.state.buttons.get('start'))
        async with connect(self.authorized()) as ws:
            await ws.send(json.dumps(dict(version=1, type='button', button='left', pressed=True)))
            await self.wait_until(lambda: 'left' in self.state.dpad)
            await ws.wait_closed()
            self.assertEqual(ws.close_code, 4408)
        await self.wait_until(lambda: not self.state.dpad)

    async def test_malformed_names_do_not_crash_connection(self):
        async with connect(self.authorized()) as ws:
            for kind, field in [('button', 'button'), ('axis', 'axis')]:
                await ws.send(json.dumps({'version': 1, 'type': kind, field: []}))
                self.assertEqual(json.loads(await ws.recv())['type'], 'error')
            await ws.send(json.dumps(dict(version=1, type='button', button='south', pressed=True)))
            await self.wait_until(lambda: self.state.buttons.get('south'))

    async def test_diagnostics_acknowledges_applied_state_and_rejections(self):
        async with connect(self.authorized()) as ws:
            await ws.send(json.dumps(dict(version=1, type='button', button='start', pressed=True, seq=1)))
            reply = json.loads(await ws.recv())
            self.assertEqual((reply['type'], reply['seq'], reply['status']), ('ack', 1, 'accepted'))
            self.assertEqual(reply['state']['buttons'], ['start'])
            self.assertEqual(reply['counters'], dict(received=1, accepted=1, invalid=0, rate_limited=0))
            self.assertGreaterEqual(reply['processing_ms'], 0)
            await ws.send(json.dumps(dict(version=1, type='axis', axis='left_x', value=0.5, seq=2)))
            reply = json.loads(await ws.recv())
            self.assertEqual(reply['state']['axes']['left_x'], 16384)
            await ws.send(json.dumps(dict(version=1, type='button', button='bogus', pressed=True, seq=3)))
            self.assertEqual(json.loads(await ws.recv())['type'], 'error')
            reply = json.loads(await ws.recv())
            self.assertEqual(reply['status'], 'invalid')
            self.assertEqual(reply['counters']['invalid'], 1)
            await ws.send(json.dumps(dict(version=1, type='release_all', seq=4)))
            reply = json.loads(await ws.recv())
            self.assertEqual(reply['state']['buttons'], [])
            self.assertTrue(all(v == 0 for v in reply['state']['axes'].values()))

    async def test_diagnostics_reports_rate_limiting(self):
        from dataclasses import replace
        self.server.close()
        await self.server.wait_closed()
        cfg = replace(self.cfg, max_events_per_sec=0, burst=1)
        self.server = await serve(make_handler(cfg, self.state), '127.0.0.1', 0)
        self.url = f'ws://127.0.0.1:{self.server.sockets[0].getsockname()[1]}/'
        async with connect(self.authorized()) as ws:
            for seq in (1, 2):
                await ws.send(json.dumps(dict(version=1, type='heartbeat', seq=seq)))
                reply = json.loads(await ws.recv())
            self.assertEqual(reply['status'], 'rate_limited')
            self.assertEqual(reply['counters']['rate_limited'], 1)
            self.assertEqual(reply['counters']['accepted'], 1)

    async def test_ack_state_reports_deferred_release_until_it_runs(self):
        self.server.close()
        await self.server.wait_closed()
        self.state = ControllerState(self.sink, min_hold=0.05,
                                     call_later=asyncio.get_running_loop().call_later)
        self.server = await serve(make_handler(self.cfg, self.state), '127.0.0.1', 0)
        self.url = f'ws://127.0.0.1:{self.server.sockets[0].getsockname()[1]}/'
        async with connect(self.authorized()) as ws:
            for seq, pressed in enumerate((True, False), 1):
                await ws.send(json.dumps(dict(version=1, type='button', button='south', pressed=pressed, seq=seq)))
                reply = json.loads(await ws.recv())
            self.assertEqual(reply['state']['pending_releases'], ['south'])
            self.assertEqual(reply['state']['buttons'], ['south'])
            await asyncio.sleep(0.08)
            await ws.send(json.dumps(dict(version=1, type='heartbeat', seq=3)))
            reply = json.loads(await ws.recv())
            self.assertEqual(reply['state']['pending_releases'], [])
            self.assertEqual(reply['state']['buttons'], [])
