/**
 * IOTA Service — Frontend JavaScript
 *
 * Auth flow with RBAC:
 *   - On login, JWT and role are stored in sessionStorage.
 *   - admin role → redirected to / (dashboard), can navigate to /identity, /sessions.
 *   - user  role → redirected to /portal (DID upload page), can view /sessions.
 *   - Nav links are rendered dynamically per role.
 *   - When login_required is off, auth checks are skipped.
 */

// ---------------------------------------------------------------------------
// Session helpers
// ---------------------------------------------------------------------------

function getToken() {
  return sessionStorage.getItem("iota_token");
}
function setToken(t) {
  sessionStorage.setItem("iota_token", t);
}
function getRole() {
  return sessionStorage.getItem("iota_role");
}
function setRole(r) {
  sessionStorage.setItem("iota_role", r);
}
function clearSession() {
  sessionStorage.removeItem("iota_token");
  sessionStorage.removeItem("iota_role");
}
function isLoggedIn() {
  return !!getToken();
}

/** Read the server-injected flag from <body data-login-required="true|false"> */
function isLoginRequired() {
  return document.body.dataset.loginRequired === "true";
}

/**
 * If login is required and the user has no token, redirect to /login.
 * Returns true when the redirect happens (caller should bail out).
 */
function requireAuth() {
  if (isLoginRequired() && !isLoggedIn()) {
    window.location.href = "/login";
    return true;
  }
  return false;
}

/**
 * Require a specific role. Redirects away if the wrong role.
 * Returns true when a redirect happens.
 */
function requireRole(role) {
  if (!isLoginRequired()) return false;
  if (requireAuth()) return true;
  const allowed = Array.isArray(role) ? role : [role];
  if (!allowed.includes(getRole())) {
    // Wrong role — send to correct home
    window.location.href = roleLandingPage();
    return true;
  }
  return false;
}

/** Return the landing page for the current role. */
function roleLandingPage() {
  const r = getRole();
  if (r === "user") return "/portal";
  if (r === "verifier") return "/verify";
  return "/";
}

// ---------------------------------------------------------------------------
// API helper
// ---------------------------------------------------------------------------

async function api(method, path, body = null) {
  const headers = { "Content-Type": "application/json" };
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const opts = { method, headers };
  if (body) opts.body = JSON.stringify(body);

  const res = await fetch(`/api${path}`, opts);
  const data = await res.json();

  // Auto-logout and redirect on 401 (expired or invalid token)
  if (res.status === 401 && isLoginRequired()) {
    clearSession();
    window.location.href = "/login";
  }
  return { status: res.status, data };
}

// ---------------------------------------------------------------------------
// UI helpers
// ---------------------------------------------------------------------------

function show(id, data, isError = false) {
  const el = document.getElementById(id);
  if (!el) return;
  el.style.display = "block";
  el.textContent =
    typeof data === "string" ? data : JSON.stringify(data, null, 2);
  el.style.borderColor = isError ? "#a04048" : "rgb(5, 204, 147)";
}

function setLoading(btnId, loading) {
  const btn = document.getElementById(btnId);
  if (btn) btn.setAttribute("aria-busy", loading);
}

function showNotice(id, message, type = "success") {
  const el = document.getElementById(id);
  if (!el) return;
  el.style.display = "block";
  el.className = `notice ${type}`;
  el.textContent = message;
}

// ---------------------------------------------------------------------------
// Nav: role-aware links + auth state
// ---------------------------------------------------------------------------

function updateNav() {
  const navLinks = document.getElementById("nav-links");
  if (!navLinks) return; // nav hidden on login page

  const authItem = document.getElementById("nav-auth-item");
  const role = getRole();

  // Build role-specific nav links (inserted before auth item)
  if (role === "admin" || !isLoginRequired()) {
    insertNavLink(navLinks, authItem, "/", "Dashboard", "dashboard");
    insertNavLink(navLinks, authItem, "/identity", "Identity", "identity");
    insertNavLink(navLinks, authItem, "/sessions", "Sessions", "sessions");
    insertNavLink(navLinks, authItem, "/verify", "Verify", "verify");
  } else if (role === "verifier") {
    insertNavLink(navLinks, authItem, "/verify", "Verify", "verify");
  } else if (role === "user") {
    insertNavLink(navLinks, authItem, "/portal", "Portal", "portal");
    insertNavLink(navLinks, authItem, "/sessions", "Sessions", "sessions");
  }

  // Auth item
  if (!isLoginRequired()) {
    authItem.style.display = "none";
    return;
  }

  if (isLoggedIn()) {
    authItem.innerHTML = '<a href="#" id="nav-logout">Logout</a>';
    document.getElementById("nav-logout").addEventListener("click", (e) => {
      e.preventDefault();
      clearSession();
      window.location.href = "/login";
    });
  } else {
    authItem.innerHTML = '<a href="/login">Login</a>';
  }
}

/** Insert a <li><a> before a reference node. Highlights based on current path. */
function insertNavLink(parent, before, href, label, key) {
  const li = document.createElement("li");
  const a = document.createElement("a");
  a.href = href;
  a.textContent = label;
  // Highlight active link
  const current = window.location.pathname;
  if (current === href || (href !== "/" && current.startsWith(href))) {
    a.className = "contrast";
  }
  li.appendChild(a);
  parent.insertBefore(li, before);
}

// ---------------------------------------------------------------------------
// Login page
// ---------------------------------------------------------------------------

function initLogin() {
  const form = document.getElementById("login-form");
  if (!form) return;

  // Already logged in? Skip to role-appropriate page
  if (isLoggedIn()) {
    window.location.href = roleLandingPage();
    return;
  }

  form.addEventListener("submit", async () => {
    setLoading("btn-login", true);
    const email = document.getElementById("login-email").value;
    const password = document.getElementById("login-password").value;

    try {
      const res = await api("POST", "/auth/login", { email, password });
      if (res.status === 200) {
        setToken(res.data.token);
        setRole(res.data.user.role || "user");
        showNotice(
          "login-status",
          `Authenticated as ${res.data.user.email} (${res.data.user.role})`,
          "success"
        );
        const dest = res.data.user.role === "user" ? "/portal" : res.data.user.role === "verifier" ? "/verify" : "/";
        setTimeout(() => (window.location.href = dest), 600);
      } else {
        showNotice(
          "login-status",
          res.data.message || "Login failed",
          "error"
        );
      }
    } catch (err) {
      showNotice("login-status", `Error: ${err.message}`, "error");
    } finally {
      setLoading("btn-login", false);
    }
  });
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

function initDashboard() {
  const btn = document.getElementById("btn-quick-did");
  if (!btn) return;

  // Admin-only page
  if (requireRole("admin")) return;

  btn.addEventListener("click", async () => {
    setLoading("btn-quick-did", true);
    try {
      const res = await api("POST", "/dids", {
        network: "iota",
        publish: false,
      });
      show("quick-did-result", res.data, res.status >= 400);
    } catch (err) {
      show("quick-did-result", `Error: ${err.message}`, true);
    } finally {
      setLoading("btn-quick-did", false);
    }
  });
}

// ---------------------------------------------------------------------------
// Identity page
// ---------------------------------------------------------------------------

function initIdentity() {
  const createForm = document.getElementById("create-did-form");
  if (!createForm) return;

  // Admin-only page
  if (requireRole("admin")) return;

  // --- Publish toggle → show/hide ledger params vs local-only section ------
  const publishSwitch = document.getElementById("did-publish");
  const ledgerParams = document.getElementById("ledger-params");
  const localSection = document.getElementById("local-only-section");
  const submitBtn = document.getElementById("btn-create-did");

  function syncPublishUI() {
    const on = publishSwitch.checked;
    ledgerParams.style.display = on ? "block" : "none";
    localSection.style.display = on ? "none" : "block";
    submitBtn.textContent = on ? "Publish DID" : "Generate Local DID";

    // Toggle required attributes
    document.getElementById("did-secret-key").required = on;
  }
  publishSwitch.addEventListener("change", syncPublishUI);
  syncPublishUI(); // run once on load

  // --- Create DID ----------------------------------------------------------
  createForm.addEventListener("submit", async () => {
    setLoading("btn-create-did", true);
    const publish = publishSwitch.checked;

    let body;
    if (publish) {
      body = {
        publish: true,
        secret_key: document.getElementById("did-secret-key").value,
        identity_pkg_id:
          document.getElementById("did-identity-pkg-id").value || undefined,
      };
    } else {
      body = {
        publish: false,
        network: document.getElementById("did-network").value,
      };
    }

    try {
      const res = await api("POST", "/dids", body);
      show("create-did-result", res.data, res.status >= 400);
      if (res.status === 201 && res.data.did) {
        const resolveInput = document.getElementById("resolve-did-input");
        const revokeInput = document.getElementById("revoke-did-input");
        if (resolveInput) resolveInput.value = res.data.did;
        if (revokeInput) revokeInput.value = res.data.did;
      }
    } catch (err) {
      show("create-did-result", `Error: ${err.message}`, true);
    } finally {
      setLoading("btn-create-did", false);
    }
  });

  // --- Resolve DID ---------------------------------------------------------
  document
    .getElementById("resolve-did-form")
    .addEventListener("submit", async () => {
      setLoading("btn-resolve-did", true);
      const did = document.getElementById("resolve-did-input").value;
      const pkgId = document.getElementById("resolve-identity-pkg-id").value;

      try {
        const params = new URLSearchParams();
        if (pkgId) params.set("identity_pkg_id", pkgId);
        const qs = params.toString();

        const encodedDid = encodeURIComponent(did);
        const url = `/dids/${encodedDid}` + (qs ? `?${qs}` : "");
        const res = await api("GET", url);
        show("resolve-did-result", res.data, res.status >= 400);
      } catch (err) {
        show("resolve-did-result", `Error: ${err.message}`, true);
      } finally {
        setLoading("btn-resolve-did", false);
      }
    });

  // --- Deactivate DID ------------------------------------------------------
  document
    .getElementById("revoke-did-form")
    .addEventListener("submit", async () => {
      setLoading("btn-revoke-did", true);
      const did = document.getElementById("revoke-did-input").value;
      const secretKey = document.getElementById("revoke-secret-key").value;
      const pkgId =
        document.getElementById("revoke-identity-pkg-id").value || undefined;

      try {
        const encodedDid = encodeURIComponent(did);
        const res = await api("POST", `/dids/${encodedDid}/revoke`, {
          secret_key: secretKey,
          identity_pkg_id: pkgId,
        });
        show("revoke-did-result", res.data, res.status >= 400);
      } catch (err) {
        show("revoke-did-result", `Error: ${err.message}`, true);
      } finally {
        setLoading("btn-revoke-did", false);
      }
    });
}

// ---------------------------------------------------------------------------
// Portal page (user role)
// ---------------------------------------------------------------------------

function initPortal() {
  const form = document.getElementById("upload-did-form");
  if (!form) return;

  // User-only page
  if (requireRole("user")) return;

  // Terminal elements
  const terminalCard = document.getElementById("terminal-card");
  const terminalIframe = document.getElementById("terminal-iframe");
  const terminalBadge = document.getElementById("terminal-did-badge");
  const validationCard = document.getElementById("did-validation-card");
  const disconnectBtn = document.getElementById("btn-disconnect-terminal");

  /**
   * Start a recording session via the API.
   * @param {string} did — The validated DID
   * @returns {Promise<string|null>} session_id or null on failure
   */
  async function startRecordingSession(did) {
    try {
      const res = await api("POST", "/sessions", { did });
      if (res.status === 201 && res.data.session_id) {
        sessionStorage.setItem("iota_session_id", res.data.session_id);
        return res.data.session_id;
      }
      console.warn("Failed to start recording session:", res.data);
      return null;
    } catch (err) {
      console.warn("Recording session start error:", err);
      return null;
    }
  }

  /**
   * End a recording session via the API (triggers notarization).
   * @param {string} sessionId
   */
  async function endRecordingSession(sessionId) {
    if (!sessionId) return;
    try {
      const res = await api("POST", `/sessions/${sessionId}/end`);
      if (res.status === 200) {
        console.log("Session ended and notarized:", res.data);
      } else {
        console.warn("Failed to end session:", res.data);
      }
    } catch (err) {
      console.warn("Recording session end error:", err);
    }
    sessionStorage.removeItem("iota_session_id");
  }

  /**
   * Show the terminal iframe, hiding the validation form.
   * @param {string} did — The validated DID to display as a badge
   */
  function showTerminal(did) {
    const ttydUrl = window.__TTYD_URL__ || "http://localhost:7681";
    terminalIframe.src = ttydUrl;
    terminalBadge.textContent = did;
    validationCard.style.display = "none";
    terminalCard.style.display = "block";
    // Store in session so page refreshes re-open the terminal
    sessionStorage.setItem("iota_portal_did", did);
  }

  /** Hide the terminal, return to the validation form. */
  async function hideTerminal() {
    terminalIframe.src = "about:blank";
    terminalCard.style.display = "none";
    validationCard.style.display = "block";

    // End the recording session (triggers notarization).
    // We wait 1 second before calling the API so that the bash EXIT trap
    // has time to flush the history file to disk after the WebSocket closes.
    const sessionId = sessionStorage.getItem("iota_session_id");
    if (sessionId) {
      if (disconnectBtn) disconnectBtn.setAttribute("aria-busy", "true");
      await new Promise((resolve) => setTimeout(resolve, 1000));
      await endRecordingSession(sessionId);
      if (disconnectBtn) disconnectBtn.setAttribute("aria-busy", "false");
    }

    sessionStorage.removeItem("iota_portal_did");
  }

  // Disconnect button
  if (disconnectBtn) {
    disconnectBtn.addEventListener("click", hideTerminal);
  }

  // If user previously validated a DID in this session, restore the terminal
  const savedDid = sessionStorage.getItem("iota_portal_did");
  if (savedDid) {
    showTerminal(savedDid);
  }

  form.addEventListener("submit", async () => {
    setLoading("btn-upload-did", true);
    // Hide previous results
    const statusEl = document.getElementById("upload-did-status");
    const resultEl = document.getElementById("upload-did-result");
    if (statusEl) statusEl.style.display = "none";
    if (resultEl) resultEl.style.display = "none";

    const did = document.getElementById("upload-did-input").value.trim();
    const pkgId = document.getElementById("portal-identity-pkg-id").value.trim();

    try {
      const body = { did };
      if (pkgId) body.identity_pkg_id = pkgId;
      const res = await api("POST", "/dids/validate", body);
      if (res.status === 200 && res.data.valid) {
        // DID is valid — start a recording session and show the terminal
        await startRecordingSession(did);
        showTerminal(did);
      } else {
        showNotice(
          "upload-did-status",
          res.data.message || "Invalid DID",
          "error"
        );
        show("upload-did-result", res.data, true);
      }
    } catch (err) {
      showNotice("upload-did-status", `Error: ${err.message}`, "error");
    } finally {
      setLoading("btn-upload-did", false);
    }
  });
}

// ---------------------------------------------------------------------------
// Sessions page
// ---------------------------------------------------------------------------

function initSessions() {
  const listCard = document.getElementById("session-list-card");
  if (!listCard) return;

  // Both admin and user can view sessions
  if (isLoginRequired() && !isLoggedIn()) {
    window.location.href = "/login";
    return;
  }

  const role = getRole();

  // Load stats for admin
  if (role === "admin" || !isLoginRequired()) {
    loadSessionStats();
  }

  // Load session list
  loadSessionList();

  // Refresh button
  const refreshBtn = document.getElementById("btn-refresh-sessions");
  if (refreshBtn) {
    refreshBtn.addEventListener("click", () => {
      loadSessionList();
      if (role === "admin" || !isLoginRequired()) loadSessionStats();
    });
  }

  // Dialog close buttons
  const dialog = document.getElementById("session-detail-dialog");
  const closeBtn = document.getElementById("btn-close-session-detail");
  const closeFooterBtn = document.getElementById("btn-close-session-detail-footer");
  if (closeBtn) closeBtn.addEventListener("click", () => dialog.close());
  if (closeFooterBtn) closeFooterBtn.addEventListener("click", () => dialog.close());

  // Download history button
  const downloadBtn = document.getElementById("btn-download-session");
  if (downloadBtn) {
    downloadBtn.addEventListener("click", () => {
      const sessionId = dialog.dataset.sessionId;
      if (sessionId) downloadSessionHistory(sessionId);
    });
  }
}

async function loadSessionStats() {
  const card = document.getElementById("session-stats-card");
  try {
    const res = await api("GET", "/sessions/stats");
    if (res.status === 200) {
      card.style.display = "block";
      document.getElementById("stat-total").textContent = res.data.total || 0;
      document.getElementById("stat-active").textContent = res.data.active || 0;
      document.getElementById("stat-notarized").textContent = res.data.notarized || 0;
      document.getElementById("stat-failed").textContent = res.data.failed || 0;
    }
  } catch (err) {
    console.warn("Failed to load session stats:", err);
  }
}

async function loadSessionList() {
  const tbody = document.getElementById("sessions-tbody");
  const table = document.getElementById("sessions-table");
  const empty = document.getElementById("sessions-empty");

  try {
    const res = await api("GET", "/sessions");
    if (res.status === 200 && res.data.sessions) {
      const sessions = res.data.sessions;
      if (sessions.length === 0) {
        table.style.display = "none";
        empty.style.display = "block";
        return;
      }

      empty.style.display = "none";
      table.style.display = "table";
      tbody.innerHTML = "";

      for (const s of sessions) {
        const tr = document.createElement("tr");
        tr.innerHTML = `
          <td><code>${s.session_id.substring(0, 16)}…</code></td>
          <td><code title="${s.did}">${truncateDid(s.did)}</code></td>
          <td>${formatDate(s.started_at)}</td>
          <td>${s.command_count || 0}</td>
          <td>${statusBadge(s.status)}</td>
          <td>${s.notarization_hash
            ? `<code title="${s.notarization_hash}">${s.notarization_hash.substring(0, 12)}…</code>`
            : "—"}</td>
          <td><button class="outline secondary btn-view-session" data-id="${s.session_id}" style="width:auto;padding:4px 12px;">View</button></td>
        `;
        tbody.appendChild(tr);
      }

      // Bind view buttons
      document.querySelectorAll(".btn-view-session").forEach((btn) => {
        btn.addEventListener("click", () => viewSessionDetail(btn.dataset.id));
      });
    }
  } catch (err) {
    console.warn("Failed to load sessions:", err);
    empty.style.display = "block";
    empty.textContent = "Failed to load sessions.";
    empty.className = "notice error";
  }
}

async function viewSessionDetail(sessionId) {
  const dialog = document.getElementById("session-detail-dialog");
  dialog.dataset.sessionId = sessionId;
  try {
    const res = await api("GET", `/sessions/${sessionId}`);
    if (res.status === 200) {
      const s = res.data;
      document.getElementById("detail-session-id").textContent = s.session_id;
      document.getElementById("detail-status").innerHTML = statusBadge(s.status);
      document.getElementById("detail-did").textContent = s.did || "—";
      document.getElementById("detail-user-id").textContent = s.user_id || "—";
      document.getElementById("detail-started-at").textContent = s.started_at
        ? new Date(s.started_at).toLocaleString()
        : "—";
      document.getElementById("detail-ended-at").textContent = s.ended_at
        ? new Date(s.ended_at).toLocaleString()
        : "—";

      // Notarization section
      document.getElementById("detail-hash").textContent = s.notarization_hash || "—";

      const onchainSection = document.getElementById("detail-onchain-section");
      onchainSection.style.display = "block";
      document.getElementById("detail-onchain-id").textContent = s.on_chain_id || "undefined";

      const errorSection = document.getElementById("detail-error-section");
      if (s.error) {
        errorSection.style.display = "block";
        document.getElementById("detail-error").textContent = s.error;
      } else {
        errorSection.style.display = "none";
      }

      // Commands section
      const commands = s.commands || [];
      document.getElementById("detail-command-count").textContent = commands.length;
      if (commands.length > 0) {
        document.getElementById("detail-commands").textContent = commands
          .map((c) => {
            const ts = c.timestamp ? `[${c.timestamp}] ` : "";
            return `${ts}${c.command}`;
          })
          .join("\n");
      } else {
        document.getElementById("detail-commands").textContent =
          "(No commands recorded — history may not have been flushed)";
      }

      dialog.showModal();
    }
  } catch (err) {
    console.warn("Failed to load session detail:", err);
  }
}

// --- Download session history ---

async function downloadSessionHistory(sessionId) {
  try {
    const token = getToken();
    const res = await fetch(`/api/sessions/${sessionId}/download`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (res.status === 401) {
      clearSession();
      window.location.href = "/login";
      return;
    }
    if (!res.ok) {
      console.warn("Download failed:", res.status);
      return;
    }
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `session_${sessionId}.json`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  } catch (err) {
    console.warn("Failed to download session history:", err);
  }
}

// --- Session UI helpers ---

function truncateDid(did) {
  if (!did || did.length < 30) return did || "—";
  return did.substring(0, 20) + "…" + did.substring(did.length - 8);
}

function statusBadge(status) {
  const colors = {
    active: "#17a2b8",
    ended: "#6c757d",
    notarized: "rgb(5, 204, 147)",
    failed: "#a04048",
  };
  const color = colors[status] || "#6c757d";
  return `<span style="color:${color};font-weight:600;">${status}</span>`;
}

function formatDate(isoStr) {
  if (!isoStr) return "—";
  const d = new Date(isoStr);
  return d.toLocaleDateString() + " " + d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

// ---------------------------------------------------------------------------
// Verify page — on-chain notarization verification
// ---------------------------------------------------------------------------

function initVerify() {
  const readBtn = document.getElementById("btn-verify-read");
  if (!readBtn) return; // not on verify page
  if (requireRole(["admin", "verifier"])) return;

  let onChainHash = null;

  readBtn.addEventListener("click", async () => {
    const objectId = document.getElementById("verify-object-id").value.trim();
    if (!objectId) return;

    setLoading("btn-verify-read", true);
    const errorEl = document.getElementById("verify-error");
    const resultEl = document.getElementById("verify-onchain-result");
    errorEl.style.display = "none";
    resultEl.style.display = "none";

    try {
      const res = await api("GET", `/verify/${objectId}`);
      if (res.status === 200) {
        const d = res.data;
        document.getElementById("verify-result-object-id").textContent = d.object_id || objectId;
        const stateData = d.state_data || d.stateData || "";
        document.getElementById("verify-result-state-data").textContent = stateData;
        document.getElementById("verify-result-description").textContent = d.description || "—";
        document.getElementById("verify-result-immutable").textContent =
          d.immutable !== undefined ? (d.immutable ? "Yes" : "No") : "—";
        onChainHash = stateData;
        resultEl.style.display = "block";
      } else {
        errorEl.textContent = res.data.message || "Failed to read on-chain data";
        errorEl.style.display = "block";
      }
    } catch (err) {
      errorEl.textContent = "Request failed: " + err.message;
      errorEl.style.display = "block";
    }
    setLoading("btn-verify-read", false);
  });

  // File input → populate textarea
  const fileInput = document.getElementById("verify-file-input");
  fileInput.addEventListener("change", async () => {
    const file = fileInput.files[0];
    if (!file) return;
    const text = await file.text();
    document.getElementById("verify-document-input").value = text;
  });

  // Compute hash & compare
  const hashBtn = document.getElementById("btn-verify-hash");
  hashBtn.addEventListener("click", async () => {
    const data = document.getElementById("verify-document-input").value;
    if (!data.trim()) return;

    setLoading("btn-verify-hash", true);
    try {
      const res = await api("POST", "/verify/hash", { data });
      if (res.status === 200) {
        const computed = res.data.hash;
        document.getElementById("verify-computed-hash").textContent = computed;
        document.getElementById("verify-onchain-hash").textContent = onChainHash || "(read on-chain data first)";

        const matchEl = document.getElementById("verify-match-result");
        if (onChainHash && computed === onChainHash) {
          matchEl.style.color = "rgb(5, 204, 147)";
          matchEl.textContent = "✓ MATCH — Document hash matches on-chain data.";
        } else if (onChainHash) {
          matchEl.style.color = "#a04048";
          matchEl.textContent = "✗ MISMATCH — Document hash does NOT match on-chain data.";
        } else {
          matchEl.style.color = "#6c757d";
          matchEl.textContent = "Hash computed. Read on-chain data to compare.";
        }
        document.getElementById("verify-hash-result").style.display = "block";
      }
    } catch (err) {
      console.warn("Hash computation failed:", err);
    }
    setLoading("btn-verify-hash", false);
  });
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

document.addEventListener("DOMContentLoaded", () => {
  updateNav();
  initLogin();
  initDashboard();
  initIdentity();
  initPortal();
  initSessions();
  initVerify();
});
