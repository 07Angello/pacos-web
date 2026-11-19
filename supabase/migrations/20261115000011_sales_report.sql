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
