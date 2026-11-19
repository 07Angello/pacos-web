-- =============================================================================
-- Paco's · Método de pago "Transferencia" además de "Efectivo".
-- create_guest_order ya valida contra esta lista, no requiere cambios.
-- =============================================================================

alter table public.restaurant_settings
  alter column payment_methods set default
    '[{"code":"CASH","label":"Efectivo"},{"code":"TRANSFER","label":"Transferencia"}]'::jsonb;

update public.restaurant_settings
set payment_methods = payment_methods || '[{"code":"TRANSFER","label":"Transferencia"}]'::jsonb
where id = 1
  and not exists (select 1 from jsonb_array_elements(payment_methods) m where m ->> 'code' = 'TRANSFER');
