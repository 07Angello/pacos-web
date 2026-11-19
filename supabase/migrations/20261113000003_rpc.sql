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
