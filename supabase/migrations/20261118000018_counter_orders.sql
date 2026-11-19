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
