// Coordinates follow the approved Salão Triunfo plan. They describe the drawing,
// not real-world dimensions. Table and seat codes stay bound to existing bookings.
export const VENUE_PLAN = { width: 1205, height: 715, displayScale: 1.2 };

export const VENUE_ZONES = {
  salao: { x: 125, y: 0, width: 710, height: 355 },
  varanda: { x: 125, y: 355, width: 710, height: 245 },
  expansao: { x: 835, y: 130, width: 370, height: 345 },
};

export function getTablePosition(area, tableNumber) {
  if (area === "salao" && tableNumber >= 1 && tableNumber <= 32) {
    const index = tableNumber - 1;
    return { x: 56 + (index % 8) * 84, y: [66, 129, 244, 307][Math.floor(index / 8)] };
  }
  if (area === "varanda" && tableNumber >= 1 && tableNumber <= 12) {
    const index = tableNumber - 1;
    const side = Math.floor(index / 6);
    return { x: [67, 148, 229][index % 3] + side * 415, y: 105 + (Math.floor(index / 3) % 2) * 81 };
  }
  if (area === "expansao" && tableNumber >= 1 && tableNumber <= 6) {
    const index = tableNumber - 1;
    return { x: [67, 247, 330][index % 3], y: 195 + Math.floor(index / 3) * 85 };
  }
  throw new RangeError(`Mesa inválida: ${area} ${tableNumber}`);
}
