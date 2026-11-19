import { DatePipe } from '@angular/common';
import { Component, computed, inject, input, OnDestroy, OnInit, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { BACKEND } from '../../core/backend/backend';
import { ApiError, OrderStatus, OrderTracking } from '../../core/models';
import { customerStatus, progressSteps, readyDescription } from '../../core/status';
import { MoneyPipe } from '../../shared/money.pipe';
import { clockLabel, pickupLabel } from '../../shared/schedule';
import { SiteHeader } from '../../shared/site-header';

const TONE_BG: Record<string, string> = {
  amber: 'bg-mustard-400 text-ink-900',
  blue: 'bg-sky-500 text-white',
  orange: 'bg-brand-500 text-white',
  green: 'bg-emerald-500 text-white',
  violet: 'bg-violet-500 text-white',
  gray: 'bg-ink-500 text-white',
  red: 'bg-red-500 text-white',
};

/** Seguimiento público por token privado (§4.6). No muestra teléfono ni dirección. */
@Component({
  selector: 'app-tracking-page',
  imports: [RouterLink, DatePipe, MoneyPipe, SiteHeader],
  template: `
    <app-site-header />
    <main class="mx-auto max-w-xl px-4 pt-6 pb-16">
      @if (loading() && !order()) {
        <div class="h-64 animate-pulse rounded-3xl bg-cream-100" aria-busy="true"></div>
      } @else if (error() && !order()) {
        <div class="card p-8 text-center">
          <span class="mx-auto grid size-16 place-items-center rounded-full bg-brand-100 text-2xl text-brand-600"><i class="fa-solid fa-link-slash"></i></span>
          <h1 class="mt-4 text-2xl font-bold">Pedido no disponible</h1>
          <p class="mt-2 text-ink-500">{{ error() }}</p>
          <a routerLink="/" class="btn btn-primary mt-6">Ir al menú</a>
        </div>
      } @else if (order(); as o) {
        @if (justCreated && o.status !== 'CANCELLED') {
          <div class="mb-4 flex items-center gap-3 rounded-3xl bg-emerald-50 p-4 text-emerald-900 ring-1 ring-emerald-200 animate-fade-in" role="status">
            <i class="fa-solid fa-champagne-glasses text-2xl"></i>
            <div>
              <p class="font-bold">¡Pedido enviado, {{ o.customerFirstName }}!</p>
              <p class="text-sm">Guarda este enlace para ver el estado de tu pedido.</p>
            </div>
          </div>
        }

        <!-- Estado actual -->
        <section class="card overflow-hidden" aria-live="polite">
          <div class="flex items-center gap-4 p-5" [class]="toneBg()">
            <span class="grid size-14 shrink-0 place-items-center rounded-2xl bg-white/25 text-2xl">
              <i class="fa-solid" [class]="info().icon" [class.fa-bounce]="o.status === 'READY'"></i>
            </span>
            <div class="min-w-0">
              <!-- El número va grande: es lo que el cliente muestra al recoger su pedido. -->
              <p class="text-2xl font-extrabold tracking-wide">Pedido <span class="whitespace-nowrap">#{{ o.orderNumber }}</span></p>
              <h1 class="text-sm font-semibold opacity-90">{{ info().label }}</h1>
            </div>
          </div>
          <div class="p-5">
            <p class="text-ink-700">{{ description() }}</p>
            @if (o.status === 'REJECTED' && o.rejectionReason) {
              <p class="mt-2 rounded-2xl bg-red-50 p-3 text-sm text-red-800"><strong>Motivo:</strong> {{ o.rejectionReason }}</p>
            }
            @if (o.status === 'CANCELLED' && o.cancellationReason) {
              <p class="mt-2 rounded-2xl bg-cream-100 p-3 text-sm text-ink-700"><strong>Motivo:</strong> {{ o.cancellationReason }}</p>
            }
            @if (o.scheduledFor && !isTerminalBad()) {
              <p class="mt-3 flex items-center gap-2 rounded-2xl bg-brand-50 p-3 font-semibold text-brand-700">
                <i class="fa-solid fa-calendar-check"></i> Recoger {{ pickup() }}
              </p>
            }
            @if (!o.scheduledFor && o.estimatedPrepMinutes && ['PENDING', 'ACCEPTED', 'PREPARING'].includes(o.status)) {
              <p class="mt-2 text-sm text-ink-500"><i class="fa-solid fa-stopwatch"></i> Tiempo estimado de preparación: ~{{ o.estimatedPrepMinutes }} min</p>
            }

            @if (!isTerminalBad()) {
              <ol class="mt-6 space-y-0">
                @for (step of steps(); track step; let last = $last; let i = $index) {
                  <li class="flex gap-3">
                    <div class="flex flex-col items-center">
                      <span class="grid size-9 place-items-center rounded-full text-sm transition"
                        [class]="i < currentIndex() ? 'bg-emerald-500 text-white' : i === currentIndex() ? 'bg-brand-500 text-white ring-4 ring-brand-100' : 'bg-cream-100 text-ink-300'">
                        <i class="fa-solid" [class]="i < currentIndex() ? 'fa-check' : statusInfo(step).icon"></i>
                      </span>
                      @if (!last) {
                        <span class="my-1 w-0.5 flex-1 rounded" [class]="i < currentIndex() ? 'bg-emerald-400' : 'bg-cream-200'" style="min-height: 1.25rem"></span>
                      }
                    </div>
                    <div class="pb-4 pt-1.5">
                      <p class="font-semibold" [class.text-ink-300]="i > currentIndex()">{{ statusInfo(step).label }}</p>
                      @if (timeOf(step); as t) {
                        <p class="text-xs text-ink-500">{{ t | date: 'h:mm a' }}</p>
                      }
                    </div>
                  </li>
                }
              </ol>
            }
            @if (o.canCancel) {
              @if (!confirmingCancel()) {
                <button type="button" class="btn btn-ghost mt-2 w-full text-red-700" (click)="confirmingCancel.set(true)">
                  <i class="fa-solid fa-ban"></i> Cancelar pedido
                </button>
              } @else {
                <div class="mt-2 rounded-2xl bg-red-50 p-4 ring-1 ring-red-200 animate-fade-in" role="group" aria-labelledby="t-cancel">
                  <p id="t-cancel" class="font-bold text-red-900">¿Cancelar tu pedido?</p>
                  <p class="mt-1 text-sm text-red-800">Puedes cancelarlo mientras el restaurante no lo haya aceptado. ¿Nos cuentas por qué? <span class="opacity-75">(opcional)</span></p>
                  <div class="mt-3 flex flex-wrap gap-2">
                    @for (r of cancelReasons; track r) {
                      <button type="button" class="chip ring-1 transition" [attr.aria-pressed]="cancelReason() === r" (click)="cancelReason.set(cancelReason() === r ? null : r)"
                        [class]="cancelReason() === r ? 'bg-red-600 text-white ring-red-600' : 'bg-white text-ink-700 ring-red-200'">{{ r }}</button>
                    }
                  </div>
                  @if (cancelError(); as ce) {
                    <p class="mt-3 text-sm font-semibold text-red-800" role="alert"><i class="fa-solid fa-circle-exclamation"></i> {{ ce }}</p>
                  }
                  <div class="mt-4 grid grid-cols-2 gap-2">
                    <button type="button" class="btn btn-ghost bg-white px-3 whitespace-nowrap" [disabled]="cancelling()" (click)="confirmingCancel.set(false)">Mantenerlo</button>
                    <button type="button" class="btn bg-red-600 px-3 whitespace-nowrap text-white hover:bg-red-700" [disabled]="cancelling()" (click)="cancel()">
                      @if (cancelling()) { <i class="fa-solid fa-spinner fa-spin"></i> } @else { <i class="fa-solid fa-ban"></i> } Sí, cancelar
                    </button>
                  </div>
                </div>
              }
            } @else if (cancelError(); as ce) {
              <p class="mt-3 rounded-2xl bg-mustard-300/30 p-3 text-sm ring-1 ring-mustard-400/60" role="alert"><i class="fa-solid fa-circle-info"></i> {{ ce }}</p>
            }
            <p class="mt-2 flex items-center gap-2 text-xs text-ink-500">
              <span class="size-2 rounded-full bg-emerald-500" [class.animate-pulse]="!isFinal()"></span>
              {{ isFinal() ? 'Pedido finalizado' : 'Se actualiza automáticamente' }}
            </p>
          </div>
        </section>

        <!-- Detalle -->
        <section class="card mt-4 p-5" aria-labelledby="t-items">
          <div class="flex items-center justify-between">
            <h2 id="t-items" class="text-lg font-bold">Tu pedido</h2>
            <span class="chip bg-cream-100 text-ink-700">
              <i class="fa-solid" [class]="o.orderType === 'PICKUP' ? 'fa-store' : 'fa-motorcycle'"></i>
              {{ o.orderType === 'PICKUP' ? 'Recoger en local' : 'A domicilio' }}
            </span>
          </div>
          <ul class="mt-3 divide-y divide-cream-200">
            @for (item of o.items; track $index) {
              <li class="flex justify-between gap-3 py-3">
                <div>
                  <p class="font-medium"><span class="font-bold text-brand-600">{{ item.quantity }}×</span> {{ item.productName }}</p>
                  @if (item.options.length) {
                    <p class="text-sm text-ink-500">{{ item.options.join(' · ') }}</p>
                  }
                </div>
                <p class="shrink-0 font-medium">{{ item.lineTotal | money }}</p>
              </li>
            }
          </ul>
          <dl class="space-y-1.5 border-t border-dashed border-cream-200 pt-3 text-sm">
            <div class="flex justify-between"><dt class="text-ink-500">Subtotal</dt><dd>{{ o.subtotal | money }}</dd></div>
            @if (o.deliveryFee > 0) {
              <div class="flex justify-between"><dt class="text-ink-500">Envío</dt><dd>{{ o.deliveryFee | money }}</dd></div>
            }
            <div class="flex justify-between text-base font-bold"><dt>Total</dt><dd>{{ o.total | money }}</dd></div>
            <div class="flex justify-between"><dt class="text-ink-500">Pago</dt><dd>{{ o.paymentMethodLabel }}</dd></div>
          </dl>
        </section>

        <!-- Enlace del pedido: copiar o compartir para que alguien más le dé seguimiento -->
        <section class="card mt-4 p-5" aria-labelledby="t-link">
          <div class="flex items-start gap-3">
            <span class="grid size-11 shrink-0 place-items-center rounded-2xl bg-brand-50 text-lg text-brand-600"><i class="fa-solid fa-link"></i></span>
            <div class="min-w-0">
              <h2 id="t-link" class="font-bold">{{ o.restaurant.name }} link</h2>
              <p class="text-sm text-ink-500">Comparte este enlace para que alguien más siga tu pedido en tiempo real.</p>
            </div>
          </div>
          <div class="mt-4 grid grid-cols-2 gap-3">
            <button type="button" class="btn btn-ghost whitespace-nowrap px-3" (click)="copyLink()">
              <i class="fa-solid" [class]="copied() ? 'fa-check text-emerald-600' : 'fa-copy'"></i> {{ copied() ? 'Copiado' : 'Copiar enlace' }}
            </button>
            <button type="button" class="btn btn-primary whitespace-nowrap px-3" (click)="share(o)" [attr.aria-expanded]="shareOpen()">
              <i class="fa-solid fa-share-nodes"></i> Compartir
            </button>
          </div>
          @if (shareOpen()) {
            <div class="mt-3 grid grid-cols-5 gap-2 animate-fade-in" role="group" aria-label="Compartir en">
              @for (n of networks(o); track n.name) {
                <a [href]="n.href" target="_blank" rel="noopener" class="flex flex-col items-center gap-1 rounded-2xl p-2 text-xs font-semibold text-ink-700 hover:bg-cream-100" (click)="shareOpen.set(false)">
                  <span class="grid size-11 place-items-center rounded-full text-lg text-white" [style.background]="n.color"><i [class]="n.icon"></i></span>
                  {{ n.name }}
                </a>
              }
            </div>
          }
          <p class="mt-3 text-xs text-ink-400"><i class="fa-solid fa-lock"></i> Quien tenga el enlace puede ver el estado y el detalle de este pedido.</p>
        </section>

        <a routerLink="/" class="btn btn-primary mt-6 w-full"><i class="fa-solid fa-utensils"></i> Hacer otro pedido</a>
      }
    </main>
  `,
})
export class TrackingPage implements OnInit, OnDestroy {
  readonly token = input.required<string>();

  private readonly backend = inject(BACKEND);
  private stopWatch?: () => void;

  protected readonly order = signal<OrderTracking | null>(null);
  protected readonly loading = signal(true);
  protected readonly error = signal<string | null>(null);
  protected readonly copied = signal(false);
  protected readonly justCreated = !!history.state?.justCreated;

  protected readonly info = computed(() => customerStatus(this.order()?.status ?? 'PENDING', this.order()?.orderType ?? 'PICKUP'));
  protected readonly toneBg = computed(() => TONE_BG[this.info().tone]);
  protected readonly steps = computed(() => progressSteps(this.order()?.orderType ?? 'PICKUP'));
  protected readonly currentIndex = computed(() => {
    const o = this.order();
    if (!o) return 0;
    if (o.status === 'COMPLETED') return this.steps().length; // todo completado
    return this.steps().indexOf(o.status);
  });
  protected readonly isTerminalBad = computed(() => ['REJECTED', 'CANCELLED'].includes(this.order()?.status ?? ''));
  protected readonly isFinal = computed(() => ['COMPLETED', 'REJECTED', 'CANCELLED'].includes(this.order()?.status ?? ''));
  protected readonly description = computed(() => {
    const o = this.order();
    if (o?.status === 'READY') return readyDescription(o.orderType);
    if (o?.scheduledFor && o.status === 'ACCEPTED') return `¡Confirmado! Lo tendremos listo para las ${clockLabel(o.scheduledFor)}.`;
    if (o?.status === 'CANCELLED' && o.cancelledAt) return 'Cancelaste este pedido. No se preparará ni se te cobrará.';
    return this.info().description;
  });
  protected readonly pickup = computed(() => (this.order()?.scheduledFor ? pickupLabel(this.order()!.scheduledFor!) : ''));

  protected readonly cancelReasons = ['Ya no lo necesito', 'Me equivoqué en el pedido', 'Está tardando mucho', 'Voy a pedir de otra forma'];
  protected readonly confirmingCancel = signal(false);
  protected readonly cancelReason = signal<string | null>(null);
  protected readonly cancelling = signal(false);
  protected readonly cancelError = signal<string | null>(null);

  protected statusInfo(s: OrderStatus) {
    return customerStatus(s, this.order()?.orderType ?? 'PICKUP');
  }

  protected timeOf(s: OrderStatus): string | undefined {
    return this.order()?.timeline.find((t) => t.status === s)?.at;
  }

  ngOnInit(): void {
    void this.load();
    this.stopWatch = this.backend.watchTracking(this.token(), () => void this.load());
  }

  ngOnDestroy(): void {
    this.stopWatch?.();
  }

  private async load(): Promise<void> {
    try {
      this.order.set(await this.backend.rpc<OrderTracking>('get_order_tracking', { token: this.token() }));
      this.error.set(null);
      if (this.isFinal()) this.stopWatch?.();
    } catch (e) {
      this.error.set(e instanceof ApiError ? e.message : 'No pudimos cargar tu pedido.');
    } finally {
      this.loading.set(false);
    }
  }

  protected async cancel(): Promise<void> {
    if (this.cancelling()) return;
    this.cancelling.set(true);
    this.cancelError.set(null);
    try {
      this.order.set(await this.backend.rpc<OrderTracking>('cancel_guest_order', { token: this.token(), reason: this.cancelReason() ?? '' }));
      this.confirmingCancel.set(false);
      this.stopWatch?.();
    } catch (e) {
      this.cancelError.set(e instanceof ApiError ? e.message : 'No pudimos cancelar. Revisa tu conexión e intenta de nuevo.');
      if (e instanceof ApiError && e.code === 'NOT_CANCELLABLE') {
        this.confirmingCancel.set(false);
        await this.load();
      }
    } finally {
      this.cancelling.set(false);
    }
  }

  protected async copyLink(): Promise<void> {
    const url = location.href;
    try {
      await navigator.clipboard.writeText(url);
    } catch {
      // Sin API de portapapeles (navegadores viejos / sin HTTPS): método clásico.
      const t = document.createElement('textarea');
      t.value = url;
      t.setAttribute('readonly', '');
      t.style.position = 'fixed';
      t.style.opacity = '0';
      document.body.appendChild(t);
      t.select();
      const ok = document.execCommand('copy');
      t.remove();
      if (!ok) return;
    }
    this.copied.set(true);
    setTimeout(() => this.copied.set(false), 2000);
  }

  protected readonly shareOpen = signal(false);

  private shareText(o: OrderTracking): string {
    return `Sigue mi pedido #${o.orderNumber} de ${o.restaurant.name} en tiempo real:`;
  }

  /** Teléfonos: menú nativo de compartir (WhatsApp, Instagram, Facebook…). Si no existe, botones de redes. */
  protected async share(o: OrderTracking): Promise<void> {
    if (typeof navigator.share === 'function') {
      try {
        await navigator.share({ title: `${o.restaurant.name} · Pedido #${o.orderNumber}`, text: this.shareText(o), url: location.href });
        return;
      } catch (e) {
        if ((e as Error)?.name === 'AbortError') return; // el cliente cerró el menú
      }
    }
    this.shareOpen.update((v) => !v);
  }

  protected networks(o: OrderTracking): { name: string; icon: string; color: string; href: string }[] {
    const url = encodeURIComponent(location.href);
    const text = encodeURIComponent(this.shareText(o));
    return [
      { name: 'WhatsApp', icon: 'fa-brands fa-whatsapp', color: '#25D366', href: `https://wa.me/?text=${text}%20${url}` },
      { name: 'Facebook', icon: 'fa-brands fa-facebook-f', color: '#1877F2', href: `https://www.facebook.com/sharer/sharer.php?u=${url}` },
      { name: 'X', icon: 'fa-brands fa-x-twitter', color: '#111111', href: `https://x.com/intent/post?text=${text}&url=${url}` },
      { name: 'Telegram', icon: 'fa-brands fa-telegram', color: '#26A5E4', href: `https://t.me/share/url?url=${url}&text=${text}` },
      { name: 'Correo', icon: 'fa-solid fa-envelope', color: '#6B5B4E', href: `mailto:?subject=${encodeURIComponent(`Pedido #${o.orderNumber}`)}&body=${text}%20${url}` },
    ];
  }
}
