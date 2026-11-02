import time


class TokenBucket:
    def __init__(self, rate: float, burst: int):
        self.rate, self.burst = rate, float(burst)
        self.tokens = float(burst)
        self.last = time.monotonic()

    def allow(self) -> bool:
        now = time.monotonic()
        self.tokens = min(self.burst, self.tokens + (now - self.last) * self.rate)
        self.last = now
        if self.tokens >= 1:
            self.tokens -= 1
            return True
        return False
