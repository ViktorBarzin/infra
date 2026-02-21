// WebAuthn helper: base64url encode/decode
function bufToBase64url(buf) {
  const bytes = new Uint8Array(buf);
  let str = '';
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

function base64urlToBuf(b64) {
  const pad = b64.length % 4;
  if (pad) b64 += '='.repeat(4 - pad);
  const str = atob(b64.replace(/-/g, '+').replace(/_/g, '/'));
  const buf = new Uint8Array(str.length);
  for (let i = 0; i < str.length; i++) buf[i] = str.charCodeAt(i);
  return buf.buffer;
}

let currentUser = null;

function showAuthDialog() {
  document.getElementById('auth-dialog').showModal();
}

function switchAuthTab(tab, evt) {
  const btns = document.querySelectorAll('.dialog-tab-btn');
  btns.forEach(b => b.classList.remove('active'));
  evt.target.classList.add('active');

  document.getElementById('auth-login-form').style.display = tab === 'login' ? 'block' : 'none';
  document.getElementById('auth-register-form').style.display = tab === 'register' ? 'block' : 'none';
  document.getElementById('login-error').textContent = '';
  document.getElementById('register-error').textContent = '';
}

async function doRegister() {
  const username = document.getElementById('register-username').value.trim();
  const errEl = document.getElementById('register-error');
  errEl.textContent = '';

  if (!username || username.length < 3) {
    errEl.textContent = 'Username must be at least 3 characters';
    return;
  }

  try {
    // Step 1: Begin registration
    const beginResp = await fetch('/api/auth/register/begin', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username })
    });

    if (!beginResp.ok) {
      const err = await beginResp.json();
      errEl.textContent = err.error || 'Registration failed';
      return;
    }

    const options = await beginResp.json();

    // Convert base64url fields to ArrayBuffers
    options.publicKey.challenge = base64urlToBuf(options.publicKey.challenge);
    options.publicKey.user.id = base64urlToBuf(options.publicKey.user.id);
    if (options.publicKey.excludeCredentials) {
      options.publicKey.excludeCredentials = options.publicKey.excludeCredentials.map(c => ({
        ...c,
        id: base64urlToBuf(c.id)
      }));
    }

    // Step 2: Create credential via browser
    const credential = await navigator.credentials.create(options);

    // Step 3: Finish registration
    const attestation = {
      id: credential.id,
      rawId: bufToBase64url(credential.rawId),
      type: credential.type,
      response: {
        attestationObject: bufToBase64url(credential.response.attestationObject),
        clientDataJSON: bufToBase64url(credential.response.clientDataJSON)
      }
    };

    const finishResp = await fetch(`/api/auth/register/finish?username=${encodeURIComponent(username)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(attestation)
    });

    if (!finishResp.ok) {
      const err = await finishResp.json();
      errEl.textContent = err.error || 'Registration failed';
      return;
    }

    const user = await finishResp.json();
    setLoggedIn(user);
    document.getElementById('auth-dialog').close();
  } catch (e) {
    console.error('Registration error:', e);
    errEl.textContent = e.message || 'Registration failed';
  }
}

async function doLogin() {
  const username = document.getElementById('login-username').value.trim();
  const errEl = document.getElementById('login-error');
  errEl.textContent = '';

  if (!username) {
    errEl.textContent = 'Username required';
    return;
  }

  try {
    // Step 1: Begin login
    const beginResp = await fetch('/api/auth/login/begin', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username })
    });

    if (!beginResp.ok) {
      const err = await beginResp.json();
      errEl.textContent = err.error || 'Login failed';
      return;
    }

    const options = await beginResp.json();

    // Convert base64url fields
    options.publicKey.challenge = base64urlToBuf(options.publicKey.challenge);
    if (options.publicKey.allowCredentials) {
      options.publicKey.allowCredentials = options.publicKey.allowCredentials.map(c => ({
        ...c,
        id: base64urlToBuf(c.id)
      }));
    }

    // Step 2: Get assertion via browser
    const assertion = await navigator.credentials.get(options);

    // Step 3: Finish login
    const assertionData = {
      id: assertion.id,
      rawId: bufToBase64url(assertion.rawId),
      type: assertion.type,
      response: {
        authenticatorData: bufToBase64url(assertion.response.authenticatorData),
        clientDataJSON: bufToBase64url(assertion.response.clientDataJSON),
        signature: bufToBase64url(assertion.response.signature),
        userHandle: assertion.response.userHandle ? bufToBase64url(assertion.response.userHandle) : ''
      }
    };

    const finishResp = await fetch(`/api/auth/login/finish?username=${encodeURIComponent(username)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(assertionData)
    });

    if (!finishResp.ok) {
      const err = await finishResp.json();
      errEl.textContent = err.error || 'Login failed';
      return;
    }

    const user = await finishResp.json();
    setLoggedIn(user);
    document.getElementById('auth-dialog').close();
  } catch (e) {
    console.error('Login error:', e);
    errEl.textContent = e.message || 'Login failed';
  }
}

async function doLogout() {
  await fetch('/api/auth/logout', { method: 'POST' });
  setLoggedOut();
}

function setLoggedIn(user) {
  currentUser = user;
  const section = document.getElementById('auth-section');
  section.innerHTML = `
    <span>Hi, ${escapeHtml(user.username)}</span>
    <button onclick="doLogout()">Logout</button>
  `;
  document.getElementById('tab-mine').classList.remove('hidden');
  if (user.is_admin) {
    document.getElementById('tab-admin').classList.remove('hidden');
  }
}

function setLoggedOut() {
  currentUser = null;
  const section = document.getElementById('auth-section');
  section.innerHTML = '<button id="login-btn" onclick="showAuthDialog()">Login / Register</button>';
  document.getElementById('tab-mine').classList.add('hidden');
  document.getElementById('tab-admin').classList.add('hidden');
  // Switch to streams tab if on a protected tab
  const activeTab = document.querySelector('.tab-btn.active');
  if (activeTab && (activeTab.dataset.tab === 'mine' || activeTab.dataset.tab === 'admin')) {
    switchTab('streams');
  }
}

async function checkAuth() {
  try {
    const resp = await fetch('/api/auth/me');
    if (resp.ok) {
      const user = await resp.json();
      setLoggedIn(user);
    }
  } catch (e) {
    // Not logged in
  }
}
