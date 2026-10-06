function tlv(id, value) {
  const text = String(value);
  const length = new TextEncoder().encode(text).length;
  return `${id}${String(length).padStart(2, "0")}${text}`;
}

export function crc16(payload) {
  let crc = 0xffff;
  for (const byte of new TextEncoder().encode(payload)) {
    crc ^= byte << 8;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc.toString(16).toUpperCase().padStart(4, "0");
}

function parsePayload(payload) {
  const fields = [];
  let offset = 0;
  while (offset + 4 <= payload.length) {
    const id = payload.slice(offset, offset + 2);
    const length = Number(payload.slice(offset + 2, offset + 4));
    const value = payload.slice(offset + 4, offset + 4 + length);
    if (!/^\d{2}$/.test(id) || !Number.isInteger(length) || value.length !== length) {
      throw new Error("invalid_pix_payload");
    }
    fields.push({ id, value });
    offset += 4 + length;
  }
  if (offset !== payload.length) throw new Error("invalid_pix_payload");
  return fields;
}

export function buildPixPayload(basePayload, amount) {
  const fields = parsePayload(String(basePayload).trim()).filter(({ id }) => id !== "54" && id !== "63");
  const numericAmount = Number(amount);
  if (!Number.isFinite(numericAmount) || numericAmount <= 0) throw new Error("invalid_pix_amount");
  const amountField = { id: "54", value: numericAmount.toFixed(2) };
  const currencyIndex = fields.findIndex(({ id }) => id === "53");
  fields.splice(currencyIndex >= 0 ? currencyIndex + 1 : fields.length, 0, amountField);
  const withoutCrc = fields.map(({ id, value }) => tlv(id, value)).join("") + "6304";
  return withoutCrc + crc16(withoutCrc);
}
