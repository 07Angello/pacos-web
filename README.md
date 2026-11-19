# Paco's · Web de pedidos

Web pública (Angular 22 + Tailwind 4 + Font Awesome) para que los clientes pidan **como invitados**:
menú, personalización, carrito, checkout y seguimiento en vivo del pedido.

Backend: **Supabase**. Este repo contiene la carpeta **`supabase/`** (esquema, RLS, RPCs, seed),
que comparten la web y la app del personal (`../pacos-app`).

## Correr en local

```bash
npm install
npm start                # http://localhost:4200
```

Requiere que la base de datos esté creada (ver `supabase/README.md`).

## Pantallas

| Ruta | Descripción |
|---|---|
| `/` | Menú: info del restaurante, abierto/cerrado, categorías, búsqueda, favoritos, carrito lateral (escritorio) o barra flotante (móvil). |
| `/carrito` | Carrito editable. Avisa si un producto se agotó o cambió de precio. |
| `/checkout` | Checkout invitado: recoger/domicilio, nombre, teléfono HN, dirección, pago en efectivo. |
| `/pedido/:token` | Seguimiento privado en vivo. No muestra teléfono ni dirección. |
| `/mis-pedidos` | Enlaces de los pedidos hechos desde este dispositivo. |

## Entornos

- `src/environments/environment.ts` → desarrollo (`ng serve`, `npm run build:dev`)
- `src/environments/environment.prod.ts` → producción (`ng build`)

Cada uno tiene `supabase.url` (URL base del proyecto, sin `/rest/v1`) y `supabase.anonKey`
(publishable key). Hoy ambos apuntan al mismo proyecto; para producción se recomienda uno aparte.

## Estructura

```
src/app/
  core/
    backend/        puerto PublicBackend + adaptador Supabase
    models.ts       contratos (DTO) de las RPCs
    menu.store.ts   menú + escucha de cambios (agotados, abierto/cerrado)
    cart.service.ts carrito (localStorage) + detección de cambios de precio
    pricing.ts      cálculo de precio mostrado (el backend siempre recalcula)
  features/         menu, cart, checkout, tracking, my-orders
  shared/           header, imagen de producto, resumen de carrito, pipes
supabase/           migraciones, RLS, RPCs, seed y config del CLI
```

## Reglas que ya cumple

- Totales calculados en servidor; el navegador nunca define precios (§4.4, AC-04).
- Doble toque / corte de red: misma `idempotencyKey` ⇒ un solo pedido (AC-05).
- Token de seguimiento aleatorio; se guarda solo su hash (§4.6).
- Si el restaurante cierra, se bloquea el checkout pero se puede ver el menú (§4.1).

## Pruebas

```bash
npm test            # unitarias (precios, opciones, teléfono HN)
```
