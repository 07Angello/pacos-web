-- =============================================================================
-- Alta de empleados (no existe registro público de empleados).
--
-- 1. Supabase Dashboard → Authentication → Users → "Add user" (correo + contraseña,
--    marcar "Auto Confirm User").
-- 2. Ejecuta este bloque en el SQL Editor cambiando correo, nombre y rol
--    (ADMIN | MANAGER | CHEF).
-- =============================================================================

with u as (
  select id from auth.users where email = 'admin@pacos.hn'      -- ← correo del empleado
)
insert into public.employee_profiles (user_id, full_name)
select id, 'Paco Hernández' from u                               -- ← nombre visible
on conflict (user_id) do update set full_name = excluded.full_name, is_active = true;

insert into public.employee_roles (user_id, role)
select id, 'ADMIN'::public.app_role from auth.users where email = 'admin@pacos.hn'   -- ← rol
on conflict (user_id) do update set role = excluded.role;
