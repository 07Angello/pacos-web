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
