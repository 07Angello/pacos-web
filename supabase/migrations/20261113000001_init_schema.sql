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
