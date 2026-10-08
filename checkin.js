const CONFIG = window.APP_CONFIG ?? {};
const SESSION_KEY = "fv26_admin_session";

let session = null;
let ticket = null;
let ticketToken = new URLSearchParams(location.search).get("t");
let cameraScanner = null;
let scanning = false;

const elements = {
  title: document.getElementById("checkin-title"),
  login: document.getElementById("checkin-login"),
  scanner: document.getElementById("scanner-view"),
  result: document.getElementById("ticket-result"),
  error: document.getElementById("error"),
  ticketData: document.getElementById("ticket-data"),
  warning: document.getElementById("ticket-warning"),
  confirm: document.getElementById("confirm-entry"),
  startCamera: document.getElementById("start-camera"),
  cameraPanel: document.getElementById("camera-panel"),
  qrReader: document.getElementById("qr-reader"),
  manualForm: document.getElementById("manual-ticket-form"),
  ticketCode: document.getElementById("ticket-code"),
  scanAnother: document.getElementById("scan-another"),
};

async function readResponse(response) {
  const text = await response.text();
  let payload = null;
  try { payload = text ? JSON.parse(text) : null; } catch { payload = text; }
  if (!response.ok) throw new Error(payload?.message || payload?.error_description || payload?.error || "request_failed");
  return payload;
}

function saveSession(value) {
  session = value;
  if (value) sessionStorage.setItem(SESSION_KEY, JSON.stringify(value));
  else sessionStorage.removeItem(SESSION_KEY);
}

function parseSession() {
  try { return JSON.parse(sessionStorage.getItem(SESSION_KEY)); }
  catch { return null; }
}

async function login(email, password) {
  const data = await readResponse(await fetch(`${CONFIG.supabaseUrl}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: CONFIG.supabasePublishableKey, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  }));
  saveSession({
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_at: Math.floor(Date.now() / 1000) + data.expires_in,
  });
}

async function refreshSession() {
  if (!session?.refresh_token) throw new Error("session_expired");
  const data = await readResponse(await fetch(`${CONFIG.supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
    method: "POST",
    headers: { apikey: CONFIG.supabasePublishableKey, "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: session.refresh_token }),
  }));
  saveSession({
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_at: Math.floor(Date.now() / 1000) + data.expires_in,
  });
}

async function ensureSession() {
  if (!session) throw new Error("session_expired");
  if ((session.expires_at ?? 0) - Math.floor(Date.now() / 1000) < 60) await refreshSession();
}

async function rpc(name, body = {}, retry = true) {
  await ensureSession();
  const response = await fetch(`${CONFIG.supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: CONFIG.supabasePublishableKey,
      Authorization: `Bearer ${session.access_token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (response.status === 401 && retry) {
    await refreshSession();
    return rpc(name, body, false);
  }
  return readResponse(response);
}

function showError(message = "") {
  elements.error.hidden = !message;
  elements.error.textContent = message;
}

function stopCamera() {
  scanning = false;
  if (cameraScanner) {
    const scanner = cameraScanner;
    cameraScanner = null;
    Promise.resolve(scanner.stop()).catch(() => {}).finally(() => {
      try { scanner.clear(); } catch {}
    });
  }
  elements.cameraPanel.hidden = true;
  elements.startCamera.textContent = "Abrir câmera";
  elements.startCamera.disabled = false;
}

function showLogin(message = "") {
  stopCamera();
  elements.login.hidden = false;
  elements.scanner.hidden = true;
  elements.result.hidden = true;
  elements.title.textContent = "Validar ingresso";
  showError(message);
}

function showScanner(message = "") {
  stopCamera();
  elements.login.hidden = true;
  elements.scanner.hidden = false;
  elements.result.hidden = true;
  elements.title.textContent = "Ler QR Code";
  elements.ticketCode.value = "";
  showError(message);
}

function detail(label, value) {
  const article = document.createElement("article");
  article.className = "detail-card";
  const caption = document.createElement("span");
  caption.textContent = label;
  const strong = document.createElement("strong");
  strong.textContent = value ?? "—";
  article.append(caption, strong);
  return article;
}

function parseTicketToken(value) {
  const input = String(value ?? "").trim();
  if (!input) return "";
  try {
    const url = new URL(input, location.origin);
    return url.searchParams.get("t") || input;
  } catch {
    return input;
  }
}

async function validateToken(value) {
  const parsed = parseTicketToken(value);
  if (!parsed) throw new Error("QR Code inválido.");
  ticketToken = parsed;
  ticket = await rpc("admin_validate_ticket", { p_ticket_token: ticketToken });
  stopCamera();
  history.replaceState(null, "", `${location.pathname}?t=${encodeURIComponent(ticketToken)}`);
  elements.login.hidden = true;
  elements.scanner.hidden = true;
  elements.result.hidden = false;
  elements.title.textContent = "Resultado da validação";
  elements.ticketData.replaceChildren(
    detail("Participante", ticket.participant_name),
    detail("Cadeira", ticket.seat_code || "Sem cadeira"),
    detail("Protocolo", ticket.protocol),
    detail("Pagamento", ticket.payment_status === "paid" ? "Quitado" : "Pendente"),
  );
  elements.warning.textContent = ticket.ticket_status === "checked_in"
    ? "Este ingresso já foi utilizado."
    : ticket.allowed
      ? "Ingresso válido. Confirme a entrada."
      : "Entrada bloqueada: o pagamento ainda não foi quitado ou o ingresso foi cancelado.";
  elements.warning.className = `ticket-warning ${ticket.allowed ? "valid" : "blocked"}`;
  elements.confirm.disabled = !ticket.allowed;
  showError("");
}

async function startCamera() {
  elements.startCamera.disabled = true;
  elements.startCamera.textContent = "Solicitando acesso à câmera…";
  showError("Autorize o uso da câmera quando o navegador solicitar.");
  if (!navigator.mediaDevices?.getUserMedia || typeof window.Html5Qrcode !== "function") {
    elements.startCamera.disabled = false;
    elements.startCamera.textContent = "Abrir câmera";
    showError("Este navegador não permitiu iniciar o leitor. Cole o link ou código do ingresso abaixo.");
    return;
  }
  try {
    elements.cameraPanel.hidden = false;
    cameraScanner = new window.Html5Qrcode(elements.qrReader.id);
    scanning = true;
    await cameraScanner.start(
      { facingMode: "environment" },
      { fps: 10, qrbox: { width: 250, height: 250 } },
      async (decodedText) => {
        if (!scanning) return;
        scanning = false;
        try { await validateToken(decodedText); }
        catch (error) {
          console.error("Ticket validation error", error);
          showScanner("QR Code inválido ou ingresso não encontrado.");
        }
      },
      () => {},
    );
    elements.startCamera.textContent = "Câmera ativa";
    showError("");
  } catch (error) {
    stopCamera();
    showError("Não foi possível abrir a câmera. Autorize o acesso ou use o campo de código manual.");
    console.error("Camera error", error);
  }
}

async function start() {
  session = parseSession();
  if (!session) {
    showLogin();
    return;
  }
  try {
    await rpc("admin_me");
    if (ticketToken) await validateToken(ticketToken);
    else showScanner();
  } catch (error) {
    console.error("Check-in session error", error);
    saveSession(null);
    showLogin("Sua sessão expirou. Entre novamente para continuar.");
  }
}

elements.login.addEventListener("submit", async (event) => {
  event.preventDefault();
  showError("");
  try {
    await login(document.getElementById("email").value, document.getElementById("password").value);
    await rpc("admin_me");
    if (ticketToken) await validateToken(ticketToken);
    else showScanner();
  } catch (error) {
    console.error("Check-in login error", error);
    saveSession(null);
    showLogin("Não foi possível entrar. Confira o e-mail, a senha e o acesso da organização.");
  }
});

elements.manualForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  try { await validateToken(elements.ticketCode.value); }
  catch (error) {
    console.error("Ticket validation error", error);
    showError("QR Code inválido ou ingresso não encontrado.");
  }
});

elements.startCamera.addEventListener("click", () => { if (!cameraScanner) void startCamera(); });

elements.scanAnother.addEventListener("click", () => {
  ticket = null;
  ticketToken = null;
  history.replaceState(null, "", location.pathname);
  showScanner();
});

elements.confirm.addEventListener("click", async () => {
  elements.confirm.disabled = true;
  try {
    await rpc("admin_checkin_ticket", { p_ticket_token: ticketToken });
    elements.warning.textContent = "Entrada confirmada com sucesso.";
    elements.warning.className = "ticket-warning valid";
  } catch (error) {
    elements.warning.textContent = "Não foi possível confirmar a entrada. Atualize a validação e tente novamente.";
    elements.warning.className = "ticket-warning blocked";
    console.error("Check-in error", error);
  }
});

window.addEventListener("pagehide", stopCamera);
void start();
