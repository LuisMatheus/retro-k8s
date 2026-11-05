// Profile selection is stored in this browser. Profiles do not authenticate users.
export function mountProfiles(root, storage = window.localStorage) {
  const select = root.querySelector('#profile-select');
  const name = root.querySelector('#profile-name');
  const status = root.querySelector('#profile-status');
  const rename = root.querySelector('#profile-rename');
  const key = 'retro-k8s-profile-id';
  let selected = '';
  try { selected = storage.getItem(key) || ''; } catch (_) { /* Storage is optional. */ }

  function remember(id) {
    selected = id;
    try { id ? storage.setItem(key, id) : storage.removeItem(key); } catch (_) { /* Optional. */ }
    rename.disabled = !id;
  }

  async function request(path, options) {
    const response = await fetch(path, options);
    let data = {};
    try { data = await response.json(); } catch (_) { /* Report HTTP failure below. */ }
    if (!response.ok) {
      const errors = data.errors?.display_name;
      throw new Error(errors?.join(', ') || data.error || 'Profile request failed');
    }
    return data;
  }

  async function refresh(preferred = selected) {
    const data = await request('/api/profiles');
    select.replaceChildren(new Option('Choose a profile', ''));
    for (const profile of data.profiles) select.add(new Option(profile.display_name, profile.id));
    select.value = data.profiles.some(profile => profile.id === preferred) ? preferred : '';
    remember(select.value);
    status.textContent = data.profiles.length ? '' : 'Create a profile to get started.';
  }

  select.addEventListener('change', () => remember(select.value));
  root.querySelector('#profile-create').addEventListener('click', async () => {
    try {
      const profile = await request('/api/profiles', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({display_name: name.value})});
      name.value = '';
      await refresh(profile.id);
    } catch (error) { status.textContent = error.message; }
  });
  rename.addEventListener('click', async () => {
    if (!selected) return;
    try {
      await request(`/api/profiles/${encodeURIComponent(selected)}`, {method: 'PATCH', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({display_name: name.value})});
      name.value = '';
      await refresh(selected);
    } catch (error) { status.textContent = error.message; }
  });
  refresh().catch(() => { status.textContent = 'Profiles are unavailable. Check the profile API.'; });
}
