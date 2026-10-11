import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { VENUE_PLAN, VENUE_ZONES, getTablePosition } from "../venue-layout.js";

const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const plan = readFileSync(new URL("../assets/venue-plan.svg", import.meta.url), "utf8");

// A small DOM harness runs the actual map, selection and availability functions
// without contacting Supabase or creating a production reservation.
function mapHarness() {
  class Element {
    children = [];
    dataset = {};
    attributes = {};
    events = {};
    className = "";
    style = { setProperty(name, value) { this[name] = value; } };
    classList = {
      add: (name) => { this.className = [...new Set([...this.className.split(" "), name])].join(" "); },
      remove: (name) => { this.className = this.className.split(" ").filter((value) => value !== name).join(" "); },
      toggle: (name, enabled) => { if (enabled) this.classList.add(name); else this.classList.remove(name); },
    };
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; }
    setAttribute(name, value) { this.attributes[name] = value; }
    addEventListener(name, callback) { this.events[name] = callback; }
    click() { if (!this.disabled) this.events.click?.(); }
  }
  const elements = new Map([...html.matchAll(/\bid="([^"]+)"/g)].map((match) => [match[1], new Element()]));
  const zones = Object.keys(VENUE_ZONES).map((area) => Object.assign(new Element(), { dataset: { zone: area } }));
  const tabs = ["all", ...Object.keys(VENUE_ZONES)].map((area) => Object.assign(new Element(), { dataset: { area } }));
  const viewport = Object.assign(new Element(), {
    scrollLeft: 0, scrollTop: 0, clientWidth: 340, clientHeight: 500,
    scrollTo({ left, top }) { this.scrollLeft = left; this.scrollTop = top; },
  });
  const seats = () => ["salao-grid", "varanda-grid", "expansao-grid"].flatMap((id) => elements.get(id).children.flatMap((table) => table.children.slice(1)));
  const document = {
    createElement: () => new Element(),
    getElementById: (id) => elements.get(id),
    querySelectorAll(selector) {
      if (selector === ".zone") return zones;
      if (selector === ".area-tabs button") return tabs;
      if (selector === ".seat") return seats();
      throw new Error(`Unsupported selector: ${selector}`);
    },
    querySelector(selector) {
      if (selector === ".map-viewport") return viewport;
      const zone = selector.match(/^\[data-zone="([^"]+)"\]$/);
      if (zone) return zones.find((value) => value.dataset.zone === zone[1]);
      const seat = selector.match(/^\.seat\[data-code="([^"]+)"\]$/);
      if (seat) return seats().find((value) => value.dataset.code === seat[1]);
      throw new Error(`Unsupported selector: ${selector}`);
    },
  };
  const context = vm.createContext({ document, window: {}, console, VENUE_PLAN, VENUE_ZONES, getTablePosition });
  const script = app.replace(/^import .*;\n/gm, "").replace("void init();", "").replace(/^export .*;\n?/gm, "");
  vm.runInContext(`${script}\nthis.mapApi = { renderMap, filterArea, setZoom, applySeatStatuses, state };`, context);
  context.mapApi.renderMap();
  return { ...context.mapApi, elements, zones, tabs, viewport, seats };
}

test("room orientation and reference drawing share one coordinate plane", () => {
  assert.equal(VENUE_ZONES.varanda.y, VENUE_ZONES.salao.y + VENUE_ZONES.salao.height);
  assert.equal(VENUE_ZONES.varanda.x, VENUE_ZONES.salao.x);
  assert.equal(VENUE_ZONES.expansao.x, VENUE_ZONES.salao.x + VENUE_ZONES.salao.width);
  assert.ok(VENUE_ZONES.expansao.y > VENUE_ZONES.salao.y);
  assert.match(plan, new RegExp(`viewBox="0 0 ${VENUE_PLAN.width} ${VENUE_PLAN.height}"`));
});

test("salon keeps four rows of eight, with both hot islands in the middle aisle", () => {
  assert.deepEqual(getTablePosition("salao", 1), { x: 56, y: 66 });
  assert.deepEqual(getTablePosition("salao", 8), { x: 644, y: 66 });
  assert.deepEqual(getTablePosition("salao", 9), { x: 56, y: 129 });
  assert.deepEqual(getTablePosition("salao", 17), { x: 56, y: 244 });
  assert.deepEqual(getTablePosition("salao", 32), { x: 644, y: 307 });
  const islands = [{ x: 228, y: 164, width: 240, height: 34 }, { x: 492, y: 164, width: 240, height: 34 }];
  const radius = 31 / VENUE_PLAN.displayScale;
  for (let number = 1; number <= 32; number++) {
    const local = getTablePosition("salao", number);
    const center = { x: local.x + VENUE_ZONES.salao.x, y: local.y };
    for (const island of islands) {
      assert.ok(center.y + radius < island.y || center.y - radius > island.y + island.height || center.x + radius < island.x || center.x - radius > island.x + island.width);
    }
  }
});

test("veranda preserves two six-table blocks and the exact V numbering", () => {
  const positions = Object.fromEntries(Array.from({ length: 12 }, (_, index) => [index + 1, getTablePosition("varanda", index + 1)]));
  assert.deepEqual(positions[1], { x: 67, y: 105 });
  assert.deepEqual(positions[3], { x: 229, y: 105 });
  assert.deepEqual(positions[4], { x: 67, y: 186 });
  assert.deepEqual(positions[6], { x: 229, y: 186 });
  assert.deepEqual(positions[7], { x: 482, y: 105 });
  assert.deepEqual(positions[10], { x: 482, y: 186 });
  assert.deepEqual(positions[12], { x: 644, y: 186 });
  assert.ok(positions[7].x - positions[3].x > 200, "central veranda passage must remain clear");
});

test("expansion preserves two rows of three, including the wider left-hand aisle", () => {
  assert.deepEqual(getTablePosition("expansao", 1), { x: 67, y: 195 });
  assert.deepEqual(getTablePosition("expansao", 2), { x: 247, y: 195 });
  assert.deepEqual(getTablePosition("expansao", 3), { x: 330, y: 195 });
  assert.deepEqual(getTablePosition("expansao", 4), { x: 67, y: 280 });
  assert.deepEqual(getTablePosition("expansao", 6), { x: 330, y: 280 });
});

test("actual renderer preserves all 50 table identities and 400 existing seat codes", () => {
  const harness = mapHarness();
  const expected = [];
  for (const [area, count, prefix] of [["salao", 32, "S"], ["varanda", 12, "V"], ["expansao", 6, "E"]]) {
    const tables = harness.elements.get(`${area}-grid`).children;
    assert.equal(tables.length, count);
    for (let table = 1; table <= count; table++) {
      for (let seat = 1; seat <= 8; seat++) expected.push(`${prefix}${String(table).padStart(2, "0")}-${String(seat).padStart(2, "0")}`);
    }
  }
  const actual = harness.seats().map((seat) => seat.dataset.code);
  assert.equal(new Set(actual).size, 400);
  assert.deepEqual(actual, expected);
  harness.renderMap();
  assert.equal(harness.seats().length, 400, "re-render must not duplicate chairs");
});

test("filters and zoom keep table geometry and the selected chair unchanged", () => {
  const harness = mapHarness();
  const chair = harness.seats().find((seat) => seat.dataset.code === "V12-08");
  chair.click();
  assert.equal(harness.state.selectedSeats.has("V12-08"), true);
  const before = harness.zones.map((zone) => JSON.stringify(zone.style));
  harness.filterArea("expansao");
  assert.equal(harness.state.selectedSeats.has("V12-08"), true);
  assert.deepEqual(harness.zones.map((zone) => JSON.stringify(zone.style)), before);
  assert.equal(harness.zones.find((zone) => zone.dataset.zone === "expansao").hidden, false);
  assert.ok(harness.viewport.scrollLeft > 0);
  assert.ok(harness.viewport.scrollTop > 0);
  harness.setZoom(1.6);
  assert.equal(harness.elements.get("map-surface").style["--map-scale"], 1.6);
  assert.equal(harness.elements.get("map-surface").style["--map-width"], "1446px");
  assert.equal(harness.elements.get("map-surface").style["--map-height"], "858px");
  assert.deepEqual(harness.zones.map((zone) => JSON.stringify(zone.style)), before);
  harness.filterArea("all");
  assert.ok(harness.zones.every((zone) => !zone.hidden));
  harness.elements.get("selected-seats").children[0].click();
  assert.equal(harness.state.selectedSeats.size, 0);
});

test("held and confirmed chairs stay unavailable with their original booking codes", () => {
  const harness = mapHarness();
  const available = harness.seats().find((seat) => seat.dataset.code === "S01-01");
  available.click();
  harness.applySeatStatuses([{ code: "S01-01", status: "held" }, { code: "E06-08", status: "confirmed" }]);
  assert.equal(available.disabled, true);
  assert.equal(harness.state.selectedSeats.size, 0);
  available.click();
  assert.equal(harness.state.selectedSeats.size, 0);
  const booked = harness.seats().find((seat) => seat.dataset.code === "E06-08");
  harness.state.reservation = { total_amount: 180 };
  harness.state.selectedSeats.add("E06-08");
  harness.applySeatStatuses([{ code: "E06-08", status: "confirmed" }]);
  assert.equal(booked.disabled, true);
  assert.equal(booked.attributes["aria-pressed"], "true");
  assert.equal(harness.state.selectedSeats.has("E06-08"), true);
});
