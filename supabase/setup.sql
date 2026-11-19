-- =============================================================================
-- Paco's · SETUP COMPLETO (generado: concatena supabase/migrations/*.sql en orden)
-- Pégalo en Supabase → SQL Editor → Run. Ejecutar UNA sola vez en un proyecto vacío.
-- Fuente de verdad: los archivos de migrations/. No edites este archivo a mano.
-- =============================================================================

-- >>> 20261113000001_init_schema.sql
-- =============================================================================
-- Paco's · Esquema inicial (un solo restaurante, sin multi-tenant)
-- Especificación §9 (modelo de datos) y §11 (seguridad).
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------
create type public.app_role as enum ('ADMIN', 'MANAGER', 'CHEF');
create type public.order_status as enum (
  'PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'OUT_FOR_DELIVERY', 'COMPLETED', 'REJECTED', 'CANCELLED'
);
create type public.order_type as enum ('PICKUP', 'DELIVERY');

-- ---------------------------------------------------------------------------
-- Configuración del restaurante (fila única)
-- ---------------------------------------------------------------------------
create table public.restaurant_settings (
  id smallint primary key default 1 check (id = 1),
  name text not null,
  slug text not null unique,
  tagline text,
  phone text,
  address text,
  timezone text not null default 'America/Tegucigalpa',
  currency text not null default 'HNL',
  currency_symbol text not null default 'L',
  is_open boolean not null default true,
  pickup_enabled boolean not null default true,
  delivery_enabled boolean not null default true,
  delivery_fee numeric(10, 2) not null default 0 check (delivery_fee >= 0),
  estimated_prep_minutes integer check (estimated_prep_minutes >= 0),
  kitchen_delay_minutes integer not null default 15 check (kitchen_delay_minutes >= 0),
  show_unavailable_products boolean not null default true,
  payment_methods jsonb not null default '[{"code":"CASH","label":"Efectivo"}]'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id)
);

create table public.business_hours (
  weekday smallint primary key check (weekday between 0 and 6),
  label text not null,
  opens_at time,
  closes_at time,
  is_closed boolean not null default false
);

-- ---------------------------------------------------------------------------
-- Empleados
-- ---------------------------------------------------------------------------
create table public.employee_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.employee_roles (
  user_id uuid primary key references public.employee_profiles (user_id) on delete cascade,
  role public.app_role not null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Menú
-- ---------------------------------------------------------------------------
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  icon text,                       -- clase Font Awesome, p. ej. 'fa-burger'
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories (id) on delete restrict,
  name text not null,
  description text,
  price numeric(10, 2) not null check (price >= 0),
  image_path text,
  is_available boolean not null default true,
  is_featured boolean not null default false,
  sort_order integer not null default 0,
  updated_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.product_options (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products (id) on delete cascade,
  name text not null,
  option_type text not null check (option_type in ('SINGLE', 'MULTIPLE')),
  is_required boolean not null default false,
  min_select integer not null default 0 check (min_select >= 0),
  max_select integer not null default 1 check (max_select >= 1),
  sort_order integer not null default 0,
  check (min_select <= max_select)
);

create table public.product_option_values (
  id uuid primary key default gen_random_uuid(),
  option_id uuid not null references public.product_options (id) on delete cascade,
  label text not null,
  price_delta numeric(10, 2) not null default 0 check (price_delta >= 0),
  is_available boolean not null default true,
  sort_order integer not null default 0
);

-- ---------------------------------------------------------------------------
-- Pedidos
-- ---------------------------------------------------------------------------
create sequence public.order_number_seq start 1001;

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  status public.order_status not null default 'PENDING',
  customer_name text not null check (char_length(customer_name) between 2 and 60),
  customer_phone text not null,                     -- normalizado +504XXXXXXXX, NO verificado
  order_type public.order_type not null,
  address_neighborhood text,
  address_street text,
  address_house text,
  address_reference text,
  notes text check (char_length(notes) <= 200),
  payment_method text not null,
  subtotal numeric(10, 2) not null check (subtotal >= 0),
  delivery_fee numeric(10, 2) not null default 0 check (delivery_fee >= 0),
  total numeric(10, 2) not null check (total >= 0),
  idempotency_key text not null unique,
  idempotency_fingerprint text not null,
  created_at timestamptz not null default now(),
  accepted_at timestamptz, accepted_by uuid references auth.users (id),
  started_at timestamptz, started_by uuid references auth.users (id),
  ready_at timestamptz, ready_by uuid references auth.users (id),
  out_for_delivery_at timestamptz, out_for_delivery_by uuid references auth.users (id),
  completed_at timestamptz, completed_by uuid references auth.users (id),
  rejected_at timestamptz, rejected_by uuid references auth.users (id),
  rejection_reason text check (char_length(rejection_reason) <= 200),
  check (order_type = 'PICKUP' or address_neighborhood is not null)
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  product_id uuid references public.products (id) on delete restrict,
  product_name_snapshot text not null,
  unit_price_snapshot numeric(10, 2) not null check (unit_price_snapshot >= 0),
  quantity integer not null check (quantity between 1 and 20),
  notes text check (char_length(notes) <= 140),
  line_total numeric(10, 2) not null check (line_total >= 0),
  sort_order integer not null default 0
);

create table public.order_item_options (
  id uuid primary key default gen_random_uuid(),
  order_item_id uuid not null references public.order_items (id) on delete cascade,
  option_name_snapshot text not null,
  value_name_snapshot text not null,
  price_delta_snapshot numeric(10, 2) not null default 0,
  quantity integer not null default 1 check (quantity >= 1)
);

create table public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  from_status public.order_status,
  to_status public.order_status not null,
  actor_user_id uuid references auth.users (id),
  actor_label text not null,
  reason text,
  created_at timestamptz not null default now()
);

create table public.order_tracking_tokens (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null default now() + interval '30 days',
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

-- Eventos livianos para Realtime: la app se suscribe aquí (sin datos personales)
-- y luego consulta el detalle autorizado vía RPC.
create table public.order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders (id) on delete cascade,
  order_number text not null,
  status public.order_status not null,
  event_type text not null,
  created_at timestamptz not null default now()
);

-- Tokens FCM (fase de push)
create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  token text not null unique,
  platform text not null default 'android',
  device_label text,
  is_active boolean not null default true,
  last_seen_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Índices
-- ---------------------------------------------------------------------------
create index orders_status_accepted_idx on public.orders (status, accepted_at);
create index orders_created_idx on public.orders (created_at);
create index order_items_order_idx on public.order_items (order_id);
create index products_category_available_idx on public.products (category_id, is_available);
create index order_status_history_order_idx on public.order_status_history (order_id, created_at);
create index order_events_created_idx on public.order_events (created_at);

-- >>> 20261113000002_security_rls.sql
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

-- >>> 20261113000003_rpc.sql
-- =============================================================================
-- Paco's · RPCs (contratos que consumen pacos-web y pacos-app)
--
-- Convención: cada RPC recibe un único argumento `params jsonb` y devuelve jsonb
-- en camelCase. Los clientes llaman: supabase.rpc('<nombre>', { params: {...} }).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Serializadores
-- ---------------------------------------------------------------------------
create or replace function public._settings_json(p_full boolean default false)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'name', s.name, 'slug', s.slug, 'tagline', s.tagline, 'phone', s.phone, 'address', s.address,
    'timezone', s.timezone, 'currency', s.currency, 'currencySymbol', s.currency_symbol,
    'isOpen', s.is_open, 'pickupEnabled', s.pickup_enabled, 'deliveryEnabled', s.delivery_enabled,
    'deliveryFee', s.delivery_fee, 'estimatedPrepMinutes', s.estimated_prep_minutes,
    'paymentMethods', s.payment_methods,
    'businessHours', coalesce((
      select jsonb_agg(jsonb_build_object(
        'weekday', h.weekday, 'label', h.label,
        'opensAt', to_char(h.opens_at, 'HH24:MI'), 'closesAt', to_char(h.closes_at, 'HH24:MI'),
        'isClosed', h.is_closed) order by h.weekday)
      from public.business_hours h), '[]'::jsonb)
  ) || case when p_full then jsonb_build_object(
    'kitchenDelayMinutes', s.kitchen_delay_minutes,
    'showUnavailableProducts', s.show_unavailable_products
  ) else '{}'::jsonb end
  from public.restaurant_settings s
  where s.id = 1
$$;

create or replace function public._product_json(p public.products)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', p.id, 'categoryId', p.category_id, 'name', p.name, 'description', p.description,
    'price', p.price, 'imagePath', p.image_path, 'isAvailable', p.is_available,
    'isFeatured', p.is_featured, 'sortOrder', p.sort_order,
    'options', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'name', o.name, 'optionType', o.option_type, 'isRequired', o.is_required,
        'minSelect', o.min_select, 'maxSelect', o.max_select, 'sortOrder', o.sort_order,
        'values', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', v.id, 'label', v.label, 'priceDelta', v.price_delta, 'isAvailable', v.is_available
          ) order by v.sort_order)
          from public.product_option_values v where v.option_id = o.id), '[]'::jsonb)
      ) order by o.sort_order)
      from public.product_options o where o.product_id = p.id), '[]'::jsonb)
  )
$$;

create or replace function public._category_json(c public.categories)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'id', c.id, 'name', c.name, 'description', c.description, 'icon', c.icon,
    'sortOrder', c.sort_order, 'isActive', c.is_active)
$$;

create or replace function public._short_name(p_full text)
returns text
language sql
immutable
as $$
  select case
    when split_part(p_full, ' ', 2) = '' then split_part(p_full, ' ', 1)
    else split_part(p_full, ' ', 1) || ' ' || left(split_part(p_full, ' ', 2), 1) || '.'
  end
$$;

-- Vista del pedido según rol: el chef solo recibe lo necesario para cocinar.
create or replace function public._order_json(o public.orders, p_role public.app_role)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_name text;
begin
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', i.id, 'productId', i.product_id, 'productName', i.product_name_snapshot,
      'quantity', i.quantity, 'notes', coalesce(i.notes, ''),
      'options', coalesce((
        select jsonb_agg(jsonb_build_object(
          'optionName', io.option_name_snapshot, 'valueName', io.value_name_snapshot,
          'priceDelta', io.price_delta_snapshot))
        from public.order_item_options io where io.order_item_id = i.id), '[]'::jsonb)
    ) || case when p_role = 'CHEF' then '{}'::jsonb else jsonb_build_object(
      'unitPrice', i.unit_price_snapshot, 'lineTotal', i.line_total) end
    order by i.sort_order), '[]'::jsonb)
  into v_items
  from public.order_items i
  where i.order_id = o.id;

  if p_role = 'CHEF' then
    return jsonb_build_object(
      'id', o.id, 'orderNumber', o.order_number, 'status', o.status, 'orderType', o.order_type,
      'customerName', public._short_name(o.customer_name), 'notes', coalesce(o.notes, ''),
      'items', v_items, 'createdAt', o.created_at, 'acceptedAt', o.accepted_at,
      'startedAt', o.started_at, 'readyAt', o.ready_at,
      'outForDeliveryAt', o.out_for_delivery_at, 'completedAt', o.completed_at);
  end if;

  return jsonb_build_object(
    'id', o.id, 'orderNumber', o.order_number, 'status', o.status,
    'customerName', o.customer_name, 'customerPhone', o.customer_phone, 'orderType', o.order_type,
    'address', case when o.order_type = 'DELIVERY' then jsonb_build_object(
      'neighborhood', o.address_neighborhood, 'street', o.address_street,
      'house', o.address_house, 'reference', o.address_reference) else null end,
    'notes', coalesce(o.notes, ''), 'paymentMethod', o.payment_method,
    'subtotal', o.subtotal, 'deliveryFee', o.delivery_fee, 'total', o.total,
    'items', v_items,
    'createdAt', o.created_at,
    'acceptedAt', o.accepted_at, 'acceptedBy', (select full_name from employee_profiles where user_id = o.accepted_by),
    'startedAt', o.started_at, 'startedBy', (select full_name from employee_profiles where user_id = o.started_by),
    'readyAt', o.ready_at, 'readyBy', (select full_name from employee_profiles where user_id = o.ready_by),
    'outForDeliveryAt', o.out_for_delivery_at, 'outForDeliveryBy', (select full_name from employee_profiles where user_id = o.out_for_delivery_by),
    'completedAt', o.completed_at, 'completedBy', (select full_name from employee_profiles where user_id = o.completed_by),
    'rejectedAt', o.rejected_at, 'rejectedBy', (select full_name from employee_profiles where user_id = o.rejected_by),
    'rejectionReason', o.rejection_reason,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', h.id, 'fromStatus', h.from_status, 'toStatus', h.to_status, 'actorUserId', h.actor_user_id,
        'actorLabel', h.actor_label, 'reason', h.reason, 'createdAt', h.created_at) order by h.created_at)
      from public.order_status_history h where h.order_id = o.id), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Públicas (anon)
-- ---------------------------------------------------------------------------
create or replace function public.get_public_menu(params jsonb default '{}'::jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'settings', public._settings_json(false),
    'categories', coalesce((
      select jsonb_agg(public._category_json(c) order by c.sort_order)
      from public.categories c where c.is_active), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(public._product_json(p) order by p.sort_order)
      from public.products p
      join public.categories c on c.id = p.category_id and c.is_active
      where p.is_available or (select show_unavailable_products from public.restaurant_settings where id = 1)), '[]'::jsonb)
  )
$$;

create or replace function public._normalize_hn_phone(p_raw text)
returns text
language plpgsql
immutable
as $$
declare
  v text := regexp_replace(coalesce(p_raw, ''), '\D', '', 'g');
begin
  if length(v) = 11 and left(v, 3) = '504' then v := substr(v, 4); end if;
  if v !~ '^[2389][0-9]{7}$' then return null; end if;
  return '+504' || v;
end;
$$;

create or replace function public._clean(p text, p_max int)
returns text
language sql
immutable
as $$
  select left(regexp_replace(btrim(coalesce(p, '')), '[<>]', '', 'g'), p_max)
$$;

create or replace function public._new_tracking_token(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token text := rtrim(translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/', '-_'), '=');
begin
  insert into public.order_tracking_tokens (order_id, token_hash)
  values (p_order_id, encode(extensions.digest(v_token, 'sha256'), 'hex'));
  return v_token;
end;
$$;

create or replace function public.create_guest_order(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  s public.restaurant_settings;
  v_key text := btrim(coalesce(params ->> 'idempotencyKey', ''));
  v_fingerprint text := md5((params - 'idempotencyKey')::text);
  v_existing public.orders;
  v_errors jsonb := '{}'::jsonb;
  v_line_errors jsonb := '[]'::jsonb;
  v_name text := public._clean(params #>> '{customer,name}', 60);
  v_phone text := public._normalize_hn_phone(params #>> '{customer,phone}');
  v_type text := params ->> 'orderType';
  v_payment text := params ->> 'paymentMethod';
  v_neigh text; v_street text; v_house text; v_ref text;
  v_items jsonb := coalesce(params -> 'items', '[]'::jsonb);
  v_item jsonb;
  v_idx int := 0;
  v_product public.products;
  v_qty int;
  v_selected uuid[];
  v_unit numeric(10, 2);
  v_group record;
  v_count int;
  v_lines jsonb := '[]'::jsonb;
  v_subtotal numeric(10, 2) := 0;
  v_fee numeric(10, 2) := 0;
  v_order_id uuid;
  v_item_id uuid;
  v_line jsonb;
  v_opt jsonb;
  v_number text;
  v_token text;
begin
  if length(v_key) < 8 then
    perform public._raise(400, 'VALIDATION', 'Falta la clave de idempotencia.');
  end if;

  -- Reintento idempotente: devuelve el mismo pedido (con un token nuevo, el anterior se conserva).
  select * into v_existing from public.orders where idempotency_key = v_key;
  if found then
    if v_existing.idempotency_fingerprint <> v_fingerprint then
      perform public._raise(409, 'IDEMPOTENCY_MISMATCH', 'Esta solicitud ya fue usada con otros datos.');
    end if;
    return jsonb_build_object('orderNumber', v_existing.order_number, 'trackingToken', public._new_tracking_token(v_existing.id),
      'total', v_existing.total, 'status', v_existing.status, 'replayed', true);
  end if;

  select * into s from public.restaurant_settings where id = 1;
  if not s.is_open then
    perform public._raise(409, 'RESTAURANT_CLOSED', 'El restaurante no está recibiendo pedidos en este momento.');
  end if;

  if length(v_name) < 2 then v_errors := v_errors || '{"name":"Ingresa tu nombre."}'; end if;
  if v_phone is null then v_errors := v_errors || '{"phone":"Ingresa un teléfono válido de Honduras (8 dígitos)."}'; end if;
  if v_type is null or v_type not in ('PICKUP', 'DELIVERY') then
    v_errors := v_errors || '{"orderType":"Selecciona cómo quieres recibir tu pedido."}';
  elsif v_type = 'PICKUP' and not s.pickup_enabled then
    v_errors := v_errors || '{"orderType":"La recogida en local no está disponible."}';
  elsif v_type = 'DELIVERY' and not s.delivery_enabled then
    v_errors := v_errors || '{"orderType":"La entrega a domicilio no está disponible."}';
  end if;

  if v_type = 'DELIVERY' then
    v_neigh := public._clean(params #>> '{address,neighborhood}', 80);
    v_street := public._clean(params #>> '{address,street}', 120);
    v_house := public._clean(params #>> '{address,house}', 80);
    v_ref := public._clean(params #>> '{address,reference}', 160);
    if length(v_neigh) < 3 then v_errors := v_errors || '{"neighborhood":"Indica la colonia o barrio."}'; end if;
    if length(v_street) < 3 then v_errors := v_errors || '{"street":"Indica la calle o avenida."}'; end if;
    if length(v_ref) < 3 then v_errors := v_errors || '{"reference":"Agrega una referencia para encontrarte."}'; end if;
    v_fee := s.delivery_fee;
  end if;

  if not exists (select 1 from jsonb_array_elements(s.payment_methods) m where m ->> 'code' = v_payment) then
    v_errors := v_errors || '{"paymentMethod":"Selecciona un método de pago."}';
  end if;

  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    v_errors := v_errors || '{"items":"Tu carrito está vacío."}';
  elsif jsonb_array_length(v_items) > 30 then
    v_errors := v_errors || '{"items":"Demasiados productos en un solo pedido."}';
  else
    -- Recalcular TODO desde la base de datos; los precios del cliente se ignoran.
    for v_item in select value from jsonb_array_elements(v_items) loop
      begin
        select p.* into v_product
        from public.products p join public.categories c on c.id = p.category_id and c.is_active
        where p.id = (v_item ->> 'productId')::uuid;
      exception when invalid_text_representation then
        v_product := null;
      end;

      if v_product.id is null then
        v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'message', 'Este producto ya no está en el menú.');
      elsif not v_product.is_available then
        v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', v_product.name || ' está agotado.');
      else
        v_qty := coalesce((v_item ->> 'quantity')::int, 0);
        select coalesce(array_agg(x::uuid), '{}') into v_selected
        from jsonb_array_elements_text(coalesce(v_item -> 'optionValueIds', '[]'::jsonb)) x;

        if v_qty < 1 or v_qty > 20 then
          v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Cantidad inválida (1 a 20).');
        elsif exists (
          select 1 from unnest(v_selected) sel
          where not exists (select 1 from public.product_option_values v join public.product_options o on o.id = v.option_id
                            where v.id = sel and o.product_id = v_product.id)
        ) then
          v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Opción inválida para ' || v_product.name || '.');
        else
          v_unit := v_product.price;
          v_line := jsonb_build_object('productId', v_product.id, 'productName', v_product.name, 'quantity', v_qty,
                                       'notes', public._clean(v_item ->> 'notes', 140), 'options', '[]'::jsonb);
          for v_group in select * from public.product_options where product_id = v_product.id order by sort_order loop
            select count(*) into v_count from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected);
            if exists (select 1 from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected) and not v.is_available) then
              v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Una opción de ' || v_product.name || ' ya no está disponible.');
              v_line := null;
              exit;
            end if;
            if v_count < (case when v_group.is_required then greatest(1, v_group.min_select) else v_group.min_select end)
               or v_count > v_group.max_select then
              v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Revisa "' || v_group.name || '" en ' || v_product.name || '.');
              v_line := null;
              exit;
            end if;
            select v_unit + coalesce(sum(v.price_delta), 0),
                   v_line -> 'options' || coalesce(jsonb_agg(jsonb_build_object('optionName', v_group.name, 'valueName', v.label, 'priceDelta', v.price_delta) order by v.sort_order), '[]'::jsonb)
              into v_unit, v_opt
            from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected);
            v_line := jsonb_set(v_line, '{options}', v_opt);
          end loop;

          if v_line is not null then
            v_line := v_line || jsonb_build_object('unitPrice', v_unit, 'lineTotal', v_unit * v_qty);
            v_lines := v_lines || v_line;
            v_subtotal := v_subtotal + v_unit * v_qty;
          end if;
        end if;
      end if;
      v_idx := v_idx + 1;
    end loop;
  end if;

  if v_errors <> '{}'::jsonb or jsonb_array_length(v_line_errors) > 0 then
    perform public._raise(422, 'VALIDATION', 'Revisa los datos de tu pedido.',
      jsonb_build_object('fields', v_errors, 'lines', v_line_errors));
  end if;

  -- Inserción atómica (toda la función corre en una transacción).
  v_number := 'R-' || lpad(nextval('public.order_number_seq')::text, 6, '0');
  insert into public.orders (order_number, customer_name, customer_phone, order_type,
    address_neighborhood, address_street, address_house, address_reference, notes, payment_method,
    subtotal, delivery_fee, total, idempotency_key, idempotency_fingerprint)
  values (v_number, v_name, v_phone, v_type::public.order_type,
    v_neigh, v_street, nullif(v_house, ''), v_ref, public._clean(params ->> 'notes', 200), v_payment,
    v_subtotal, v_fee, v_subtotal + v_fee, v_key, v_fingerprint)
  returning id into v_order_id;

  v_idx := 0;
  for v_line in select value from jsonb_array_elements(v_lines) loop
    insert into public.order_items (order_id, product_id, product_name_snapshot, unit_price_snapshot, quantity, notes, line_total, sort_order)
    values (v_order_id, (v_line ->> 'productId')::uuid, v_line ->> 'productName', (v_line ->> 'unitPrice')::numeric,
            (v_line ->> 'quantity')::int, nullif(v_line ->> 'notes', ''), (v_line ->> 'lineTotal')::numeric, v_idx)
    returning id into v_item_id;
    insert into public.order_item_options (order_item_id, option_name_snapshot, value_name_snapshot, price_delta_snapshot)
    select v_item_id, o ->> 'optionName', o ->> 'valueName', (o ->> 'priceDelta')::numeric
    from jsonb_array_elements(v_line -> 'options') o;
    v_idx := v_idx + 1;
  end loop;

  insert into public.order_status_history (order_id, from_status, to_status, actor_label)
  values (v_order_id, null, 'PENDING', 'Cliente (web)');

  v_token := public._new_tracking_token(v_order_id);
  return jsonb_build_object('orderNumber', v_number, 'trackingToken', v_token,
    'total', v_subtotal + v_fee, 'status', 'PENDING', 'replayed', false);
end;
$$;

create or replace function public.get_order_tracking(params jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  o public.orders;
  s public.restaurant_settings;
begin
  select ord.* into o
  from public.order_tracking_tokens t
  join public.orders ord on ord.id = t.order_id
  where t.token_hash = encode(extensions.digest(coalesce(params ->> 'token', ''), 'sha256'), 'hex')
    and t.revoked_at is null and t.expires_at > now();
  if not found then
    perform public._raise(404, 'NOT_FOUND', 'No encontramos este pedido. Revisa el enlace.');
  end if;
  select * into s from public.restaurant_settings where id = 1;

  return jsonb_build_object(
    'orderNumber', o.order_number, 'status', o.status, 'orderType', o.order_type,
    'customerFirstName', split_part(o.customer_name, ' ', 1),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'productName', i.product_name_snapshot, 'quantity', i.quantity, 'lineTotal', i.line_total,
        'options', coalesce((select jsonb_agg(io.value_name_snapshot) from public.order_item_options io where io.order_item_id = i.id), '[]'::jsonb)
      ) order by i.sort_order) from public.order_items i where i.order_id = o.id), '[]'::jsonb),
    'subtotal', o.subtotal, 'deliveryFee', o.delivery_fee, 'total', o.total,
    'paymentMethodLabel', coalesce((select m ->> 'label' from jsonb_array_elements(s.payment_methods) m where m ->> 'code' = o.payment_method), o.payment_method),
    'createdAt', o.created_at,
    'timeline', coalesce((select jsonb_agg(jsonb_build_object('status', h.to_status, 'at', h.created_at) order by h.created_at)
                          from public.order_status_history h where h.order_id = o.id), '[]'::jsonb),
    'rejectionReason', o.rejection_reason,
    'restaurant', jsonb_build_object('name', s.name, 'phone', s.phone, 'address', s.address),
    'estimatedPrepMinutes', s.estimated_prep_minutes
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Personal (authenticated)
-- ---------------------------------------------------------------------------
create or replace function public.staff_me(params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.app_role := public._require_role(array['ADMIN', 'MANAGER', 'CHEF']::public.app_role[]);
begin
  return (
    select jsonb_build_object('id', p.user_id, 'email', u.email, 'fullName', p.full_name, 'role', v_role, 'isActive', p.is_active)
    from public.employee_profiles p join auth.users u on u.id = p.user_id
    where p.user_id = auth.uid());
end;
$$;

create or replace function public.list_orders(params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.app_role := public._require_role(array['ADMIN', 'MANAGER', 'CHEF']::public.app_role[]);
begin
  return coalesce((
    select jsonb_agg(public._order_json(o, v_role) order by o.created_at)
    from public.orders o
    where (v_role <> 'CHEF' or o.status in ('ACCEPTED', 'PREPARING', 'READY', 'OUT_FOR_DELIVERY'))
      and (o.status not in ('COMPLETED', 'REJECTED', 'CANCELLED') or o.created_at >= now() - interval '24 hours')
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_order(params jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.app_role := public._require_role(array['ADMIN', 'MANAGER', 'CHEF']::public.app_role[]);
  o public.orders;
begin
  select * into o from public.orders where id = (params ->> 'order_id')::uuid;
  if not found or (v_role = 'CHEF' and o.status not in ('ACCEPTED', 'PREPARING', 'READY', 'OUT_FOR_DELIVERY')) then
    perform public._raise(404, 'NOT_FOUND', 'Pedido no encontrado.');
  end if;
  return public._order_json(o, v_role);
end;
$$;

-- Transición genérica: UPDATE condicional por estado esperado + historial en la misma transacción.
create or replace function public._transition(p_order_id uuid, p_action text, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_from public.order_status[];
  v_to public.order_status;
  v_roles public.app_role[];
  v_role public.app_role;
  v_prev public.order_status;
  v_reason text := nullif(public._clean(p_reason, 200), '');
  o public.orders;
  v_actor text;
begin
  case p_action
    when 'accept' then v_from := '{PENDING}'; v_to := 'ACCEPTED'; v_roles := '{ADMIN,MANAGER}';
    when 'reject' then v_from := '{PENDING}'; v_to := 'REJECTED'; v_roles := '{ADMIN,MANAGER}';
    when 'start' then v_from := '{ACCEPTED}'; v_to := 'PREPARING'; v_roles := '{ADMIN,MANAGER,CHEF}';
    when 'ready' then v_from := '{PREPARING}'; v_to := 'READY'; v_roles := '{ADMIN,MANAGER,CHEF}';
    when 'dispatch' then v_from := '{READY}'; v_to := 'OUT_FOR_DELIVERY'; v_roles := '{ADMIN,MANAGER}';
    when 'complete' then v_from := '{READY,OUT_FOR_DELIVERY}'; v_to := 'COMPLETED'; v_roles := '{ADMIN,MANAGER}';
    else perform public._raise(400, 'VALIDATION', 'Acción desconocida.');
  end case;

  v_role := public._require_role(v_roles);
  if p_action = 'reject' and coalesce(length(v_reason), 0) < 3 then
    perform public._raise(422, 'VALIDATION', 'Indica el motivo del rechazo.');
  end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then
    perform public._raise(404, 'NOT_FOUND', 'Pedido no encontrado.');
  end if;
  if not (o.status = any (v_from)) then
    perform public._raise(409, 'CONFLICT', 'El pedido ya está en estado ' || o.status || '.',
      jsonb_build_object('currentStatus', o.status));
  end if;
  if p_action = 'dispatch' and o.order_type <> 'DELIVERY' then
    perform public._raise(409, 'CONFLICT', 'Solo los pedidos a domicilio salen a entrega.');
  end if;

  v_prev := o.status;
  update public.orders set
    status = v_to,
    accepted_at = case when p_action = 'accept' then now() else accepted_at end,
    accepted_by = case when p_action = 'accept' then auth.uid() else accepted_by end,
    rejected_at = case when p_action = 'reject' then now() else rejected_at end,
    rejected_by = case when p_action = 'reject' then auth.uid() else rejected_by end,
    rejection_reason = case when p_action = 'reject' then v_reason else rejection_reason end,
    started_at = case when p_action = 'start' then now() else started_at end,
    started_by = case when p_action = 'start' then auth.uid() else started_by end,
    ready_at = case when p_action = 'ready' then now() else ready_at end,
    ready_by = case when p_action = 'ready' then auth.uid() else ready_by end,
    out_for_delivery_at = case when p_action = 'dispatch' then now() else out_for_delivery_at end,
    out_for_delivery_by = case when p_action = 'dispatch' then auth.uid() else out_for_delivery_by end,
    completed_at = case when p_action = 'complete' then now() else completed_at end,
    completed_by = case when p_action = 'complete' then auth.uid() else completed_by end
  where id = p_order_id and status = v_prev
  returning * into o;

  select full_name into v_actor from public.employee_profiles where user_id = auth.uid();
  insert into public.order_status_history (order_id, from_status, to_status, actor_user_id, actor_label, reason)
  values (o.id, v_prev, v_to, auth.uid(), coalesce(v_actor, 'Empleado'), v_reason);

  return public._order_json(o, v_role);
end;
$$;

create or replace function public.accept_order(params jsonb) returns jsonb language sql volatile security definer set search_path = public
as $$ select public._transition((params ->> 'order_id')::uuid, 'accept') $$;
create or replace function public.reject_order(params jsonb) returns jsonb language sql volatile security definer set search_path = public
as $$ select public._transition((params ->> 'order_id')::uuid, 'reject', params ->> 'reason') $$;
create or replace function public.start_preparation(params jsonb) returns jsonb language sql volatile security definer set search_path = public
as $$ select public._transition((params ->> 'order_id')::uuid, 'start') $$;
create or replace function public.mark_order_ready(params jsonb) returns jsonb language sql volatile security definer set search_path = public
as $$ select public._transition((params ->> 'order_id')::uuid, 'ready') $$;
create or replace function public.mark_out_for_delivery(params jsonb) returns jsonb language sql volatile security definer set search_path = public
as $$ select public._transition((params ->> 'order_id')::uuid, 'dispatch') $$;
create or replace function public.complete_order(params jsonb) returns jsonb language sql volatile security definer set search_path = public
as $$ select public._transition((params ->> 'order_id')::uuid, 'complete') $$;

-- ---------------------------------------------------------------------------
-- Configuración
-- ---------------------------------------------------------------------------
create or replace function public.get_settings(params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_role(array['ADMIN', 'MANAGER', 'CHEF']::public.app_role[]);
  return public._settings_json(true);
end;
$$;

create or replace function public.update_settings(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_role public.app_role := public._require_role(array['ADMIN', 'MANAGER']::public.app_role[]);
  v_key text;
  v_allowed text[] := case when v_role = 'ADMIN' then
    array['isOpen', 'pickupEnabled', 'deliveryEnabled', 'deliveryFee', 'estimatedPrepMinutes', 'kitchenDelayMinutes',
          'showUnavailableProducts', 'phone', 'address', 'tagline']
    else array['isOpen'] end;   -- el encargado solo abre/cierra pedidos
begin
  for v_key in select jsonb_object_keys(params) loop
    if not (v_key = any (v_allowed)) then
      perform public._raise(403, 'FORBIDDEN', 'No puedes cambiar "' || v_key || '".');
    end if;
  end loop;

  update public.restaurant_settings set
    is_open = coalesce((params ->> 'isOpen')::boolean, is_open),
    pickup_enabled = coalesce((params ->> 'pickupEnabled')::boolean, pickup_enabled),
    delivery_enabled = coalesce((params ->> 'deliveryEnabled')::boolean, delivery_enabled),
    delivery_fee = coalesce((params ->> 'deliveryFee')::numeric, delivery_fee),
    estimated_prep_minutes = coalesce((params ->> 'estimatedPrepMinutes')::int, estimated_prep_minutes),
    kitchen_delay_minutes = coalesce((params ->> 'kitchenDelayMinutes')::int, kitchen_delay_minutes),
    show_unavailable_products = coalesce((params ->> 'showUnavailableProducts')::boolean, show_unavailable_products),
    phone = coalesce(public._clean(params ->> 'phone', 160), phone),
    address = coalesce(public._clean(params ->> 'address', 160), address),
    tagline = coalesce(public._clean(params ->> 'tagline', 160), tagline),
    updated_by = auth.uid()
  where id = 1;
  return public._settings_json(true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Administración del menú
-- ---------------------------------------------------------------------------
create or replace function public.admin_get_menu(params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  return jsonb_build_object(
    'categories', coalesce((select jsonb_agg(public._category_json(c) order by c.sort_order) from public.categories c), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(public._product_json(p) order by p.sort_order) from public.products p), '[]'::jsonb));
end;
$$;

create or replace function public.update_product_availability(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  p public.products;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  update public.products set is_available = (params ->> 'is_available')::boolean, updated_by = auth.uid()
  where id = (params ->> 'product_id')::uuid returning * into p;
  if not found then perform public._raise(404, 'NOT_FOUND', 'Producto no encontrado.'); end if;
  return public._product_json(p);
end;
$$;

create or replace function public.update_product(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  p public.products;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  if params ? 'price' and (params ->> 'price')::numeric < 0 then
    perform public._raise(422, 'VALIDATION', 'Precio inválido.');
  end if;
  update public.products set
    price = coalesce((params ->> 'price')::numeric, price),
    name = coalesce(nullif(public._clean(params ->> 'name', 80), ''), name),
    description = case when params ? 'description' then public._clean(params ->> 'description', 240) else description end,
    updated_by = auth.uid()
  where id = (params ->> 'product_id')::uuid returning * into p;
  if not found then perform public._raise(404, 'NOT_FOUND', 'Producto no encontrado.'); end if;
  return public._product_json(p);
end;
$$;

create or replace function public.update_category(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  c public.categories;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  update public.categories set is_active = coalesce((params ->> 'is_active')::boolean, is_active)
  where id = (params ->> 'category_id')::uuid returning * into c;
  if not found then perform public._raise(404, 'NOT_FOUND', 'Categoría no encontrada.'); end if;
  return public._category_json(c);
end;
$$;

-- ---------------------------------------------------------------------------
-- Empleados
-- ---------------------------------------------------------------------------
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
    select jsonb_agg(jsonb_build_object('id', p.user_id, 'email', u.email, 'fullName', p.full_name, 'role', r.role, 'isActive', p.is_active)
                     order by r.role, p.full_name)
    from public.employee_profiles p
    join public.employee_roles r on r.user_id = p.user_id
    join auth.users u on u.id = p.user_id), '[]'::jsonb);
end;
$$;

create or replace function public.set_employee_active(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid := (params ->> 'user_id')::uuid;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  if v_id = auth.uid() then
    perform public._raise(409, 'CONFLICT', 'No puedes desactivar tu propio usuario.');
  end if;
  update public.employee_profiles set is_active = (params ->> 'is_active')::boolean where user_id = v_id;
  if not found then perform public._raise(404, 'NOT_FOUND', 'Empleado no encontrado.'); end if;
  -- Un empleado desactivado pierde acceso: current_app_role() devuelve null en cada RPC/RLS.
  update public.device_tokens set is_active = false where user_id = v_id and not (params ->> 'is_active')::boolean;
  return (select jsonb_build_object('id', p.user_id, 'email', u.email, 'fullName', p.full_name, 'role', r.role, 'isActive', p.is_active)
          from public.employee_profiles p join public.employee_roles r on r.user_id = p.user_id join auth.users u on u.id = p.user_id
          where p.user_id = v_id);
end;
$$;

create or replace function public.register_device_token(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  perform public._require_role(array['ADMIN', 'MANAGER', 'CHEF']::public.app_role[]);
  insert into public.device_tokens (user_id, token, platform, device_label)
  values (auth.uid(), params ->> 'token', coalesce(params ->> 'platform', 'android'), params ->> 'label')
  on conflict (token) do update set user_id = excluded.user_id, is_active = true, last_seen_at = now(), device_label = excluded.device_label;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Permisos de ejecución
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.get_public_menu(jsonb) to anon, authenticated;
grant execute on function public.create_guest_order(jsonb) to anon, authenticated;
grant execute on function public.get_order_tracking(jsonb) to anon, authenticated;

-- current_app_role() se usa dentro de políticas RLS que también evalúa anon.
grant execute on function public.current_app_role() to anon, authenticated;
grant execute on function public.staff_me(jsonb) to authenticated;
grant execute on function public.list_orders(jsonb) to authenticated;
grant execute on function public.get_order(jsonb) to authenticated;
grant execute on function public.accept_order(jsonb) to authenticated;
grant execute on function public.reject_order(jsonb) to authenticated;
grant execute on function public.start_preparation(jsonb) to authenticated;
grant execute on function public.mark_order_ready(jsonb) to authenticated;
grant execute on function public.mark_out_for_delivery(jsonb) to authenticated;
grant execute on function public.complete_order(jsonb) to authenticated;
grant execute on function public.get_settings(jsonb) to authenticated;
grant execute on function public.update_settings(jsonb) to authenticated;
grant execute on function public.admin_get_menu(jsonb) to authenticated;
grant execute on function public.update_product_availability(jsonb) to authenticated;
grant execute on function public.update_product(jsonb) to authenticated;
grant execute on function public.update_category(jsonb) to authenticated;
grant execute on function public.list_employees(jsonb) to authenticated;
grant execute on function public.set_employee_active(jsonb) to authenticated;
grant execute on function public.register_device_token(jsonb) to authenticated;

-- >>> 20261113000004_grants_storage.sql
-- =============================================================================
-- Paco's · Permisos explícitos de la Data API, Storage y recarga de esquema
--
-- Algunos proyectos Supabase nuevos no exponen automáticamente las tablas a los
-- roles anon/authenticated. Aquí se otorga SOLO lo necesario; RLS sigue filtrando
-- filas y los pedidos solo se tocan mediante RPCs security definer.
-- =============================================================================

grant usage on schema public to anon, authenticated;

-- Menú y configuración pública: lectura (también la usa Realtime para avisar cambios).
grant select on public.restaurant_settings, public.business_hours, public.categories,
  public.products, public.product_options, public.product_option_values to anon, authenticated;

-- Escritura directa del menú: solo pasa la RLS del ADMIN.
grant insert, update, delete on public.categories, public.products, public.product_options,
  public.product_option_values, public.business_hours to authenticated;

-- Empleados: lectura (RLS: el propio perfil o ADMIN).
grant select on public.employee_profiles, public.employee_roles to authenticated;

-- Realtime de pedidos: eventos livianos, solo empleados activos (RLS).
grant select on public.order_events to authenticated;

-- Tokens FCM propios.
grant select, insert, update, delete on public.device_tokens to authenticated;

-- Pedidos, líneas, historial y tokens de seguimiento: SIN acceso directo.
revoke all on public.orders, public.order_items, public.order_item_options,
  public.order_status_history, public.order_tracking_tokens from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Storage: bucket público para fotos de productos y logo (solo ADMIN sube).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('menu-images', 'menu-images', true, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

create policy "menu-images: lectura pública" on storage.objects for select
  using (bucket_id = 'menu-images');
create policy "menu-images: admin sube" on storage.objects for insert to authenticated
  with check (bucket_id = 'menu-images' and public.current_app_role() = 'ADMIN');
create policy "menu-images: admin actualiza" on storage.objects for update to authenticated
  using (bucket_id = 'menu-images' and public.current_app_role() = 'ADMIN');
create policy "menu-images: admin borra" on storage.objects for delete to authenticated
  using (bucket_id = 'menu-images' and public.current_app_role() = 'ADMIN');

-- Que PostgREST vea de inmediato tablas y funciones nuevas.
notify pgrst, 'reload schema';

-- >>> 20261114000005_payment_transfer.sql
-- =============================================================================
-- Paco's · Método de pago "Transferencia" además de "Efectivo".
-- create_guest_order ya valida contra esta lista, no requiere cambios.
-- =============================================================================

alter table public.restaurant_settings
  alter column payment_methods set default
    '[{"code":"CASH","label":"Efectivo"},{"code":"TRANSFER","label":"Transferencia"}]'::jsonb;

update public.restaurant_settings
set payment_methods = payment_methods || '[{"code":"TRANSFER","label":"Transferencia"}]'::jsonb
where id = 1
  and not exists (select 1 from jsonb_array_elements(payment_methods) m where m ->> 'code' = 'TRANSFER');

-- >>> 20261114000006_menu_builder.sql
-- =============================================================================
-- Paco's · Menú configurable por el administrador (sin programar)
--
-- 1. Grupos de opciones REUTILIZABLES: un grupo ("Extras de hamburguesa") se crea
--    una vez y se asigna a varios platos (tabla product_option_links).
-- 2. Opción preseleccionada por defecto (product_option_values.is_default).
-- 3. Platos archivados (archived_at): "eliminar" sin romper pedidos históricos.
-- 4. RPCs de administración: platos, grupos, categorías, orden y archivado.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Esquema
-- ---------------------------------------------------------------------------
alter table public.products add column archived_at timestamptz;
alter table public.product_option_values add column is_default boolean not null default false;
alter table public.product_options
  add column created_at timestamptz not null default now(),
  add column updated_at timestamptz not null default now();

create table public.product_option_links (
  product_id uuid not null references public.products (id) on delete cascade,
  option_id uuid not null references public.product_options (id) on delete cascade,
  sort_order integer not null default 0,
  primary key (product_id, option_id)
);
create index product_option_links_option_idx on public.product_option_links (option_id);

-- Migrar los grupos existentes (antes cada grupo pertenecía a un solo plato).
insert into public.product_option_links (product_id, option_id, sort_order)
select product_id, id, sort_order from public.product_options;

alter table public.product_options drop column product_id;

create trigger product_options_touch before update on public.product_options
  for each row execute function public._touch_updated_at();

-- RLS + permisos de la nueva tabla
alter table public.product_option_links enable row level security;
create policy "menu: lectura pública" on public.product_option_links for select using (true);
create policy "menu: admin escribe" on public.product_option_links for all
  using (public.current_app_role() = 'ADMIN') with check (public.current_app_role() = 'ADMIN');
grant select on public.product_option_links to anon, authenticated;
grant insert, update, delete on public.product_option_links to authenticated;

-- La web se entera al instante de cambios en opciones y categorías.
alter publication supabase_realtime add table public.categories, public.product_options,
  public.product_option_values, public.product_option_links;

-- ---------------------------------------------------------------------------
-- Serializadores
-- ---------------------------------------------------------------------------
create or replace function public._option_values_json(p_option_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', v.id, 'label', v.label, 'priceDelta', v.price_delta,
    'isAvailable', v.is_available, 'isDefault', v.is_default, 'sortOrder', v.sort_order
  ) order by v.sort_order, v.label), '[]'::jsonb)
  from public.product_option_values v
  where v.option_id = p_option_id
$$;

create or replace function public._product_json(p public.products)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', p.id, 'categoryId', p.category_id, 'name', p.name, 'description', p.description,
    'price', p.price, 'imagePath', p.image_path, 'isAvailable', p.is_available,
    'isFeatured', p.is_featured, 'sortOrder', p.sort_order,
    'options', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'name', o.name, 'optionType', o.option_type, 'isRequired', o.is_required,
        'minSelect', o.min_select, 'maxSelect', o.max_select, 'sortOrder', l.sort_order,
        'values', public._option_values_json(o.id)
      ) order by l.sort_order)
      from public.product_option_links l
      join public.product_options o on o.id = l.option_id
      where l.product_id = p.id), '[]'::jsonb)
  )
$$;

/** Grupo de la biblioteca, con los platos que lo usan. */
create or replace function public._option_group_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', o.id, 'name', o.name, 'optionType', o.option_type, 'isRequired', o.is_required,
    'minSelect', o.min_select, 'maxSelect', o.max_select,
    'values', public._option_values_json(o.id),
    'productIds', coalesce((
      select jsonb_agg(l.product_id order by pr.name)
      from public.product_option_links l join public.products pr on pr.id = l.product_id
      where l.option_id = o.id and pr.archived_at is null), '[]'::jsonb)
  )
  from public.product_options o
  where o.id = p_id
$$;

-- ---------------------------------------------------------------------------
-- Lecturas (excluyen platos archivados)
-- ---------------------------------------------------------------------------
create or replace function public.get_public_menu(params jsonb default '{}'::jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'settings', public._settings_json(false),
    'categories', coalesce((
      select jsonb_agg(public._category_json(c) order by c.sort_order)
      from public.categories c where c.is_active), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(public._product_json(p) order by p.sort_order)
      from public.products p
      join public.categories c on c.id = p.category_id and c.is_active
      where p.archived_at is null
        and (p.is_available or (select show_unavailable_products from public.restaurant_settings where id = 1))), '[]'::jsonb)
  )
$$;

create or replace function public.admin_get_menu(params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  return jsonb_build_object(
    'categories', coalesce((select jsonb_agg(public._category_json(c) order by c.sort_order) from public.categories c), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(public._product_json(p) order by p.sort_order, p.name)
                          from public.products p where p.archived_at is null), '[]'::jsonb),
    'optionGroups', coalesce((select jsonb_agg(public._option_group_json(o.id) order by o.name)
                              from public.product_options o), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- create_guest_order: misma lógica, ahora valida contra los grupos enlazados
-- al plato y rechaza platos archivados.
-- ---------------------------------------------------------------------------
create or replace function public.create_guest_order(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  s public.restaurant_settings;
  v_key text := btrim(coalesce(params ->> 'idempotencyKey', ''));
  v_fingerprint text := md5((params - 'idempotencyKey')::text);
  v_existing public.orders;
  v_errors jsonb := '{}'::jsonb;
  v_line_errors jsonb := '[]'::jsonb;
  v_name text := public._clean(params #>> '{customer,name}', 60);
  v_phone text := public._normalize_hn_phone(params #>> '{customer,phone}');
  v_type text := params ->> 'orderType';
  v_payment text := params ->> 'paymentMethod';
  v_neigh text; v_street text; v_house text; v_ref text;
  v_items jsonb := coalesce(params -> 'items', '[]'::jsonb);
  v_item jsonb;
  v_idx int := 0;
  v_product public.products;
  v_qty int;
  v_selected uuid[];
  v_unit numeric(10, 2);
  v_group record;
  v_count int;
  v_lines jsonb := '[]'::jsonb;
  v_subtotal numeric(10, 2) := 0;
  v_fee numeric(10, 2) := 0;
  v_order_id uuid;
  v_item_id uuid;
  v_line jsonb;
  v_opt jsonb;
  v_number text;
  v_token text;
begin
  if length(v_key) < 8 then
    perform public._raise(400, 'VALIDATION', 'Falta la clave de idempotencia.');
  end if;

  -- Reintento idempotente: devuelve el mismo pedido (con un token nuevo, el anterior se conserva).
  select * into v_existing from public.orders where idempotency_key = v_key;
  if found then
    if v_existing.idempotency_fingerprint <> v_fingerprint then
      perform public._raise(409, 'IDEMPOTENCY_MISMATCH', 'Esta solicitud ya fue usada con otros datos.');
    end if;
    return jsonb_build_object('orderNumber', v_existing.order_number, 'trackingToken', public._new_tracking_token(v_existing.id),
      'total', v_existing.total, 'status', v_existing.status, 'replayed', true);
  end if;

  select * into s from public.restaurant_settings where id = 1;
  if not s.is_open then
    perform public._raise(409, 'RESTAURANT_CLOSED', 'El restaurante no está recibiendo pedidos en este momento.');
  end if;

  if length(v_name) < 2 then v_errors := v_errors || '{"name":"Ingresa tu nombre."}'; end if;
  if v_phone is null then v_errors := v_errors || '{"phone":"Ingresa un teléfono válido de Honduras (8 dígitos)."}'; end if;
  if v_type is null or v_type not in ('PICKUP', 'DELIVERY') then
    v_errors := v_errors || '{"orderType":"Selecciona cómo quieres recibir tu pedido."}';
  elsif v_type = 'PICKUP' and not s.pickup_enabled then
    v_errors := v_errors || '{"orderType":"La recogida en local no está disponible."}';
  elsif v_type = 'DELIVERY' and not s.delivery_enabled then
    v_errors := v_errors || '{"orderType":"La entrega a domicilio no está disponible."}';
  end if;

  if v_type = 'DELIVERY' then
    v_neigh := public._clean(params #>> '{address,neighborhood}', 80);
    v_street := public._clean(params #>> '{address,street}', 120);
    v_house := public._clean(params #>> '{address,house}', 80);
    v_ref := public._clean(params #>> '{address,reference}', 160);
    if length(v_neigh) < 3 then v_errors := v_errors || '{"neighborhood":"Indica la colonia o barrio."}'; end if;
    if length(v_street) < 3 then v_errors := v_errors || '{"street":"Indica la calle o avenida."}'; end if;
    if length(v_ref) < 3 then v_errors := v_errors || '{"reference":"Agrega una referencia para encontrarte."}'; end if;
    v_fee := s.delivery_fee;
  end if;

  if not exists (select 1 from jsonb_array_elements(s.payment_methods) m where m ->> 'code' = v_payment) then
    v_errors := v_errors || '{"paymentMethod":"Selecciona un método de pago."}';
  end if;

  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    v_errors := v_errors || '{"items":"Tu carrito está vacío."}';
  elsif jsonb_array_length(v_items) > 30 then
    v_errors := v_errors || '{"items":"Demasiados productos en un solo pedido."}';
  else
    -- Recalcular TODO desde la base de datos; los precios del cliente se ignoran.
    for v_item in select value from jsonb_array_elements(v_items) loop
      begin
        select p.* into v_product
        from public.products p join public.categories c on c.id = p.category_id and c.is_active
        where p.id = (v_item ->> 'productId')::uuid and p.archived_at is null;
      exception when invalid_text_representation then
        v_product := null;
      end;

      if v_product.id is null then
        v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'message', 'Este producto ya no está en el menú.');
      elsif not v_product.is_available then
        v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', v_product.name || ' está agotado.');
      else
        v_qty := coalesce((v_item ->> 'quantity')::int, 0);
        select coalesce(array_agg(x::uuid), '{}') into v_selected
        from jsonb_array_elements_text(coalesce(v_item -> 'optionValueIds', '[]'::jsonb)) x;

        if v_qty < 1 or v_qty > 20 then
          v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Cantidad inválida (1 a 20).');
        elsif exists (
          select 1 from unnest(v_selected) sel
          where not exists (select 1 from public.product_option_values v join public.product_option_links l on l.option_id = v.option_id
                            where v.id = sel and l.product_id = v_product.id)
        ) then
          v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Opción inválida para ' || v_product.name || '.');
        else
          v_unit := v_product.price;
          v_line := jsonb_build_object('productId', v_product.id, 'productName', v_product.name, 'quantity', v_qty,
                                       'notes', public._clean(v_item ->> 'notes', 140), 'options', '[]'::jsonb);
          for v_group in select o.* from public.product_options o join public.product_option_links l on l.option_id = o.id
                         where l.product_id = v_product.id order by l.sort_order loop
            select count(*) into v_count from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected);
            if exists (select 1 from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected) and not v.is_available) then
              v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Una opción de ' || v_product.name || ' ya no está disponible.');
              v_line := null;
              exit;
            end if;
            if v_count < (case when v_group.is_required then greatest(1, v_group.min_select) else v_group.min_select end)
               or v_count > v_group.max_select then
              v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Revisa "' || v_group.name || '" en ' || v_product.name || '.');
              v_line := null;
              exit;
            end if;
            select v_unit + coalesce(sum(v.price_delta), 0),
                   v_line -> 'options' || coalesce(jsonb_agg(jsonb_build_object('optionName', v_group.name, 'valueName', v.label, 'priceDelta', v.price_delta) order by v.sort_order), '[]'::jsonb)
              into v_unit, v_opt
            from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected);
            v_line := jsonb_set(v_line, '{options}', v_opt);
          end loop;

          if v_line is not null then
            v_line := v_line || jsonb_build_object('unitPrice', v_unit, 'lineTotal', v_unit * v_qty);
            v_lines := v_lines || v_line;
            v_subtotal := v_subtotal + v_unit * v_qty;
          end if;
        end if;
      end if;
      v_idx := v_idx + 1;
    end loop;
  end if;

  if v_errors <> '{}'::jsonb or jsonb_array_length(v_line_errors) > 0 then
    perform public._raise(422, 'VALIDATION', 'Revisa los datos de tu pedido.',
      jsonb_build_object('fields', v_errors, 'lines', v_line_errors));
  end if;

  -- Inserción atómica (toda la función corre en una transacción).
  v_number := 'R-' || lpad(nextval('public.order_number_seq')::text, 6, '0');
  insert into public.orders (order_number, customer_name, customer_phone, order_type,
    address_neighborhood, address_street, address_house, address_reference, notes, payment_method,
    subtotal, delivery_fee, total, idempotency_key, idempotency_fingerprint)
  values (v_number, v_name, v_phone, v_type::public.order_type,
    v_neigh, v_street, nullif(v_house, ''), v_ref, public._clean(params ->> 'notes', 200), v_payment,
    v_subtotal, v_fee, v_subtotal + v_fee, v_key, v_fingerprint)
  returning id into v_order_id;

  v_idx := 0;
  for v_line in select value from jsonb_array_elements(v_lines) loop
    insert into public.order_items (order_id, product_id, product_name_snapshot, unit_price_snapshot, quantity, notes, line_total, sort_order)
    values (v_order_id, (v_line ->> 'productId')::uuid, v_line ->> 'productName', (v_line ->> 'unitPrice')::numeric,
            (v_line ->> 'quantity')::int, nullif(v_line ->> 'notes', ''), (v_line ->> 'lineTotal')::numeric, v_idx)
    returning id into v_item_id;
    insert into public.order_item_options (order_item_id, option_name_snapshot, value_name_snapshot, price_delta_snapshot)
    select v_item_id, o ->> 'optionName', o ->> 'valueName', (o ->> 'priceDelta')::numeric
    from jsonb_array_elements(v_line -> 'options') o;
    v_idx := v_idx + 1;
  end loop;

  insert into public.order_status_history (order_id, from_status, to_status, actor_label)
  values (v_order_id, null, 'PENDING', 'Cliente (web)');

  v_token := public._new_tracking_token(v_order_id);
  return jsonb_build_object('orderNumber', v_number, 'trackingToken', v_token,
    'total', v_subtotal + v_fee, 'status', 'PENDING', 'replayed', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- Administración: grupos de opciones (biblioteca reutilizable)
-- ---------------------------------------------------------------------------
create or replace function public.admin_upsert_option_group(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid := nullif(params ->> 'id', '')::uuid;
  v_name text := public._clean(params ->> 'name', 80);
  v_type text := coalesce(params ->> 'optionType', 'SINGLE');
  v_required boolean := coalesce((params ->> 'isRequired')::boolean, false);
  v_values jsonb := coalesce(params -> 'values', '[]'::jsonb);
  v_count int;
  v_min int;
  v_max int;
  v_defaults int;
  v_val jsonb;
  v_vid uuid;
  v_idx int := 0;
  v_keep uuid[] := '{}';
  v_label text;
  v_price numeric;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);

  if length(v_name) < 2 then
    perform public._raise(422, 'VALIDATION', 'Ponle un nombre al grupo (ej.: "Extras").');
  end if;
  if v_type not in ('SINGLE', 'MULTIPLE') then
    perform public._raise(422, 'VALIDATION', 'Tipo de grupo inválido.');
  end if;
  if jsonb_typeof(v_values) <> 'array' or jsonb_array_length(v_values) = 0 then
    perform public._raise(422, 'VALIDATION', 'Agrega al menos una opción al grupo.');
  end if;
  v_count := jsonb_array_length(v_values);
  if v_count > 40 then
    perform public._raise(422, 'VALIDATION', 'Máximo 40 opciones por grupo.');
  end if;

  if v_type = 'SINGLE' then
    v_min := case when v_required then 1 else 0 end;
    v_max := 1;
  else
    v_max := coalesce((params ->> 'maxSelect')::int, v_count);
    v_min := greatest(coalesce((params ->> 'minSelect')::int, 0), case when v_required then 1 else 0 end);
    if v_max < 1 or v_max > v_count then
      perform public._raise(422, 'VALIDATION', 'El máximo debe estar entre 1 y ' || v_count || '.');
    end if;
    if v_min > v_max then
      perform public._raise(422, 'VALIDATION', 'El mínimo no puede ser mayor que el máximo.');
    end if;
  end if;

  select count(*) into v_defaults from jsonb_array_elements(v_values) e where coalesce((e ->> 'isDefault')::boolean, false);
  if v_defaults > v_max then
    perform public._raise(422, 'VALIDATION', 'Hay más opciones preseleccionadas que el máximo permitido.');
  end if;

  if v_id is null then
    insert into public.product_options (name, option_type, is_required, min_select, max_select)
    values (v_name, v_type, v_required, v_min, v_max) returning id into v_id;
  else
    update public.product_options
    set name = v_name, option_type = v_type, is_required = v_required, min_select = v_min, max_select = v_max
    where id = v_id;
    if not found then perform public._raise(404, 'NOT_FOUND', 'Grupo no encontrado.'); end if;
  end if;

  for v_val in select value from jsonb_array_elements(v_values) loop
    v_label := public._clean(v_val ->> 'label', 60);
    v_price := coalesce((v_val ->> 'priceDelta')::numeric, 0);
    if length(v_label) < 1 then
      perform public._raise(422, 'VALIDATION', 'Hay una opción sin nombre.');
    end if;
    if v_price < 0 then
      perform public._raise(422, 'VALIDATION', 'El precio adicional no puede ser negativo.');
    end if;
    v_vid := nullif(v_val ->> 'id', '')::uuid;
    if v_vid is not null and exists (select 1 from public.product_option_values where id = v_vid and option_id = v_id) then
      update public.product_option_values
      set label = v_label, price_delta = v_price, sort_order = v_idx,
          is_available = coalesce((v_val ->> 'isAvailable')::boolean, true),
          is_default = coalesce((v_val ->> 'isDefault')::boolean, false)
      where id = v_vid;
    else
      insert into public.product_option_values (option_id, label, price_delta, is_available, is_default, sort_order)
      values (v_id, v_label, v_price, coalesce((v_val ->> 'isAvailable')::boolean, true),
              coalesce((v_val ->> 'isDefault')::boolean, false), v_idx)
      returning id into v_vid;
    end if;
    v_keep := v_keep || v_vid;
    v_idx := v_idx + 1;
  end loop;

  -- Las opciones quitadas se borran: los pedidos guardan copia (snapshot) del texto y precio.
  delete from public.product_option_values where option_id = v_id and not (id = any (v_keep));

  return public._option_group_json(v_id);
end;
$$;

create or replace function public.admin_delete_option_group(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  delete from public.product_options where id = (params ->> 'id')::uuid;
  if not found then perform public._raise(404, 'NOT_FOUND', 'Grupo no encontrado.'); end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Administración: platos
-- ---------------------------------------------------------------------------
create or replace function public.admin_upsert_product(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid := nullif(params ->> 'id', '')::uuid;
  v_category uuid := nullif(params ->> 'categoryId', '')::uuid;
  v_name text := public._clean(params ->> 'name', 80);
  v_price numeric := (params ->> 'price')::numeric;
  v_groups jsonb := coalesce(params -> 'optionGroupIds', '[]'::jsonb);
  v_image text := nullif(btrim(coalesce(params ->> 'imagePath', '')), '');
  p public.products;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);

  if length(v_name) < 2 then
    perform public._raise(422, 'VALIDATION', 'Ponle nombre al plato.');
  end if;
  if v_price is null or v_price < 0 or v_price > 100000 then
    perform public._raise(422, 'VALIDATION', 'Precio inválido.');
  end if;
  if v_category is null or not exists (select 1 from public.categories where id = v_category) then
    perform public._raise(422, 'VALIDATION', 'Elige una categoría.');
  end if;
  if v_image is not null and (length(v_image) > 300 or v_image ~ '\.\.') then
    perform public._raise(422, 'VALIDATION', 'Ruta de imagen inválida.');
  end if;
  if exists (
    select 1 from jsonb_array_elements_text(v_groups) g
    where not exists (select 1 from public.product_options o where o.id::text = g)
  ) then
    perform public._raise(422, 'VALIDATION', 'Uno de los grupos de opciones ya no existe.');
  end if;

  if v_id is null then
    insert into public.products (category_id, name, description, price, image_path, is_available, is_featured, sort_order, updated_by)
    values (v_category, v_name, public._clean(params ->> 'description', 240), v_price, v_image,
            coalesce((params ->> 'isAvailable')::boolean, true), coalesce((params ->> 'isFeatured')::boolean, false),
            coalesce((select max(sort_order) + 1 from public.products where category_id = v_category), 1), auth.uid())
    returning * into p;
  else
    update public.products set
      category_id = v_category, name = v_name, description = public._clean(params ->> 'description', 240),
      price = v_price, image_path = v_image,
      is_available = coalesce((params ->> 'isAvailable')::boolean, is_available),
      is_featured = coalesce((params ->> 'isFeatured')::boolean, is_featured),
      updated_by = auth.uid()
    where id = v_id and archived_at is null
    returning * into p;
    if not found then perform public._raise(404, 'NOT_FOUND', 'Plato no encontrado.'); end if;
  end if;

  delete from public.product_option_links where product_id = p.id;
  insert into public.product_option_links (product_id, option_id, sort_order)
  select p.id, g::uuid, (ord - 1)::int
  from jsonb_array_elements_text(v_groups) with ordinality as t(g, ord)
  on conflict do nothing;

  return public._product_json(p);
end;
$$;

-- "Eliminar" un plato = archivarlo: desaparece del menú y del admin, pero los
-- pedidos históricos conservan su referencia.
create or replace function public.admin_archive_product(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  update public.products set archived_at = now(), is_available = false, updated_by = auth.uid()
  where id = (params ->> 'product_id')::uuid and archived_at is null;
  if not found then perform public._raise(404, 'NOT_FOUND', 'Plato no encontrado.'); end if;
  delete from public.product_option_links where product_id = (params ->> 'product_id')::uuid;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Administración: categorías y orden
-- ---------------------------------------------------------------------------
create or replace function public.admin_upsert_category(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid := nullif(params ->> 'id', '')::uuid;
  v_name text := public._clean(params ->> 'name', 60);
  v_icon text := coalesce(nullif(params ->> 'icon', ''), 'fa-utensils');
  c public.categories;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  if length(v_name) < 2 then
    perform public._raise(422, 'VALIDATION', 'Ponle nombre a la categoría.');
  end if;
  if v_icon !~ '^fa-[a-z0-9-]{1,40}$' then
    perform public._raise(422, 'VALIDATION', 'Ícono inválido.');
  end if;

  if v_id is null then
    insert into public.categories (name, description, icon, is_active, sort_order)
    values (v_name, public._clean(params ->> 'description', 160), v_icon, coalesce((params ->> 'isActive')::boolean, true),
            coalesce((select max(sort_order) + 1 from public.categories), 1))
    returning * into c;
  else
    update public.categories set name = v_name, description = public._clean(params ->> 'description', 160),
      icon = v_icon, is_active = coalesce((params ->> 'isActive')::boolean, is_active)
    where id = v_id returning * into c;
    if not found then perform public._raise(404, 'NOT_FOUND', 'Categoría no encontrada.'); end if;
  end if;
  return public._category_json(c);
end;
$$;

-- Reordena categorías o los platos de una categoría según el arreglo de ids recibido.
create or replace function public.admin_reorder(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_kind text := params ->> 'kind';
  v_ids jsonb := coalesce(params -> 'ids', '[]'::jsonb);
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  if v_kind = 'categories' then
    update public.categories c set sort_order = t.ord
    from jsonb_array_elements_text(v_ids) with ordinality as t(id, ord)
    where c.id = t.id::uuid;
  elsif v_kind = 'products' then
    update public.products p set sort_order = t.ord
    from jsonb_array_elements_text(v_ids) with ordinality as t(id, ord)
    where p.id = t.id::uuid;
  else
    perform public._raise(400, 'VALIDATION', 'Tipo de orden inválido.');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public._option_values_json(uuid), public._option_group_json(uuid)
  from public, anon, authenticated;
revoke execute on function public.admin_upsert_option_group(jsonb), public.admin_delete_option_group(jsonb),
  public.admin_upsert_product(jsonb), public.admin_archive_product(jsonb), public.admin_upsert_category(jsonb),
  public.admin_reorder(jsonb) from public, anon;
grant execute on function public.admin_upsert_option_group(jsonb), public.admin_delete_option_group(jsonb),
  public.admin_upsert_product(jsonb), public.admin_archive_product(jsonb), public.admin_upsert_category(jsonb),
  public.admin_reorder(jsonb) to authenticated;
-- create or replace conserva los permisos; se reafirman por claridad.
grant execute on function public.get_public_menu(jsonb), public.create_guest_order(jsonb) to anon, authenticated;
grant execute on function public.admin_get_menu(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- >>> 20261114000007_cancel_and_schedule.sql
-- =============================================================================
-- Paco's · Cancelación por el cliente y pedidos programados para recoger
--
-- 1. El cliente puede cancelar su pedido (con su enlace de seguimiento) mientras
--    siga PENDING. Una vez aceptado, solo el restaurante puede cambiarlo.
-- 2. En pedidos PICKUP el cliente puede elegir la hora de recogida (hoy o mañana,
--    dentro del horario, cada 15 min). Un job de pg_cron revisa cada minuto y
--    emite el evento `order.reminder` cuando falta el tiempo promedio de
--    preparación para la hora elegida; la app avisa a encargados y administradores.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Columnas
-- ---------------------------------------------------------------------------
alter table public.orders
  add column scheduled_for timestamptz,
  add column reminder_sent_at timestamptz,
  add column cancelled_at timestamptz,
  add column cancellation_reason text check (char_length(cancellation_reason) <= 200),
  add constraint orders_scheduled_pickup_chk check (scheduled_for is null or order_type = 'PICKUP');

create index orders_scheduled_reminder_idx on public.orders (scheduled_for)
  where scheduled_for is not null and reminder_sent_at is null;
create index orders_ready_at_idx on public.orders (ready_at) where ready_at is not null;

-- ---------------------------------------------------------------------------
-- Tiempo promedio de preparación (minutos)
-- Muestras: últimos 30 pedidos listos en 14 días.
--   · Pedido inmediato: aceptado → listo (incluye la fila de cocina).
--   · Pedido programado: inicio de preparación → listo (se acepta con horas de anticipación).
-- Se descartan valores fuera de 1–180 min. Con menos de 3 muestras se usa el
-- tiempo estimado de Ajustes (o 20 min).
-- ---------------------------------------------------------------------------
create or replace function public._avg_prep_minutes()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  with samples as (
    select extract(epoch from (o.ready_at - case when o.scheduled_for is null then o.accepted_at
                                                 else coalesce(o.started_at, o.accepted_at) end)) / 60 as mins
    from public.orders o
    where o.ready_at is not null and o.accepted_at is not null
      and o.ready_at >= now() - interval '14 days'
    order by o.ready_at desc
    limit 30
  ), valid as (
    select mins from samples where mins between 1 and 180
  )
  select case when (select count(*) from valid) >= 3
    then greatest(5, least(120, round((select avg(mins) from valid))))::int
    else coalesce((select nullif(estimated_prep_minutes, 0) from public.restaurant_settings where id = 1), 20)
  end
$$;

-- Anticipación mínima para programar: promedio + 10 min de margen (mínimo 30).
create or replace function public._pickup_min_lead()
returns integer
language sql
stable
security definer
set search_path = public
as $$ select greatest(30, public._avg_prep_minutes() + 10) $$;

-- ---------------------------------------------------------------------------
-- Horarios disponibles para recoger (hoy y mañana, hora local del restaurante).
-- Desde 30 min después de abrir hasta 15 min antes de cerrar, cada 15 min.
-- ---------------------------------------------------------------------------
create or replace function public._pickup_slots(p_lead_minutes integer)
returns table (day_index integer, local_date date, slot_at timestamptz, label text)
language sql
stable
security definer
set search_path = public
as $$
  with days as (
    select d as day_index, ((now() at time zone s.timezone)::date + d) as local_date, s.timezone as tz
    from public.restaurant_settings s, generate_series(0, 1) d
    where s.id = 1
  )
  select days.day_index, days.local_date, (t at time zone days.tz), to_char(t, 'FMHH12:MI AM')
  from days
  join public.business_hours h
    on h.weekday = extract(dow from days.local_date)
   and not h.is_closed and h.opens_at is not null and h.closes_at is not null
  cross join lateral generate_series(
    days.local_date + h.opens_at + interval '30 minutes',
    days.local_date + h.closes_at
      + case when h.closes_at <= h.opens_at then interval '1 day' else interval '0' end
      - interval '15 minutes',
    interval '15 minutes') as t
  where (t at time zone days.tz) >= now() + make_interval(mins => p_lead_minutes)
  order by 3
$$;

create or replace function public.get_pickup_slots(params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.restaurant_settings;
  v_lead int := public._pickup_min_lead();
begin
  select * into s from public.restaurant_settings where id = 1;
  return jsonb_build_object(
    'leadMinutes', v_lead,
    'days', case when not s.pickup_enabled then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('dayIndex', d.day_index, 'date', d.local_date, 'slots', d.slots) order by d.day_index)
      from (
        select x.day_index, x.local_date, jsonb_agg(jsonb_build_object('at', x.slot_at, 'label', x.label) order by x.slot_at) as slots
        from public._pickup_slots(v_lead) x
        group by x.day_index, x.local_date
      ) d), '[]'::jsonb) end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- create_guest_order: la lógica de carrito/precios sigue en el núcleo; esta
-- envoltura valida y guarda la hora programada (`scheduledFor`, ISO 8601).
-- Cambios futuros al carrito → editar public._create_guest_order_core.
-- ---------------------------------------------------------------------------
alter function public.create_guest_order(jsonb) rename to _create_guest_order_core;
revoke execute on function public._create_guest_order_core(jsonb) from public, anon, authenticated;

create or replace function public.create_guest_order(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_raw text := nullif(btrim(coalesce(params ->> 'scheduledFor', '')), '');
  v_sched timestamptz;
  v_result jsonb;
  v_msg text;
begin
  -- Un reintento idempotente devuelve el pedido original aunque la hora ya haya pasado.
  if v_raw is not null and not exists (
    select 1 from public.orders where idempotency_key = btrim(coalesce(params ->> 'idempotencyKey', ''))
  ) then
    begin
      v_sched := v_raw::timestamptz;
    exception when others then
      v_msg := 'Hora de recogida inválida.';
    end;
    if v_msg is null and coalesce(params ->> 'orderType', '') <> 'PICKUP' then
      v_msg := 'Solo los pedidos para recoger se pueden programar.';
    elsif v_msg is null and not exists (
      -- 10 min de tolerancia por el tiempo que el cliente tarda en llenar el formulario.
      select 1 from public._pickup_slots(greatest(0, public._pickup_min_lead() - 10)) x where x.slot_at = v_sched
    ) then
      v_msg := 'Esa hora ya no está disponible. Elige otra.';
    end if;
    if v_msg is not null then
      perform public._raise(422, 'VALIDATION', 'Revisa la hora de recogida.',
        jsonb_build_object('fields', jsonb_build_object('scheduledFor', v_msg), 'lines', '[]'::jsonb));
    end if;
  end if;

  v_result := public._create_guest_order_core(params);

  if v_sched is not null and not coalesce((v_result ->> 'replayed')::boolean, false) then
    update public.orders set scheduled_for = v_sched where order_number = v_result ->> 'orderNumber';
  end if;
  return v_result || jsonb_build_object('scheduledFor',
    (select scheduled_for from public.orders where order_number = v_result ->> 'orderNumber'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Cancelación por el cliente (solo PENDING), autenticada por el token de seguimiento.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_guest_order(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  o public.orders;
  v_reason text := nullif(public._clean(params ->> 'reason', 200), '');
begin
  select ord.* into o
  from public.order_tracking_tokens t
  join public.orders ord on ord.id = t.order_id
  where t.token_hash = encode(extensions.digest(coalesce(params ->> 'token', ''), 'sha256'), 'hex')
    and t.revoked_at is null and t.expires_at > now()
  for update of ord;
  if not found then
    perform public._raise(404, 'NOT_FOUND', 'No encontramos este pedido. Revisa el enlace.');
  end if;

  if o.status = 'CANCELLED' then
    return public.get_order_tracking(params);  -- doble toque: sin error
  elsif o.status = 'REJECTED' or o.status = 'COMPLETED' then
    perform public._raise(409, 'NOT_CANCELLABLE', 'Este pedido ya fue cerrado.', jsonb_build_object('currentStatus', o.status));
  elsif o.status <> 'PENDING' then
    perform public._raise(409, 'NOT_CANCELLABLE',
      'El restaurante ya aceptó tu pedido y no se puede cancelar en línea. Si necesitas cambiarlo, llámanos.',
      jsonb_build_object('currentStatus', o.status));
  end if;

  update public.orders
  set status = 'CANCELLED', cancelled_at = now(), cancellation_reason = v_reason
  where id = o.id and status = 'PENDING';

  insert into public.order_status_history (order_id, from_status, to_status, actor_label, reason)
  values (o.id, 'PENDING', 'CANCELLED', 'Cliente (web)', v_reason);

  return public.get_order_tracking(params);
end;
$$;

-- ---------------------------------------------------------------------------
-- Recordatorios de pedidos programados (pg_cron, cada minuto)
-- ---------------------------------------------------------------------------
create or replace function public._send_pickup_reminders()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_lead int := public._avg_prep_minutes();
  v_count int;
begin
  with due as (
    update public.orders
    set reminder_sent_at = now()
    where scheduled_for is not null
      and reminder_sent_at is null
      and status in ('PENDING', 'ACCEPTED')
      and scheduled_for - make_interval(mins => v_lead) <= now()
    returning id, order_number, status
  )
  insert into public.order_events (order_id, order_number, status, event_type)
  select id, order_number, status, 'order.reminder' from due;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('pacos-pickup-reminders', '* * * * *', 'select public._send_pickup_reminders()');

-- ---------------------------------------------------------------------------
-- Serializadores con los campos nuevos
-- ---------------------------------------------------------------------------
create or replace function public._order_json(o public.orders, p_role public.app_role)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_schedule jsonb;
begin
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', i.id, 'productId', i.product_id, 'productName', i.product_name_snapshot,
      'quantity', i.quantity, 'notes', coalesce(i.notes, ''),
      'options', coalesce((
        select jsonb_agg(jsonb_build_object(
          'optionName', io.option_name_snapshot, 'valueName', io.value_name_snapshot,
          'priceDelta', io.price_delta_snapshot))
        from public.order_item_options io where io.order_item_id = i.id), '[]'::jsonb)
    ) || case when p_role = 'CHEF' then '{}'::jsonb else jsonb_build_object(
      'unitPrice', i.unit_price_snapshot, 'lineTotal', i.line_total) end
    order by i.sort_order), '[]'::jsonb)
  into v_items
  from public.order_items i
  where i.order_id = o.id;

  -- reminderAt: cuándo conviene empezar (hora programada − promedio actual de preparación).
  v_schedule := jsonb_build_object(
    'scheduledFor', o.scheduled_for,
    'reminderAt', case when o.scheduled_for is not null
                       then o.scheduled_for - make_interval(mins => public._avg_prep_minutes()) end,
    'reminderSentAt', o.reminder_sent_at);

  if p_role = 'CHEF' then
    return jsonb_build_object(
      'id', o.id, 'orderNumber', o.order_number, 'status', o.status, 'orderType', o.order_type,
      'customerName', public._short_name(o.customer_name), 'notes', coalesce(o.notes, ''),
      'items', v_items, 'createdAt', o.created_at, 'acceptedAt', o.accepted_at,
      'startedAt', o.started_at, 'readyAt', o.ready_at,
      'outForDeliveryAt', o.out_for_delivery_at, 'completedAt', o.completed_at) || v_schedule;
  end if;

  return jsonb_build_object(
    'id', o.id, 'orderNumber', o.order_number, 'status', o.status,
    'customerName', o.customer_name, 'customerPhone', o.customer_phone, 'orderType', o.order_type,
    'address', case when o.order_type = 'DELIVERY' then jsonb_build_object(
      'neighborhood', o.address_neighborhood, 'street', o.address_street,
      'house', o.address_house, 'reference', o.address_reference) else null end,
    'notes', coalesce(o.notes, ''), 'paymentMethod', o.payment_method,
    'subtotal', o.subtotal, 'deliveryFee', o.delivery_fee, 'total', o.total,
    'items', v_items,
    'createdAt', o.created_at,
    'acceptedAt', o.accepted_at, 'acceptedBy', (select full_name from employee_profiles where user_id = o.accepted_by),
    'startedAt', o.started_at, 'startedBy', (select full_name from employee_profiles where user_id = o.started_by),
    'readyAt', o.ready_at, 'readyBy', (select full_name from employee_profiles where user_id = o.ready_by),
    'outForDeliveryAt', o.out_for_delivery_at, 'outForDeliveryBy', (select full_name from employee_profiles where user_id = o.out_for_delivery_by),
    'completedAt', o.completed_at, 'completedBy', (select full_name from employee_profiles where user_id = o.completed_by),
    'rejectedAt', o.rejected_at, 'rejectedBy', (select full_name from employee_profiles where user_id = o.rejected_by),
    'rejectionReason', o.rejection_reason,
    'cancelledAt', o.cancelled_at, 'cancellationReason', o.cancellation_reason,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', h.id, 'fromStatus', h.from_status, 'toStatus', h.to_status, 'actorUserId', h.actor_user_id,
        'actorLabel', h.actor_label, 'reason', h.reason, 'createdAt', h.created_at) order by h.created_at)
      from public.order_status_history h where h.order_id = o.id), '[]'::jsonb)
  ) || v_schedule;
end;
$$;

create or replace function public.get_order_tracking(params jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  o public.orders;
  s public.restaurant_settings;
begin
  select ord.* into o
  from public.order_tracking_tokens t
  join public.orders ord on ord.id = t.order_id
  where t.token_hash = encode(extensions.digest(coalesce(params ->> 'token', ''), 'sha256'), 'hex')
    and t.revoked_at is null and t.expires_at > now();
  if not found then
    perform public._raise(404, 'NOT_FOUND', 'No encontramos este pedido. Revisa el enlace.');
  end if;
  select * into s from public.restaurant_settings where id = 1;

  return jsonb_build_object(
    'orderNumber', o.order_number, 'status', o.status, 'orderType', o.order_type,
    'customerFirstName', split_part(o.customer_name, ' ', 1),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'productName', i.product_name_snapshot, 'quantity', i.quantity, 'lineTotal', i.line_total,
        'options', coalesce((select jsonb_agg(io.value_name_snapshot) from public.order_item_options io where io.order_item_id = i.id), '[]'::jsonb)
      ) order by i.sort_order) from public.order_items i where i.order_id = o.id), '[]'::jsonb),
    'subtotal', o.subtotal, 'deliveryFee', o.delivery_fee, 'total', o.total,
    'paymentMethodLabel', coalesce((select m ->> 'label' from jsonb_array_elements(s.payment_methods) m where m ->> 'code' = o.payment_method), o.payment_method),
    'createdAt', o.created_at,
    'scheduledFor', o.scheduled_for,
    'canCancel', o.status = 'PENDING',
    'cancelledAt', o.cancelled_at,
    'cancellationReason', o.cancellation_reason,
    'timeline', coalesce((select jsonb_agg(jsonb_build_object('status', h.to_status, 'at', h.created_at) order by h.created_at)
                          from public.order_status_history h where h.order_id = o.id), '[]'::jsonb),
    'rejectionReason', o.rejection_reason,
    'restaurant', jsonb_build_object('name', s.name, 'phone', s.phone, 'address', s.address),
    'estimatedPrepMinutes', s.estimated_prep_minutes
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public._avg_prep_minutes(), public._pickup_min_lead(), public._pickup_slots(integer),
  public._send_pickup_reminders() from public, anon, authenticated;
revoke execute on function public.create_guest_order(jsonb), public.cancel_guest_order(jsonb),
  public.get_pickup_slots(jsonb) from public;
grant execute on function public.create_guest_order(jsonb), public.cancel_guest_order(jsonb),
  public.get_pickup_slots(jsonb), public.get_order_tracking(jsonb) to anon, authenticated;

notify pgrst, 'reload schema';

-- >>> 20261115000008_employee_admin.sql
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

-- >>> 20261115000009_push_notifications.sql
-- =============================================================================
-- Paco's · Notificaciones push (FCM) para el personal
--
-- Flujo: INSERT en order_events → trigger → pg_net llama (asíncrono, tras el commit)
-- a la Edge Function `push-dispatch` con { eventId } → la función reclama el evento
-- con `_push_claim_event` (una sola vez), arma el texto y envía por FCM a los
-- dispositivos de los roles que corresponden.
--
-- Configuración en Supabase Vault (ver README):
--   push_dispatch_url    URL de la Edge Function push-dispatch. Sin ella el trigger no hace nada.
--   fcm_service_account  JSON de la cuenta de servicio de Firebase (llave privada).
--
-- Destinatarios por evento:
--   order.created / order.reminder / order.cancelled / order.ready → ADMIN y MANAGER
--   order.accepted                                                 → CHEF
-- Se excluye a quien hizo el cambio (no se avisa a uno mismo).
-- =============================================================================

create extension if not exists supabase_vault with schema vault;
create extension if not exists pg_net with schema extensions;

alter table public.order_events add column push_sent_at timestamptz;
alter table public.device_tokens add column last_error text;
create index device_tokens_user_active_idx on public.device_tokens (user_id) where is_active;

-- ---------------------------------------------------------------------------
-- Trigger: avisar a la Edge Function
-- ---------------------------------------------------------------------------
create or replace function public._push_on_order_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
begin
  if new.event_type not in ('order.created', 'order.accepted', 'order.reminder', 'order.cancelled', 'order.ready') then
    return new;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_dispatch_url' limit 1;
  if v_url is null or v_url = '' then
    return new; -- push no configurado
  end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('eventId', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000);
  return new;
exception when others then
  -- Nunca bloquear un pedido por un problema de notificaciones.
  raise warning '[push] no se pudo encolar el evento %: %', new.id, sqlerrm;
  return new;
end;
$$;

create trigger order_events_push after insert on public.order_events
  for each row execute function public._push_on_order_event();

-- ---------------------------------------------------------------------------
-- Reclamar un evento (solo service_role): lo marca como enviado y devuelve
-- el resumen del pedido + los tokens destino. null si no existe o ya se envió.
-- Así, llamar a la función varias veces (o desde fuera) no duplica avisos.
-- ---------------------------------------------------------------------------
create or replace function public._push_claim_event(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  e public.order_events;
  o public.orders;
  v_roles public.app_role[];
  v_actor uuid;
  v_tokens jsonb;
begin
  update public.order_events set push_sent_at = now()
  where id = (params ->> 'event_id')::bigint and push_sent_at is null
  returning * into e;
  if not found then return null; end if;

  select * into o from public.orders where id = e.order_id;
  v_roles := case e.event_type
    when 'order.accepted' then array['CHEF']::public.app_role[]
    else array['ADMIN', 'MANAGER']::public.app_role[] end;

  -- Quién provocó el cambio (para no avisarle a sí mismo).
  select h.actor_user_id into v_actor from public.order_status_history h
  where h.order_id = o.id and h.to_status = e.status order by h.created_at desc limit 1;
  if e.event_type = 'order.reminder' then v_actor := null; end if;

  select coalesce(jsonb_agg(t.token), '[]'::jsonb) into v_tokens
  from public.device_tokens t
  join public.employee_profiles p on p.user_id = t.user_id and p.is_active
  join public.employee_roles r on r.user_id = t.user_id
  where t.is_active and r.role = any (v_roles) and t.user_id is distinct from v_actor;

  return jsonb_build_object(
    'eventType', e.event_type,
    'tokens', v_tokens,
    'order', jsonb_build_object(
      'id', o.id, 'orderNumber', o.order_number, 'status', o.status, 'orderType', o.order_type,
      'customerName', public._short_name(o.customer_name), 'total', o.total,
      'scheduledFor', o.scheduled_for,
      'reminderAt', case when o.scheduled_for is not null
                         then o.scheduled_for - make_interval(mins => public._avg_prep_minutes()) end,
      'cancellationReason', o.cancellation_reason,
      'itemCount', (select coalesce(sum(i.quantity), 0) from public.order_items i where i.order_id = o.id),
      'items', (select coalesce(string_agg(i.quantity || '× ' || i.product_name_snapshot, ', ' order by i.sort_order), '')
                from public.order_items i where i.order_id = o.id)));
end;
$$;

-- Tokens que FCM reporta como inválidos (app desinstalada, token rotado…).
create or replace function public._push_disable_tokens(params jsonb)
returns integer
language sql
volatile
security definer
set search_path = public
as $$
  with upd as (
    update public.device_tokens t set is_active = false, last_error = x.err
    from jsonb_to_recordset(coalesce(params -> 'tokens', '[]'::jsonb)) as x(token text, err text)
    where t.token = x.token
    returning 1)
  select count(*)::int from upd
$$;

-- Credencial de Firebase desde Vault (solo service_role, la usa la Edge Function).
create or replace function public._push_fcm_credentials()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'fcm_service_account' limit 1
$$;

-- ---------------------------------------------------------------------------
-- El dispositivo deja de recibir avisos al cerrar sesión.
-- ---------------------------------------------------------------------------
create or replace function public.unregister_device_token(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    perform public._raise(401, 'UNAUTHORIZED', 'Tu sesión expiró. Inicia sesión de nuevo.');
  end if;
  update public.device_tokens set is_active = false
  where token = params ->> 'token' and user_id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;

-- register_device_token: igual, pero limpia el error anterior al reactivar.
create or replace function public.register_device_token(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_token text := btrim(coalesce(params ->> 'token', ''));
begin
  perform public._require_role(array['ADMIN', 'MANAGER', 'CHEF']::public.app_role[]);
  if length(v_token) < 20 or length(v_token) > 4096 then
    perform public._raise(422, 'VALIDATION', 'Token de dispositivo inválido.');
  end if;
  insert into public.device_tokens (user_id, token, platform, device_label)
  values (auth.uid(), v_token, coalesce(params ->> 'platform', 'android'), left(params ->> 'label', 120))
  on conflict (token) do update set user_id = excluded.user_id, is_active = true, last_seen_at = now(),
    device_label = excluded.device_label, platform = excluded.platform, last_error = null;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public._push_on_order_event(), public._push_claim_event(jsonb),
  public._push_disable_tokens(jsonb), public._push_fcm_credentials() from public, anon, authenticated;
grant execute on function public._push_claim_event(jsonb), public._push_disable_tokens(jsonb),
  public._push_fcm_credentials() to service_role;
revoke execute on function public.unregister_device_token(jsonb), public.register_device_token(jsonb) from public, anon;
grant execute on function public.unregister_device_token(jsonb), public.register_device_token(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- >>> 20261115000010_delete_category.sql
-- =============================================================================
-- Paco's · Eliminar categorías del menú (solo ADMIN)
--
-- · Con platos activos: no se puede (hay que moverlos o eliminarlos primero).
-- · Vacía: se borra.
-- · Solo con platos ya eliminados (archivados, los conservan los pedidos
--   anteriores): se archiva la categoría (archived_at) y desaparece del menú.
-- =============================================================================

alter table public.categories add column archived_at timestamptz;

create or replace function public.admin_delete_category(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid := nullif(params ->> 'id', '')::uuid;
  c public.categories;
  v_active int;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  select * into c from public.categories where id = v_id and archived_at is null for update;
  if not found then
    perform public._raise(404, 'NOT_FOUND', 'Categoría no encontrada.');
  end if;

  select count(*) into v_active from public.products where category_id = v_id and archived_at is null;
  if v_active > 0 then
    perform public._raise(409, 'CATEGORY_NOT_EMPTY',
      'Esta categoría tiene ' || v_active || case when v_active = 1 then ' plato' else ' platos' end
        || '. Muévelos a otra categoría o elimínalos primero.',
      jsonb_build_object('productCount', v_active));
  end if;

  if exists (select 1 from public.products where category_id = v_id) then
    update public.categories set archived_at = now(), is_active = false where id = v_id;
  else
    delete from public.categories where id = v_id;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- El editor no ve categorías archivadas.
create or replace function public.admin_get_menu(params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  return jsonb_build_object(
    'categories', coalesce((select jsonb_agg(public._category_json(c) order by c.sort_order)
                            from public.categories c where c.archived_at is null), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(public._product_json(p) order by p.sort_order, p.name)
                          from public.products p where p.archived_at is null), '[]'::jsonb),
    'optionGroups', coalesce((select jsonb_agg(public._option_group_json(o.id) order by o.name)
                              from public.product_options o), '[]'::jsonb));
end;
$$;

-- Una categoría archivada no recibe platos ni se puede volver a mostrar.
create or replace function public._guard_archived_category()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'products' then
    if new.archived_at is null and exists (select 1 from public.categories where id = new.category_id and archived_at is not null) then
      perform public._raise(422, 'VALIDATION', 'Esa categoría fue eliminada. Elige otra.');
    end if;
  elsif old.archived_at is not null and new.is_active then
    perform public._raise(404, 'NOT_FOUND', 'Categoría no encontrada.');
  end if;
  return new;
end;
$$;

create trigger products_guard_archived_category before insert or update of category_id, archived_at on public.products
  for each row execute function public._guard_archived_category();
create trigger categories_guard_archived before update on public.categories
  for each row execute function public._guard_archived_category();

revoke execute on function public.admin_delete_category(jsonb), public._guard_archived_category() from public, anon;
revoke execute on function public._guard_archived_category() from authenticated;
grant execute on function public.admin_delete_category(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- >>> 20261115000011_sales_report.sql
-- =============================================================================
-- Paco's · Reporte de ventas del negocio (solo ADMIN)
--
-- report_sales({ from, to })  — rango [from, to) en ISO 8601 (la app lo arma en la
-- hora del restaurante). Un pedido pertenece al rango por su hora de creación.
-- Ventas = pedidos COMPLETED (entregados). Cancelados, rechazados y abiertos se
-- reportan aparte. Agrupaciones por día/hora en la zona horaria del restaurante.
-- Incluye el mismo resumen del periodo anterior de igual duración para comparar.
-- =============================================================================

create index if not exists orders_created_status_idx on public.orders (created_at, status);

create or replace function public._report_summary(p_from timestamptz, p_to timestamptz)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with o as (
    select * from public.orders where created_at >= p_from and created_at < p_to
  ), done as (
    select * from o where status = 'COMPLETED'
  )
  select jsonb_build_object(
    'orders', (select count(*) from done),
    'sales', (select coalesce(sum(total), 0) from done),
    'subtotal', (select coalesce(sum(subtotal), 0) from done),
    'deliveryFees', (select coalesce(sum(delivery_fee), 0) from done),
    'avgTicket', (select coalesce(round(avg(total), 2), 0) from done),
    'itemsSold', (select coalesce(sum(i.quantity), 0) from public.order_items i join done on done.id = i.order_id),
    'pickupOrders', (select count(*) from done where order_type = 'PICKUP'),
    'pickupSales', (select coalesce(sum(total), 0) from done where order_type = 'PICKUP'),
    'deliveryOrders', (select count(*) from done where order_type = 'DELIVERY'),
    'deliverySales', (select coalesce(sum(total), 0) from done where order_type = 'DELIVERY'),
    'scheduledOrders', (select count(*) from done where scheduled_for is not null),
    'customers', (select count(distinct customer_phone) from done),
    'returningCustomers', (select count(distinct d.customer_phone) from done d
                           where exists (select 1 from public.orders p where p.customer_phone = d.customer_phone
                                         and p.status = 'COMPLETED' and p.created_at < p_from)),
    'cancelledOrders', (select count(*) from o where status = 'CANCELLED'),
    'cancelledValue', (select coalesce(sum(total), 0) from o where status = 'CANCELLED'),
    'rejectedOrders', (select count(*) from o where status = 'REJECTED'),
    'rejectedValue', (select coalesce(sum(total), 0) from o where status = 'REJECTED'),
    'openOrders', (select count(*) from o where status not in ('COMPLETED', 'CANCELLED', 'REJECTED')),
    'openValue', (select coalesce(sum(total), 0) from o where status not in ('COMPLETED', 'CANCELLED', 'REJECTED'))
  )
$$;

create or replace function public.report_sales(params jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_tz text;
  v_len interval;
  s public.restaurant_settings;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  begin
    v_from := (params ->> 'from')::timestamptz;
    v_to := (params ->> 'to')::timestamptz;
  exception when others then
    perform public._raise(422, 'VALIDATION', 'Rango de fechas inválido.');
  end;
  if v_from is null or v_to is null or v_to <= v_from then
    perform public._raise(422, 'VALIDATION', 'La fecha final debe ser posterior a la inicial.');
  end if;
  if v_to - v_from > interval '400 days' then
    perform public._raise(422, 'VALIDATION', 'El rango máximo es de un año.');
  end if;

  select * into s from public.restaurant_settings where id = 1;
  v_tz := s.timezone;
  v_len := v_to - v_from;

  return jsonb_build_object(
    'range', jsonb_build_object('from', v_from, 'to', v_to, 'timezone', v_tz, 'generatedAt', now(),
                                'restaurant', s.name, 'currencySymbol', s.currency_symbol),
    'summary', public._report_summary(v_from, v_to),
    'previous', public._report_summary(v_from - v_len, v_from),

    -- Cierre de caja: lo cobrado por método de pago.
    'byPayment', coalesce((
      select jsonb_agg(jsonb_build_object('code', x.payment_method, 'label', x.label, 'orders', x.n, 'sales', x.sales) order by x.sales desc)
      from (
        select o.payment_method,
               coalesce((select m ->> 'label' from jsonb_array_elements(s.payment_methods) m where m ->> 'code' = o.payment_method), o.payment_method) as label,
               count(*) as n, sum(o.total) as sales
        from public.orders o
        where o.created_at >= v_from and o.created_at < v_to and o.status = 'COMPLETED'
        group by o.payment_method) x), '[]'::jsonb),

    -- Ventas por día (incluye días sin ventas).
    'byDay', coalesce((
      select jsonb_agg(jsonb_build_object('date', to_char(d.day, 'YYYY-MM-DD'), 'orders', coalesce(x.n, 0), 'sales', coalesce(x.sales, 0)) order by d.day)
      from generate_series((v_from at time zone v_tz)::date, ((v_to - interval '1 microsecond') at time zone v_tz)::date, interval '1 day') as d(day)
      left join (
        select (o.created_at at time zone v_tz)::date as day, count(*) as n, sum(o.total) as sales
        from public.orders o
        where o.created_at >= v_from and o.created_at < v_to and o.status = 'COMPLETED'
        group by 1) x on x.day = d.day::date), '[]'::jsonb),

    -- Ventas por hora del día (0–23).
    'byHour', coalesce((
      select jsonb_agg(jsonb_build_object('hour', h, 'orders', coalesce(x.n, 0), 'sales', coalesce(x.sales, 0)) order by h)
      from generate_series(0, 23) h
      left join (
        select extract(hour from o.created_at at time zone v_tz)::int as hour, count(*) as n, sum(o.total) as sales
        from public.orders o
        where o.created_at >= v_from and o.created_at < v_to and o.status = 'COMPLETED'
        group by 1) x on x.hour = h), '[]'::jsonb),

    -- Horas pico: día de la semana (0 = domingo) × hora.
    'heatmap', coalesce((
      select jsonb_agg(jsonb_build_object('weekday', x.wd, 'hour', x.hr, 'orders', x.n, 'sales', x.sales))
      from (
        select extract(dow from o.created_at at time zone v_tz)::int as wd, extract(hour from o.created_at at time zone v_tz)::int as hr,
               count(*) as n, sum(o.total) as sales
        from public.orders o
        where o.created_at >= v_from and o.created_at < v_to and o.status = 'COMPLETED'
        group by 1, 2) x), '[]'::jsonb),

    -- Productos (nombre del último pedido del rango, por si se renombró).
    'products', coalesce((
      select jsonb_agg(jsonb_build_object('name', x.name, 'category', x.category, 'quantity', x.qty, 'sales', x.sales, 'orders', x.n)
                       order by x.sales desc, x.qty desc)
      from (
        select (array_agg(i.product_name_snapshot order by o.created_at desc))[1] as name,
               coalesce(max(c.name), 'Sin categoría') as category,
               sum(i.quantity) as qty, sum(i.line_total) as sales, count(distinct o.id) as n
        from public.order_items i
        join public.orders o on o.id = i.order_id
        left join public.products p on p.id = i.product_id
        left join public.categories c on c.id = p.category_id
        where o.created_at >= v_from and o.created_at < v_to and o.status = 'COMPLETED'
        group by coalesce(i.product_id::text, i.product_name_snapshot)
        limit 200) x), '[]'::jsonb),

    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('name', x.name, 'quantity', x.qty, 'sales', x.sales) order by x.sales desc)
      from (
        select coalesce(c.name, 'Sin categoría') as name, sum(i.quantity) as qty, sum(i.line_total) as sales
        from public.order_items i
        join public.orders o on o.id = i.order_id
        left join public.products p on p.id = i.product_id
        left join public.categories c on c.id = p.category_id
        where o.created_at >= v_from and o.created_at < v_to and o.status = 'COMPLETED'
        group by 1) x), '[]'::jsonb),

    -- Extras y opciones: cuántas veces se eligieron y cuánto sumaron.
    'extras', coalesce((
      select jsonb_agg(jsonb_build_object('group', x.grp, 'name', x.val, 'times', x.times, 'sales', x.sales) order by x.sales desc, x.times desc)
      from (
        select io.option_name_snapshot as grp, io.value_name_snapshot as val,
               sum(i.quantity) as times, sum(io.price_delta_snapshot * i.quantity) as sales
        from public.order_item_options io
        join public.order_items i on i.id = io.order_item_id
        join public.orders o on o.id = i.order_id
        where o.created_at >= v_from and o.created_at < v_to and o.status = 'COMPLETED'
        group by 1, 2
        order by sales desc, times desc
        limit 100) x), '[]'::jsonb),

    -- Ventas que no se concretaron, por motivo.
    'losses', coalesce((
      select jsonb_agg(jsonb_build_object('type', x.status, 'reason', x.reason, 'orders', x.n, 'value', x.value) order by x.value desc)
      from (
        select o.status::text as status,
               coalesce(nullif(case when o.status = 'REJECTED' then o.rejection_reason else o.cancellation_reason end, ''), 'Sin motivo') as reason,
               count(*) as n, sum(o.total) as value
        from public.orders o
        where o.created_at >= v_from and o.created_at < v_to and o.status in ('REJECTED', 'CANCELLED')
        group by 1, 2) x), '[]'::jsonb),

    -- Pedidos a domicilio por colonia (dónde está la demanda).
    'neighborhoods', coalesce((
      select jsonb_agg(jsonb_build_object('name', x.name, 'orders', x.n, 'sales', x.sales) order by x.n desc, x.sales desc)
      from (
        select initcap(lower(btrim(o.address_neighborhood))) as name, count(*) as n, sum(o.total) as sales
        from public.orders o
        where o.created_at >= v_from and o.created_at < v_to and o.status = 'COMPLETED' and o.order_type = 'DELIVERY'
        group by 1
        order by n desc
        limit 30) x), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public._report_summary(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public.report_sales(jsonb) from public, anon;
grant execute on function public.report_sales(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- >>> 20261115000012_license.sql
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

-- >>> 20261115000013_business_hours.sql
-- =============================================================================
-- Paco's · Horario de atención editable desde la app (solo ADMIN)
--
-- update_business_hours({ hours: [{ weekday, isClosed, opensAt, closesAt }] })
--   weekday   0 = domingo … 6 = sábado (se pueden mandar solo los días que cambian)
--   opensAt / closesAt  'HH:MM' (24 h). Si cierra antes de abrir, cierra después de
--   medianoche (ej. 18:00 → 02:00), igual que ya lo interpreta _pickup_slots.
--
-- La web se entera al instante: se toca restaurant_settings, que ya está en Realtime.
-- =============================================================================

create or replace function public.update_business_hours(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_day int;
  v_closed boolean;
  v_open text;
  v_close text;
  v_names text[] := array['Domingo', 'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado'];
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);

  if jsonb_typeof(params -> 'hours') is distinct from 'array' or jsonb_array_length(params -> 'hours') = 0 then
    perform public._raise(400, 'VALIDATION_ERROR', 'Envía al menos un día.', jsonb_build_object('field', 'hours'));
  end if;

  for v_item in select * from jsonb_array_elements(params -> 'hours') loop
    v_day := case when (v_item ->> 'weekday') ~ '^[0-6]$' then (v_item ->> 'weekday')::int end;
    if v_day is null then
      perform public._raise(400, 'VALIDATION_ERROR', 'Día inválido.', jsonb_build_object('field', 'weekday'));
    end if;
    v_closed := coalesce((v_item ->> 'isClosed')::boolean, false);
    v_open := nullif(btrim(v_item ->> 'opensAt'), '');
    v_close := nullif(btrim(v_item ->> 'closesAt'), '');

    if not v_closed then
      if v_open is null or v_close is null
         or v_open !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or v_close !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
        perform public._raise(400, 'VALIDATION_ERROR',
          v_names[v_day + 1] || ': indica la hora de apertura y de cierre.', jsonb_build_object('field', 'hours', 'weekday', v_day));
      end if;
      if v_open = v_close then
        perform public._raise(400, 'VALIDATION_ERROR',
          v_names[v_day + 1] || ': la apertura y el cierre no pueden ser la misma hora.', jsonb_build_object('field', 'hours', 'weekday', v_day));
      end if;
    end if;

    insert into public.business_hours (weekday, label, opens_at, closes_at, is_closed)
    values (v_day, v_names[v_day + 1], v_open::time, v_close::time, v_closed)
    on conflict (weekday) do update set
      opens_at = coalesce(excluded.opens_at, business_hours.opens_at),   -- un día cerrado conserva su horario
      closes_at = coalesce(excluded.closes_at, business_hours.closes_at),
      is_closed = excluded.is_closed;
  end loop;

  -- Aviso en tiempo real a la web (escucha restaurant_settings).
  update public.restaurant_settings set updated_by = auth.uid() where id = 1;

  return public._settings_json(true);
end;
$$;

revoke execute on function public.update_business_hours(jsonb) from public, anon;
grant execute on function public.update_business_hours(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- >>> 20261115000014_delivery_flow.sql
-- =============================================================================
-- Paco's · Flujo de entrega correcto
--
-- Antes un pedido a domicilio podía pasar de READY directo a COMPLETED, y el cliente
-- nunca veía "En camino". Ahora:
--   Recoger:    … → READY (listo para recoger) → COMPLETED (lo recogió el cliente)
--   Domicilio:  … → READY (listo para enviar) → OUT_FOR_DELIVERY (en camino) → COMPLETED (entregado)
-- Cocina (CHEF) solo inicia y marca listo; entregar y "salió a entrega" son de ADMIN/MANAGER.
-- =============================================================================

-- Transición genérica: UPDATE condicional por estado esperado + historial en la misma transacción.
create or replace function public._transition(p_order_id uuid, p_action text, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_from public.order_status[];
  v_to public.order_status;
  v_roles public.app_role[];
  v_role public.app_role;
  v_prev public.order_status;
  v_reason text := nullif(public._clean(p_reason, 200), '');
  o public.orders;
  v_actor text;
begin
  case p_action
    when 'accept' then v_from := '{PENDING}'; v_to := 'ACCEPTED'; v_roles := '{ADMIN,MANAGER}';
    when 'reject' then v_from := '{PENDING}'; v_to := 'REJECTED'; v_roles := '{ADMIN,MANAGER}';
    when 'start' then v_from := '{ACCEPTED}'; v_to := 'PREPARING'; v_roles := '{ADMIN,MANAGER,CHEF}';
    when 'ready' then v_from := '{PREPARING}'; v_to := 'READY'; v_roles := '{ADMIN,MANAGER,CHEF}';
    when 'dispatch' then v_from := '{READY}'; v_to := 'OUT_FOR_DELIVERY'; v_roles := '{ADMIN,MANAGER}';
    when 'complete' then v_from := '{READY,OUT_FOR_DELIVERY}'; v_to := 'COMPLETED'; v_roles := '{ADMIN,MANAGER}';
    else perform public._raise(400, 'VALIDATION', 'Acción desconocida.');
  end case;

  v_role := public._require_role(v_roles);
  if p_action = 'reject' and coalesce(length(v_reason), 0) < 3 then
    perform public._raise(422, 'VALIDATION', 'Indica el motivo del rechazo.');
  end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then
    perform public._raise(404, 'NOT_FOUND', 'Pedido no encontrado.');
  end if;
  if not (o.status = any (v_from)) then
    perform public._raise(409, 'CONFLICT', 'El pedido ya está en estado ' || o.status || '.',
      jsonb_build_object('currentStatus', o.status));
  end if;
  if p_action = 'complete' and o.order_type = 'DELIVERY' and o.status <> 'OUT_FOR_DELIVERY' then
    perform public._raise(409, 'CONFLICT', 'Marca primero que el pedido salió a entrega (En camino).',
      jsonb_build_object('currentStatus', o.status));
  end if;
  if p_action = 'complete' and o.order_type = 'PICKUP' and o.status <> 'READY' then
    perform public._raise(409, 'CONFLICT', 'El pedido aún no está listo para recoger.', jsonb_build_object('currentStatus', o.status));
  end if;
  if p_action = 'dispatch' and o.order_type <> 'DELIVERY' then
    perform public._raise(409, 'CONFLICT', 'Solo los pedidos a domicilio salen a entrega.');
  end if;

  v_prev := o.status;
  update public.orders set
    status = v_to,
    accepted_at = case when p_action = 'accept' then now() else accepted_at end,
    accepted_by = case when p_action = 'accept' then auth.uid() else accepted_by end,
    rejected_at = case when p_action = 'reject' then now() else rejected_at end,
    rejected_by = case when p_action = 'reject' then auth.uid() else rejected_by end,
    rejection_reason = case when p_action = 'reject' then v_reason else rejection_reason end,
    started_at = case when p_action = 'start' then now() else started_at end,
    started_by = case when p_action = 'start' then auth.uid() else started_by end,
    ready_at = case when p_action = 'ready' then now() else ready_at end,
    ready_by = case when p_action = 'ready' then auth.uid() else ready_by end,
    out_for_delivery_at = case when p_action = 'dispatch' then now() else out_for_delivery_at end,
    out_for_delivery_by = case when p_action = 'dispatch' then auth.uid() else out_for_delivery_by end,
    completed_at = case when p_action = 'complete' then now() else completed_at end,
    completed_by = case when p_action = 'complete' then auth.uid() else completed_by end
  where id = p_order_id and status = v_prev
  returning * into o;

  select full_name into v_actor from public.employee_profiles where user_id = auth.uid();
  insert into public.order_status_history (order_id, from_status, to_status, actor_user_id, actor_label, reason)
  values (o.id, v_prev, v_to, auth.uid(), coalesce(v_actor, 'Empleado'), v_reason);

  return public._order_json(o, v_role);
end;
$$;

notify pgrst, 'reload schema';

-- >>> 20261115000015_order_number_8_digits.sql
-- =============================================================================
-- Paco's · Número de pedido de 8 dígitos: R-00001424 (antes R-001424)
--
-- Capacidad: 99,999,999 pedidos (antes 999,999). Además corrige un riesgo: lpad()
-- RECORTA el texto si el número es más largo, así que con 6 dígitos el pedido
-- 1,000,000 habría generado un número repetido. Ahora, si algún día se superan los
-- 8 dígitos, el número simplemente crece (R-100000000) en lugar de recortarse.
--
-- Los pedidos anteriores conservan su número; la secuencia continúa igual.
-- Se redefine el núcleo del carrito (_create_guest_order_core, ver migración 7):
-- es la misma lógica de 20261114000006_menu_builder.sql con este único cambio.
-- =============================================================================

create or replace function public._next_order_number()
returns text
language sql
volatile
security definer
set search_path = public
as $$
  select 'R-' || case when n < 100000000 then lpad(n::text, 8, '0') else n::text end
  from (select nextval('public.order_number_seq') as n) s
$$;
revoke execute on function public._next_order_number() from public, anon, authenticated;

create or replace function public._create_guest_order_core(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  s public.restaurant_settings;
  v_key text := btrim(coalesce(params ->> 'idempotencyKey', ''));
  v_fingerprint text := md5((params - 'idempotencyKey')::text);
  v_existing public.orders;
  v_errors jsonb := '{}'::jsonb;
  v_line_errors jsonb := '[]'::jsonb;
  v_name text := public._clean(params #>> '{customer,name}', 60);
  v_phone text := public._normalize_hn_phone(params #>> '{customer,phone}');
  v_type text := params ->> 'orderType';
  v_payment text := params ->> 'paymentMethod';
  v_neigh text; v_street text; v_house text; v_ref text;
  v_items jsonb := coalesce(params -> 'items', '[]'::jsonb);
  v_item jsonb;
  v_idx int := 0;
  v_product public.products;
  v_qty int;
  v_selected uuid[];
  v_unit numeric(10, 2);
  v_group record;
  v_count int;
  v_lines jsonb := '[]'::jsonb;
  v_subtotal numeric(10, 2) := 0;
  v_fee numeric(10, 2) := 0;
  v_order_id uuid;
  v_item_id uuid;
  v_line jsonb;
  v_opt jsonb;
  v_number text;
  v_token text;
begin
  if length(v_key) < 8 then
    perform public._raise(400, 'VALIDATION', 'Falta la clave de idempotencia.');
  end if;

  -- Reintento idempotente: devuelve el mismo pedido (con un token nuevo, el anterior se conserva).
  select * into v_existing from public.orders where idempotency_key = v_key;
  if found then
    if v_existing.idempotency_fingerprint <> v_fingerprint then
      perform public._raise(409, 'IDEMPOTENCY_MISMATCH', 'Esta solicitud ya fue usada con otros datos.');
    end if;
    return jsonb_build_object('orderNumber', v_existing.order_number, 'trackingToken', public._new_tracking_token(v_existing.id),
      'total', v_existing.total, 'status', v_existing.status, 'replayed', true);
  end if;

  select * into s from public.restaurant_settings where id = 1;
  if not s.is_open then
    perform public._raise(409, 'RESTAURANT_CLOSED', 'El restaurante no está recibiendo pedidos en este momento.');
  end if;

  if length(v_name) < 2 then v_errors := v_errors || '{"name":"Ingresa tu nombre."}'; end if;
  if v_phone is null then v_errors := v_errors || '{"phone":"Ingresa un teléfono válido de Honduras (8 dígitos)."}'; end if;
  if v_type is null or v_type not in ('PICKUP', 'DELIVERY') then
    v_errors := v_errors || '{"orderType":"Selecciona cómo quieres recibir tu pedido."}';
  elsif v_type = 'PICKUP' and not s.pickup_enabled then
    v_errors := v_errors || '{"orderType":"La recogida en local no está disponible."}';
  elsif v_type = 'DELIVERY' and not s.delivery_enabled then
    v_errors := v_errors || '{"orderType":"La entrega a domicilio no está disponible."}';
  end if;

  if v_type = 'DELIVERY' then
    v_neigh := public._clean(params #>> '{address,neighborhood}', 80);
    v_street := public._clean(params #>> '{address,street}', 120);
    v_house := public._clean(params #>> '{address,house}', 80);
    v_ref := public._clean(params #>> '{address,reference}', 160);
    if length(v_neigh) < 3 then v_errors := v_errors || '{"neighborhood":"Indica la colonia o barrio."}'; end if;
    if length(v_street) < 3 then v_errors := v_errors || '{"street":"Indica la calle o avenida."}'; end if;
    if length(v_ref) < 3 then v_errors := v_errors || '{"reference":"Agrega una referencia para encontrarte."}'; end if;
    v_fee := s.delivery_fee;
  end if;

  if not exists (select 1 from jsonb_array_elements(s.payment_methods) m where m ->> 'code' = v_payment) then
    v_errors := v_errors || '{"paymentMethod":"Selecciona un método de pago."}';
  end if;

  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    v_errors := v_errors || '{"items":"Tu carrito está vacío."}';
  elsif jsonb_array_length(v_items) > 30 then
    v_errors := v_errors || '{"items":"Demasiados productos en un solo pedido."}';
  else
    -- Recalcular TODO desde la base de datos; los precios del cliente se ignoran.
    for v_item in select value from jsonb_array_elements(v_items) loop
      begin
        select p.* into v_product
        from public.products p join public.categories c on c.id = p.category_id and c.is_active
        where p.id = (v_item ->> 'productId')::uuid and p.archived_at is null;
      exception when invalid_text_representation then
        v_product := null;
      end;

      if v_product.id is null then
        v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'message', 'Este producto ya no está en el menú.');
      elsif not v_product.is_available then
        v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', v_product.name || ' está agotado.');
      else
        v_qty := coalesce((v_item ->> 'quantity')::int, 0);
        select coalesce(array_agg(x::uuid), '{}') into v_selected
        from jsonb_array_elements_text(coalesce(v_item -> 'optionValueIds', '[]'::jsonb)) x;

        if v_qty < 1 or v_qty > 20 then
          v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Cantidad inválida (1 a 20).');
        elsif exists (
          select 1 from unnest(v_selected) sel
          where not exists (select 1 from public.product_option_values v join public.product_option_links l on l.option_id = v.option_id
                            where v.id = sel and l.product_id = v_product.id)
        ) then
          v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Opción inválida para ' || v_product.name || '.');
        else
          v_unit := v_product.price;
          v_line := jsonb_build_object('productId', v_product.id, 'productName', v_product.name, 'quantity', v_qty,
                                       'notes', public._clean(v_item ->> 'notes', 140), 'options', '[]'::jsonb);
          for v_group in select o.* from public.product_options o join public.product_option_links l on l.option_id = o.id
                         where l.product_id = v_product.id order by l.sort_order loop
            select count(*) into v_count from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected);
            if exists (select 1 from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected) and not v.is_available) then
              v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Una opción de ' || v_product.name || ' ya no está disponible.');
              v_line := null;
              exit;
            end if;
            if v_count < (case when v_group.is_required then greatest(1, v_group.min_select) else v_group.min_select end)
               or v_count > v_group.max_select then
              v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Revisa "' || v_group.name || '" en ' || v_product.name || '.');
              v_line := null;
              exit;
            end if;
            select v_unit + coalesce(sum(v.price_delta), 0),
                   v_line -> 'options' || coalesce(jsonb_agg(jsonb_build_object('optionName', v_group.name, 'valueName', v.label, 'priceDelta', v.price_delta) order by v.sort_order), '[]'::jsonb)
              into v_unit, v_opt
            from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected);
            v_line := jsonb_set(v_line, '{options}', v_opt);
          end loop;

          if v_line is not null then
            v_line := v_line || jsonb_build_object('unitPrice', v_unit, 'lineTotal', v_unit * v_qty);
            v_lines := v_lines || v_line;
            v_subtotal := v_subtotal + v_unit * v_qty;
          end if;
        end if;
      end if;
      v_idx := v_idx + 1;
    end loop;
  end if;

  if v_errors <> '{}'::jsonb or jsonb_array_length(v_line_errors) > 0 then
    perform public._raise(422, 'VALIDATION', 'Revisa los datos de tu pedido.',
      jsonb_build_object('fields', v_errors, 'lines', v_line_errors));
  end if;

  -- Inserción atómica (toda la función corre en una transacción).
  v_number := public._next_order_number();
  insert into public.orders (order_number, customer_name, customer_phone, order_type,
    address_neighborhood, address_street, address_house, address_reference, notes, payment_method,
    subtotal, delivery_fee, total, idempotency_key, idempotency_fingerprint)
  values (v_number, v_name, v_phone, v_type::public.order_type,
    v_neigh, v_street, nullif(v_house, ''), v_ref, public._clean(params ->> 'notes', 200), v_payment,
    v_subtotal, v_fee, v_subtotal + v_fee, v_key, v_fingerprint)
  returning id into v_order_id;

  v_idx := 0;
  for v_line in select value from jsonb_array_elements(v_lines) loop
    insert into public.order_items (order_id, product_id, product_name_snapshot, unit_price_snapshot, quantity, notes, line_total, sort_order)
    values (v_order_id, (v_line ->> 'productId')::uuid, v_line ->> 'productName', (v_line ->> 'unitPrice')::numeric,
            (v_line ->> 'quantity')::int, nullif(v_line ->> 'notes', ''), (v_line ->> 'lineTotal')::numeric, v_idx)
    returning id into v_item_id;
    insert into public.order_item_options (order_item_id, option_name_snapshot, value_name_snapshot, price_delta_snapshot)
    select v_item_id, o ->> 'optionName', o ->> 'valueName', (o ->> 'priceDelta')::numeric
    from jsonb_array_elements(v_line -> 'options') o;
    v_idx := v_idx + 1;
  end loop;

  insert into public.order_status_history (order_id, from_status, to_status, actor_label)
  values (v_order_id, null, 'PENDING', 'Cliente (web)');

  v_token := public._new_tracking_token(v_order_id);
  return jsonb_build_object('orderNumber', v_number, 'trackingToken', v_token,
    'total', v_subtotal + v_fee, 'status', 'PENDING', 'replayed', false);
end;
$$;

revoke execute on function public._create_guest_order_core(jsonb) from public, anon, authenticated;

notify pgrst, 'reload schema';

-- >>> 20261115000016_auto_close.sql
-- =============================================================================
-- Paco's · Cierre automático de pedidos en línea según el horario de atención
--
-- Cada minuto (pg_cron) se revisa si ya pasó la hora de cierre del día. Si es así,
-- se apaga "Recibir pedidos en línea" (restaurant_settings.is_open = false):
-- la web deja de aceptar pedidos y la app ve el interruptor apagado en tiempo real.
--
-- Solo CIERRA; abrir sigue siendo manual. Se cierra una sola vez por cada horario:
-- si después del cierre alguien vuelve a abrir a mano (p. ej. un evento especial),
-- no se vuelve a cerrar hasta el cierre del siguiente día.
-- Horarios que cruzan medianoche (18:00 → 02:00) cierran a las 02:00 del día siguiente.
-- =============================================================================

alter table public.restaurant_settings
  add column if not exists last_auto_close_at timestamptz;

comment on column public.restaurant_settings.last_auto_close_at is
  'Último cierre programado ya aplicado (para no cerrar dos veces el mismo horario).';

-- Último cierre programado que ya llegó (de ayer o de hoy, hora del restaurante), o null.
create or replace function public._last_scheduled_close(p_now timestamptz default now())
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select max(c.close_at)
  from public.restaurant_settings s
  cross join generate_series(-1, 0) d
  cross join lateral (select ((p_now at time zone s.timezone)::date + d) as local_date) ld
  join public.business_hours h
    on h.weekday = extract(dow from ld.local_date)
   and not h.is_closed and h.opens_at is not null and h.closes_at is not null
  cross join lateral (
    select ((ld.local_date + h.closes_at
             + case when h.closes_at <= h.opens_at then interval '1 day' else interval '0' end)
            at time zone s.timezone) as close_at) c
  where s.id = 1
    and c.close_at <= p_now
    and c.close_at > p_now - interval '12 hours'  -- si el cron estuvo caído mucho tiempo, no cerrar tarde
$$;

create or replace function public._auto_close_orders()
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_close timestamptz := public._last_scheduled_close();
begin
  if v_close is null then
    return;
  end if;
  -- Un solo cierre por horario: si ya se aplicó este cierre, no hacer nada.
  update public.restaurant_settings
     set is_open = false,
         last_auto_close_at = v_close
   where id = 1
     and (last_auto_close_at is null or last_auto_close_at < v_close)
     and is_open;
  -- Si ya estaba cerrado, solo se marca el cierre como aplicado (sin disparar cambios).
  update public.restaurant_settings
     set last_auto_close_at = v_close
   where id = 1
     and (last_auto_close_at is null or last_auto_close_at < v_close)
     and not is_open;
end;
$$;

revoke execute on function public._last_scheduled_close(timestamptz), public._auto_close_orders()
  from public, anon, authenticated;

-- Al instalarlo no cerrar "en retroactivo": el cierre de hoy que ya pasó se da por aplicado.
update public.restaurant_settings set last_auto_close_at = public._last_scheduled_close() where id = 1;

select cron.schedule('pacos-auto-close', '* * * * *', 'select public._auto_close_orders()');

-- >>> 20261118000017_dine_in_type.sql
-- =============================================================================
-- Paco's · Nueva modalidad de pedido: DINE_IN ("Comer aquí")
--
-- Va sola en su migración: PostgreSQL no permite usar un valor nuevo de un enum
-- en la misma transacción en que se agrega. La lógica que lo usa está en la 18.
-- =============================================================================

alter type public.order_type add value if not exists 'DINE_IN';

-- >>> 20261118000018_counter_orders.sql
-- =============================================================================
-- Paco's · Pedidos en el local (mostrador), creados desde la app por ADMIN/MANAGER
--
-- create_counter_order({ idempotencyKey, orderType: 'PICKUP' | 'DINE_IN',
--   customer?: { name?, phone? }, paymentMethod, notes?, items: [...] })
--   - Para llevar (PICKUP) o Comer aquí (DINE_IN). Nombre y teléfono opcionales
--     (sin nombre → "Cliente en local").
--   - Entra ya ACEPTADO: aparece de inmediato en Cocina (push "Nuevo en cocina" al
--     cocinero) y no suena la alarma de "pedido por aprobar".
--   - Funciona aunque "Recibir pedidos en línea" esté apagado (eso es solo para la web).
--   - Precios y opciones se recalculan en el servidor con la MISMA lógica que la web
--     (_price_order_items).
-- orders.channel: 'WEB' (cliente en línea) | 'COUNTER' (tomado en el local).
-- =============================================================================

alter table public.orders
  add column if not exists channel text not null default 'WEB' check (channel in ('WEB', 'COUNTER')),
  add column if not exists created_by uuid references auth.users (id);

-- Teléfono opcional en pedidos del local (la web lo sigue exigiendo en su validación).
alter table public.orders alter column customer_phone drop not null;

-- La dirección solo es obligatoria a domicilio (antes: todo lo que no fuera PICKUP).
alter table public.orders drop constraint if exists orders_check;
alter table public.orders add constraint orders_delivery_address_chk
  check (order_type <> 'DELIVERY' or address_neighborhood is not null);

-- -----------------------------------------------------------------------------
-- Eventos: un pedido que nace ya aceptado se anuncia como "order.accepted"
-- (cocina recibe el aviso; administración no recibe la alarma de "por aprobar").
-- -----------------------------------------------------------------------------
create or replace function public._emit_order_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_events (order_id, order_number, status, event_type)
    values (new.id, new.order_number, new.status, 'order.' ||
      case when tg_op = 'INSERT' and new.status = 'PENDING' then 'created' else lower(new.status::text) end);
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Cálculo de líneas compartido (misma lógica que _create_guest_order_core).
-- Devuelve { lines, subtotal, lineErrors }.
-- -----------------------------------------------------------------------------
create or replace function public._price_order_items(p_items jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_items jsonb := coalesce(p_items, '[]'::jsonb);
  v_line_errors jsonb := '[]'::jsonb;
  v_item jsonb;
  v_idx int := 0;
  v_product public.products;
  v_qty int;
  v_selected uuid[];
  v_unit numeric(10, 2);
  v_group record;
  v_count int;
  v_lines jsonb := '[]'::jsonb;
  v_subtotal numeric(10, 2) := 0;
  v_line jsonb;
  v_opt jsonb;
begin
  for v_item in select value from jsonb_array_elements(v_items) loop
    begin
      select p.* into v_product
      from public.products p join public.categories c on c.id = p.category_id and c.is_active
      where p.id = (v_item ->> 'productId')::uuid and p.archived_at is null;
    exception when invalid_text_representation then
      v_product := null;
    end;

    if v_product.id is null then
      v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'message', 'Este producto ya no está en el menú.');
    elsif not v_product.is_available then
      v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', v_product.name || ' está agotado.');
    else
      v_qty := coalesce((v_item ->> 'quantity')::int, 0);
      select coalesce(array_agg(x::uuid), '{}') into v_selected
      from jsonb_array_elements_text(coalesce(v_item -> 'optionValueIds', '[]'::jsonb)) x;

      if v_qty < 1 or v_qty > 20 then
        v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Cantidad inválida (1 a 20).');
      elsif exists (
        select 1 from unnest(v_selected) sel
        where not exists (select 1 from public.product_option_values v join public.product_option_links l on l.option_id = v.option_id
                          where v.id = sel and l.product_id = v_product.id)
      ) then
        v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Opción inválida para ' || v_product.name || '.');
      else
        v_unit := v_product.price;
        v_line := jsonb_build_object('productId', v_product.id, 'productName', v_product.name, 'quantity', v_qty,
                                     'notes', public._clean(v_item ->> 'notes', 140), 'options', '[]'::jsonb);
        for v_group in select o.* from public.product_options o join public.product_option_links l on l.option_id = o.id
                       where l.product_id = v_product.id order by l.sort_order loop
          select count(*) into v_count from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected);
          if exists (select 1 from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected) and not v.is_available) then
            v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Una opción de ' || v_product.name || ' ya no está disponible.');
            v_line := null;
            exit;
          end if;
          if v_count < (case when v_group.is_required then greatest(1, v_group.min_select) else v_group.min_select end)
             or v_count > v_group.max_select then
            v_line_errors := v_line_errors || jsonb_build_object('index', v_idx, 'productId', v_product.id, 'message', 'Revisa "' || v_group.name || '" en ' || v_product.name || '.');
            v_line := null;
            exit;
          end if;
          select v_unit + coalesce(sum(v.price_delta), 0),
                 v_line -> 'options' || coalesce(jsonb_agg(jsonb_build_object('optionName', v_group.name, 'valueName', v.label, 'priceDelta', v.price_delta) order by v.sort_order), '[]'::jsonb)
            into v_unit, v_opt
          from public.product_option_values v where v.option_id = v_group.id and v.id = any (v_selected);
          v_line := jsonb_set(v_line, '{options}', v_opt);
        end loop;

        if v_line is not null then
          v_line := v_line || jsonb_build_object('unitPrice', v_unit, 'lineTotal', v_unit * v_qty);
          v_lines := v_lines || v_line;
          v_subtotal := v_subtotal + v_unit * v_qty;
        end if;
      end if;
    end if;
    v_idx := v_idx + 1;
  end loop;
  return jsonb_build_object('lines', v_lines, 'subtotal', v_subtotal, 'lineErrors', v_line_errors);
end;
$$;

-- -----------------------------------------------------------------------------
-- Pedido en el local
-- -----------------------------------------------------------------------------
create or replace function public.create_counter_order(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_role public.app_role := public._require_role(array['ADMIN', 'MANAGER']::public.app_role[]);
  s public.restaurant_settings;
  v_key text := btrim(coalesce(params ->> 'idempotencyKey', ''));
  v_fingerprint text := md5((params - 'idempotencyKey')::text);
  v_existing public.orders;
  v_errors jsonb := '{}'::jsonb;
  v_name text := public._clean(params #>> '{customer,name}', 60);
  v_phone_raw text := btrim(coalesce(params #>> '{customer,phone}', ''));
  v_phone text;
  v_type text := params ->> 'orderType';
  v_payment text := params ->> 'paymentMethod';
  v_items jsonb := coalesce(params -> 'items', '[]'::jsonb);
  v_priced jsonb;
  v_subtotal numeric(10, 2);
  v_order public.orders;
  v_item_id uuid;
  v_line jsonb;
  v_idx int := 0;
  v_actor text;
begin
  if length(v_key) < 8 then
    perform public._raise(400, 'VALIDATION', 'Falta la clave de idempotencia.');
  end if;
  select * into v_existing from public.orders where idempotency_key = v_key;
  if found then
    if v_existing.idempotency_fingerprint <> v_fingerprint then
      perform public._raise(409, 'IDEMPOTENCY_MISMATCH', 'Esta solicitud ya fue usada con otros datos.');
    end if;
    return public._order_json(v_existing, v_role) || jsonb_build_object('replayed', true);
  end if;

  select * into s from public.restaurant_settings where id = 1;

  if v_type is null or v_type not in ('PICKUP', 'DINE_IN') then
    v_errors := v_errors || '{"orderType":"Elige si es para llevar o para comer aquí."}';
  end if;
  if coalesce(length(v_name), 0) < 2 then
    v_name := 'Cliente en local';
  end if;
  if v_phone_raw <> '' then
    v_phone := public._normalize_hn_phone(v_phone_raw);
    if v_phone is null then
      v_errors := v_errors || '{"phone":"Teléfono inválido (8 dígitos de Honduras) o déjalo vacío."}';
    end if;
  end if;
  if not exists (select 1 from jsonb_array_elements(s.payment_methods) m where m ->> 'code' = v_payment) then
    v_errors := v_errors || '{"paymentMethod":"Selecciona un método de pago."}';
  end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    v_errors := v_errors || '{"items":"Agrega al menos un plato."}';
  elsif jsonb_array_length(v_items) > 30 then
    v_errors := v_errors || '{"items":"Demasiados productos en un solo pedido."}';
  end if;

  if v_errors = '{}'::jsonb then
    v_priced := public._price_order_items(v_items);
  end if;
  if v_errors <> '{}'::jsonb or jsonb_array_length(v_priced -> 'lineErrors') > 0 then
    perform public._raise(422, 'VALIDATION', 'Revisa los datos del pedido.',
      jsonb_build_object('fields', v_errors, 'lines', coalesce(v_priced -> 'lineErrors', '[]'::jsonb)));
  end if;
  v_subtotal := (v_priced ->> 'subtotal')::numeric;

  insert into public.orders (order_number, status, customer_name, customer_phone, order_type, notes, payment_method,
    subtotal, delivery_fee, total, idempotency_key, idempotency_fingerprint,
    channel, created_by, accepted_at, accepted_by)
  values (public._next_order_number(), 'ACCEPTED', v_name, v_phone, v_type::public.order_type,
    public._clean(params ->> 'notes', 200), v_payment, v_subtotal, 0, v_subtotal, v_key, v_fingerprint,
    'COUNTER', auth.uid(), now(), auth.uid())
  returning * into v_order;

  for v_line in select value from jsonb_array_elements(v_priced -> 'lines') loop
    insert into public.order_items (order_id, product_id, product_name_snapshot, unit_price_snapshot, quantity, notes, line_total, sort_order)
    values (v_order.id, (v_line ->> 'productId')::uuid, v_line ->> 'productName', (v_line ->> 'unitPrice')::numeric,
            (v_line ->> 'quantity')::int, nullif(v_line ->> 'notes', ''), (v_line ->> 'lineTotal')::numeric, v_idx)
    returning id into v_item_id;
    insert into public.order_item_options (order_item_id, option_name_snapshot, value_name_snapshot, price_delta_snapshot)
    select v_item_id, o ->> 'optionName', o ->> 'valueName', (o ->> 'priceDelta')::numeric
    from jsonb_array_elements(v_line -> 'options') o;
    v_idx := v_idx + 1;
  end loop;

  select full_name into v_actor from public.employee_profiles where user_id = auth.uid();
  insert into public.order_status_history (order_id, from_status, to_status, actor_user_id, actor_label, reason)
  values (v_order.id, null, 'ACCEPTED', auth.uid(), coalesce(v_actor, 'Empleado'), 'Pedido tomado en el local');

  return public._order_json(v_order, v_role) || jsonb_build_object('replayed', false);
end;
$$;

revoke execute on function public._price_order_items(jsonb) from public, anon, authenticated;
revoke execute on function public.create_counter_order(jsonb) from public, anon;
grant execute on function public.create_counter_order(jsonb) to authenticated;

-- -----------------------------------------------------------------------------
-- Pedido JSON (app): agrega origen y quién lo tomó.
-- -----------------------------------------------------------------------------
alter function public._order_json(public.orders, public.app_role) rename to _order_json_base;
revoke execute on function public._order_json_base(public.orders, public.app_role) from public, anon, authenticated;

create or replace function public._order_json(o public.orders, p_role public.app_role)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public._order_json_base(o, p_role) || jsonb_build_object(
    'channel', o.channel,
    'createdBy', (select full_name from public.employee_profiles where user_id = o.created_by))
$$;
revoke execute on function public._order_json(public.orders, public.app_role) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Transiciones: "Comer aquí" se entrega desde Listo, igual que recoger.
-- -----------------------------------------------------------------------------
create or replace function public._transition(p_order_id uuid, p_action text, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_from public.order_status[];
  v_to public.order_status;
  v_roles public.app_role[];
  v_role public.app_role;
  v_prev public.order_status;
  v_reason text := nullif(public._clean(p_reason, 200), '');
  o public.orders;
  v_actor text;
begin
  case p_action
    when 'accept' then v_from := '{PENDING}'; v_to := 'ACCEPTED'; v_roles := '{ADMIN,MANAGER}';
    when 'reject' then v_from := '{PENDING}'; v_to := 'REJECTED'; v_roles := '{ADMIN,MANAGER}';
    when 'start' then v_from := '{ACCEPTED}'; v_to := 'PREPARING'; v_roles := '{ADMIN,MANAGER,CHEF}';
    when 'ready' then v_from := '{PREPARING}'; v_to := 'READY'; v_roles := '{ADMIN,MANAGER,CHEF}';
    when 'dispatch' then v_from := '{READY}'; v_to := 'OUT_FOR_DELIVERY'; v_roles := '{ADMIN,MANAGER}';
    when 'complete' then v_from := '{READY,OUT_FOR_DELIVERY}'; v_to := 'COMPLETED'; v_roles := '{ADMIN,MANAGER}';
    else perform public._raise(400, 'VALIDATION', 'Acción desconocida.');
  end case;

  v_role := public._require_role(v_roles);
  if p_action = 'reject' and coalesce(length(v_reason), 0) < 3 then
    perform public._raise(422, 'VALIDATION', 'Indica el motivo del rechazo.');
  end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then
    perform public._raise(404, 'NOT_FOUND', 'Pedido no encontrado.');
  end if;
  if not (o.status = any (v_from)) then
    perform public._raise(409, 'CONFLICT', 'El pedido ya está en estado ' || o.status || '.',
      jsonb_build_object('currentStatus', o.status));
  end if;
  if p_action = 'complete' and o.order_type = 'DELIVERY' and o.status <> 'OUT_FOR_DELIVERY' then
    perform public._raise(409, 'CONFLICT', 'Marca primero que el pedido salió a entrega (En camino).',
      jsonb_build_object('currentStatus', o.status));
  end if;
  if p_action = 'complete' and o.order_type <> 'DELIVERY' and o.status <> 'READY' then
    perform public._raise(409, 'CONFLICT', 'El pedido aún no está listo.', jsonb_build_object('currentStatus', o.status));
  end if;
  if p_action = 'dispatch' and o.order_type <> 'DELIVERY' then
    perform public._raise(409, 'CONFLICT', 'Solo los pedidos a domicilio salen a entrega.');
  end if;

  v_prev := o.status;
  update public.orders set
    status = v_to,
    accepted_at = case when p_action = 'accept' then now() else accepted_at end,
    accepted_by = case when p_action = 'accept' then auth.uid() else accepted_by end,
    rejected_at = case when p_action = 'reject' then now() else rejected_at end,
    rejected_by = case when p_action = 'reject' then auth.uid() else rejected_by end,
    rejection_reason = case when p_action = 'reject' then v_reason else rejection_reason end,
    started_at = case when p_action = 'start' then now() else started_at end,
    started_by = case when p_action = 'start' then auth.uid() else started_by end,
    ready_at = case when p_action = 'ready' then now() else ready_at end,
    ready_by = case when p_action = 'ready' then auth.uid() else ready_by end,
    out_for_delivery_at = case when p_action = 'dispatch' then now() else out_for_delivery_at end,
    out_for_delivery_by = case when p_action = 'dispatch' then auth.uid() else out_for_delivery_by end,
    completed_at = case when p_action = 'complete' then now() else completed_at end,
    completed_by = case when p_action = 'complete' then auth.uid() else completed_by end
  where id = p_order_id and status = v_prev
  returning * into o;

  select full_name into v_actor from public.employee_profiles where user_id = auth.uid();
  insert into public.order_status_history (order_id, from_status, to_status, actor_user_id, actor_label, reason)
  values (o.id, v_prev, v_to, auth.uid(), coalesce(v_actor, 'Empleado'), v_reason);

  return public._order_json(o, v_role);
end;
$$;

-- -----------------------------------------------------------------------------
-- Reportes: ventas por modalidad y por origen (web / local).
-- -----------------------------------------------------------------------------
alter function public._report_summary(timestamptz, timestamptz) rename to _report_summary_base;
revoke execute on function public._report_summary_base(timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public._report_summary(p_from timestamptz, p_to timestamptz)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with done as (
    select * from public.orders where created_at >= p_from and created_at < p_to and status = 'COMPLETED'
  )
  select public._report_summary_base(p_from, p_to) || jsonb_build_object(
    'dineInOrders', (select count(*) from done where order_type = 'DINE_IN'),
    'dineInSales', (select coalesce(sum(total), 0) from done where order_type = 'DINE_IN'),
    'counterOrders', (select count(*) from done where channel = 'COUNTER'),
    'counterSales', (select coalesce(sum(total), 0) from done where channel = 'COUNTER'),
    'webOrders', (select count(*) from done where channel = 'WEB'),
    'webSales', (select coalesce(sum(total), 0) from done where channel = 'WEB'))
$$;
revoke execute on function public._report_summary(timestamptz, timestamptz) from public, anon, authenticated;

notify pgrst, 'reload schema';

-- >>> 20261118000019_web_visits.sql
-- =============================================================================
-- Clientes en la web: historial de visitas y conversión.
--
-- El contador EN VIVO no usa la base de datos (Realtime Presence, canal
-- 'web-visitors'). Aquí solo se guarda UNA fila por dispositivo y día con hasta
-- dónde llegó: menú → carrito → datos → compró.
--
-- track_web_visit({ visitorId, stage, device?, token? })   (público, anónimo)
--   stage: MENU | CART | CHECKOUT | ORDERED
--   ORDERED exige el token del pedido recién creado: se verifica que exista, que
--   sea de la web y reciente, y cada pedido se cuenta UNA sola vez.
-- report_web_visits({ from, to })                            (solo ADMIN)
-- =============================================================================

create table if not exists public.web_visits (
  visit_date date not null,
  visitor_id uuid not null,
  device text not null default 'MOBILE' check (device in ('MOBILE', 'DESKTOP')),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  reached_cart boolean not null default false,
  reached_checkout boolean not null default false,
  orders integer not null default 0,
  sales numeric(12, 2) not null default 0,
  primary key (visit_date, visitor_id)
);

create index if not exists web_visits_visitor_idx on public.web_visits (visitor_id, visit_date);

-- Solo se accede por las funciones de abajo.
alter table public.web_visits enable row level security;
revoke all on public.web_visits from public, anon, authenticated;

-- Pedido web atribuido a un visitante (evita contarlo dos veces).
alter table public.orders add column if not exists web_visitor_id uuid;

-- -----------------------------------------------------------------------------
create or replace function public.track_web_visit(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_visitor uuid;
  v_stage text := upper(coalesce(params ->> 'stage', 'MENU'));
  v_device text := case when upper(coalesce(params ->> 'device', '')) = 'DESKTOP' then 'DESKTOP' else 'MOBILE' end;
  v_day date;
  v_order public.orders;
  -- Tope de filas nuevas por día: evita que alguien infle el historial a propósito.
  c_daily_cap constant integer := 20000;
begin
  begin
    v_visitor := (params ->> 'visitorId')::uuid;
  exception when others then
    perform public._raise(422, 'VALIDATION', 'Visitante inválido.');
  end;
  if v_visitor is null then
    perform public._raise(422, 'VALIDATION', 'Visitante inválido.');
  end if;
  if v_stage not in ('MENU', 'CART', 'CHECKOUT', 'ORDERED') then
    perform public._raise(422, 'VALIDATION', 'Paso inválido.');
  end if;

  v_day := (now() at time zone (select timezone from public.restaurant_settings where id = 1))::date;

  if not exists (select 1 from public.web_visits where visit_date = v_day and visitor_id = v_visitor) then
    if (select count(*) from public.web_visits where visit_date = v_day) >= c_daily_cap then
      return jsonb_build_object('ok', false);
    end if;
  end if;

  -- ORDERED solo cuenta si el token es de un pedido web reciente que aún no se
  -- atribuyó a nadie; si no, se registra como una visita normal.
  if v_stage = 'ORDERED' then
    update public.orders o
       set web_visitor_id = v_visitor
      from public.order_tracking_tokens t
     where t.order_id = o.id
       and t.token_hash = encode(extensions.digest(coalesce(params ->> 'token', ''), 'sha256'), 'hex')
       and o.channel = 'WEB'
       and o.web_visitor_id is null
       and o.created_at > now() - interval '2 hours'
    returning o.* into v_order;
    if v_order.id is null then v_stage := 'MENU'; end if;
  end if;

  insert into public.web_visits as w (visit_date, visitor_id, device, reached_cart, reached_checkout, orders, sales)
  values (v_day, v_visitor, v_device,
          v_stage in ('CART', 'CHECKOUT', 'ORDERED'),
          v_stage in ('CHECKOUT', 'ORDERED'),
          case when v_order.id is not null then 1 else 0 end,
          coalesce(v_order.total, 0))
  on conflict (visit_date, visitor_id) do update
    set last_seen = now(),
        reached_cart = w.reached_cart or excluded.reached_cart,
        reached_checkout = w.reached_checkout or excluded.reached_checkout,
        orders = w.orders + excluded.orders,
        sales = w.sales + excluded.sales;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.track_web_visit(jsonb) from public;
grant execute on function public.track_web_visit(jsonb) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Resumen de un rango de días [d_from, d_to] (inclusivo).
create or replace function public._web_visits_summary(p_from date, p_to date)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with v as (select * from public.web_visits where visit_date between p_from and p_to),
  per as (
    select visitor_id,
           bool_or(reached_cart) as cart,
           bool_or(reached_checkout) as checkout,
           sum(orders) as orders,
           sum(sales) as sales,
           min(visit_date) as first_day
      from v group by visitor_id
  )
  select jsonb_build_object(
    'visits', (select count(*) from v),
    'visitors', (select count(*) from per),
    'cart', (select count(*) from per where cart),
    'checkout', (select count(*) from per where checkout),
    'buyers', (select count(*) from per where orders > 0),
    'orders', coalesce((select sum(orders) from per), 0),
    'sales', coalesce((select sum(sales) from per), 0),
    'mobile', (select count(distinct visitor_id) from v where device = 'MOBILE'),
    'desktop', (select count(distinct visitor_id) from v where device = 'DESKTOP'),
    -- Ya habían entrado antes de este periodo.
    'returning', (select count(*) from per p
                   where exists (select 1 from public.web_visits w
                                  where w.visitor_id = p.visitor_id and w.visit_date < p_from)),
    -- Pedidos web del periodo (todos), para comparar con los que se pudieron atribuir.
    'webOrders', (select count(*) from public.orders o
                   where o.channel = 'WEB'
                     and (o.created_at at time zone (select timezone from public.restaurant_settings where id = 1))::date
                         between p_from and p_to)
  )
$$;

create or replace function public.report_web_visits(params jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_tz text;
  d_from date;
  d_to date;
  v_days integer;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  begin
    v_from := (params ->> 'from')::timestamptz;
    v_to := (params ->> 'to')::timestamptz;
  exception when others then
    perform public._raise(422, 'VALIDATION', 'Rango de fechas inválido.');
  end;
  if v_from is null or v_to is null or v_to <= v_from then
    perform public._raise(422, 'VALIDATION', 'La fecha final debe ser posterior a la inicial.');
  end if;
  if v_to - v_from > interval '400 days' then
    perform public._raise(422, 'VALIDATION', 'El rango máximo es de un año.');
  end if;

  select timezone into v_tz from public.restaurant_settings where id = 1;
  d_from := (v_from at time zone v_tz)::date;
  d_to := ((v_to - interval '1 second') at time zone v_tz)::date;
  v_days := d_to - d_from + 1;

  return jsonb_build_object(
    'range', jsonb_build_object('from', d_from, 'to', d_to, 'timezone', v_tz, 'generatedAt', now()),
    'summary', public._web_visits_summary(d_from, d_to),
    'previous', public._web_visits_summary(d_from - v_days, d_from - 1),
    'byDay', coalesce((
      select jsonb_agg(jsonb_build_object('date', d.day::date, 'visitors', coalesce(x.visitors, 0), 'buyers', coalesce(x.buyers, 0)) order by d.day)
        from generate_series(d_from, d_to, interval '1 day') as d(day)
        left join (
          select visit_date, count(*) as visitors, count(*) filter (where orders > 0) as buyers
            from public.web_visits where visit_date between d_from and d_to group by visit_date
        ) x on x.visit_date = d.day::date
    ), '[]'::jsonb),
    'byHour', coalesce((
      select jsonb_agg(jsonb_build_object('hour', h.hour, 'visitors', coalesce(x.visitors, 0)) order by h.hour)
        from generate_series(0, 23) as h(hour)
        left join (
          select extract(hour from first_seen at time zone v_tz)::int as hour, count(*) as visitors
            from public.web_visits where visit_date between d_from and d_to group by 1
        ) x on x.hour = h.hour
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public._web_visits_summary(date, date) from public, anon, authenticated;
revoke execute on function public.report_web_visits(jsonb) from public, anon;
grant execute on function public.report_web_visits(jsonb) to authenticated;

-- -----------------------------------------------------------------------------
-- Limpieza: se guarda poco más de un año de historial.
create or replace function public._web_visits_cleanup()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.web_visits where visit_date < current_date - 400;
$$;

revoke execute on function public._web_visits_cleanup() from public, anon, authenticated;

select cron.unschedule('pacos-web-visits-cleanup')
 where exists (select 1 from cron.job where jobname = 'pacos-web-visits-cleanup');
select cron.schedule('pacos-web-visits-cleanup', '20 9 * * *', 'select public._web_visits_cleanup()');

notify pgrst, 'reload schema';
