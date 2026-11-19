import { Component, inject, OnInit } from '@angular/core';
import { RouterLink } from '@angular/router';
import { CartService } from '../../core/cart.service';
import { MenuStore } from '../../core/menu.store';
import { CartSummary } from '../../shared/cart-summary';
import { SiteHeader } from '../../shared/site-header';

@Component({
  selector: 'app-cart-page',
  imports: [RouterLink, SiteHeader, CartSummary],
  template: `
    <app-site-header back="/" [showCart]="false" />
    <main class="mx-auto max-w-xl px-4 pt-6 pb-16">
      <div class="flex items-end justify-between">
        <h1 class="text-3xl font-extrabold">Tu carrito</h1>
        @if (cart.count()) {
          <a routerLink="/" class="text-sm font-semibold text-brand-600 hover:underline"><i class="fa-solid fa-plus"></i> Agregar más</a>
        }
      </div>
      <div class="card mt-4 p-5">
        <app-cart-summary />
      </div>
      @if (!cart.count()) {
        <a routerLink="/" class="btn btn-primary mt-6 w-full"><i class="fa-solid fa-utensils"></i> Ver el menú</a>
      }
    </main>
  `,
})
export class CartPage implements OnInit {
  protected readonly cart = inject(CartService);
  private readonly menu = inject(MenuStore);

  ngOnInit(): void {
    void this.menu.ensureLoaded();
  }
}
