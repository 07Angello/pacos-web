import { DatePipe } from '@angular/common';
import { Component, inject } from '@angular/core';
import { RouterLink } from '@angular/router';
import { RecentOrdersService } from '../../core/recent-orders.service';
import { MoneyPipe } from '../../shared/money.pipe';
import { SiteHeader } from '../../shared/site-header';

@Component({
  selector: 'app-my-orders-page',
  imports: [RouterLink, DatePipe, MoneyPipe, SiteHeader],
  template: `
    <app-site-header back="/" />
    <main class="mx-auto max-w-xl px-4 pt-6 pb-16">
      <h1 class="text-3xl font-extrabold">Mis pedidos</h1>
      <p class="mt-1 text-sm text-ink-500">Pedidos hechos desde este dispositivo. Toca uno para ver su estado.</p>
      <ul class="mt-5 space-y-3">
        @for (o of recent.orders(); track o.token) {
          <li>
            <a [routerLink]="['/pedido', o.token]" class="card flex items-center gap-4 p-4 transition hover:-translate-y-0.5">
              <span class="grid size-12 place-items-center rounded-2xl bg-brand-50 text-xl text-brand-600"><i class="fa-solid fa-receipt"></i></span>
              <span class="flex-1">
                <span class="block font-display text-lg font-bold">#{{ o.orderNumber }}</span>
                <span class="text-sm text-ink-500">{{ o.createdAt | date: 'd MMM, h:mm a' }} · {{ o.total | money }}</span>
              </span>
              <i class="fa-solid fa-chevron-right text-ink-300"></i>
            </a>
          </li>
        } @empty {
          <li class="card p-8 text-center text-ink-500">Aún no has hecho pedidos desde este dispositivo.</li>
        }
      </ul>
      <p class="mt-6 text-center text-xs text-ink-500">
        ¿Perdiste el enlace de un pedido? Llámanos y con gusto te ayudamos.
      </p>
    </main>
  `,
})
export class MyOrdersPage {
  protected readonly recent = inject(RecentOrdersService);
}
