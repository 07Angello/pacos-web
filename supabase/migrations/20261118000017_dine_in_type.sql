-- =============================================================================
-- Paco's · Nueva modalidad de pedido: DINE_IN ("Comer aquí")
--
-- Va sola en su migración: PostgreSQL no permite usar un valor nuevo de un enum
-- en la misma transacción en que se agrega. La lógica que lo usa está en la 18.
-- =============================================================================

alter type public.order_type add value if not exists 'DINE_IN';
