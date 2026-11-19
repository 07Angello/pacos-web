/** Formato de horas de recogida en la zona horaria del restaurante (no la del navegador). */
export const RESTAURANT_TZ = 'America/Tegucigalpa';

const WEEKDAYS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];

function ymd(d: Date, tz: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
}

/** "4:00 p. m." */
export function clockLabel(iso: string, tz = RESTAURANT_TZ): string {
  return new Intl.DateTimeFormat('es-HN', { timeZone: tz, hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(iso));
}

/** Hora de pared '23:00' → '11:00 p. m.' (horario de atención, sin zona). */
export function hhmmLabel(hhmm: string | null): string {
  const m = /^(\d{1,2}):(\d{2})/.exec(hhmm ?? '');
  if (!m) return '';
  const h = Number(m[1]);
  return `${h % 12 || 12}:${m[2]} ${h < 12 ? 'a. m.' : 'p. m.'}`;
}

/** "hoy", "mañana" o "sábado 15" según la fecha local del restaurante. */
export function dayLabel(iso: string, now = Date.now(), tz = RESTAURANT_TZ): string {
  const day = ymd(new Date(iso), tz);
  if (day === ymd(new Date(now), tz)) return 'hoy';
  if (day === ymd(new Date(now + 86_400_000), tz)) return 'mañana';
  return weekdayLabel(day);
}

/** "hoy a las 4:00 p. m." */
export function pickupLabel(iso: string, now = Date.now(), tz = RESTAURANT_TZ): string {
  return `${dayLabel(iso, now, tz)} a las ${clockLabel(iso, tz)}`;
}

/** "sábado 15" a partir de "2026-11-15". */
export function weekdayLabel(date: string): string {
  const [y, m, d] = date.split('-').map(Number);
  return `${WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]} ${d}`;
}
