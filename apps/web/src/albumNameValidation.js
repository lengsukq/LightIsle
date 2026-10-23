export function validateAlbumName(value) {
  const name = String(value ?? "").trim();
  if (!name) return { valid: false, name, reason: "empty" };
  if (Array.from(name).length > 60) return { valid: false, name, reason: "too_long" };
  if (/[\u0000-\u001f\u007f-\u009f]/.test(name)) {
    return { valid: false, name, reason: "control_character" };
  }
  return { valid: true, name, reason: null };
}
