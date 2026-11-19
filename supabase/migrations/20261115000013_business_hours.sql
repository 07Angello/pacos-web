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
