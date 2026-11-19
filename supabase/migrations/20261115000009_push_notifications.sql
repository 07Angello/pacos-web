-- =============================================================================
-- Paco's · Notificaciones push (FCM) para el personal
--
-- Flujo: INSERT en order_events → trigger → pg_net llama (asíncrono, tras el commit)
-- a la Edge Function `push-dispatch` con { eventId } → la función reclama el evento
-- con `_push_claim_event` (una sola vez), arma el texto y envía por FCM a los
-- dispositivos de los roles que corresponden.
--
-- Configuración en Supabase Vault (ver README):
--   push_dispatch_url    URL de la Edge Function push-dispatch. Sin ella el trigger no hace nada.
--   fcm_service_account  JSON de la cuenta de servicio de Firebase (llave privada).
--
-- Destinatarios por evento:
--   order.created / order.reminder / order.cancelled / order.ready → ADMIN y MANAGER
--   order.accepted                                                 → CHEF
-- Se excluye a quien hizo el cambio (no se avisa a uno mismo).
-- =============================================================================

create extension if not exists supabase_vault with schema vault;
create extension if not exists pg_net with schema extensions;

alter table public.order_events add column push_sent_at timestamptz;
alter table public.device_tokens add column last_error text;
create index device_tokens_user_active_idx on public.device_tokens (user_id) where is_active;

-- ---------------------------------------------------------------------------
-- Trigger: avisar a la Edge Function
-- ---------------------------------------------------------------------------
create or replace function public._push_on_order_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
begin
  if new.event_type not in ('order.created', 'order.accepted', 'order.reminder', 'order.cancelled', 'order.ready') then
    return new;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_dispatch_url' limit 1;
  if v_url is null or v_url = '' then
    return new; -- push no configurado
  end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('eventId', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000);
  return new;
exception when others then
  -- Nunca bloquear un pedido por un problema de notificaciones.
  raise warning '[push] no se pudo encolar el evento %: %', new.id, sqlerrm;
  return new;
end;
$$;

create trigger order_events_push after insert on public.order_events
  for each row execute function public._push_on_order_event();

-- ---------------------------------------------------------------------------
-- Reclamar un evento (solo service_role): lo marca como enviado y devuelve
-- el resumen del pedido + los tokens destino. null si no existe o ya se envió.
-- Así, llamar a la función varias veces (o desde fuera) no duplica avisos.
-- ---------------------------------------------------------------------------
create or replace function public._push_claim_event(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  e public.order_events;
  o public.orders;
  v_roles public.app_role[];
  v_actor uuid;
  v_tokens jsonb;
begin
  update public.order_events set push_sent_at = now()
  where id = (params ->> 'event_id')::bigint and push_sent_at is null
  returning * into e;
  if not found then return null; end if;

  select * into o from public.orders where id = e.order_id;
  v_roles := case e.event_type
    when 'order.accepted' then array['CHEF']::public.app_role[]
    else array['ADMIN', 'MANAGER']::public.app_role[] end;

  -- Quién provocó el cambio (para no avisarle a sí mismo).
  select h.actor_user_id into v_actor from public.order_status_history h
  where h.order_id = o.id and h.to_status = e.status order by h.created_at desc limit 1;
  if e.event_type = 'order.reminder' then v_actor := null; end if;

  select coalesce(jsonb_agg(t.token), '[]'::jsonb) into v_tokens
  from public.device_tokens t
  join public.employee_profiles p on p.user_id = t.user_id and p.is_active
  join public.employee_roles r on r.user_id = t.user_id
  where t.is_active and r.role = any (v_roles) and t.user_id is distinct from v_actor;

  return jsonb_build_object(
    'eventType', e.event_type,
    'tokens', v_tokens,
    'order', jsonb_build_object(
      'id', o.id, 'orderNumber', o.order_number, 'status', o.status, 'orderType', o.order_type,
      'customerName', public._short_name(o.customer_name), 'total', o.total,
      'scheduledFor', o.scheduled_for,
      'reminderAt', case when o.scheduled_for is not null
                         then o.scheduled_for - make_interval(mins => public._avg_prep_minutes()) end,
      'cancellationReason', o.cancellation_reason,
      'itemCount', (select coalesce(sum(i.quantity), 0) from public.order_items i where i.order_id = o.id),
      'items', (select coalesce(string_agg(i.quantity || '× ' || i.product_name_snapshot, ', ' order by i.sort_order), '')
                from public.order_items i where i.order_id = o.id)));
end;
$$;

-- Tokens que FCM reporta como inválidos (app desinstalada, token rotado…).
create or replace function public._push_disable_tokens(params jsonb)
returns integer
language sql
volatile
security definer
set search_path = public
as $$
  with upd as (
    update public.device_tokens t set is_active = false, last_error = x.err
    from jsonb_to_recordset(coalesce(params -> 'tokens', '[]'::jsonb)) as x(token text, err text)
    where t.token = x.token
    returning 1)
  select count(*)::int from upd
$$;

-- Credencial de Firebase desde Vault (solo service_role, la usa la Edge Function).
create or replace function public._push_fcm_credentials()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'fcm_service_account' limit 1
$$;

-- ---------------------------------------------------------------------------
-- El dispositivo deja de recibir avisos al cerrar sesión.
-- ---------------------------------------------------------------------------
create or replace function public.unregister_device_token(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    perform public._raise(401, 'UNAUTHORIZED', 'Tu sesión expiró. Inicia sesión de nuevo.');
  end if;
  update public.device_tokens set is_active = false
  where token = params ->> 'token' and user_id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;

-- register_device_token: igual, pero limpia el error anterior al reactivar.
create or replace function public.register_device_token(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_token text := btrim(coalesce(params ->> 'token', ''));
begin
  perform public._require_role(array['ADMIN', 'MANAGER', 'CHEF']::public.app_role[]);
  if length(v_token) < 20 or length(v_token) > 4096 then
    perform public._raise(422, 'VALIDATION', 'Token de dispositivo inválido.');
  end if;
  insert into public.device_tokens (user_id, token, platform, device_label)
  values (auth.uid(), v_token, coalesce(params ->> 'platform', 'android'), left(params ->> 'label', 120))
  on conflict (token) do update set user_id = excluded.user_id, is_active = true, last_seen_at = now(),
    device_label = excluded.device_label, platform = excluded.platform, last_error = null;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
revoke execute on function public._push_on_order_event(), public._push_claim_event(jsonb),
  public._push_disable_tokens(jsonb), public._push_fcm_credentials() from public, anon, authenticated;
grant execute on function public._push_claim_event(jsonb), public._push_disable_tokens(jsonb),
  public._push_fcm_credentials() to service_role;
revoke execute on function public.unregister_device_token(jsonb), public.register_device_token(jsonb) from public, anon;
grant execute on function public.unregister_device_token(jsonb), public.register_device_token(jsonb) to authenticated;

notify pgrst, 'reload schema';
