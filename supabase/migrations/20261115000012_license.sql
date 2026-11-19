-- =============================================================================
-- Paco's · Licencia del sistema (un solo registro)
--
-- status       ACTIVE | INACTIVE
-- expires_at   null  → licencia completa, sin vencimiento.
--              fecha → periodo de prueba: al pasar la fecha queda INACTIVE (pg_cron, cada minuto).
-- block_web    si la licencia no está disponible, bloquear la web de clientes.
-- block_app    si la licencia no está disponible, bloquear la app del personal.
-- message      texto del aviso que ven las apps bloqueadas (null = mensaje por defecto).
--
-- El bloqueo es en el servidor: una función pre-request de PostgREST rechaza toda
-- llamada de la API (anon = web, authenticated = app) con 403 LICENSE_INACTIVE.
-- Realtime/Storage del personal quedan cortados vía current_app_role().
-- Solo se modifica desde el SQL Editor (postgres): las apps únicamente pueden leer.
-- =============================================================================

create table public.app_license (
  id smallint primary key default 1 check (id = 1),
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'INACTIVE')),
  expires_at timestamptz,
  block_web boolean not null default true,
  block_app boolean not null default true,
  message text check (char_length(message) <= 500),
  updated_at timestamptz not null default now()
);
insert into public.app_license (id, status) values (1, 'ACTIVE') on conflict (id) do nothing;

create trigger app_license_touch before update on public.app_license
  for each row execute function public._touch_updated_at();

-- Lectura pública (no contiene datos sensibles) para que las apps reaccionen en tiempo real.
alter table public.app_license enable row level security;
create policy "licencia: lectura" on public.app_license for select using (true);
revoke all on public.app_license from anon, authenticated;
grant select on public.app_license to anon, authenticated;
alter publication supabase_realtime add table public.app_license;

-- ¿Está bloqueada esta app? p_app: 'WEB' | 'APP'
create or replace function public._license_blocked(p_app text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select not (l.status = 'ACTIVE' and (l.expires_at is null or l.expires_at > now()))
           and case p_app when 'WEB' then l.block_web else l.block_app end
    from public.app_license l where l.id = 1), false)
$$;

-- Estado para las apps (público).
create or replace function public.get_license_status(params jsonb default '{}'::jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'status', case when l.status = 'ACTIVE' and (l.expires_at is null or l.expires_at > now()) then 'ACTIVE' else 'INACTIVE' end,
    'trial', l.expires_at is not null,
    'expiresAt', l.expires_at,
    'webBlocked', public._license_blocked('WEB'),
    'appBlocked', public._license_blocked('APP'),
    'message', coalesce(nullif(btrim(l.message), ''), 'Este sistema está temporalmente deshabilitado. Comunícate con el administrador para reactivarlo.'),
    'serverTime', now())
  from public.app_license l where l.id = 1
$$;

-- -----------------------------------------------------------------------------
-- Puerta de la API: se ejecuta antes de cada request de PostgREST.
-- -----------------------------------------------------------------------------
create or replace function public._license_gate()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text := current_setting('request.jwt.claims', true)::jsonb ->> 'role';
  v_path text := coalesce(current_setting('request.path', true), '');
  v_app text;
begin
  if v_path like '%/rpc/get_license_status' then return; end if;
  v_app := case coalesce(v_role, 'anon') when 'anon' then 'WEB' when 'authenticated' then 'APP' else null end;
  if v_app is null then return; end if; -- service_role y otros roles internos
  if public._license_blocked(v_app) then
    perform public._raise(403, 'LICENSE_INACTIVE',
      (select coalesce(nullif(btrim(message), ''), 'Este sistema está temporalmente deshabilitado.') from public.app_license where id = 1));
  end if;
end;
$$;

alter role authenticator set pgrst.db_pre_request = 'public._license_gate';

-- Realtime y Storage del personal dependen de current_app_role(): sin licencia, no hay rol.
create or replace function public.current_app_role()
returns public.app_role
language sql
stable
security definer
set search_path = public
as $$
  select r.role
  from public.employee_roles r
  join public.employee_profiles p on p.user_id = r.user_id
  where r.user_id = auth.uid() and p.is_active and not public._license_blocked('APP')
$$;

-- Sin licencia para la app no se envían notificaciones push.
create or replace function public._push_on_order_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
begin
  if new.event_type not in ('order.created', 'order.accepted', 'order.reminder', 'order.cancelled', 'order.ready')
     or public._license_blocked('APP') then
    return new;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_dispatch_url' limit 1;
  if v_url is null or v_url = '' then
    return new;
  end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('eventId', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000);
  return new;
exception when others then
  raise warning '[push] no se pudo encolar el evento %: %', new.id, sqlerrm;
  return new;
end;
$$;

-- Vencimiento del periodo de prueba: pasa a INACTIVE (dispara Realtime en las apps).
create or replace function public._license_expire()
returns void
language sql
volatile
security definer
set search_path = public
as $$
  update public.app_license set status = 'INACTIVE'
  where id = 1 and status = 'ACTIVE' and expires_at is not null and expires_at <= now()
$$;
select cron.schedule('pacos-license-expiry', '* * * * *', 'select public._license_expire()');

-- Permisos
revoke execute on function public._license_blocked(text), public._license_gate(), public._license_expire()
  from public, anon, authenticated;
grant execute on function public._license_gate() to anon, authenticated, service_role;
revoke execute on function public.get_license_status(jsonb) from public;
grant execute on function public.get_license_status(jsonb) to anon, authenticated;

notify pgrst, 'reload config';
notify pgrst, 'reload schema';
