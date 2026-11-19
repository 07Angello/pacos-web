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
