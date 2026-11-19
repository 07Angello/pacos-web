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
