// Paco's · Edge Function `push-dispatch`
//
// La llama la base de datos (pg_net) con { eventId } cada vez que se inserta un
// evento de pedido. Reclama el evento una sola vez (`_push_claim_event`), arma el
// mensaje y lo envía por Firebase Cloud Messaging (HTTP v1) a los dispositivos
// de los roles que corresponden.
//
// Credencial: JSON de la cuenta de servicio de Firebase guardado en Supabase Vault con el
// nombre `fcm_service_account` (se lee con la RPC `_push_fcm_credentials`, solo service_role).
// Alternativa: secreto de Edge Functions FCM_SERVICE_ACCOUNT (tiene prioridad si existe).
//
// No requiere sesión: solo puede enviar avisos de eventos reales que aún no se
// enviaron, así que llamarla desde fuera no permite mandar mensajes arbitrarios.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4';

const TZ = 'America/Tegucigalpa';
const FCM_BASE = Deno.env.get('FCM_API_BASE') ?? 'https://fcm.googleapis.com'; // sobrescribible en pruebas

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

interface Claim {
  eventType: string;
  tokens: string[];
  order: {
    id: string; orderNumber: string; status: string; orderType: 'PICKUP' | 'DELIVERY'; customerName: string; total: number;
    scheduledFor: string | null; reminderAt: string | null; cancellationReason: string | null; itemCount: number; items: string;
  };
}

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

function key(classic: string, modern: string): string {
  const direct = Deno.env.get(classic);
  if (direct) return direct;
  try {
    return JSON.parse(Deno.env.get(modern) ?? '{}').default ?? '';
  } catch {
    return '';
  }
}

// ----------------------------------------------------------------- textos
const num = (n: string) => n.replace(/^R-0*/, '');
const clock = (iso: string) => new Intl.DateTimeFormat('es-HN', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(iso));
const money = (n: number) => `L ${Number(n).toLocaleString('es-HN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
function day(iso: string): string {
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(d);
  const d = ymd(new Date(iso));
  if (d === ymd(new Date())) return 'hoy';
  if (d === ymd(new Date(Date.now() + 86_400_000))) return 'mañana';
  return new Intl.DateTimeFormat('es-HN', { timeZone: TZ, weekday: 'long', day: 'numeric' }).format(new Date(iso));
}

function compose(c: Claim): { title: string; body: string; target: 'order' | 'kitchen' } {
  const o = c.order;
  const n = num(o.orderNumber);
  const type = o.orderType === 'PICKUP' ? 'Recoger' : 'Domicilio';
  const products = `${o.itemCount} ${o.itemCount === 1 ? 'producto' : 'productos'}`;
  switch (c.eventType) {
    case 'order.created':
      return o.scheduledFor
        ? { title: `Nuevo pedido programado #${n}`, body: `${o.customerName} · recoger ${day(o.scheduledFor)} a las ${clock(o.scheduledFor)} · ${money(o.total)}`, target: 'order' }
        : { title: `Nuevo pedido #${n}`, body: `${o.customerName} · ${products} · ${money(o.total)} · ${type}. Toca para aprobarlo.`, target: 'order' };
    case 'order.accepted':
      return o.scheduledFor
        ? { title: `Pedido programado #${n}`, body: `Recoger ${day(o.scheduledFor)} ${clock(o.scheduledFor)}${o.reminderAt ? ` · empezar ~${clock(o.reminderAt)}` : ''}: ${o.items}`, target: 'kitchen' }
        : { title: `Nuevo en cocina #${n}`, body: o.items, target: 'kitchen' };
    case 'order.reminder':
      return {
        title: `Hora de preparar el pedido #${n}`,
        body: `Programado para las ${o.scheduledFor ? clock(o.scheduledFor) : '—'} (${o.customerName}).${o.status === 'PENDING' ? ' Aún no está aceptado.' : ''}`,
        target: 'order',
      };
    case 'order.cancelled':
      return { title: `Pedido #${n} cancelado`, body: `${o.customerName} lo canceló${o.cancellationReason ? `: ${o.cancellationReason}` : '.'}`, target: 'order' };
    case 'order.ready':
      return { title: `Pedido #${n} listo`, body: o.orderType === 'PICKUP' ? `Listo para que ${o.customerName} lo recoja.` : 'Listo para enviar a domicilio.', target: 'order' };
    default:
      return { title: `Pedido #${n}`, body: 'Hay una actualización.', target: 'order' };
  }
}

// ----------------------------------------------------------- OAuth Google
let cached: { token: string; exp: number } | null = null;

const b64url = (data: ArrayBuffer | Uint8Array | string) => {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data);
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

async function accessToken(sa: ServiceAccount): Promise<string> {
  if (cached && cached.exp - 60 > Date.now() / 1000) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const tokenUri = sa.token_uri ?? 'https://oauth2.googleapis.com/token';
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = b64url(JSON.stringify({
    iss: sa.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging', aud: tokenUri, iat: now, exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (ch) => ch.charCodeAt(0));
  const k = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', k, new TextEncoder().encode(`${header}.${claim}`));
  const res = await fetch(tokenUri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${header}.${claim}.${b64url(sig)}` }),
  });
  if (!res.ok) throw new Error(`OAuth ${res.status}: ${await res.text()}`);
  const data = await res.json();
  cached = { token: data.access_token, exp: now + (data.expires_in ?? 3600) };
  return cached.token;
}

// ------------------------------------------------------------------ envío
Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'method' });
  let eventId: number;
  try {
    eventId = Number((await req.json()).eventId);
  } catch {
    return json(400, { error: 'body' });
  }
  if (!Number.isSafeInteger(eventId) || eventId <= 0) return json(400, { error: 'eventId' });

  const db = createClient(Deno.env.get('SUPABASE_URL')!, key('SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_SECRET_KEYS'), { auth: { persistSession: false } });

  const raw = Deno.env.get('FCM_SERVICE_ACCOUNT') || ((await db.rpc('_push_fcm_credentials')).data as string | null);
  if (!raw) {
    console.warn('[push] Falta fcm_service_account en Vault: no se envía nada.');
    return json(200, { skipped: 'not-configured' });
  }
  let sa: ServiceAccount;
  try {
    sa = JSON.parse(raw.trim());
  } catch {
    // Diagnóstico sin revelar el contenido del secreto.
    const t = raw.trim();
    const hint = /apiKey|authDomain|firebaseConfig/.test(t)
      ? 'Es la configuración web de Firebase (firebaseConfig), no la clave de la cuenta de servicio.'
      : !t.startsWith('{') || !t.endsWith('}')
        ? 'Debe empezar con { y terminar con }: copia el archivo completo.'
        : 'El JSON está incompleto o fue modificado al pegarlo: vuelve a copiar el archivo completo.';
    console.error('[push] fcm_service_account inválido:', hint);
    return json(500, { error: 'credentials', hint, length: t.length });
  }
  if (!sa.private_key || !sa.client_email || !sa.project_id) {
    const hint = 'El JSON no es una cuenta de servicio (faltan private_key / client_email / project_id).';
    console.error('[push]', hint);
    return json(500, { error: 'credentials', hint });
  }
  const { data: claim, error } = await db.rpc('_push_claim_event', { params: { event_id: eventId } });
  if (error) {
    console.error('[push] claim', error);
    return json(500, { error: 'claim' });
  }
  if (!claim) return json(200, { skipped: 'already-sent' });
  const c = claim as Claim;
  if (!c.tokens.length) return json(200, { sent: 0, reason: 'no-devices' });

  const { title, body, target } = compose(c);
  const token = await accessToken(sa);
  const url = `${FCM_BASE}/v1/projects/${sa.project_id}/messages:send`;
  const invalid: { token: string; err: string }[] = [];
  let sent = 0;

  await Promise.all(c.tokens.map(async (deviceToken) => {
    const res = await fetch(url, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token: deviceToken,
          notification: { title, body },
          data: { orderId: c.order.id, orderNumber: c.order.orderNumber, type: c.eventType, target },
          android: {
            priority: 'HIGH',
            ttl: '3600s',
            notification: {
              channel_id: 'pedidos',
              tag: `${c.order.id}:${c.eventType}`,
              notification_priority: 'PRIORITY_MAX',
              visibility: 'PUBLIC',
              default_sound: true,
              default_vibrate_timings: true,
              color: '#E8531F',
            },
          },
        },
      }),
    });
    if (res.ok) {
      sent++;
      return;
    }
    const text = await res.text();
    // Token muerto: la app se desinstaló o el token rotó → se desactiva.
    if (res.status === 404 || /UNREGISTERED|registration-token-not-registered|INVALID_ARGUMENT.*token/i.test(text)) {
      invalid.push({ token: deviceToken, err: text.slice(0, 300) });
    } else {
      console.error(`[push] FCM ${res.status}`, text.slice(0, 500));
    }
  }));

  if (invalid.length) await db.rpc('_push_disable_tokens', { params: { tokens: invalid } });
  return json(200, { sent, invalid: invalid.length, devices: c.tokens.length });
});
