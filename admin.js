const CONFIG = window.APP_CONFIG ?? {};
const SESSION_KEY = "fv26_admin_session";

const state = {
  session: null,
  profile: null,
  reservations: [],
  currentReservation: null,
  searchTimer: null,
};

const elements = {
  loginView: document.getElementById("login-view"),
  dashboardView: document.getElementById("dashboard-view"),
  loginForm: document.getElementById("login-form"),
  loginEmail: document.getElementById("login-email"),
  loginPassword: document.getElementById("login-password"),
  loginButton: document.getElementById("login-button"),
  loginError: document.getElementById("login-error"),
  identity: document.getElementById("admin-identity"),
  adminName: document.getElementById("admin-name"),
  logoutButton: document.getElementById("logout-button"),
  refreshButton: document.getElementById("refresh-button"),
  statusFilter: document.getElementById("status-filter"),
  searchInput: document.getElementById("search-input"),
  list: document.getElementById("reservations-list"),
  loading: document.getElementById("reservations-loading"),
  empty: document.getElementById("reservations-empty"),
  summary: document.getElementById("results-summary"),
  dialog: document.getElementById("reservation-dialog"),
  dialogClose: document.getElementById("dialog-close"),
  dialogProtocol: document.getElementById("dialog-protocol"),
  dialogLoading: document.getElementById("dialog-loading"),
  dialogContent: document.getElementById("dialog-content"),
  details: document.getElementById("reservation-details"),
  participants: document.getElementById("participants-list"),
  proofSection: document.getElementById("proof-section"),
  proofButton: document.getElementById("proof-button"),
  proofDescription: document.getElementById("proof-description"),
  historySection: document.getElementById("history-section"),
  history: document.getElementById("history-list"),
  reviewSection: document.getElementById("review-section"),
  reviewNotes: document.getElementById("review-notes"),
  confirmButton: document.getElementById("confirm-button"),
  rejectButton: document.getElementById("reject-button"),
  cancelButton: document.getElementById("cancel-button"),
  toast: document.getElementById("toast"),
};

const statusLabels = {
  held: "Em preenchimento",
  pending_review: "Aguardando análise",
  confirmed: "Confirmada",
  cancelled: "Cancelada",
  rejected: "Rejeitada",
  expired: "Expirada",
};

const actionLabels = {
  confirm: "Pagamento aprovado",
  reject: "Pagamento rejeitado",
  cancel: "Reserva cancelada",
};

const money = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const dateTime = new Intl.DateTimeFormat("pt-BR", { dateStyle: "short", timeStyle: "short" });
const dateOnly = new Intl.DateTimeFormat("pt-BR", { timeZone: "UTC" });

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatCpf(value) {
  const digits = String(value ?? "").replace(/\D/g, "");
  return digits.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, "$1.$2.$3-$4");
}

function formatPhone(value) {
  const digits = String(value ?? "").replace(/\D/g, "");
  return digits.replace(/^(\d{2})(\d{5})(\d{4})$/, "($1) $2-$3");
}

function parseSession() {
  try { return JSON.parse(sessionStorage.getItem(SESSION_KEY)); }
  catch { return null; }
}

function saveSession(session) {
  state.session = session;
  if (session) sessionStorage.setItem(SESSION_KEY, JSON.stringify(session));
  else sessionStorage.removeItem(SESSION_KEY);
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

async function signIn(email, password) {
  const response = await fetch(`${CONFIG.supabaseUrl}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: CONFIG.supabasePublishableKey, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const data = await readResponse(response);
  return {
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_at: Math.floor(Date.now() / 1000) + data.expires_in,
  };
}

async function refreshSession() {
  if (!state.session?.refresh_token) throw new Error("session_expired");
  const response = await fetch(`${CONFIG.supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
    method: "POST",
    headers: { apikey: CONFIG.supabasePublishableKey, "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: state.session.refresh_token }),
  });
  const data = await readResponse(response);
  saveSession({
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_at: Math.floor(Date.now() / 1000) + data.expires_in,
  });
}

async function ensureSession() {
  if (!state.session) throw new Error("session_expired");
  if ((state.session.expires_at ?? 0) - Math.floor(Date.now() / 1000) < 60) await refreshSession();
}

async function rpc(functionName, body = {}) {
  await ensureSession();
  const response = await fetch(`${CONFIG.supabaseUrl}/rest/v1/rpc/${functionName}`, {
    method: "POST",
    headers: {
      apikey: CONFIG.supabasePublishableKey,
      Authorization: `Bearer ${state.session.access_token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (response.status === 401) {
    await refreshSession();
    return rpc(functionName, body);
  }
  return readResponse(response);
}

function showToast(message) {
  elements.toast.textContent = message;
  elements.toast.hidden = false;
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => { elements.toast.hidden = true; }, 4200);
}

function showLogin(message = "") {
  elements.loginView.hidden = false;
  elements.dashboardView.hidden = true;
  elements.identity.hidden = true;
  elements.loginError.hidden = !message;
  elements.loginError.textContent = message;
  elements.loginPassword.value = "";
}

function showDashboard() {
  elements.loginView.hidden = true;
  elements.dashboardView.hidden = false;
  elements.identity.hidden = false;
  elements.adminName.textContent = state.profile.display_name;
}

async function loadDashboard() {
  const data = await rpc("admin_dashboard", { p_event_slug: CONFIG.eventSlug });
  document.getElementById("metric-confirmed-seats").textContent = data.confirmed_seats;
  document.getElementById("metric-capacity").textContent = `de ${data.total_seats}`;
  document.getElementById("metric-pending-seats").textContent = data.pending_seats;
  document.getElementById("metric-pending-reservations").textContent = `${data.pending_reservations} reserva${data.pending_reservations === 1 ? "" : "s"}`;
  document.getElementById("metric-available-seats").textContent = data.available_seats;
  document.getElementById("metric-confirmed-revenue").textContent = money.format(data.confirmed_revenue);
  document.getElementById("metric-pending-revenue").textContent = `${money.format(data.pending_revenue)} em análise`;
}

function renderReservations() {
  elements.list.innerHTML = "";
  elements.empty.hidden = state.reservations.length > 0;
  elements.summary.textContent = `${state.reservations.length} inscrição${state.reservations.length === 1 ? "" : "ões"} encontrada${state.reservations.length === 1 ? "" : "s"}`;

  for (const reservation of state.reservations) {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "reservation-row";
    row.dataset.reservationId = reservation.id;
    row.innerHTML = `
      <span class="reservation-person">
        <strong>${escapeHtml(reservation.buyer_name)}</strong>
        <small>${escapeHtml(formatPhone(reservation.buyer_whatsapp))}</small>
      </span>
      <span class="reservation-protocol">
        <strong>${escapeHtml(reservation.protocol)}</strong>
        <small>${escapeHtml(dateTime.format(new Date(reservation.created_at)))}</small>
      </span>
      <span class="reservation-seats seat-pills">
        ${(reservation.seat_codes ?? []).map(code => `<i>${escapeHtml(code)}</i>`).join("")}
      </span>
      <span class="reservation-status">
        <i class="status-badge status-${escapeHtml(reservation.status)}">${escapeHtml(statusLabels[reservation.status] ?? reservation.status)}</i>
      </span>
      <span class="reservation-amount">${escapeHtml(money.format(reservation.total_amount))}</span>
      <span class="row-arrow" aria-hidden="true">›</span>
    `;
    row.addEventListener("click", () => openReservation(reservation.id));
    elements.list.appendChild(row);
  }
}

async function loadReservations() {
  elements.loading.hidden = false;
  elements.empty.hidden = true;
  elements.list.innerHTML = "";
  try {
    const data = await rpc("admin_list_reservations", {
      p_event_slug: CONFIG.eventSlug,
      p_status: elements.statusFilter.value,
      p_search: elements.searchInput.value.trim(),
    });
    state.reservations = Array.isArray(data) ? data : [];
    renderReservations();
  } finally {
    elements.loading.hidden = true;
  }
}

function detailCard(label, value) {
  return `<article class="detail-card"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></article>`;
}

function renderReservationDetail(data) {
  state.currentReservation = data;
  elements.dialogProtocol.textContent = data.protocol;
  elements.details.innerHTML = [
    detailCard("Responsável", data.buyer_name),
    detailCard("CPF", formatCpf(data.buyer_cpf)),
    detailCard("WhatsApp", formatPhone(data.buyer_whatsapp)),
    detailCard("E-mail", data.buyer_email),
    detailCard("Valor", money.format(data.total_amount)),
    `<article class="detail-card"><span>Status</span><i class="status-badge status-${escapeHtml(data.status)}">${escapeHtml(statusLabels[data.status] ?? data.status)}</i></article>`,
  ].join("");

  elements.participants.innerHTML = (data.participants ?? []).map(participant => `
    <article class="participant-card">
      <span class="participant-seat">${escapeHtml(participant.seat_code)}</span>
      <div>
        <strong>${escapeHtml(participant.name)}</strong>
        <p>${escapeHtml(formatCpf(participant.cpf))} · ${escapeHtml(formatPhone(participant.whatsapp))}</p>
        <p>${escapeHtml(dateOnly.format(new Date(`${participant.birth_date}T00:00:00Z`)))} · ${escapeHtml(participant.age)} anos · ${escapeHtml(participant.category === "full" ? "Inteira" : participant.category === "half" ? "Meia" : "Gratuita")}</p>
      </div>
      <span class="participant-price">${escapeHtml(money.format(participant.price))}</span>
    </article>
  `).join("");

  elements.proofSection.hidden = !data.proof;
  if (data.proof) {
    elements.proofDescription.textContent = `${data.proof.original_filename} · enviado em ${dateTime.format(new Date(data.proof.uploaded_at))}`;
  }

  const history = data.history ?? [];
  elements.historySection.hidden = history.length === 0;
  elements.history.innerHTML = history.map(item => `
    <article class="history-item">
      <strong>${escapeHtml(actionLabels[item.action] ?? item.action)}</strong> por ${escapeHtml(item.admin_name ?? "Organização")}
      <p>${escapeHtml(dateTime.format(new Date(item.created_at)))}${item.notes ? ` · ${escapeHtml(item.notes)}` : ""}</p>
    </article>
  `).join("");

  const canConfirm = data.status === "pending_review";
  const canReject = data.status === "pending_review";
  const canCancel = ["held", "pending_review", "confirmed"].includes(data.status);
  elements.confirmButton.hidden = !canConfirm;
  elements.rejectButton.hidden = !canReject;
  elements.cancelButton.hidden = !canCancel;
  elements.reviewSection.hidden = !canConfirm && !canReject && !canCancel;
  elements.reviewNotes.value = "";
}

async function openReservation(reservationId) {
  elements.dialog.showModal();
  elements.dialogLoading.hidden = false;
  elements.dialogContent.hidden = true;
  try {
    const data = await rpc("admin_get_reservation", { p_reservation_id: reservationId });
    renderReservationDetail(data);
    elements.dialogContent.hidden = false;
  } catch (error) {
    elements.dialog.close();
    showToast("Não foi possível abrir essa inscrição.");
  } finally {
    elements.dialogLoading.hidden = true;
  }
}

async function viewProof() {
  const proof = state.currentReservation?.proof;
  if (!proof) return;
  const popup = window.open("", "_blank");
  try {
    await ensureSession();
    const path = proof.storage_path.split("/").map(encodeURIComponent).join("/");
    const response = await fetch(`${CONFIG.supabaseUrl}/storage/v1/object/sign/payment-proofs/${path}`, {
      method: "POST",
      headers: {
        apikey: CONFIG.supabasePublishableKey,
        Authorization: `Bearer ${state.session.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ expiresIn: 300 }),
    });
    const data = await readResponse(response);
    const signedPath = data.signedURL || data.signedUrl;
    const url = signedPath.startsWith("http") ? signedPath : `${CONFIG.supabaseUrl}/storage/v1${signedPath}`;
    popup.location = url;
  } catch (error) {
    popup?.close();
    showToast("Não foi possível abrir o comprovante.");
  }
}

async function reviewReservation(action) {
  const reservation = state.currentReservation;
  if (!reservation) return;
  const messages = {
    confirm: `Aprovar o pagamento da inscrição ${reservation.protocol}?`,
    reject: `Rejeitar a inscrição ${reservation.protocol} e liberar as cadeiras?`,
    cancel: `Cancelar a inscrição ${reservation.protocol} e liberar as cadeiras?`,
  };
  if (!window.confirm(messages[action])) return;

  const buttons = [elements.confirmButton, elements.rejectButton, elements.cancelButton];
  buttons.forEach(button => { button.disabled = true; });
  try {
    await rpc("admin_review_reservation", {
      p_reservation_id: reservation.id,
      p_action: action,
      p_notes: elements.reviewNotes.value.trim() || null,
    });
    elements.dialog.close();
    showToast(action === "confirm" ? "Pagamento aprovado com sucesso." : "Reserva atualizada e cadeiras liberadas.");
    await Promise.all([loadDashboard(), loadReservations()]);
  } catch (error) {
    showToast("Não foi possível atualizar a reserva.");
  } finally {
    buttons.forEach(button => { button.disabled = false; });
  }
}

async function enterDashboard() {
  state.profile = await rpc("admin_me");
  showDashboard();
  await Promise.all([loadDashboard(), loadReservations()]);
}

elements.loginForm.addEventListener("submit", async event => {
  event.preventDefault();
  elements.loginButton.disabled = true;
  elements.loginButton.textContent = "Entrando…";
  elements.loginError.hidden = true;
  try {
    saveSession(await signIn(elements.loginEmail.value.trim(), elements.loginPassword.value));
    await enterDashboard();
  } catch (error) {
    saveSession(null);
    const message = String(error.message).includes("admin_required")
      ? "Esta conta não possui permissão de organização."
      : "E-mail ou senha inválidos.";
    showLogin(message);
  } finally {
    elements.loginButton.disabled = false;
    elements.loginButton.textContent = "Entrar";
  }
});

elements.logoutButton.addEventListener("click", () => {
  saveSession(null);
  state.profile = null;
  showLogin();
});
elements.refreshButton.addEventListener("click", async () => {
  elements.refreshButton.disabled = true;
  try {
    await Promise.all([loadDashboard(), loadReservations()]);
    showToast("Dados atualizados.");
  } finally { elements.refreshButton.disabled = false; }
});
elements.statusFilter.addEventListener("change", loadReservations);
elements.searchInput.addEventListener("input", () => {
  window.clearTimeout(state.searchTimer);
  state.searchTimer = window.setTimeout(loadReservations, 350);
});
elements.dialogClose.addEventListener("click", () => elements.dialog.close());
elements.dialog.addEventListener("click", event => {
  if (event.target === elements.dialog) elements.dialog.close();
});
elements.proofButton.addEventListener("click", viewProof);
elements.confirmButton.addEventListener("click", () => reviewReservation("confirm"));
elements.rejectButton.addEventListener("click", () => reviewReservation("reject"));
elements.cancelButton.addEventListener("click", () => reviewReservation("cancel"));

async function initialize() {
  if (!CONFIG.supabaseUrl || !CONFIG.supabasePublishableKey) {
    showLogin("A conexão com o banco de dados não está configurada.");
    return;
  }
  state.session = parseSession();
  if (!state.session) {
    showLogin();
    return;
  }
  try { await enterDashboard(); }
  catch {
    saveSession(null);
    showLogin("Sua sessão expirou. Entre novamente.");
  }
}

initialize();
