import assert from "node:assert/strict";
import { buildPixPayload, crc16 } from "../pix.js";

const basePayload = "00020126430014br.gov.bcb.pix0114265648990001690203Pix5204000053039865802BR5925IGREJA BATISTA ATOS NA CO6008IPATINGA62290525C8NG06XTux4mdr3cyM2AnYAjT63041FC1";

for (const amount of [90, 180, 270, 72000]) {
  const payload = buildPixPayload(basePayload, amount);
  const amountText = amount.toFixed(2);
  assert.ok(payload.includes(`54${String(amountText.length).padStart(2, "0")}${amountText}`));
  assert.equal(crc16(payload.slice(0, -4)), payload.slice(-4));
}

assert.throws(() => buildPixPayload(basePayload, 0), /invalid_pix_amount/);
assert.throws(() => buildPixPayload("invalid", 180), /invalid_pix_payload/);

console.log("Pix payload tests passed.");
