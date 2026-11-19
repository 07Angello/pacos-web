# Supabase · Paco's

Backend del sistema. Las dos apps ya están conectadas por `environment` (URL + publishable key);
solo falta crear la base de datos con estos archivos.

## Contenido

| Archivo | Qué hace |
|---|---|
| `config.toml` | Configuración del Supabase CLI (local). Registro público desactivado, bucket `menu-images`. |
| `migrations/…_init_schema.sql` | Tablas (§9): settings, horario, empleados, menú, pedidos, historial, tokens, eventos, device tokens. |
| `migrations/…_security_rls.sql` | RLS en todas las tablas, helpers de rol, historial append-only, publicación Realtime. |
| `migrations/…_rpc.sql` | RPCs: `create_guest_order`, `get_order_tracking`, `accept_order`, `mark_order_ready`, … |
| `migrations/…_grants_storage.sql` | Permisos explícitos de la API, bucket `menu-images` y recarga del esquema. |
| `migrations/…_payment_transfer.sql` | Método de pago "Transferencia". |
| `migrations/…_menu_builder.sql` | Menú configurable: grupos de opciones reutilizables, opción preseleccionada, platos archivados y RPCs del editor. |
| `migrations/…_employee_admin.sql` | Editar empleados (`admin_update_employee`), protección del último administrador y funciones internas para la Edge Function. |
| `functions/admin-employees` | Edge Function (solo ADMIN): crear empleados y restablecer contraseñas con la llave secreta del servidor. |
| `migrations/…_dine_in_type.sql` + `…_counter_orders.sql` | Pedidos en el local desde la app (`create_counter_order`, ADMIN/MANAGER): para llevar o **comer aquí** (`DINE_IN`), nombre/teléfono opcionales, entran ya aceptados (aviso a cocina), `orders.channel` WEB/COUNTER, precios con `_price_order_items` (misma lógica que la web) y reportes por modalidad y origen. |
| `migrations/…_web_visits.sql` | **Clientes en la web**: historial anónimo de visitas (`web_visits`, una fila por dispositivo y día) con el embudo menú → carrito → datos → compra. `track_web_visit` (público; la compra se verifica con el token del pedido y cuenta una sola vez) y `report_web_visits` (solo ADMIN). Limpieza diaria (>400 días, cron `pacos-web-visits-cleanup`). El contador **en vivo** no usa tablas: Realtime Presence, canal `web-visitors`. |
| `migrations/…_auto_close.sql` | Cierre automático: a la hora de cierre del horario (cron `pacos-auto-close`, cada minuto) se apaga `is_open`. Solo cierra, una vez por horario; abrir es manual. |
| `migrations/…_order_number_8_digits.sql` | Números de pedido de 8 dígitos (`R-00001424`, hasta 99,999,999) con `_next_order_number()`; los anteriores conservan su número. |
| `migrations/…_delivery_flow.sql` | Flujo de entrega: domicilio pasa obligatoriamente por "En camino" antes de entregarse; recoger se entrega desde "Listo". Cocina solo inicia y marca listo. |
| `migrations/…_business_hours.sql` | Horario de atención por día editable desde la app (`update_business_hours`, solo ADMIN). Avisa a la web en tiempo real. |
| `migrations/…_license.sql` | Licencia (`app_license`, un registro): bloquea web y/o app en el servidor y en tiempo real. Consultas listas en `scripts/license.sql`. |
| `migrations/…_sales_report.sql` | Reporte de ventas `report_sales` (solo ADMIN): cierre de caja, productos, horas pico, colonias, no concretados, comparación con el periodo anterior. |
| `migrations/…_delete_category.sql` | Eliminar categorías (`admin_delete_category`): vacías se borran; con platos eliminados se archivan. |
| `migrations/…_push_notifications.sql` | Push (FCM): trigger en `order_events` → `pg_net` → Edge Function `push-dispatch`; registro de teléfonos. |
| `functions/push-dispatch` | Edge Function: arma el aviso y lo envía por Firebase a los roles que corresponden. |
| `migrations/…_cancel_and_schedule.sql` | Cancelación por el cliente (solo PENDING), recogida programada (`get_pickup_slots`) y recordatorios con `pg_cron`. |
| `setup.sql` | **Generado**: todas las migraciones en un solo archivo para pegar en el SQL Editor. |
| `seed.sql` | Configuración del restaurante, horario y un menú inicial (edítalo con el menú real). |
| `scripts/create_employee.sql` | Asignar perfil + rol a un usuario creado en Auth. |

Convención de RPC: un solo argumento `params jsonb` → `supabase.rpc('accept_order', { params: { order_id } })`.
Errores: SQLSTATE `PTxxx` (PostgREST lo devuelve como HTTP `xxx`) y el código de negocio en `hint`
(`VALIDATION`, `CONFLICT`, `FORBIDDEN`, `RESTAURANT_CLOSED`, …).

## Flujo con la CLI (recomendado)

La CLI está instalada en `pacos-web` (`supabase@3.1.0`) y enlazada al proyecto **Paco's**
(`rbtnpgysqhrnczvxqoqx`). El enlace es por carpeta: no interfiere con otros proyectos.

```bash
cd pacos-web
npm run db:start      # Supabase local en Docker (API http://127.0.0.1:54321, Studio http://127.0.0.1:54323)
npm run db:reset      # recrea la BD local: migraciones + seed.sql
npm run start:local   # (en pacos-web y en pacos-app) apps apuntando al Supabase local
npm run db:push       # sube migraciones pendientes a la nube (agrega -- --include-seed para el seed)
npm run db:stop
```

Los empleados se crean desde la app (Ajustes → Empleados → Agregar, solo ADMIN). Para el **primer**
administrador, o si la Edge Function no está desplegada, usa Studio → Authentication → Add user y
`scripts/create_employee.sql`.

Edge Functions:
```bash
npx supabase functions serve                     # local (http://127.0.0.1:54321/functions/v1/…)
npx supabase functions deploy admin-employees    # nube (usa verify_jwt=false de config.toml)
```

Para cambios futuros del esquema: crea un archivo nuevo en `migrations/` (nunca edites uno ya
subido), pruébalo con `db:reset` y luego `db:push`.

## Opción manual · SQL Editor

1. Crea el proyecto en https://supabase.com (región cercana, p. ej. `us-east-1`).
2. SQL Editor → pega y ejecuta `setup.sql`; luego `seed.sql`.
   *(o con CLI: `npx supabase link --project-ref <ref>` y `npx supabase db push`)*
3. Authentication → Providers → Email: desactiva **Allow new users to sign up**.
4. Authentication → Users → **Add user** para cada empleado (marca *Auto Confirm*).
5. SQL Editor → `scripts/create_employee.sql` por cada empleado (rol `ADMIN`, `MANAGER` o `CHEF`).
6. Project Settings → API → copia **Project URL** y **anon public key**.
7. En `pacos-web/src/environments/*.ts` y `pacos-app/src/environments/*.ts`:
   ```ts
   supabase: { url: 'https://xxxx.supabase.co', anonKey: 'sb_publishable_…' },
   ```

> ⚠️ Nunca pongas la `service_role` key en las apps. La anon key es pública por diseño; la seguridad la dan RLS y las RPCs.

## Opción B · Local con Docker

```bash
cd pacos-web
npx supabase start        # levanta Postgres, Auth, Realtime y Studio (http://localhost:54323)
npx supabase db reset     # aplica migraciones + seed.sql
```
URL local: `http://127.0.0.1:54321`; la anon key la imprime `supabase start`.

## Cómo funciona el tiempo real

- La tabla `order_events` recibe una fila por cada pedido creado o cambio de estado (trigger).
- La app del personal se suscribe a `INSERT` en `order_events` (RLS: solo empleados activos) y luego
  pide el detalle con `get_order`, que ya filtra los campos según el rol (el chef no recibe teléfono,
  dirección ni montos).
- El seguimiento público del cliente consulta `get_order_tracking` por sondeo (el anónimo no puede leer pedidos).

## Pedidos programados y recordatorios

- Solo pedidos **para recoger**. `get_pickup_slots` devuelve horarios de hoy y mañana cada 15 min, desde
  30 min después de abrir hasta 15 min antes de cerrar (`business_hours`, zona del restaurante), con una
  anticipación mínima de *promedio de preparación + 10 min* (mínimo 30).
- Promedio de preparación (`_avg_prep_minutes`): últimos 30 pedidos listos en 14 días (aceptado → listo;
  en programados, inicio → listo). Con menos de 3 muestras usa el tiempo estimado de Ajustes (o 20 min).
- El job `pacos-pickup-reminders` de `pg_cron` corre cada minuto: cuando `hora programada − promedio ≤ ahora`
  marca `reminder_sent_at` e inserta `order.reminder` en `order_events`. La app avisa con sonido a
  encargados y administradores **si la tienen abierta**; con la app cerrada el aviso requiere push (FCM, pendiente).
- `create_guest_order` es una envoltura que valida `scheduledFor`; la lógica del carrito vive en
  `_create_guest_order_core` (edita esa función para cambios de precios/opciones).

## Notificaciones push (Android)

Configuración en **Supabase Vault** (Dashboard → Project Settings → Vault, o SQL `select vault.create_secret(valor, nombre)`):

| Nombre | Valor |
|---|---|
| `push_dispatch_url` | `https://<project-ref>.supabase.co/functions/v1/push-dispatch` |
| `fcm_service_account` | JSON completo de Firebase → Configuración del proyecto → Cuentas de servicio → Generar nueva clave privada |

Destinatarios: pedido nuevo, recordatorio, cancelación y listo → ADMIN y MANAGER; aceptado → CHEF.
Nunca se avisa a quien hizo el cambio. Tokens rechazados por FCM se desactivan solos.
En la app: `android/app/google-services.json` (Firebase → app Android `hn.pacos.staff`).

## Pendiente (fases siguientes)

- Rate limiting de `create_guest_order` / `get_order_tracking` (Edge Function o API Gateway).
- Validar horario (`business_hours`) en pedidos inmediatos: `is_open` se apaga solo al cierre (`_auto_close_orders`), pero abrir sigue siendo manual (los programados sí se validan).
- Cancelación automática de pedidos que nadie acepta (punto 6 del cliente).
