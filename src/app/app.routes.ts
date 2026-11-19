import { Routes } from '@angular/router';

export const routes: Routes = [
  { path: '', loadComponent: () => import('./features/menu/menu.page').then((m) => m.MenuPage), title: "Paco's · Menú" },
  { path: 'carrito', loadComponent: () => import('./features/cart/cart.page').then((m) => m.CartPage), title: "Paco's · Tu carrito" },
  { path: 'checkout', loadComponent: () => import('./features/checkout/checkout.page').then((m) => m.CheckoutPage), title: "Paco's · Confirmar pedido" },
  { path: 'pedido/:token', loadComponent: () => import('./features/tracking/tracking.page').then((m) => m.TrackingPage), title: "Paco's · Tu pedido" },
  { path: 'mis-pedidos', loadComponent: () => import('./features/my-orders/my-orders.page').then((m) => m.MyOrdersPage), title: "Paco's · Mis pedidos" },
  { path: '**', redirectTo: '' },
];
