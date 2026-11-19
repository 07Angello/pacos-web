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
