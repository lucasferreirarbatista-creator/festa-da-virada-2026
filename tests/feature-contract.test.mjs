import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync(new URL("../supabase/migrations/009_payments_tickets_and_capacity.sql", import.meta.url), "utf8");
const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const tickets = readFileSync(new URL("../tickets.js", import.meta.url), "utf8");
const checkin = readFileSync(new URL("../checkin.js", import.meta.url), "utf8");
const expiryFix = readFileSync(new URL("../supabase/migrations/010_fix_expiry_cancelled_at.sql", import.meta.url), "utf8");

assert.match(migration, /full_seat_limit smallint not null default 350/);
assert.match(migration, /half_seat_limit smallint not null default 50/);
assert.match(migration, /deposit_percent numeric\(5,2\) not null default 30/);
assert.match(migration, /cash_hold_hours smallint not null default 48/);
assert.match(migration, /balance_due_date = date '2026-12-10'/);
assert.match(migration, /admin_cancel_reservation_seat/);
assert.match(migration, /admin_validate_ticket/);
assert.match(app, /p_free_children/);
assert.match(app, /rpc\/start_payment/);
assert.match(tickets, /checkin\.html\?t=/);
assert.match(tickets, /\["pending_review","partial","paid"\]/);
assert.match(app, /\["pending_review", "partial", "paid"\]/);
assert.match(checkin, /sessionStorage\.getItem\(SESSION_KEY\)/);
assert.match(checkin, /BarcodeDetector/);
assert.match(checkin, /else showScanner\(\)/);
assert.match(expiryFix, /coalesce\(rs\.cancelled_at, now\(\)\)/);
assert.match(expiryFix, /coalesce\(rg\.cancelled_at, now\(\)\)/);

console.log("Feature contract tests passed.");
