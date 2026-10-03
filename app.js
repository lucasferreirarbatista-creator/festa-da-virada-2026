const EVENT_DATE = new Date("2026-12-31T12:00:00-03:00");

const AREAS = {
  salao: { prefix: "S", count: 32, grid: "salao-grid" },
  varanda: { prefix: "V", count: 12, grid: "varanda-grid" },
  expansao: { prefix: "E", count: 6, grid: "expansao-grid" },
};

const state = {
  selectedSeats: new Set(),
  unavailableSeats: new Set(["S05-01", "V04-02"]),
  zoom: 1,
};

const money = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const pad = (value) => String(value).padStart(2, "0");

function seatCode(area, tableNumber, seatNumber) {
  return `${AREAS[area].prefix}${pad(tableNumber)}-${pad(seatNumber)}`;
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
    button.classList.remove("selected");
    button.setAttribute("aria-pressed", "false");
  } else {
    state.selectedSeats.add(code);
    button.classList.add("selected");
    button.setAttribute("aria-pressed", "true");
  }
  renderSelection();
}

function renderSelection() {
  const seats = [...state.selectedSeats].sort();
  const total = 0;
  document.getElementById("selection-count").textContent = `(${seats.length})`;
  document.getElementById("footer-seat-count").textContent = `${seats.length} ${seats.length === 1 ? "cadeira" : "cadeiras"}`;
  document.getElementById("footer-total").textContent = money.format(total);
  document.getElementById("continue-button").disabled = seats.length === 0;

  const list = document.getElementById("selected-seats");
  list.replaceChildren();
  if (!seats.length) {
    const empty = document.createElement("p");
    empty.className = "empty-selection";
    empty.textContent = "Nenhuma cadeira selecionada.";
    list.append(empty);
    return;
  }

  seats.forEach((code) => {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "selected-seat-chip";
    chip.textContent = `${code} ×`;
    chip.title = `Remover cadeira ${code}`;
    chip.addEventListener("click", () => {
      document.querySelector(`.seat[data-code="${code}"]`)?.click();
    });
    list.append(chip);
  });
}

function filterArea(area) {
  document.querySelectorAll(".area-tabs button").forEach((button) => {
    button.classList.toggle("active", button.dataset.area === area);
  });
  document.querySelectorAll(".zone").forEach((zone) => {
    zone.hidden = area !== "all" && zone.dataset.zone !== area;
  });
  const map = document.getElementById("venue-map");
  map.style.gridTemplateColumns = area === "all" ? "minmax(690px, 2fr) minmax(340px, 1fr)" : "minmax(760px, 1fr)";
  map.style.width = area === "all" ? "1100px" : "800px";
  if (area !== "all") {
    document.querySelector(`.zone[data-zone="${area}"]`).style.gridArea = "auto";
  } else {
    document.querySelector('[data-zone="salao"]').style.gridArea = "salao";
    document.querySelector('[data-zone="varanda"]').style.gridArea = "varanda";
    document.querySelector('[data-zone="expansao"]').style.gridArea = "expansao";
  }
}

function setZoom(nextZoom) {
  state.zoom = Math.min(1.35, Math.max(.75, nextZoom));
  document.getElementById("venue-map").style.setProperty("--map-scale", state.zoom);
}

function showRegistration() {
  document.getElementById("landing").hidden = true;
  document.getElementById("registration").hidden = false;
  document.querySelector(".site-footer").hidden = true;
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function init() {
  renderMap();
  renderSelection();
  document.getElementById("start-button").addEventListener("click", showRegistration);
  document.querySelectorAll(".area-tabs button").forEach((button) => {
    button.addEventListener("click", () => filterArea(button.dataset.area));
  });
  document.getElementById("zoom-in").addEventListener("click", () => setZoom(state.zoom + .1));
  document.getElementById("zoom-out").addEventListener("click", () => setZoom(state.zoom - .1));
  document.getElementById("continue-button").addEventListener("click", () => {
    document.getElementById("step-seats").hidden = true;
    document.getElementById("step-placeholder").hidden = false;
    document.querySelectorAll(".progress li").forEach((item, index) => item.classList.toggle("active", index === 1));
    window.scrollTo({ top: 0, behavior: "smooth" });
  });
}

init();

export { EVENT_DATE };
