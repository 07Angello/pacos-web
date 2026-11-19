-- =============================================================================
-- Paco's · Eliminar categorías del menú (solo ADMIN)
--
-- · Con platos activos: no se puede (hay que moverlos o eliminarlos primero).
-- · Vacía: se borra.
-- · Solo con platos ya eliminados (archivados, los conservan los pedidos
--   anteriores): se archiva la categoría (archived_at) y desaparece del menú.
-- =============================================================================

alter table public.categories add column archived_at timestamptz;

create or replace function public.admin_delete_category(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid := nullif(params ->> 'id', '')::uuid;
  c public.categories;
  v_active int;
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  select * into c from public.categories where id = v_id and archived_at is null for update;
  if not found then
    perform public._raise(404, 'NOT_FOUND', 'Categoría no encontrada.');
  end if;

  select count(*) into v_active from public.products where category_id = v_id and archived_at is null;
  if v_active > 0 then
    perform public._raise(409, 'CATEGORY_NOT_EMPTY',
      'Esta categoría tiene ' || v_active || case when v_active = 1 then ' plato' else ' platos' end
        || '. Muévelos a otra categoría o elimínalos primero.',
      jsonb_build_object('productCount', v_active));
  end if;

  if exists (select 1 from public.products where category_id = v_id) then
    update public.categories set archived_at = now(), is_active = false where id = v_id;
  else
    delete from public.categories where id = v_id;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- El editor no ve categorías archivadas.
create or replace function public.admin_get_menu(params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_role(array['ADMIN']::public.app_role[]);
  return jsonb_build_object(
    'categories', coalesce((select jsonb_agg(public._category_json(c) order by c.sort_order)
                            from public.categories c where c.archived_at is null), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(public._product_json(p) order by p.sort_order, p.name)
                          from public.products p where p.archived_at is null), '[]'::jsonb),
    'optionGroups', coalesce((select jsonb_agg(public._option_group_json(o.id) order by o.name)
                              from public.product_options o), '[]'::jsonb));
end;
$$;

-- Una categoría archivada no recibe platos ni se puede volver a mostrar.
create or replace function public._guard_archived_category()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'products' then
    if new.archived_at is null and exists (select 1 from public.categories where id = new.category_id and archived_at is not null) then
      perform public._raise(422, 'VALIDATION', 'Esa categoría fue eliminada. Elige otra.');
    end if;
  elsif old.archived_at is not null and new.is_active then
    perform public._raise(404, 'NOT_FOUND', 'Categoría no encontrada.');
  end if;
  return new;
end;
$$;

create trigger products_guard_archived_category before insert or update of category_id, archived_at on public.products
  for each row execute function public._guard_archived_category();
create trigger categories_guard_archived before update on public.categories
  for each row execute function public._guard_archived_category();

revoke execute on function public.admin_delete_category(jsonb), public._guard_archived_category() from public, anon;
revoke execute on function public._guard_archived_category() from authenticated;
grant execute on function public.admin_delete_category(jsonb) to authenticated;

notify pgrst, 'reload schema';
