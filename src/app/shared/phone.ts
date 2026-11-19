/** Normaliza teléfonos de Honduras a +504XXXXXXXX (misma regla que el backend). */
export function normalizeHnPhone(raw: string): string | null {
  let digits = (raw ?? '').replace(/\D/g, '');
  if (digits.length === 11 && digits.startsWith('504')) digits = digits.slice(3);
  return /^[2389]\d{7}$/.test(digits) ? `+504${digits}` : null;
}

export function formatHnPhone(normalized: string): string {
  const d = normalized.replace('+504', '');
  return `+504 ${d.slice(0, 4)}-${d.slice(4)}`;
}

/**
 * Máscara del campo teléfono: solo dígitos, máximo 8, con guion "9999-9999".
 * Si se pega un número con prefijo (+504 9999 9999), se descarta el 504.
 */
export function maskHnPhone(raw: string): string {
  let digits = (raw ?? '').replace(/\D/g, '');
  if (digits.length > 8 && digits.startsWith('504')) digits = digits.slice(3);
  digits = digits.slice(0, 8);
  return digits.length > 4 ? `${digits.slice(0, 4)}-${digits.slice(4)}` : digits;
}
