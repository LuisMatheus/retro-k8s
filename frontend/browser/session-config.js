export function shouldApplyConfig(current, next, session, ready, connected) {
  if (!current || JSON.stringify(next) !== JSON.stringify(current)) return true;
  return Boolean(session && ready && !connected);
}
