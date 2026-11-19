-- =============================================================================
-- Paco's · Licencia del sistema
-- Ejecuta UNO de estos bloques en Supabase → SQL Editor. El cambio llega a la web
-- y a la app del personal en segundos (tiempo real), sin publicar nada.
--
-- Bloquear solo una app: pon block_web o block_app en false.
-- El mensaje aparece en la pantalla de bloqueo (null = mensaje por defecto).
-- =============================================================================

-- 1) ACTIVAR licencia completa (sin vencimiento)
update public.app_license
set status = 'ACTIVE', expires_at = null, block_web = true, block_app = true, message = null
where id = 1;

-- 2) PERIODO DE PRUEBA hasta una fecha (hora de Honduras, -06). Al vencer se bloquea solo.
update public.app_license
set status = 'ACTIVE', expires_at = '2026-12-31 23:59:59-06', block_web = true, block_app = true,
    message = 'El periodo de prueba terminó. Comunícate con soporte para activar tu licencia.'
where id = 1;

-- 3) DESACTIVAR y bloquear la web y la app de inmediato
update public.app_license
set status = 'INACTIVE', expires_at = null, block_web = true, block_app = true,
    message = 'El sistema está suspendido temporalmente. Comunícate con soporte para reactivarlo.'
where id = 1;

-- 4) CONSULTAR el estado actual de la licencia
select
  case
    when status = 'ACTIVE' and expires_at is null then 'ACTIVA (completa, sin vencimiento)'
    when status = 'ACTIVE' and expires_at > now() then 'ACTIVA (periodo de prueba)'
    when status = 'ACTIVE' then 'VENCIDA (se desactiva en menos de 1 minuto)'
    else 'DESACTIVADA'
  end as estado,
  to_char(expires_at at time zone 'America/Tegucigalpa', 'DD/MM/YYYY HH12:MI AM') as vence_hora_honduras,
  case when expires_at > now()
       then extract(day from expires_at - now())::int || ' días, ' || extract(hour from expires_at - now())::int || ' horas'
  end as tiempo_restante,
  public._license_blocked('WEB') as web_bloqueada,
  public._license_blocked('APP') as app_bloqueada,
  block_web, block_app,
  coalesce(message, '(mensaje por defecto)') as mensaje,
  to_char(updated_at at time zone 'America/Tegucigalpa', 'DD/MM/YYYY HH12:MI AM') as ultimo_cambio
from public.app_license
where id = 1;
