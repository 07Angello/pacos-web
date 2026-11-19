-- =============================================================================
-- Paco's · Datos iniciales: configuración, horario y menú inicial (ajústalo al menú real).
-- Se ejecuta con `supabase db reset` (local) o pegándolo en el SQL Editor.
-- Los empleados se crean aparte: ver supabase/scripts/create_employee.sql
-- =============================================================================

insert into public.restaurant_settings (id, name, slug, tagline, phone, address, timezone, currency, currency_symbol,
  is_open, pickup_enabled, delivery_enabled, delivery_fee, estimated_prep_minutes, kitchen_delay_minutes,
  show_unavailable_products, payment_methods)
values (1, 'Paco''s', 'pacos', 'Hamburguesas, alitas y más · hechas al momento', '+504 2222-3344',
  'Col. Palmira, Tegucigalpa', 'America/Tegucigalpa', 'HNL', 'L', true, true, true, 40, 25, 15, true,
  '[{"code":"CASH","label":"Efectivo"},{"code":"TRANSFER","label":"Transferencia"}]')
on conflict (id) do nothing;

insert into public.business_hours (weekday, label, opens_at, closes_at, is_closed) values
  (0, 'Domingo', '12:00', '21:00', false),
  (1, 'Lunes', '11:00', '22:00', false),
  (2, 'Martes', '11:00', '22:00', false),
  (3, 'Miércoles', '11:00', '22:00', false),
  (4, 'Jueves', '11:00', '22:00', false),
  (5, 'Viernes', '11:00', '23:00', false),
  (6, 'Sábado', '11:00', '23:00', false)
on conflict (weekday) do nothing;

do $$
declare
  c_burgers uuid; c_wings uuid; c_hotdogs uuid; c_sides uuid; c_drinks uuid; c_desserts uuid;
  g_term uuid; g_burger_extras uuid; g_remove uuid; g_chicken_extras uuid;
  g_wing_qty uuid; g_wing_sauce uuid; g_fries uuid; g_soda uuid; g_lemonade uuid; g_shake uuid;
  g_combo_side uuid; g_combo_drink uuid;
  v_product uuid;
begin
  if exists (select 1 from public.categories) then
    raise notice 'El menú ya tiene datos; se omite el seed.';
    return;
  end if;

  -- Categorías
  insert into public.categories (name, description, icon, sort_order) values ('Hamburguesas', 'Carne 100% res a la parrilla', 'fa-burger', 1) returning id into c_burgers;
  insert into public.categories (name, description, icon, sort_order) values ('Alitas y pollo', 'Crujientes y con salsas de la casa', 'fa-drumstick-bite', 2) returning id into c_wings;
  insert into public.categories (name, description, icon, sort_order) values ('Hot dogs', 'Pan suave y salchicha jumbo', 'fa-hotdog', 3) returning id into c_hotdogs;
  insert into public.categories (name, description, icon, sort_order) values ('Acompañantes', 'Para compartir (o no)', 'fa-bowl-food', 4) returning id into c_sides;
  insert into public.categories (name, description, icon, sort_order) values ('Bebidas', 'Frías y naturales', 'fa-glass-water', 5) returning id into c_drinks;
  insert into public.categories (name, description, icon, sort_order) values ('Postres', 'El cierre perfecto', 'fa-ice-cream', 6) returning id into c_desserts;

  -- Biblioteca de grupos de opciones (reutilizables entre platos)
  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Término de la carne', 'SINGLE', true, 1, 1) returning id into g_term;
  insert into public.product_option_values (option_id, label, price_delta, is_default, sort_order) values
    (g_term, 'Término medio', 0, false, 0), (g_term, 'Tres cuartos', 0, true, 1), (g_term, 'Bien cocida', 0, false, 2);

  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Extras de hamburguesa', 'MULTIPLE', false, 0, 4) returning id into g_burger_extras;
  insert into public.product_option_values (option_id, label, price_delta, is_available, sort_order) values
    (g_burger_extras, 'Queso cheddar extra', 20, true, 0), (g_burger_extras, 'Tocino', 30, true, 1), (g_burger_extras, 'Huevo frito', 20, true, 2),
    (g_burger_extras, 'Jalapeños', 10, true, 3), (g_burger_extras, 'Aguacate', 25, false, 4);

  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Quitar ingredientes', 'MULTIPLE', false, 0, 4) returning id into g_remove;
  insert into public.product_option_values (option_id, label, price_delta, sort_order) values
    (g_remove, 'Sin cebolla', 0, 0), (g_remove, 'Sin tomate', 0, 1), (g_remove, 'Sin lechuga', 0, 2), (g_remove, 'Sin salsa', 0, 3);

  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Extras de pollo', 'MULTIPLE', false, 0, 3) returning id into g_chicken_extras;
  insert into public.product_option_values (option_id, label, price_delta, sort_order) values
    (g_chicken_extras, 'Queso cheddar extra', 20, 0), (g_chicken_extras, 'Tocino', 30, 1), (g_chicken_extras, 'Jalapeños', 10, 2);

  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Cantidad de alitas', 'SINGLE', true, 1, 1) returning id into g_wing_qty;
  insert into public.product_option_values (option_id, label, price_delta, is_default, sort_order) values (g_wing_qty, '6 piezas', 0, true, 0), (g_wing_qty, '12 piezas', 130, false, 1);

  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Salsa de alitas', 'SINGLE', true, 1, 1) returning id into g_wing_sauce;
  insert into public.product_option_values (option_id, label, price_delta, is_default, sort_order) values
    (g_wing_sauce, 'BBQ', 0, true, 0), (g_wing_sauce, 'Búfalo', 0, false, 1), (g_wing_sauce, 'Mango habanero', 0, false, 2), (g_wing_sauce, 'Ajo parmesano', 0, false, 3);

  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Tamaño de papas', 'SINGLE', true, 1, 1) returning id into g_fries;
  insert into public.product_option_values (option_id, label, price_delta, is_default, sort_order) values (g_fries, 'Regular', 0, true, 0), (g_fries, 'Grande', 25, false, 1);

  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Sabor de refresco', 'SINGLE', true, 1, 1) returning id into g_soda;
  insert into public.product_option_values (option_id, label, price_delta, sort_order) values
    (g_soda, 'Coca-Cola', 0, 0), (g_soda, 'Coca-Cola sin azúcar', 0, 1), (g_soda, 'Sprite', 0, 2), (g_soda, 'Fanta naranja', 0, 3);

  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Preparación de limonada', 'SINGLE', true, 1, 1) returning id into g_lemonade;
  insert into public.product_option_values (option_id, label, price_delta, is_default, sort_order) values (g_lemonade, 'Clásica', 0, true, 0), (g_lemonade, 'Con hierbabuena', 10, false, 1);

  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Sabor de malteada', 'SINGLE', true, 1, 1) returning id into g_shake;
  insert into public.product_option_values (option_id, label, price_delta, sort_order) values
    (g_shake, 'Vainilla', 0, 0), (g_shake, 'Chocolate', 0, 1), (g_shake, 'Fresa', 0, 2), (g_shake, 'Oreo', 15, 3);

  -- Grupos de combo
  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Acompañante del combo', 'SINGLE', true, 1, 1) returning id into g_combo_side;
  insert into public.product_option_values (option_id, label, price_delta, is_default, sort_order) values
    (g_combo_side, 'Papas fritas regulares', 0, true, 0), (g_combo_side, 'Papas grandes', 25, false, 1), (g_combo_side, 'Aros de cebolla', 15, false, 2);
  insert into public.product_options (name, option_type, is_required, min_select, max_select) values ('Bebida del combo', 'SINGLE', true, 1, 1) returning id into g_combo_drink;
  insert into public.product_option_values (option_id, label, price_delta, is_default, sort_order) values
    (g_combo_drink, 'Coca-Cola', 0, true, 0), (g_combo_drink, 'Sprite', 0, false, 1), (g_combo_drink, 'Limonada natural', 10, false, 2), (g_combo_drink, 'Horchata', 5, false, 3);

  -- Hamburguesas: comparten término, extras y "quitar ingredientes"
  insert into public.products (category_id, name, description, price, is_featured, sort_order) values
    (c_burgers, 'Paco Clásica', 'Carne de res, queso cheddar, lechuga, tomate, cebolla y salsa Paco.', 165, true, 1) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values (v_product, g_term, 0), (v_product, g_burger_extras, 1), (v_product, g_remove, 2);

  insert into public.products (category_id, name, description, price, is_featured, sort_order) values
    (c_burgers, 'Doble Paco', 'Doble carne, doble cheddar, tocino crujiente y pepinillos.', 235, true, 2) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values (v_product, g_term, 0), (v_product, g_burger_extras, 1), (v_product, g_remove, 2);

  insert into public.products (category_id, name, description, price, sort_order) values
    (c_burgers, 'BBQ Ranchera', 'Carne de res, aros de cebolla, queso ahumado y salsa BBQ.', 195, 3) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values (v_product, g_term, 0), (v_product, g_burger_extras, 1), (v_product, g_remove, 2);

  insert into public.products (category_id, name, description, price, sort_order) values
    (c_burgers, 'Combo Paco', 'Paco Clásica + acompañante + bebida. Personaliza cada parte.', 225, 4) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values
    (v_product, g_term, 0), (v_product, g_burger_extras, 1), (v_product, g_remove, 2), (v_product, g_combo_side, 3), (v_product, g_combo_drink, 4);

  insert into public.products (category_id, name, description, price, sort_order) values
    (c_burgers, 'Pollo Crispy', 'Pechuga empanizada, ensalada de col y mayo de chipotle.', 175, 5) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values (v_product, g_chicken_extras, 0), (v_product, g_remove, 1);

  insert into public.products (category_id, name, description, price, is_available, sort_order) values
    (c_burgers, 'Veggie de hongos', 'Portobello a la parrilla, queso suizo y cebolla caramelizada.', 160, false, 6);

  -- Alitas y pollo
  insert into public.products (category_id, name, description, price, is_featured, sort_order) values
    (c_wings, 'Alitas de la casa', 'Alitas fritas bañadas en tu salsa favorita, con apio y aderezo ranch.', 150, true, 1) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values (v_product, g_wing_qty, 0), (v_product, g_wing_sauce, 1);
  insert into public.products (category_id, name, description, price, sort_order) values
    (c_wings, 'Tenders de pollo', '5 tiras de pechuga crujiente con miel mostaza.', 140, 2);

  -- Hot dogs
  insert into public.products (category_id, name, description, price, sort_order) values
    (c_hotdogs, 'Hot dog Paco', 'Salchicha jumbo, repollo, salsa de tomate, mostaza y mayonesa.', 95, 1),
    (c_hotdogs, 'Chili dog', 'Salchicha jumbo con chili de carne y queso fundido.', 125, 2);

  -- Acompañantes
  insert into public.products (category_id, name, description, price, sort_order) values
    (c_sides, 'Papas fritas', 'Papas crujientes con sal de la casa.', 55, 1) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values (v_product, g_fries, 0);
  insert into public.products (category_id, name, description, price, sort_order) values
    (c_sides, 'Papas Paco', 'Papas con queso fundido, tocino y cebollín.', 90, 2),
    (c_sides, 'Aros de cebolla', 'Empanizados y dorados, con salsa chipotle.', 70, 3);

  -- Bebidas
  insert into public.products (category_id, name, description, price, sort_order) values
    (c_drinks, 'Refresco', 'Lata de 355 ml bien fría.', 35, 1) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values (v_product, g_soda, 0);
  insert into public.products (category_id, name, description, price, sort_order) values
    (c_drinks, 'Limonada natural', 'Hecha al momento. Pregunta por la de hierbabuena.', 45, 2) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values (v_product, g_lemonade, 0);
  insert into public.products (category_id, name, description, price, sort_order) values
    (c_drinks, 'Horchata', 'Receta de la casa, con canela.', 40, 3),
    (c_drinks, 'Agua embotellada', '600 ml.', 25, 4);

  -- Postres
  insert into public.products (category_id, name, description, price, sort_order) values
    (c_desserts, 'Brownie con helado', 'Brownie tibio de chocolate con helado de vainilla.', 85, 1);
  insert into public.products (category_id, name, description, price, sort_order) values
    (c_desserts, 'Malteada', 'Espesa y cremosa, con crema batida.', 90, 2) returning id into v_product;
  insert into public.product_option_links (product_id, option_id, sort_order) values (v_product, g_shake, 0);
end;
$$;
