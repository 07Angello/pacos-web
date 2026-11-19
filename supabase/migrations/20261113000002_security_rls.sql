-- =============================================================================
-- Paco's · Seguridad: helpers de rol, RLS, triggers y Realtime
-- =============================================================================

-- Rol del empleado autenticado (null si no es empleado o está desactivado).
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
  where r.user_id = auth.uid() and p.is_active
$$;

-- Lanza un error con código HTTP para PostgREST (SQLSTATE PTxxx => HTTP xxx).
-- El "hint" lleva el código de negocio que leen los clientes.
create or replace function public._raise(p_http int, p_code text, p_message text, p_details jsonb default null)
returns void
language plpgsql
as $$
begin
  raise exception using
    errcode = 'PT' || p_http::text,
    message = p_message,
    hint = p_code,
    detail = coalesce(p_details::text, '');
end;
$$;

create or replace function public._require_role(p_roles public.app_role[])
returns public.app_role
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.app_role := public.current_app_role();
begin
  if auth.uid() is null then
    perform public._raise(401, 'UNAUTHORIZED', 'Tu sesión expiró. Inicia sesión de nuevo.');
  end if;
  if v_role is null then
    perform public._raise(403, 'INACTIVE', 'Tu usuario está desactivado o no es empleado.');
  end if;
  if not (v_role = any (p_roles)) then
    perform public._raise(403, 'FORBIDDEN', 'Tu rol no permite esta acción.');
  end if;
  return v_role;
end;
$$;

-- ---------------------------------------------------------------------------
-- updated_at automático
-- ---------------------------------------------------------------------------
create or replace function public._touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger categories_touch before update on public.categories
  for each row execute function public._touch_updated_at();
create trigger products_touch before update on public.products
  for each row execute function public._touch_updated_at();
create trigger settings_touch before update on public.restaurant_settings
  for each row execute function public._touch_updated_at();

-- ---------------------------------------------------------------------------
-- Eventos de pedido para Realtime (después de insertar o cambiar estado)
-- ---------------------------------------------------------------------------
create or replace function public._emit_order_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_events (order_id, order_number, status, event_type)
    values (new.id, new.order_number, new.status, 'order.' || case when tg_op = 'INSERT' then 'created' else lower(new.status::text) end);
  end if;
  return new;
end;
$$;

create trigger orders_emit_event after insert or update of status on public.orders
  for each row execute function public._emit_order_event();

-- El historial es append-only para empleados (§7).
create or replace function public._history_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'order_status_history es append-only';
end;
$$;

create trigger order_status_history_no_update before update or delete on public.order_status_history
  for each row execute function public._history_append_only();

-- ---------------------------------------------------------------------------
-- RLS: habilitado en TODAS las tablas.
-- Pedidos solo se leen/escriben vía RPC security definer (no hay políticas
-- directas para anon). El menú y la configuración pública son de lectura libre.
-- ---------------------------------------------------------------------------
alter table public.restaurant_settings enable row level security;
alter table public.business_hours enable row level security;
alter table public.employee_profiles enable row level security;
alter table public.employee_roles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_options enable row level security;
alter table public.product_option_values enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_item_options enable row level security;
alter table public.order_status_history enable row level security;
alter table public.order_tracking_tokens enable row level security;
alter table public.order_events enable row level security;
alter table public.device_tokens enable row level security;

-- Lectura pública del menú
create policy "menu: lectura pública" on public.categories for select using (is_active or public.current_app_role() = 'ADMIN');
create policy "menu: lectura pública" on public.products for select using (true);
create policy "menu: lectura pública" on public.product_options for select using (true);
create policy "menu: lectura pública" on public.product_option_values for select using (true);
create policy "horario: lectura pública" on public.business_hours for select using (true);
create policy "settings: lectura pública" on public.restaurant_settings for select using (true);

-- Escritura del menú solo ADMIN (además de las RPCs)
create policy "menu: admin escribe" on public.categories for all
  using (public.current_app_role() = 'ADMIN') with check (public.current_app_role() = 'ADMIN');
create policy "menu: admin escribe" on public.products for all
  using (public.current_app_role() = 'ADMIN') with check (public.current_app_role() = 'ADMIN');
create policy "menu: admin escribe" on public.product_options for all
  using (public.current_app_role() = 'ADMIN') with check (public.current_app_role() = 'ADMIN');
create policy "menu: admin escribe" on public.product_option_values for all
  using (public.current_app_role() = 'ADMIN') with check (public.current_app_role() = 'ADMIN');
create policy "horario: admin escribe" on public.business_hours for all
  using (public.current_app_role() = 'ADMIN') with check (public.current_app_role() = 'ADMIN');

-- Empleados: cada uno ve su perfil; el admin ve a todos
create policy "empleados: propio o admin" on public.employee_profiles for select
  using (user_id = auth.uid() or public.current_app_role() = 'ADMIN');
create policy "roles: propio o admin" on public.employee_roles for select
  using (user_id = auth.uid() or public.current_app_role() = 'ADMIN');

-- Eventos de pedido: cualquier empleado activo (Realtime respeta RLS)
create policy "eventos: empleados" on public.order_events for select
  using (public.current_app_role() is not null);

-- Tokens de dispositivo: cada empleado gestiona los suyos
create policy "device tokens: propios" on public.device_tokens for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.order_events;
alter publication supabase_realtime add table public.restaurant_settings;
alter publication supabase_realtime add table public.products;
