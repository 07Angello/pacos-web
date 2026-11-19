-- =============================================================================
-- Paco's · Gestión de empleados desde la app (solo ADMIN)
--
-- Crear la cuenta de acceso (Supabase Auth) requiere la llave secreta, así que
-- lo hace la Edge Function `admin-employees`, que valida que quien llama sea
-- ADMIN activo y luego registra perfil + rol con `_admin_register_employee`
-- (solo service_role). Editar nombre, teléfono y rol es una RPC normal.
-- =============================================================================

create or replace function public._employee_json(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', p.user_id, 'email', u.email, 'fullName', p.full_name, 'phone', p.phone, 'role', r.role,
    'isActive', p.is_active, 'createdAt', p.created_at, 'lastSignInAt', u.last_sign_in_at)
  from public.employee_profiles p
  join public.employee_roles r on r.user_id = p.user_id
  join auth.users u on u.id = p.user_id
  where p.user_id = p_user_id
$$;

create or replace function public.list_employees(params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  return coalesce((
    select jsonb_agg(public._employee_json(p.user_id)
                     order by p.is_active desc, r.role, p.full_name)
    from public.employee_profiles p
    join public.employee_roles r on r.user_id = p.user_id), '[]'::jsonb);
end;
$$;

-- Valida nombre / teléfono / rol. Devuelve el teléfono normalizado (+504XXXXXXXX) o null.
create or replace function public._validate_employee(p_name text, p_phone text, p_role text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_norm text;
begin
  if length(public._clean(p_name, 60)) < 2 then
    perform public._raise(422, 'VALIDATION', 'Escribe el nombre del empleado.');
  end if;
  if p_role is null or p_role not in ('ADMIN', 'MANAGER', 'CHEF') then
    perform public._raise(422, 'VALIDATION', 'Elige un rol válido.');
  end if;
  if v_phone is not null then
    v_norm := public._normalize_hn_phone(v_phone);
    if v_norm is null then
      perform public._raise(422, 'VALIDATION', 'Teléfono inválido (8 dígitos).');
    end if;
  end if;
  return v_norm;
end;
$$;

-- Lo llama la Edge Function con la llave secreta, después de crear el usuario en Auth.
create or replace function public._admin_register_employee(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid := (params ->> 'user_id')::uuid;
  v_name text := public._clean(params ->> 'fullName', 60);
  v_role text := params ->> 'role';
  v_phone text := public._validate_employee(v_name, params ->> 'phone', v_role);
begin
  if not exists (select 1 from auth.users where id = v_id) then
    perform public._raise(404, 'NOT_FOUND', 'Usuario no encontrado.');
  end if;
  if exists (select 1 from public.employee_profiles where user_id = v_id) then
    perform public._raise(409, 'ALREADY_EMPLOYEE', 'Ese correo ya pertenece a un empleado.');
  end if;
  insert into public.employee_profiles (user_id, full_name, phone) values (v_id, v_name, v_phone);
  insert into public.employee_roles (user_id, role) values (v_id, v_role::public.app_role);
  return public._employee_json(v_id);
end;
$$;

-- Busca una cuenta por id o correo (solo service_role): { userId, isEmployee } o null.
create or replace function public._admin_lookup_user(params jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('userId', u.id, 'isEmployee', exists (select 1 from public.employee_profiles p where p.user_id = u.id))
  from auth.users u
  where u.id = nullif(params ->> 'user_id', '')::uuid
     or lower(u.email) = lower(nullif(btrim(params ->> 'email'), ''))
  limit 1
$$;

create or replace function public.admin_update_employee(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid := (params ->> 'user_id')::uuid;
  v_name text := public._clean(params ->> 'fullName', 60);
  v_role text := params ->> 'role';
  v_phone text;
  v_current public.app_role;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  v_phone := public._validate_employee(v_name, params ->> 'phone', v_role);

  select role into v_current from public.employee_roles where user_id = v_id for update;
  if not found then
    perform public._raise(404, 'NOT_FOUND', 'Empleado no encontrado.');
  end if;
  if v_id = auth.uid() and v_role <> v_current::text then
    perform public._raise(409, 'CONFLICT', 'No puedes cambiar tu propio rol.');
  end if;

  update public.employee_profiles set full_name = v_name, phone = v_phone where user_id = v_id;
  update public.employee_roles set role = v_role::public.app_role where user_id = v_id;
  return public._employee_json(v_id);
end;
$$;

-- set_employee_active: mismo comportamiento + nunca dejar el restaurante sin administrador activo.
create or replace function public.set_employee_active(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid := (params ->> 'user_id')::uuid;
  v_active boolean := (params ->> 'is_active')::boolean;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  if v_id = auth.uid() then
    perform public._raise(409, 'CONFLICT', 'No puedes desactivar tu propio usuario.');
  end if;
  update public.employee_profiles set is_active = v_active where user_id = v_id;
  if not found then perform public._raise(404, 'NOT_FOUND', 'Empleado no encontrado.'); end if;
  -- Un empleado desactivado pierde acceso: current_app_role() devuelve null en cada RPC/RLS.
  update public.device_tokens set is_active = false where user_id = v_id and not v_active;
  return public._employee_json(v_id);
end;
$$;

-- Último administrador: no se puede degradar el rol del único ADMIN activo.
create or replace function public._guard_last_admin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.role = 'ADMIN' and new.role <> 'ADMIN' and not exists (
    select 1 from public.employee_roles r join public.employee_profiles p on p.user_id = r.user_id
    where r.role = 'ADMIN' and p.is_active and r.user_id <> old.user_id
  ) then
    perform public._raise(409, 'LAST_ADMIN', 'Debe quedar al menos un administrador activo.');
  end if;
  return new;
end;
$$;

create trigger employee_roles_last_admin before update of role on public.employee_roles
  for each row execute function public._guard_last_admin();

-- Permisos
revoke execute on function public._employee_json(uuid), public._validate_employee(text, text, text),
  public._admin_register_employee(jsonb), public._admin_lookup_user(jsonb), public._guard_last_admin()
  from public, anon, authenticated;
grant execute on function public._admin_register_employee(jsonb), public._admin_lookup_user(jsonb) to service_role;
revoke execute on function public.admin_update_employee(jsonb) from public, anon;
grant execute on function public.admin_update_employee(jsonb), public.list_employees(jsonb),
  public.set_employee_active(jsonb) to authenticated;

notify pgrst, 'reload schema';
