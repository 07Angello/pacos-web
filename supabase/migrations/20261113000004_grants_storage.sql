-- =============================================================================
-- Paco's · Permisos explícitos de la Data API, Storage y recarga de esquema
--
-- Algunos proyectos Supabase nuevos no exponen automáticamente las tablas a los
-- roles anon/authenticated. Aquí se otorga SOLO lo necesario; RLS sigue filtrando
-- filas y los pedidos solo se tocan mediante RPCs security definer.
-- =============================================================================

grant usage on schema public to anon, authenticated;

-- Menú y configuración pública: lectura (también la usa Realtime para avisar cambios).
grant select on public.restaurant_settings, public.business_hours, public.categories,
  public.products, public.product_options, public.product_option_values to anon, authenticated;

-- Escritura directa del menú: solo pasa la RLS del ADMIN.
grant insert, update, delete on public.categories, public.products, public.product_options,
  public.product_option_values, public.business_hours to authenticated;

-- Empleados: lectura (RLS: el propio perfil o ADMIN).
grant select on public.employee_profiles, public.employee_roles to authenticated;

-- Realtime de pedidos: eventos livianos, solo empleados activos (RLS).
grant select on public.order_events to authenticated;

-- Tokens FCM propios.
grant select, insert, update, delete on public.device_tokens to authenticated;

-- Pedidos, líneas, historial y tokens de seguimiento: SIN acceso directo.
revoke all on public.orders, public.order_items, public.order_item_options,
  public.order_status_history, public.order_tracking_tokens from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Storage: bucket público para fotos de productos y logo (solo ADMIN sube).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('menu-images', 'menu-images', true, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

create policy "menu-images: lectura pública" on storage.objects for select
  using (bucket_id = 'menu-images');
create policy "menu-images: admin sube" on storage.objects for insert to authenticated
  with check (bucket_id = 'menu-images' and public.current_app_role() = 'ADMIN');
create policy "menu-images: admin actualiza" on storage.objects for update to authenticated
  using (bucket_id = 'menu-images' and public.current_app_role() = 'ADMIN');
create policy "menu-images: admin borra" on storage.objects for delete to authenticated
  using (bucket_id = 'menu-images' and public.current_app_role() = 'ADMIN');

-- Que PostgREST vea de inmediato tablas y funciones nuevas.
notify pgrst, 'reload schema';
