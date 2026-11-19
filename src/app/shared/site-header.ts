import { Component, inject, input } from '@angular/core';
import { RouterLink } from '@angular/router';
import { CartService } from '../core/cart.service';
import { RecentOrdersService } from '../core/recent-orders.service';

@Component({
  selector: 'app-site-header',
  imports: [RouterLink],
  template: `
    <header class="sticky top-0 z-30 border-b border-cream-200/80 bg-cream-50/90 backdrop-blur-md">
      <div class="mx-auto flex h-16 max-w-6xl items-center gap-3 px-4">
        @if (back()) {
          <a [routerLink]="back()" class="grid size-11 place-items-center rounded-full bg-white ring-1 ring-cream-200 hover:bg-cream-100" aria-label="Volver">
            <i class="fa-solid fa-arrow-left"></i>
          </a>
        }
        <a routerLink="/" class="flex items-center gap-2.5" aria-label="Paco's, inicio">
          <span class="grid size-10 place-items-center rounded-2xl bg-brand-500 text-lg text-mustard-400 shadow-sm">
            <i class="fa-solid fa-burger"></i>
          </span>
          <span class="font-display text-xl font-extrabold tracking-tight">Paco's</span>
        </a>
        <span class="flex-1"></span>
        @if (recent.orders().length) {
          <a routerLink="/mis-pedidos" class="btn btn-ghost min-h-11 px-3 text-sm" aria-label="Mis pedidos">
            <i class="fa-solid fa-receipt"></i><span class="hidden sm:inline">Mis pedidos</span>
          </a>
        }
        @if (showCart()) {
          <a routerLink="/carrito" class="btn btn-dark relative min-h-11 px-3 text-sm lg:hidden" [attr.aria-label]="'Carrito, ' + cart.count() + ' productos'">
            <i class="fa-solid fa-bag-shopping"></i>
            @if (cart.count()) {
              <span class="grid min-w-6 place-items-center rounded-full bg-mustard-400 px-1.5 text-xs font-bold text-ink-900">{{ cart.count() }}</span>
            }
          </a>
        }
      </div>
    </header>
  `,
})
export class SiteHeader {
  readonly back = input<string | null>(null);
  readonly showCart = input(true);
  protected readonly cart = inject(CartService);
  protected readonly recent = inject(RecentOrdersService);
}
