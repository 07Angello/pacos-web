// Paco's · Edge Function `admin-employees` (solo ADMIN)
//
// Acciones (POST JSON):
//   { action: 'create', email, password, fullName, role, phone? }
//   { action: 'reset_password', userId, password }
//
// Seguridad: la llamada trae la sesión del empleado (Authorization: Bearer <jwt>).
// Antes de usar la llave secreta se consulta `staff_me` CON esa sesión: si no es
// ADMIN activo, se rechaza. La llave secreta nunca sale del servidor.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const ROLES = ['ADMIN', 'MANAGER', 'CHEF'];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const fail = (status: number, code: string, message: string) => json(status, { code, message });

/** Llaves del entorno: nombres clásicos o el formato nuevo (SUPABASE_*_KEYS en JSON). */
function key(classic: string, modern: string): string {
  const direct = Deno.env.get(classic);
  if (direct) return direct;
  try {
    return JSON.parse(Deno.env.get(modern) ?? '{}').default ?? '';
  } catch {
    return '';
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return fail(405, 'METHOD', 'Método no permitido.');

  const url = Deno.env.get('SUPABASE_URL')!;
  const anonKey = key('SUPABASE_ANON_KEY', 'SUPABASE_PUBLISHABLE_KEYS');
  const serviceKey = key('SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_SECRET_KEYS');
  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return fail(401, 'UNAUTHORIZED', 'Tu sesión expiró. Inicia sesión de nuevo.');

  // 1) ¿Quién llama? (valida token, empleado activo y rol en la base de datos)
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
  const me = await caller.rpc('staff_me', { params: {} });
  if (me.error) {
    const status = Number(String(me.error.code).replace('PT', '')) || 401;
    return fail(status >= 400 && status < 500 ? status : 401, me.error.hint ?? 'UNAUTHORIZED', me.error.message);
  }
  if (me.data?.role !== 'ADMIN') return fail(403, 'FORBIDDEN', 'Solo un administrador puede gestionar empleados.');

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail(400, 'VALIDATION', 'Solicitud inválida.');
  }
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const password = String(body.password ?? '');
  if (password.length < 8 || password.length > 72) return fail(422, 'VALIDATION', 'La contraseña debe tener entre 8 y 72 caracteres.');

  // 2) Acciones
  if (body.action === 'create') {
    const email = String(body.email ?? '').trim().toLowerCase();
    const fullName = String(body.fullName ?? '').trim();
    const role = String(body.role ?? '');
    const phone = String(body.phone ?? '').trim();
    if (!EMAIL_RE.test(email)) return fail(422, 'VALIDATION', 'Escribe un correo válido.');
    if (fullName.length < 2) return fail(422, 'VALIDATION', 'Escribe el nombre del empleado.');
    if (!ROLES.includes(role)) return fail(422, 'VALIDATION', 'Elige un rol válido.');

    const found = await admin.rpc('_admin_lookup_user', { params: { email } });
    if (found.error) return fail(500, 'SERVER', 'No se pudo verificar el correo.');
    if (found.data?.isEmployee) return fail(409, 'ALREADY_EMPLOYEE', 'Ese correo ya pertenece a un empleado.');

    // Cuenta ya creada antes (p. ej. desde el panel de Supabase) pero sin perfil: se vincula.
    let userId: string | undefined = found.data?.userId;
    const linked = !!userId;
    if (!userId) {
      const created = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name: fullName } });
      if (created.error || !created.data.user) {
        const weak = /password/i.test(created.error?.message ?? '');
        return fail(weak ? 422 : 500, weak ? 'VALIDATION' : 'SERVER', weak ? 'La contraseña es muy débil. Usa una más larga.' : 'No se pudo crear la cuenta.');
      }
      userId = created.data.user.id;
    }

    const reg = await admin.rpc('_admin_register_employee', { params: { user_id: userId, fullName, role, phone } });
    if (reg.error) {
      if (!linked) await admin.auth.admin.deleteUser(userId); // no dejar cuentas huérfanas
      const status = Number(String(reg.error.code).replace('PT', '')) || 500;
      return fail(status, reg.error.hint ?? 'SERVER', reg.error.message);
    }
    return json(200, { employee: reg.data, linked });
  }

  if (body.action === 'reset_password') {
    const userId = String(body.userId ?? '');
    const found = await admin.rpc('_admin_lookup_user', { params: { user_id: userId } });
    if (found.error || !found.data?.isEmployee) return fail(404, 'NOT_FOUND', 'Empleado no encontrado.');
    const upd = await admin.auth.admin.updateUserById(userId, { password });
    if (upd.error) return fail(422, 'VALIDATION', 'No se pudo cambiar la contraseña. Prueba con una más larga.');
    return json(200, { ok: true });
  }

  return fail(400, 'VALIDATION', 'Acción desconocida.');
});
