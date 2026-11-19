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
