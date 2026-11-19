-- =============================================================================
-- Paco's · Flujo de entrega correcto
--
-- Antes un pedido a domicilio podía pasar de READY directo a COMPLETED, y el cliente
-- nunca veía "En camino". Ahora:
--   Recoger:    … → READY (listo para recoger) → COMPLETED (lo recogió el cliente)
--   Domicilio:  … → READY (listo para enviar) → OUT_FOR_DELIVERY (en camino) → COMPLETED (entregado)
-- Cocina (CHEF) solo inicia y marca listo; entregar y "salió a entrega" son de ADMIN/MANAGER.
-- =============================================================================

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
  if p_action = 'complete' and o.order_type = 'DELIVERY' and o.status <> 'OUT_FOR_DELIVERY' then
    perform public._raise(409, 'CONFLICT', 'Marca primero que el pedido salió a entrega (En camino).',
      jsonb_build_object('currentStatus', o.status));
  end if;
  if p_action = 'complete' and o.order_type = 'PICKUP' and o.status <> 'READY' then
    perform public._raise(409, 'CONFLICT', 'El pedido aún no está listo para recoger.', jsonb_build_object('currentStatus', o.status));
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

notify pgrst, 'reload schema';
