const CONFIG = window.APP_CONFIG ?? {};
const SESSION_KEY = "fv26_admin_session";

const elements = {
  loadingView: document.getElementById("loading-view"),
  passwordView: document.getElementById("password-view"),
  recoveryView: document.getElementById("recovery-view"),
  invalidView: document.getElementById("invalid-view"),
  successView: document.getElementById("success-view"),
  passwordForm: document.getElementById("password-form"),
  newPassword: document.getElementById("new-password"),
  confirmPassword: document.getElementById("confirm-password"),
  passwordError: document.getElementById("password-error"),
  passwordButton: document.getElementById("password-button"),
  recoveryForm: document.getElementById("recovery-form"),
  recoveryEmail: document.getElementById("recovery-email"),
  recoveryError: document.getElementById("recovery-error"),
  recoverySuccess: document.getElementById("recovery-success"),
  recoveryButton: document.getElementById("recovery-button"),
  invalidMessage: document.getElementById("invalid-message"),
};

let callbackSession = null;

function showOnly(view) {
  [elements.loadingView, elements.passwordView, elements.recoveryView, elements.invalidView, elements.successView]
    .forEach(item => { item.hidden = item !== view; });
}

async function readResponse(response) {
  const text = await response.text();
  let payload = null;
  try { payload = text ? JSON.parse(text) : null; } catch { payload = text; }
  if (!response.ok) {
    const message = payload?.message || payload?.msg || payload?.error_description || payload?.error || "request_failed";
    throw new Error(message);
  }
  return payload;
}

function makeSession(data) {
  if (!data?.access_token) return null;
  return {
    access_token: data.access_token,
    refresh_token: data.refresh_token || "",
    expires_at: Math.floor(Date.now() / 1000) + Number(data.expires_in || 3600),
  };
}

function sessionFromHash(hash) {
  return makeSession({
    access_token: hash.get("access_token"),
    refresh_token: hash.get("refresh_token"),
    expires_in: hash.get("expires_in"),
  });
}

async function verifyTokenHash(tokenHash, type) {
  const response = await fetch(`${CONFIG.supabaseUrl}/auth/v1/verify`, {
    method: "POST",
    headers: { apikey: CONFIG.supabasePublishableKey, "Content-Type": "application/json" },
    body: JSON.stringify({ token_hash: tokenHash, type }),
  });
  return makeSession(await readResponse(response));
}

function saveSession(session) {
  sessionStorage.setItem(SESSION_KEY, JSON.stringify(session));
}

function friendlyLinkError(description = "") {
  const normalized = description.toLowerCase();
  if (normalized.includes("expired")) return "Este link expirou. Solicite um novo acesso para criar sua senha.";
  if (normalized.includes("already")) return "Este link já foi utilizado. Se necessário, solicite um novo acesso.";
  return "Este link é inválido ou não pôde ser confirmado. Solicite um novo acesso.";
}

elements.passwordForm.addEventListener("submit", async event => {
  event.preventDefault();
  elements.passwordError.hidden = true;

  const password = elements.newPassword.value;
  if (password.length < 8) {
    elements.passwordError.textContent = "A senha precisa ter pelo menos 8 caracteres.";
    elements.passwordError.hidden = false;
    return;
  }
  if (password !== elements.confirmPassword.value) {
    elements.passwordError.textContent = "As duas senhas precisam ser iguais.";
    elements.passwordError.hidden = false;
    return;
  }

  elements.passwordButton.disabled = true;
  elements.passwordButton.textContent = "Criando senha…";
  try {
    const response = await fetch(`${CONFIG.supabaseUrl}/auth/v1/user`, {
      method: "PUT",
      headers: {
        apikey: CONFIG.supabasePublishableKey,
        Authorization: `Bearer ${callbackSession.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ password }),
    });
    await readResponse(response);
    saveSession(callbackSession);
    showOnly(elements.successView);
  } catch (error) {
    const expired = /expired|jwt|token/i.test(String(error.message));
    elements.passwordError.textContent = expired
      ? "O link expirou. Solicite um novo acesso e tente novamente."
      : "Não foi possível criar a senha agora. Tente novamente.";
    elements.passwordError.hidden = false;
  } finally {
    elements.passwordButton.disabled = false;
    elements.passwordButton.textContent = "Criar senha e acessar";
  }
});

elements.recoveryForm.addEventListener("submit", async event => {
  event.preventDefault();
  elements.recoveryError.hidden = true;
  elements.recoverySuccess.hidden = true;
  elements.recoveryButton.disabled = true;
  elements.recoveryButton.textContent = "Enviando…";

  try {
    const redirectTo = new URL("./definir-senha.html", window.location.href).toString();
    const response = await fetch(`${CONFIG.supabaseUrl}/auth/v1/recover?redirect_to=${encodeURIComponent(redirectTo)}`, {
      method: "POST",
      headers: { apikey: CONFIG.supabasePublishableKey, "Content-Type": "application/json" },
      body: JSON.stringify({ email: elements.recoveryEmail.value.trim() }),
    });
    await readResponse(response);
    elements.recoverySuccess.textContent = "Se esse e-mail estiver cadastrado, o novo link de acesso chegará em alguns minutos.";
    elements.recoverySuccess.hidden = false;
    elements.recoveryForm.reset();
  } catch {
    elements.recoveryError.textContent = "Não foi possível enviar o link agora. Confira o e-mail e tente novamente.";
    elements.recoveryError.hidden = false;
  } finally {
    elements.recoveryButton.disabled = false;
    elements.recoveryButton.textContent = "Enviar link de acesso";
  }
});

async function initialize() {
  if (!CONFIG.supabaseUrl || !CONFIG.supabasePublishableKey) {
    elements.invalidMessage.textContent = "A conexão com o sistema não está configurada.";
    showOnly(elements.invalidView);
    return;
  }

  const hash = new URLSearchParams(window.location.hash.slice(1));
  const query = new URLSearchParams(window.location.search);
  const errorDescription = hash.get("error_description") || query.get("error_description");
  const type = hash.get("type") || query.get("type") || "invite";
  const tokenHash = query.get("token_hash");

  const hasSensitiveCallbackData = Boolean(
    hash.toString() ||
    tokenHash ||
    query.get("error_description") ||
    query.get("error_code")
  );
  if (hasSensitiveCallbackData) history.replaceState(null, "", window.location.pathname);

  if (errorDescription) {
    elements.invalidMessage.textContent = friendlyLinkError(errorDescription);
    showOnly(elements.invalidView);
    return;
  }

  try {
    callbackSession = sessionFromHash(hash);
    if (!callbackSession && tokenHash && ["invite", "recovery", "signup"].includes(type)) {
      callbackSession = await verifyTokenHash(tokenHash, type);
    }
  } catch (error) {
    elements.invalidMessage.textContent = friendlyLinkError(String(error.message));
    showOnly(elements.invalidView);
    return;
  }

  if (callbackSession) {
    showOnly(elements.passwordView);
    elements.newPassword.focus();
    return;
  }

  if (query.get("modo") === "recuperar") {
    showOnly(elements.recoveryView);
    elements.recoveryEmail.focus();
    return;
  }

  showOnly(elements.invalidView);
}

initialize();
