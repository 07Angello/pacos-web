import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { CartService } from '../../core/cart.service';
import { MenuStore } from '../../core/menu.store';
import { Product } from '../../core/models';
import { CartSummary } from '../../shared/cart-summary';
import { MoneyPipe } from '../../shared/money.pipe';
import { ProductImage } from '../../shared/product-image';
import { hhmmLabel } from '../../shared/schedule';
import { SiteHeader } from '../../shared/site-header';
import { ProductSheet } from './product-sheet';

@Component({
  selector: 'app-menu-page',
  imports: [FormsModule, RouterLink, SiteHeader, ProductImage, ProductSheet, CartSummary, MoneyPipe],
  template: `
    <app-site-header />

    @if (store.loading() && !store.menu()) {
      <div class="mx-auto max-w-6xl px-4 py-8" aria-busy="true">
        <div class="h-40 animate-pulse rounded-3xl bg-cream-100"></div>
        <div class="mt-6 grid gap-4 sm:grid-cols-2">
          @for (i of [1, 2, 3, 4]; track i) {
            <div class="h-32 animate-pulse rounded-3xl bg-cream-100"></div>
          }
        </div>
      </div>
    } @else if (store.error() && !store.menu()) {
      <div class="mx-auto max-w-md px-4 py-16 text-center">
        <span class="mx-auto grid size-16 place-items-center rounded-full bg-brand-100 text-2xl text-brand-600"><i class="fa-solid fa-plug-circle-xmark"></i></span>
        <h1 class="mt-4 text-2xl font-bold">No pudimos cargar el menú</h1>
        <p class="mt-2 text-ink-500">{{ store.error() }}</p>
        <button type="button" class="btn btn-primary mt-6" (click)="store.refresh()"><i class="fa-solid fa-rotate-right"></i> Reintentar</button>
      </div>
    } @else if (store.settings(); as s) {
      <!-- Hero del restaurante -->
      <section class="relative overflow-hidden bg-ink-900 text-white">
        <div class="pointer-events-none absolute inset-0 opacity-20" aria-hidden="true">
          <i class="fa-solid fa-burger absolute -top-6 right-6 rotate-12 text-[9rem] text-brand-400"></i>
          <i class="fa-solid fa-pepper-hot absolute bottom-2 left-[45%] -rotate-12 text-6xl text-mustard-400"></i>
          <i class="fa-solid fa-drumstick-bite absolute top-10 left-[-1rem] text-7xl text-brand-300"></i>
        </div>
        <div class="relative mx-auto max-w-6xl px-4 pt-8 pb-10 sm:pt-12">
          <span class="chip" [class]="s.isOpen ? 'bg-emerald-400/20 text-emerald-200 ring-1 ring-emerald-300/40' : 'bg-white/10 text-white/80 ring-1 ring-white/20'">
            <span class="size-2 rounded-full" [class]="s.isOpen ? 'bg-emerald-300' : 'bg-white/50'"></span>
            {{ s.isOpen ? 'Abierto · recibiendo pedidos' : 'Cerrado por ahora' }}
          </span>
          <h1 class="mt-3 text-4xl font-extrabold tracking-tight sm:text-5xl">{{ s.name }}</h1>
          <p class="mt-2 max-w-xl text-lg text-white/80">{{ s.tagline }}</p>

          <div class="mt-5 flex flex-wrap gap-2 text-sm">
            @if (todayHours(); as h) {
              <span class="chip bg-white/10 py-1.5 text-white"><i class="fa-regular fa-clock"></i> Hoy {{ h }}</span>
            }
            @if (s.address) {
              <span class="chip bg-white/10 py-1.5 text-white"><i class="fa-solid fa-location-dot"></i> {{ s.address }}</span>
            }
            @if (s.phone) {
              <a class="chip bg-white/10 py-1.5 text-white hover:bg-white/20" [href]="'tel:' + s.phone"><i class="fa-solid fa-phone"></i> {{ s.phone }}</a>
            }
          </div>
          <div class="mt-3 flex flex-wrap gap-2 text-sm">
            @if (s.pickupEnabled) {
              <span class="chip bg-mustard-400 py-1.5 text-ink-900"><i class="fa-solid fa-store"></i> Recoger en local</span>
            }
            @if (s.deliveryEnabled) {
              <span class="chip bg-mustard-400 py-1.5 text-ink-900"><i class="fa-solid fa-motorcycle"></i> Domicilio {{ s.deliveryFee | money }}</span>
            }
            @if (s.estimatedPrepMinutes) {
              <span class="chip bg-white/10 py-1.5 text-white"><i class="fa-solid fa-stopwatch"></i> ~{{ s.estimatedPrepMinutes }} min</span>
            }
            @if (paymentLabels(); as pl) {
              <span class="chip bg-white/10 py-1.5 text-white"><i class="fa-solid fa-wallet"></i> Pago: {{ pl }}</span>
            }
          </div>
        </div>
      </section>

      @if (!s.isOpen) {
        <div class="border-b border-cream-200 bg-cream-100">
          <p class="mx-auto flex max-w-6xl items-center gap-2 px-4 py-3 text-sm font-medium text-ink-700">
            <i class="fa-solid fa-moon text-brand-500"></i>
            Ahora no estamos recibiendo pedidos. Puedes ver el menú y armar tu carrito; podrás confirmarlo cuando abramos.
          </p>
        </div>
      }

      <!-- Barra de categorías -->
      <nav class="sticky top-16 z-20 border-b border-cream-200/80 bg-cream-50/95 backdrop-blur-md" aria-label="Categorías">
        <div class="mx-auto flex max-w-6xl items-center gap-2 overflow-x-auto px-4 py-3 [scrollbar-width:none]">
          <label class="relative shrink-0">
            <span class="sr-only">Buscar en el menú</span>
            <i class="fa-solid fa-magnifying-glass pointer-events-none absolute top-1/2 left-3.5 -translate-y-1/2 text-sm text-ink-500"></i>
            <input type="search" class="h-10 w-36 rounded-full border-0 bg-white pr-3 pl-9 text-sm ring-1 ring-cream-200 focus:w-48 focus:ring-2 focus:ring-brand-400 focus:outline-none sm:w-48"
              placeholder="Buscar…" [ngModel]="query()" (ngModelChange)="query.set($event)" />
          </label>
          @for (c of store.categories(); track c.id) {
            <button type="button" class="chip h-10 shrink-0 px-4 text-sm transition"
              [class]="activeCategory() === c.id ? 'bg-ink-900 text-white' : 'bg-white text-ink-700 ring-1 ring-cream-200 hover:bg-cream-100'"
              (click)="scrollTo(c.id)">
              <i class="fa-solid" [class]="c.icon ?? 'fa-utensils'"></i> {{ c.name }}
            </button>
          }
        </div>
      </nav>

      <div class="mx-auto grid max-w-6xl gap-8 px-4 pt-6 pb-32 lg:grid-cols-[1fr_360px] lg:pb-12">
        <main class="min-w-0">
          @if (!query() && store.featured().length) {
            <section class="mb-8" aria-labelledby="fav-title">
              <h2 id="fav-title" class="mb-3 flex items-center gap-2 text-xl font-bold"><i class="fa-solid fa-fire text-brand-500"></i> Los favoritos</h2>
              <div class="-mx-4 flex snap-x gap-3 overflow-x-auto px-4 pb-2 [scrollbar-width:none]">
                @for (p of store.featured(); track p.id) {
                  <button type="button" class="card w-56 shrink-0 snap-start overflow-hidden text-left transition hover:-translate-y-0.5" (click)="open(p)">
                    <app-product-image class="h-28 w-full" [path]="p.imagePath" [icon]="iconOf(p)" [size]="44" [alt]="p.name" />
                    <div class="p-3">
                      <p class="truncate font-semibold">{{ p.name }}</p>
                      <p class="text-sm font-bold text-brand-600">{{ p.price | money }}</p>
                    </div>
                  </button>
                }
              </div>
            </section>
          }

          @for (section of sections(); track section.category.id) {
            <section class="mb-10" [id]="'cat-' + section.category.id" [attr.aria-labelledby]="'h-' + section.category.id">
              <div class="mb-3">
                <h2 [id]="'h-' + section.category.id" class="flex items-center gap-2 text-xl font-bold">
                  <i class="fa-solid text-brand-500" [class]="section.category.icon ?? 'fa-utensils'"></i> {{ section.category.name }}
                </h2>
                @if (section.category.description) {
                  <p class="text-sm text-ink-500">{{ section.category.description }}</p>
                }
              </div>
              <div class="grid gap-3 sm:grid-cols-2">
                @for (p of section.products; track p.id) {
                  <button type="button" class="card group flex min-h-32 items-stretch gap-3 overflow-hidden p-3 text-left transition enabled:hover:-translate-y-0.5 enabled:hover:shadow-float disabled:opacity-60"
                    (click)="open(p)" [disabled]="!p.isAvailable" [attr.aria-label]="p.name + ', ' + (p.price | money) + (p.isAvailable ? '' : ', agotado')">
                    <div class="flex min-w-0 flex-1 flex-col">
                      <p class="font-semibold leading-snug">{{ p.name }}</p>
                      <p class="mt-1 line-clamp-2 text-sm text-ink-500">{{ p.description }}</p>
                      <div class="mt-auto flex items-center gap-2 pt-2">
                        <span class="font-bold text-ink-900">{{ p.price | money }}</span>
                        @if (!p.isAvailable) {
                          <span class="chip bg-cream-200 text-ink-700">Agotado</span>
                        } @else if (p.options.length) {
                          <span class="text-xs text-ink-500">Personalizable</span>
                        }
                      </div>
                    </div>
                    <div class="relative shrink-0">
                      <app-product-image class="size-24 rounded-2xl" [path]="p.imagePath" [icon]="section.category.icon ?? 'fa-utensils'" [size]="34" [alt]="p.name" />
                      @if (p.isAvailable) {
                        <span class="absolute -right-1 -bottom-1 grid size-9 place-items-center rounded-full bg-white text-brand-600 shadow ring-1 ring-cream-200 transition group-hover:bg-brand-500 group-hover:text-white">
                          <i class="fa-solid fa-plus"></i>
                        </span>
                      }
                    </div>
                  </button>
                }
              </div>
            </section>
          } @empty {
            <div class="py-16 text-center text-ink-500">
              <i class="fa-solid fa-magnifying-glass mb-3 text-3xl"></i>
              <p>No encontramos "{{ query() }}" en el menú.</p>
            </div>
          }
        </main>

        <!-- Carrito lateral (escritorio) -->
        <aside class="hidden lg:block" aria-label="Tu pedido">
          <div class="card sticky top-36 max-h-[calc(100dvh-10rem)] overflow-y-auto p-5">
            <h2 class="flex items-center gap-2 text-lg font-bold"><i class="fa-solid fa-bag-shopping text-brand-500"></i> Tu pedido</h2>
            <app-cart-summary />
          </div>
        </aside>
      </div>

      <!-- Barra flotante de carrito (móvil/tablet) -->
      @if (cart.count() > 0) {
        <div class="fixed inset-x-0 bottom-0 z-30 flex justify-center px-4 pb-[max(1rem,env(safe-area-inset-bottom))] lg:hidden">
          <a routerLink="/carrito" class="btn btn-primary mx-auto h-14 w-full max-w-lg justify-between rounded-2xl px-5 shadow-float">
            <span class="flex items-center gap-2">
              <span class="grid size-8 place-items-center rounded-full bg-white/20 font-bold" [class.animate-pop]="bump()">{{ cart.count() }}</span>
              Ver carrito
            </span>
            <span class="font-bold">{{ cart.subtotal() | money }}</span>
          </a>
        </div>
      }
    }

    @if (selected(); as p) {
      <app-product-sheet [product]="p" (dismissed)="selected.set(null)" (added)="onAdded($event)" />
    }

    @if (toast(); as t) {
      <div class="fixed inset-x-0 top-20 z-[60] flex justify-center px-4" role="status" aria-live="polite">
        <p class="flex items-center gap-2 rounded-full bg-ink-900 px-4 py-2.5 text-sm font-medium text-white shadow-float animate-fade-in">
          <i class="fa-solid fa-circle-check text-emerald-400"></i> {{ t }}
        </p>
      </div>
    }
  `,
})
export class MenuPage implements OnInit {
  protected readonly store = inject(MenuStore);
  protected readonly cart = inject(CartService);

  protected readonly query = signal('');
  protected readonly selected = signal<Product | null>(null);
  protected readonly activeCategory = signal<string | null>(null);
  protected readonly toast = signal<string | null>(null);
  protected readonly bump = signal(false);
  private toastTimer?: ReturnType<typeof setTimeout>;

  protected readonly sections = computed(() => {
    const q = normalize(this.query());
    return this.store
      .categories()
      .map((category) => ({
        category,
        products: this.store
          .products()
          .filter((p) => p.categoryId === category.id)
          .filter((p) => !q || normalize(`${p.name} ${p.description ?? ''}`).includes(q)),
      }))
      .filter((s) => s.products.length > 0);
  });

  protected readonly paymentLabels = computed(() =>
    (this.store.settings()?.paymentMethods ?? []).map((m) => m.label.toLowerCase()).join(' o '),
  );

  protected readonly todayHours = computed(() => {
    const s = this.store.settings();
    if (!s) return null;
    const weekday = Number(new Intl.DateTimeFormat('en-US', { timeZone: s.timezone, weekday: 'short' }).formatToParts(new Date())
      .map((p) => ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(p.value)).find((i) => i >= 0));
    const h = s.businessHours.find((b) => b.weekday === weekday);
    if (!h) return null;
    return h.isClosed ? 'cerrado' : `${hhmmLabel(h.opensAt)} – ${hhmmLabel(h.closesAt)}`;
  });

  ngOnInit(): void {
    void this.store.ensureLoaded();
  }

  protected iconOf(p: Product): string {
    return this.store.categoryOf(p)?.icon ?? 'fa-utensils';
  }

  protected open(p: Product): void {
    if (p.isAvailable) this.selected.set(p);
  }

  protected scrollTo(categoryId: string): void {
    this.query.set('');
    this.activeCategory.set(categoryId);
    queueMicrotask(() => document.getElementById(`cat-${categoryId}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
  }

  protected onAdded(name: string): void {
    this.toast.set(`${name} agregado al carrito`);
    this.bump.set(false);
    queueMicrotask(() => this.bump.set(true));
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => this.toast.set(null), 2200);
  }
}

function normalize(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
}
