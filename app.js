const EVENT_DATE = new Date("2026-12-31T12:00:00-03:00");

const AREAS = {
  salao: { prefix: "S", count: 32, grid: "salao-grid", label: "Salão principal" },
  varanda: { prefix: "V", count: 12, grid: "varanda-grid", label: "Varanda" },
  expansao: { prefix: "E", count: 6, grid: "expansao-grid", label: "Expansão coberta" },
};

const state = {
  step: 1,
  selectedSeats: new Set(),
  unavailableSeats: new Set(),
  zoom: 1,
  participants: {},
};

const money = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const pad = (value) => String(value).padStart(2, "0");
const digits = (value) => value.replace(/\D/g, "");

function seatCode(area, tableNumber, seatNumber) {
  return `${AREAS[area].prefix}${pad(tableNumber)}-${pad(seatNumber)}`;
}

function seatArea(code) {
  const prefix = code[0];
  return Object.values(AREAS).find((area) => area.prefix === prefix)?.label ?? "";
}

function createTable(area, tableNumber) {
  const table = document.createElement("div");
  table.className = "table-unit";
  table.dataset.table = `${AREAS[area].prefix}${pad(tableNumber)}`;
  const core = document.createElement("div");
  core.className = "table-core";
  core.textContent = table.dataset.table;
  table.append(core);

  for (let seatNumber = 1; seatNumber <= 8; seatNumber += 1) {
    const code = seatCode(area, tableNumber, seatNumber);
    const seat = document.createElement("button");
    seat.type = "button";
    seat.className = "seat";
    seat.dataset.code = code;
    seat.dataset.position = seatNumber;
    seat.textContent = pad(seatNumber);
    seat.title = `Cadeira ${code}`;
    seat.setAttribute("aria-label", `Selecionar cadeira ${code}`);
    seat.setAttribute("aria-pressed", "false");
    if (state.unavailableSeats.has(code)) {
      seat.disabled = true;
      seat.title = `Cadeira ${code} indisponível`;
      seat.setAttribute("aria-label", `Cadeira ${code} indisponível`);
    }
    seat.addEventListener("click", () => toggleSeat(seat));
    table.append(seat);
  }
  return table;
}

function renderMap() {
  Object.entries(AREAS).forEach(([area, config]) => {
    const grid = document.getElementById(config.grid);
    for (let tableNumber = 1; tableNumber <= config.count; tableNumber += 1) {
      if (area === "salao" && tableNumber === 17) {
        const islands = document.createElement("div");
        islands.className = "hot-islands";
        islands.innerHTML = "<span>Ilha quente 1</span><span>Ilha quente 2</span>";
        grid.append(islands);
      }
      grid.append(createTable(area, tableNumber));
    }
  });
}

function toggleSeat(button) {
  const { code } = button.dataset;
  if (state.selectedSeats.has(code)) {
    state.selectedSeats.delete(code);
    delete state.participants[code];
    button.classList.remove("selected");
    button.setAttribute("aria-pressed", "false");
  } else {
    state.selectedSeats.add(code);
    button.classList.add("selected");
    button.setAttribute("aria-pressed", "true");
  }
  renderSelection();
}

const selectedCodes = () => [...state.selectedSeats].sort();
const currentTotal = () => Object.values(state.participants).reduce((sum, person) => sum + (person.price ?? 0), 0);

function renderSelection() {
  const seats = selectedCodes();
  document.getElementById("selection-count").textContent = `(${seats.length})`;
  document.getElementById("continue-button").disabled = seats.length === 0;
  const list = document.getElementById("selected-seats");
  list.replaceChildren();
  if (!seats.length) {
    const empty = document.createElement("p");
    empty.className = "empty-selection";
    empty.textContent = "Nenhuma cadeira selecionada.";
    list.append(empty);
  } else {
    seats.forEach((code) => {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "selected-seat-chip";
      chip.textContent = `${code} ×`;
      chip.title = `Remover cadeira ${code}`;
      chip.addEventListener("click", () => document.querySelector(`.seat[data-code="${code}"]`)?.click());
      list.append(chip);
    });
  }
  updateFooter();
}

function filterArea(area) {
  document.querySelectorAll(".area-tabs button").forEach((button) => button.classList.toggle("active", button.dataset.area === area));
  document.querySelectorAll(".zone").forEach((zone) => { zone.hidden = area !== "all" && zone.dataset.zone !== area; });
  const map = document.getElementById("venue-map");
  map.style.gridTemplateColumns = area === "all" ? "minmax(690px, 2fr) minmax(340px, 1fr)" : "minmax(760px, 1fr)";
  map.style.width = area === "all" ? "1100px" : "800px";
  const areas = { salao: "salao", varanda: "varanda", expansao: "expansao" };
  document.querySelectorAll(".zone").forEach((zone) => { zone.style.gridArea = area === "all" ? areas[zone.dataset.zone] : "auto"; });
}

function setZoom(nextZoom) {
  state.zoom = Math.min(1.35, Math.max(.75, nextZoom));
  document.getElementById("venue-map").style.setProperty("--map-scale", state.zoom);
}

function maskCpf(value) {
  return digits(value).slice(0, 11).replace(/(\d{3})(\d)/, "$1.$2").replace(/(\d{3})(\d)/, "$1.$2").replace(/(\d{3})(\d{1,2})$/, "$1-$2");
}

function maskPhone(value) {
  const clean = digits(value).slice(0, 11);
  if (clean.length <= 10) return clean.replace(/(\d{2})(\d)/, "($1) $2").replace(/(\d{4})(\d)/, "$1-$2");
  return clean.replace(/(\d{2})(\d)/, "($1) $2").replace(/(\d{5})(\d)/, "$1-$2");
}

function validCpf(value) {
  const cpf = digits(value);
  if (cpf.length !== 11 || /^(\d)\1{10}$/.test(cpf)) return false;
  const verify = (size) => {
    let sum = 0;
    for (let index = 0; index < size; index += 1) sum += Number(cpf[index]) * (size + 1 - index);
    const result = (sum * 10) % 11;
    return Number(cpf[size]) === (result === 10 ? 0 : result);
  };
  return verify(9) && verify(10);
}

function validPhone(value) {
  const phone = digits(value);
  return phone.length === 11 && Number(phone.slice(0, 2)) >= 11 && phone[2] === "9";
}

function calculateCategory(dateValue) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateValue)) return null;
  const [year, month, day] = dateValue.split("-").map(Number);
  const birth = new Date(year, month - 1, day, 12);
  if (birth.getFullYear() !== year || birth.getMonth() !== month - 1 || birth.getDate() !== day) return null;
  const minDate = new Date(1900, 0, 1, 12);
  if (birth < minDate || birth > EVENT_DATE) return null;
  let age = EVENT_DATE.getFullYear() - birth.getFullYear();
  const beforeBirthday = EVENT_DATE.getMonth() < birth.getMonth() || (EVENT_DATE.getMonth() === birth.getMonth() && EVENT_DATE.getDate() < birth.getDate());
  if (beforeBirthday) age -= 1;
  if (age <= 5) return { age, category: "Gratuita", price: 0 };
  if (age <= 10) return { age, category: "Meia", price: 90 };
  return { age, category: "Inteira", price: 180 };
}

const inputValue = (id) => document.getElementById(id)?.value.trim() ?? "";
const buyerData = () => ({ name: inputValue("buyer-name"), cpf: inputValue("buyer-cpf"), whatsapp: inputValue("buyer-whatsapp"), email: inputValue("buyer-email") });

function participantTemplate(code, saved = {}) {
  return `
    <fieldset class="form-card participant-card" data-seat="${code}">
      <legend>Cadeira ${code}</legend>
      <div class="participant-options">
        <label class="check-label"><input type="checkbox" data-action="buyer-occupies" ${saved.buyerOccupies ? "checked" : ""}>O responsável ocupará esta cadeira</label>
        <label class="check-label"><input type="checkbox" data-action="same-phone" ${saved.samePhone ? "checked" : ""}>Usar o WhatsApp do responsável</label>
      </div>
      <div class="form-grid">
        <label>Nome completo<input data-field="name" value="${escapeHtml(saved.name ?? "")}" required></label>
        <label>CPF<input data-field="cpf" inputmode="numeric" maxlength="14" placeholder="000.000.000-00" value="${escapeHtml(saved.cpf ?? "")}" required></label>
        <label>WhatsApp<input data-field="whatsapp" inputmode="tel" maxlength="15" placeholder="(31) 90000-0000" value="${escapeHtml(saved.whatsapp ?? "")}" required></label>
        <label>Data de nascimento<input data-field="birthDate" type="date" min="1900-01-01" max="2026-12-31" value="${escapeHtml(saved.birthDate ?? "")}" required></label>
      </div>
      <div class="category-strip">
        <div><small>Categoria</small><strong data-result="category">${saved.category ? `${saved.category} · ${saved.age} anos` : "Aguardando data"}</strong></div>
        <div><small>Valor</small><strong data-result="price">${money.format(saved.price ?? 0)}</strong></div>
        <div><small>Cadeira</small><strong>${code}</strong></div>
      </div>
    </fieldset>`;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[char]));
}

function saveParticipantCard(card) {
  const code = card.dataset.seat;
  const result = calculateCategory(card.querySelector('[data-field="birthDate"]').value);
  state.participants[code] = {
    name: card.querySelector('[data-field="name"]').value.trim(),
    cpf: card.querySelector('[data-field="cpf"]').value,
    whatsapp: card.querySelector('[data-field="whatsapp"]').value,
    birthDate: card.querySelector('[data-field="birthDate"]').value,
    buyerOccupies: card.querySelector('[data-action="buyer-occupies"]').checked,
    samePhone: card.querySelector('[data-action="same-phone"]').checked,
    age: result?.age,
    category: result?.category,
    price: result?.price,
  };
  card.querySelector('[data-result="category"]').textContent = result ? `${result.category} · ${result.age} anos` : "Data inválida";
  card.querySelector('[data-result="price"]').textContent = money.format(result?.price ?? 0);
  updateFooter();
}

function bindParticipantCard(card) {
  const cpf = card.querySelector('[data-field="cpf"]');
  const phone = card.querySelector('[data-field="whatsapp"]');
  cpf.addEventListener("input", () => { cpf.value = maskCpf(cpf.value); saveParticipantCard(card); });
  phone.addEventListener("input", () => { phone.value = maskPhone(phone.value); saveParticipantCard(card); });
  card.querySelectorAll("input").forEach((input) => input.addEventListener("change", () => saveParticipantCard(card)));
  card.querySelector('[data-field="name"]').addEventListener("input", () => saveParticipantCard(card));
  card.querySelector('[data-action="buyer-occupies"]').addEventListener("change", (event) => {
    if (event.target.checked) {
      document.querySelectorAll('[data-action="buyer-occupies"]').forEach((checkbox) => { if (checkbox !== event.target) checkbox.checked = false; });
      const buyer = buyerData();
      card.querySelector('[data-field="name"]').value = buyer.name;
      card.querySelector('[data-field="cpf"]').value = buyer.cpf;
      card.querySelector('[data-field="whatsapp"]').value = buyer.whatsapp;
      card.querySelector('[data-action="same-phone"]').checked = true;
    }
    document.querySelectorAll(".participant-card").forEach(saveParticipantCard);
  });
  card.querySelector('[data-action="same-phone"]').addEventListener("change", (event) => {
    if (event.target.checked) card.querySelector('[data-field="whatsapp"]').value = buyerData().whatsapp;
    saveParticipantCard(card);
  });
}

function renderParticipantCards() {
  const container = document.getElementById("participant-cards");
  container.innerHTML = selectedCodes().map((code) => participantTemplate(code, state.participants[code])).join("");
  container.querySelectorAll(".participant-card").forEach(bindParticipantCard);
  const buyerCpf = document.getElementById("buyer-cpf");
  const buyerPhone = document.getElementById("buyer-whatsapp");
  buyerCpf.addEventListener("input", () => { buyerCpf.value = maskCpf(buyerCpf.value); });
  buyerPhone.addEventListener("input", () => { buyerPhone.value = maskPhone(buyerPhone.value); });
}

function validateParticipants() {
  const errors = [];
  const buyer = buyerData();
  document.querySelectorAll("input.invalid").forEach((input) => input.classList.remove("invalid"));
  const buyerFields = [
    ["buyer-name", buyer.name.length >= 3, "Informe o nome completo do responsável."],
    ["buyer-cpf", validCpf(buyer.cpf), "Informe um CPF válido para o responsável."],
    ["buyer-whatsapp", validPhone(buyer.whatsapp), "Informe um WhatsApp válido com DDD."],
    ["buyer-email", /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(buyer.email), "Informe um e-mail válido."],
  ];
  buyerFields.forEach(([id, valid, message]) => { if (!valid) { errors.push(message); document.getElementById(id).classList.add("invalid"); } });
  document.querySelectorAll(".participant-card").forEach((card) => {
    saveParticipantCard(card);
    const person = state.participants[card.dataset.seat];
    const checks = [
      ["name", person.name.length >= 3, `Informe o nome da cadeira ${card.dataset.seat}.`],
      ["cpf", validCpf(person.cpf), `Informe um CPF válido na cadeira ${card.dataset.seat}.`],
      ["whatsapp", validPhone(person.whatsapp), `Informe um WhatsApp válido na cadeira ${card.dataset.seat}.`],
      ["birthDate", Boolean(calculateCategory(person.birthDate)), `Informe uma data de nascimento válida na cadeira ${card.dataset.seat}.`],
    ];
    checks.forEach(([field, valid, message]) => { if (!valid) { errors.push(message); card.querySelector(`[data-field="${field}"]`).classList.add("invalid"); } });
  });
  const errorBox = document.getElementById("form-errors");
  errorBox.hidden = errors.length === 0;
  errorBox.innerHTML = errors.length ? `<strong>Revise os dados:</strong><br>${errors.map(escapeHtml).join("<br>")}` : "";
  if (errors.length) errorBox.scrollIntoView({ behavior: "smooth", block: "center" });
  return errors.length === 0;
}

function renderSummary() {
  const buyer = buyerData();
  document.getElementById("summary-buyer").innerHTML = `<h3>${escapeHtml(buyer.name)}</h3><p>${escapeHtml(buyer.whatsapp)} · ${escapeHtml(buyer.email)}</p>`;
  document.getElementById("summary-items").innerHTML = selectedCodes().map((code) => {
    const person = state.participants[code];
    return `<tr><td><strong>${code}</strong><br><small>${seatArea(code)}</small></td><td>${escapeHtml(person.name)}<br><small>${person.age} anos</small></td><td>${person.category}</td><td>${money.format(person.price)}</td></tr>`;
  }).join("");
  document.getElementById("summary-total").textContent = money.format(currentTotal());
}

function updateFooter() {
  const count = state.selectedSeats.size;
  document.getElementById("footer-seat-count").textContent = `${count} ${count === 1 ? "cadeira" : "cadeiras"}`;
  document.getElementById("footer-total").textContent = money.format(currentTotal());
}

function updateProgress() {
  document.querySelectorAll(".progress li").forEach((item, index) => item.classList.toggle("active", index === state.step - 1));
  document.getElementById("back-button").hidden = state.step === 1;
  const button = document.getElementById("continue-button");
  button.textContent = state.step === 3 ? "Ir para pagamento" : "Avançar";
  button.disabled = (state.step === 1 && state.selectedSeats.size === 0) || state.step === 4;
}

function showStep(step) {
  state.step = step;
  ["seats", "participants", "summary", "payment"].forEach((name, index) => { document.getElementById(`step-${name}`).hidden = step !== index + 1; });
  updateProgress();
  updateFooter();
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function nextStep() {
  if (state.step === 1) { renderParticipantCards(); showStep(2); return; }
  if (state.step === 2) { if (validateParticipants()) { renderSummary(); showStep(3); } return; }
  if (state.step === 3) showStep(4);
}

function showRegistration() {
  document.getElementById("landing").hidden = true;
  document.getElementById("registration").hidden = false;
  document.querySelector(".site-footer").hidden = true;
  showStep(1);
}

function init() {
  renderMap();
  renderSelection();
  document.getElementById("start-button").addEventListener("click", showRegistration);
  document.querySelectorAll(".area-tabs button").forEach((button) => button.addEventListener("click", () => filterArea(button.dataset.area)));
  document.getElementById("zoom-in").addEventListener("click", () => setZoom(state.zoom + .1));
  document.getElementById("zoom-out").addEventListener("click", () => setZoom(state.zoom - .1));
  document.getElementById("continue-button").addEventListener("click", nextStep);
  document.getElementById("back-button").addEventListener("click", () => { if (state.step > 1) showStep(state.step - 1); });
}

init();

export { EVENT_DATE, calculateCategory, validCpf, validPhone };
