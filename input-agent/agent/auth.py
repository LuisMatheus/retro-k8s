"""Short-lived HMAC tokens. Your backend/operator mints them; the agent verifies.
Token = base64url(json{sid, exp}) + "." + hex(hmac_sha256(secret, payload))."""
import base64
import hashlib
import hmac
import json
import sys
import time


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def _unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def mint_token(secret: str, session_id: str, ttl: int = 60, now: float | None = None) -> str:
    now = time.time() if now is None else now
    payload = _b64(json.dumps({"sid": session_id, "exp": int(now + ttl)}).encode())
    sig = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{sig}"


def verify_token(token: str, secret: str, session_id: str, now: float | None = None) -> bool:
    now = time.time() if now is None else now
    try:
        payload, sig = token.split(".", 1)
        expected = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            return False
        data = json.loads(_unb64(payload))
        return data["sid"] == session_id and data["exp"] >= now
    except Exception:
        return False


if __name__ == "__main__":  # python -m agent.auth <secret> <session_id> [ttl]
    print(mint_token(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 60))
