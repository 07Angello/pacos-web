import { NgTemplateOutlet } from '@angular/common';
import { Component, computed, inject, input, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { CartItem, CartService } from '../core/cart.service';
import { Product } from '../core/models';
import { ProductSheet } from '../features/menu/product-sheet';
import { MenuStore } from '../core/menu.store';
import { MoneyPipe } from './money.pipe';
import { ProductImage } from './product-image';

/** Lista editable del carrito + totales. Se usa en /carrito y en el panel lateral de escritorio. */
@Component({
  selector: 'app-cart-summary',
  imports: [RouterLink, NgTemplateOutlet, MoneyPipe, ProductImage, ProductSheet],
  template: `
    @if (cart.items().length === 0) {
      <div class="flex flex-col items-center px-6 py-10 text-center">
        <span class="mb-4 grid size-16 place-items-center rounded-full bg-cream-100 text-2xl text-brand-500">
          <i class="fa-solid fa-bag-shopping"></i>
        </span>
        <p class="font-display text-lg font-bold">Tu carrito está vacío</p>
        <p class="mt-1 text-sm text-ink-500">Agrega algo rico del menú para empezar.</p>
      </div>
    } @else {
      @if (cart.issues().length) {
        <div class="mb-4 rounded-2xl bg-mustard-300/30 p-4 text-sm ring-1 ring-mustard-400/60" role="alert">
          <p class="flex items-center gap-2 font-semibold"><i class="fa-solid fa-triangle-exclamation"></i> El menú cambió</p>
          <ul class="mt-1 list-inside list-disc text-ink-700">
            @for (issue of cart.issues(); track issue.key) {
              <li>{{ issue.message }} @if (issue.newPrice !== undefined) { Ahora: {{ issue.newPrice | money }} }</li>
            }
          </ul>
          <button type="button" class="btn btn-dark mt-3 min-h-10 w-full text-sm" (click)="cart.applyMenuChanges()">
            Actualizar mi carrito
          </button>
        </div>
      }

      <ul class="divide-y divide-cream-200">
        @for (item of cart.items(); track item.key) {
          <li class="flex gap-3 py-4">
            <app-product-image class="size-16 shrink-0 rounded-2xl" [icon]="item.categoryIcon ?? 'fa-utensils'" [size]="22" [alt]="item.productName" />
            <div class="min-w-0 flex-1">
              @if (editable()) {
                <button type="button" class="group -m-1.5 block w-[calc(100%+0.75rem)] rounded-xl p-1.5 text-left transition hover:bg-cream-100"
                  (click)="edit(item)" [attr.aria-label]="'Editar ' + item.productName">
                  <ng-container *ngTemplateOutlet="info; context: { $implicit: item }" />
                  <span class="mt-1 inline-flex items-center gap-1 text-xs font-semibold text-brand-600 group-hover:underline">
                    <i class="fa-solid fa-pen"></i> Editar opciones
                  </span>
                </button>
              } @else {
                <ng-container *ngTemplateOutlet="info; context: { $implicit: item }" />
              }
              @if (editable()) {
                <div class="mt-2 flex items-center gap-2">
                  <button type="button" class="qty-btn size-9" (click)="cart.setQuantity(item.key, item.quantity - 1)" [attr.aria-label]="'Quitar uno de ' + item.productName">
                    <i class="fa-solid" [class]="item.quantity === 1 ? 'fa-trash-can text-red-600' : 'fa-minus'"></i>
                  </button>
                  <span class="w-6 text-center font-semibold" aria-live="polite">{{ item.quantity }}</span>
                  <button type="button" class="qty-btn size-9" (click)="cart.setQuantity(item.key, item.quantity + 1)" [disabled]="item.quantity >= 20" [attr.aria-label]="'Agregar uno de ' + item.productName">
                    <i class="fa-solid fa-plus"></i>
                  </button>
                </div>
              } @else {
                <p class="mt-1 text-sm text-ink-500">Cantidad: {{ item.quantity }}</p>
              }
            </div>
          </li>
        }
      </ul>

      <ng-template #info let-item>
        <div class="flex items-start justify-between gap-2">
          <p class="font-semibold leading-tight">{{ item.productName }}</p>
          <p class="shrink-0 font-semibold">{{ item.unitPrice * item.quantity | money }}</p>
        </div>
        @if (item.selections.length) {
          <p class="mt-0.5 text-sm text-ink-500">{{ selectionText(item.selections) }}</p>
        }
        @if (item.notes) {
          <p class="mt-1 flex items-start gap-1.5 text-sm text-brand-700"><i class="fa-solid fa-comment-dots mt-0.5 text-xs"></i>{{ item.notes }}</p>
        }
      </ng-template>

      @if (editMessage()) {
        <p class="mt-2 rounded-2xl bg-cream-100 p-3 text-sm text-ink-700" role="status"><i class="fa-solid fa-circle-info"></i> {{ editMessage() }}</p>
      }

      <dl class="mt-2 space-y-2 border-t border-dashed border-cream-200 pt-4 text-sm">
        <div class="flex justify-between"><dt class="text-ink-500">Subtotal</dt><dd class="font-semibold">{{ cart.subtotal() | money }}</dd></div>
        @if (deliveryFee() !== null) {
          <div class="flex justify-between"><dt class="text-ink-500">Envío a domicilio</dt><dd class="font-semibold">{{ deliveryFee() | money }}</dd></div>
        }
        <div class="flex justify-between pt-1 text-lg"><dt class="font-display font-bold">Total</dt><dd class="font-display font-bold">{{ total() | money }}</dd></div>
        @if (deliveryFee() === null && menu.settings()?.deliveryEnabled) {
          <p class="text-xs text-ink-500">Envío a domicilio: {{ menu.settings()?.deliveryFee | money }} (se agrega en el checkout)</p>
        }
      </dl>

      @if (showCheckout()) {
        @if (menu.settings()?.isOpen === false) {
          <p class="mt-4 rounded-2xl bg-cream-100 p-3 text-center text-sm font-medium text-ink-700">
            <i class="fa-solid fa-moon mr-1"></i> Estamos cerrados. Podrás confirmar cuando abramos.
          </p>
        } @else {
          <a routerLink="/checkout" class="btn btn-primary mt-4 w-full" [class.pointer-events-none]="cart.issues().length" [class.opacity-50]="cart.issues().length">
            Continuar <i class="fa-solid fa-arrow-right"></i>
          </a>
        }
      }
    }

    @if (editing(); as e) {
      <app-product-sheet [product]="e.product" [editItem]="e.item" (dismissed)="editing.set(null)" />
    }
  `,
})
export class CartSummary {
  readonly editable = input(true);
  readonly showCheckout = input(true);
  /** Tarifa de envío a mostrar (null = no aplica todavía). */
  readonly deliveryFee = input<number | null>(null);

  protected readonly cart = inject(CartService);
  protected readonly menu = inject(MenuStore);
  protected readonly total = computed(() => this.cart.subtotal() + (this.deliveryFee() ?? 0));

  protected readonly editing = signal<{ product: Product; item: CartItem } | null>(null);
  protected readonly editMessage = signal<string | null>(null);

  /** Reabre el producto con lo que el cliente eligió para cambiar extras, opciones, notas o cantidad. */
  protected edit(item: CartItem): void {
    const product = this.menu.productsById().get(item.productId);
    if (!product || !product.isAvailable) {
      this.editMessage.set(`${item.productName} ya no está disponible; puedes quitarlo del carrito.`);
      return;
    }
    this.editMessage.set(null);
    this.editing.set({ product, item });
  }

  protected selectionText(sel: { label: string }[]): string {
    return sel.map((s) => s.label).join(' · ');
  }
}
