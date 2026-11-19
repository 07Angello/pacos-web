import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';
import { BACKEND } from '../../core/backend/backend';
import { CartService } from '../../core/cart.service';
import { CustomerProfileService } from '../../core/customer-profile.service';
import { MenuStore } from '../../core/menu.store';
import { ApiError, CreateOrderInput, CreateOrderResult, OrderType, PickupSlots, ValidationDetails } from '../../core/models';
import { RecentOrdersService } from '../../core/recent-orders.service';
import { VisitorTrackerService } from '../../core/visitor-tracker.service';
import { CartSummary } from '../../shared/cart-summary';
import { MoneyPipe } from '../../shared/money.pipe';
import { paymentHint, paymentIcon } from '../../shared/payment';
import { maskHnPhone, normalizeHnPhone } from '../../shared/phone';
import { clockLabel, pickupLabel, weekdayLabel } from '../../shared/schedule';
import { SiteHeader } from '../../shared/site-header';

const PENDING_KEY = 'pacos.checkout.idempotency';

type Field = 'name' | 'phone' | 'orderType' | 'scheduledFor' | 'neighborhood' | 'street' | 'reference' | 'paymentMethod';

/** Checkout como invitado (§4.5). Sin registro, sin OTP. */
@Component({
  selector: 'app-checkout-page',
  imports: [FormsModule, RouterLink, SiteHeader, CartSummary, MoneyPipe],
  template: `
    <app-site-header back="/carrito" [showCart]="false" />

    @if (cart.count() === 0 && !submitting()) {
      <main class="mx-auto max-w-md px-4 py-16 text-center">
        <p class="text-lg font-semibold">Tu carrito está vacío.</p>
        <a routerLink="/" class="btn btn-primary mt-6">Ver el menú</a>
      </main>
    } @else if (menu.settings(); as s) {
      <main class="mx-auto grid max-w-5xl gap-6 px-4 pt-6 pb-36 lg:grid-cols-[1fr_380px] lg:pb-16">
        <form id="checkout" class="space-y-6" (ngSubmit)="submit()" novalidate>
          <h1 class="text-3xl font-extrabold">Confirmar pedido</h1>

          @if (prefilled()) {
            <div class="flex items-center gap-3 rounded-2xl bg-emerald-50 p-3 text-sm text-emerald-900 ring-1 ring-emerald-200 animate-fade-in" role="status">
              <i class="fa-solid fa-user-check text-lg"></i>
              <p class="min-w-0 flex-1">Llenamos tus datos del último pedido, <strong>{{ firstName() }}</strong>. Revisa que sigan correctos.</p>
              <button type="button" class="shrink-0 font-semibold underline" (click)="forgetMe()">No soy yo</button>
            </div>
          }

          <!-- Tipo de pedido -->
          <section class="card p-5" aria-labelledby="t-type">
            <h2 id="t-type" class="mb-3 text-lg font-bold">¿Cómo lo quieres?</h2>
            <div class="grid grid-cols-2 gap-3" role="radiogroup" aria-labelledby="t-type">
              @if (s.pickupEnabled) {
                <button type="button" role="radio" [attr.aria-checked]="orderType() === 'PICKUP'" (click)="orderType.set('PICKUP')"
                  class="flex flex-col items-center gap-1.5 rounded-2xl p-4 ring-1 transition"
                  [class]="orderType() === 'PICKUP' ? 'bg-brand-50 ring-2 ring-brand-500' : 'bg-white ring-cream-200 hover:bg-cream-100'">
                  <i class="fa-solid fa-store text-2xl text-brand-500"></i>
                  <span class="font-semibold">Recoger</span>
                  <span class="text-xs text-ink-500">En el local · gratis</span>
                </button>
              }
              @if (s.deliveryEnabled) {
                <button type="button" role="radio" [attr.aria-checked]="orderType() === 'DELIVERY'" (click)="orderType.set('DELIVERY')"
                  class="flex flex-col items-center gap-1.5 rounded-2xl p-4 ring-1 transition"
                  [class]="orderType() === 'DELIVERY' ? 'bg-brand-50 ring-2 ring-brand-500' : 'bg-white ring-cream-200 hover:bg-cream-100'">
                  <i class="fa-solid fa-motorcycle text-2xl text-brand-500"></i>
                  <span class="font-semibold">A domicilio</span>
                  <span class="text-xs text-ink-500">Envío {{ s.deliveryFee | money }}</span>
                </button>
              }
            </div>
            @if (err('orderType')) {
              <p class="field-error"><i class="fa-solid fa-circle-exclamation"></i>{{ err('orderType') }}</p>
            }

            <!-- Hora de recogida -->
            @if (orderType() === 'PICKUP') {
              <div class="mt-5 border-t border-cream-200 pt-4">
                <h3 id="t-when" class="mb-3 font-bold">¿Cuándo pasas a recogerlo?</h3>
                <div class="grid grid-cols-2 gap-3" role="radiogroup" aria-labelledby="t-when">
                  <button type="button" role="radio" [attr.aria-checked]="!scheduleMode()" (click)="setScheduleMode(false)"
                    class="flex min-w-0 flex-col items-center gap-1 rounded-2xl p-3 text-center ring-1 transition"
                    [class]="!scheduleMode() ? 'bg-brand-50 ring-2 ring-brand-500' : 'bg-white ring-cream-200 hover:bg-cream-100'">
                    <i class="fa-solid fa-bolt text-xl text-brand-500"></i>
                    <span class="font-semibold">Lo antes posible</span>
                    <span class="text-xs text-ink-500">{{ s.estimatedPrepMinutes ? '~' + s.estimatedPrepMinutes + ' min' : 'Al confirmar' }}</span>
                  </button>
                  <button type="button" role="radio" [attr.aria-checked]="scheduleMode()" (click)="setScheduleMode(true)"
                    class="flex min-w-0 flex-col items-center gap-1 rounded-2xl p-3 text-center ring-1 transition"
                    [class]="scheduleMode() ? 'bg-brand-50 ring-2 ring-brand-500' : 'bg-white ring-cream-200 hover:bg-cream-100'">
                    <i class="fa-solid fa-calendar-check text-xl text-brand-500"></i>
                    <span class="font-semibold">Programar hora</span>
                    <span class="truncate text-xs text-ink-500 max-w-full">{{ scheduledFor() ? chosenLabel() : 'Hoy o mañana' }}</span>
                  </button>
                </div>

                @if (scheduleMode()) {
                  @if (slotsLoading() && !slots()) {
                    <div class="mt-4 h-28 animate-pulse rounded-2xl bg-cream-100" aria-busy="true"></div>
                  } @else if (!slots()?.days?.length) {
                    <p class="mt-4 rounded-2xl bg-cream-100 p-4 text-sm text-ink-700">
                      <i class="fa-solid fa-circle-info"></i> No hay horarios disponibles para programar. Puedes pedirlo para lo antes posible.
                    </p>
                  } @else {
                    <div class="mt-4 flex gap-2" role="tablist" aria-label="Día de recogida">
                      @for (d of slots()!.days; track d.date) {
                        <button type="button" role="tab" [attr.aria-selected]="slotDay() === d.dayIndex" (click)="slotDay.set(d.dayIndex)"
                          class="flex-1 rounded-2xl px-3 py-2 text-center ring-1 transition"
                          [class]="slotDay() === d.dayIndex ? 'bg-ink-900 text-white ring-ink-900' : 'bg-white ring-cream-200 hover:bg-cream-100'">
                          <span class="block font-semibold">{{ d.dayIndex === 0 ? 'Hoy' : 'Mañana' }}</span>
                          <span class="block text-xs opacity-75">{{ weekday(d.date) }}</span>
                        </button>
                      }
                    </div>
                    <div class="mt-3 grid max-h-64 grid-cols-3 gap-2 overflow-y-auto p-0.5 sm:grid-cols-4" role="radiogroup" aria-label="Hora de recogida">
                      @for (slot of daySlots(); track slot.at) {
                        <button type="button" role="radio" [attr.aria-checked]="scheduledFor() === slot.at" (click)="pickSlot(slot.at)"
                          class="h-11 rounded-xl text-sm font-semibold ring-1 transition"
                          [class]="scheduledFor() === slot.at ? 'bg-brand-500 text-white ring-brand-500' : 'bg-white ring-cream-200 hover:bg-cream-100'">
                          {{ clock(slot.at) }}
                        </button>
                      }
                    </div>
                    <p class="mt-2 text-xs text-ink-500">
                      <i class="fa-solid fa-circle-info"></i> Lo tendremos listo a esa hora. Puedes programarlo con al menos {{ slots()!.leadMinutes }} min de anticipación.
                    </p>
                  }
                }
                @if (err('scheduledFor')) {
                  <p class="field-error"><i class="fa-solid fa-circle-exclamation"></i>{{ err('scheduledFor') }}</p>
                }
              </div>
            }
          </section>

          <!-- Datos de contacto -->
          <section class="card space-y-4 p-5" aria-labelledby="t-contact">
            <h2 id="t-contact" class="text-lg font-bold">Tus datos</h2>
            <div>
              <label class="field-label" for="name">Nombre de quien recibe</label>
              <input id="name" name="name" class="field" [class.field-invalid]="err('name')" autocomplete="name" maxlength="60"
                [(ngModel)]="name" [attr.aria-invalid]="!!err('name')" aria-describedby="name-err" />
              @if (err('name')) {<p id="name-err" class="field-error"><i class="fa-solid fa-circle-exclamation"></i>{{ err('name') }}</p>}
            </div>
            <div>
              <label class="field-label" for="phone">Teléfono</label>
              <div class="relative">
                <span class="pointer-events-none absolute top-1/2 left-4 -translate-y-1/2 font-medium text-ink-500">+504</span>
                <input #phoneInput id="phone" name="phone" type="tel" inputmode="numeric" class="field pl-16 tracking-wide" [class.field-invalid]="err('phone')" autocomplete="tel-national"
                  [value]="phone()" (input)="onPhoneInput(phoneInput)" (keydown)="onPhoneKeydown($event)"
                  [attr.aria-invalid]="!!err('phone')" aria-describedby="phone-help phone-err" placeholder="9999-9999" maxlength="9" />
              </div>
              <p id="phone-help" class="mt-1.5 text-xs text-ink-500">Lo usaremos solo para comunicarnos sobre este pedido.</p>
              @if (err('phone')) {<p id="phone-err" class="field-error"><i class="fa-solid fa-circle-exclamation"></i>{{ err('phone') }}</p>}
            </div>
          </section>

          <!-- Dirección -->
          @if (orderType() === 'DELIVERY') {
            <section class="card space-y-4 p-5" aria-labelledby="t-address">
              <h2 id="t-address" class="text-lg font-bold"><i class="fa-solid fa-location-dot mr-1 text-brand-500"></i> Dirección de entrega</h2>
              <div>
                <label class="field-label" for="neighborhood">Colonia o barrio</label>
                <input id="neighborhood" name="neighborhood" class="field" [class.field-invalid]="err('neighborhood')" maxlength="80" [(ngModel)]="neighborhood" placeholder="Ej.: Col. Palmira" />
                @if (err('neighborhood')) {<p class="field-error"><i class="fa-solid fa-circle-exclamation"></i>{{ err('neighborhood') }}</p>}
              </div>
              <div class="grid gap-4 sm:grid-cols-2">
                <div>
                  <label class="field-label" for="street">Calle / avenida</label>
                  <input id="street" name="street" class="field" [class.field-invalid]="err('street')" maxlength="120" [(ngModel)]="street" placeholder="Ej.: 3ra avenida" />
                  @if (err('street')) {<p class="field-error"><i class="fa-solid fa-circle-exclamation"></i>{{ err('street') }}</p>}
                </div>
                <div>
                  <label class="field-label" for="house">Casa / apto. <span class="font-normal text-ink-500">(opcional)</span></label>
                  <input id="house" name="house" class="field" maxlength="80" [(ngModel)]="house" placeholder="Ej.: Casa 12" />
                </div>
              </div>
              <div>
                <label class="field-label" for="reference">Referencia</label>
                <input id="reference" name="reference" class="field" [class.field-invalid]="err('reference')" maxlength="160" [(ngModel)]="reference" placeholder="Ej.: Frente a la pulpería, portón negro" />
                @if (err('reference')) {<p class="field-error"><i class="fa-solid fa-circle-exclamation"></i>{{ err('reference') }}</p>}
              </div>
              <p class="text-xs text-ink-500"><i class="fa-solid fa-circle-info"></i> El restaurante confirmará la cobertura de tu zona.</p>
            </section>
          }

          <!-- Pago y notas -->
          <section class="card space-y-4 p-5" aria-labelledby="t-pay">
            <h2 id="t-pay" class="text-lg font-bold">Pago</h2>
            <div class="space-y-2" role="radiogroup" aria-labelledby="t-pay">
              @for (m of s.paymentMethods; track m.code) {
                <label class="flex min-h-14 items-center gap-3 rounded-2xl px-4 ring-1 transition"
                  [class]="paymentMethod() === m.code ? 'bg-brand-50 ring-2 ring-brand-500' : 'bg-white ring-cream-200'">
                  <input type="radio" name="payment" class="size-5 accent-brand-500" [value]="m.code" [checked]="paymentMethod() === m.code" (change)="paymentMethod.set(m.code)" />
                  <i class="fa-solid w-5 text-center text-lg" [class]="paymentIcon(m.code)"></i>
                  <span class="flex flex-1 flex-col py-2">
                    <span class="font-medium">{{ m.label }}</span>
                    <span class="text-xs text-ink-500">{{ paymentHint(m.code, orderType()) }}</span>
                  </span>
                </label>
              }
            </div>
            @if (err('paymentMethod')) {<p class="field-error"><i class="fa-solid fa-circle-exclamation"></i>{{ err('paymentMethod') }}</p>}
            <div>
              <label class="field-label" for="notes">Notas del pedido <span class="font-normal text-ink-500">(opcional)</span></label>
              <textarea id="notes" name="notes" class="field min-h-20 resize-none" maxlength="200" [(ngModel)]="notes" placeholder="Ej.: pagaré con billete de 500"></textarea>
            </div>
          </section>

          <label class="card flex cursor-pointer items-start gap-3 p-4">
            <input type="checkbox" class="mt-0.5 size-5 shrink-0 accent-brand-500" [checked]="remember()" (change)="remember.set($any($event.target).checked)" />
            <span class="text-sm">
              <span class="block font-semibold">Recordar mis datos en este dispositivo</span>
              <span class="block text-ink-500">Para tu próximo pedido no tendrás que escribir nombre, teléfono ni dirección. Desmárcalo si este teléfono no es tuyo.</span>
            </span>
          </label>

          <p class="px-1 text-xs leading-relaxed text-ink-500">
            <i class="fa-solid fa-shield-halved"></i>
            Usamos tu nombre, teléfono y dirección solo para preparar y entregar este pedido. No necesitas crear una cuenta.
            @if (profiles.profile()) {
              Tus datos guardados viven solo en este navegador. <button type="button" class="font-semibold text-brand-600 underline" (click)="forgetMe()">Borrarlos</button>
            }
          </p>
        </form>

        <!-- Resumen -->
        <aside aria-label="Resumen del pedido">
          <div class="card p-5 lg:sticky lg:top-24">
            <h2 class="flex items-center gap-2 text-lg font-bold"><i class="fa-solid fa-receipt text-brand-500"></i> Resumen</h2>
            <app-cart-summary [editable]="false" [showCheckout]="false" [deliveryFee]="orderType() === 'DELIVERY' ? s.deliveryFee : null" />
            <a routerLink="/carrito" class="mt-3 block text-center text-sm font-semibold text-brand-600 hover:underline">Editar carrito</a>
            @if (isScheduled()) {
              <p class="mt-4 flex items-center gap-2 rounded-2xl bg-brand-50 p-3 text-sm font-medium text-brand-700">
                <i class="fa-solid fa-calendar-check"></i> Recoger {{ chosenLabel() }}
              </p>
            }

            @if (formError(); as fe) {
              <div class="mt-4 rounded-2xl bg-red-50 p-4 text-sm text-red-800 ring-1 ring-red-200" role="alert">
                <p class="font-semibold"><i class="fa-solid fa-circle-exclamation"></i> {{ fe }}</p>
                @for (l of lineErrors(); track $index) {
                  <p class="mt-1">• {{ l }}</p>
                }
                @if (lineErrors().length) {
                  <a routerLink="/carrito" class="mt-2 inline-block font-semibold underline">Revisar carrito</a>
                }
              </div>
            }
            @if (uncertain()) {
              <div class="mt-4 rounded-2xl bg-mustard-300/30 p-4 text-sm ring-1 ring-mustard-400/60" role="alert">
                <p class="font-semibold"><i class="fa-solid fa-wifi"></i> No sabemos si tu pedido llegó</p>
                <p class="mt-1 text-ink-700">Se perdió la conexión. Toca "Confirmar" de nuevo: si ya lo recibimos, no se duplicará.</p>
              </div>
            }

            <button type="submit" form="checkout" class="btn btn-primary mt-4 hidden w-full lg:flex" [disabled]="submitting() || !s.isOpen">
              @if (submitting()) { <i class="fa-solid fa-spinner fa-spin"></i> Enviando… } @else { Confirmar pedido · {{ total() | money }} }
            </button>
            @if (!s.isOpen) {
              <p class="mt-3 text-center text-sm font-medium text-ink-700"><i class="fa-solid fa-moon"></i> Estamos cerrados en este momento.</p>
            }
          </div>
        </aside>

        <div class="fixed inset-x-0 bottom-0 z-30 flex justify-center border-t border-cream-200 bg-white/95 px-4 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] backdrop-blur lg:hidden">
          <button type="submit" form="checkout" class="btn btn-primary mx-auto h-14 w-full max-w-lg" [disabled]="submitting() || !s.isOpen">
            @if (submitting()) { <i class="fa-solid fa-spinner fa-spin"></i> Enviando… } @else { Confirmar pedido · {{ total() | money }} }
          </button>
        </div>
      </main>
    }
  `,
})
export class CheckoutPage implements OnInit {
  protected readonly cart = inject(CartService);
  protected readonly menu = inject(MenuStore);
  private readonly backend = inject(BACKEND);
  private readonly recent = inject(RecentOrdersService);
  private readonly visitors = inject(VisitorTrackerService);
  protected readonly profiles = inject(CustomerProfileService);
  private readonly router = inject(Router);

  protected readonly orderType = signal<OrderType | null>(null);
  protected readonly name = signal('');
  protected readonly phone = signal('');
  protected readonly neighborhood = signal('');
  protected readonly street = signal('');
  protected readonly house = signal('');
  protected readonly reference = signal('');
  protected readonly paymentMethod = signal<string | null>(null);
  protected readonly notes = signal('');

  /** Recogida programada (solo PICKUP). */
  protected readonly scheduleMode = signal(false);
  protected readonly scheduledFor = signal<string | null>(null);
  protected readonly slots = signal<PickupSlots | null>(null);
  protected readonly slotsLoading = signal(false);
  protected readonly slotDay = signal(0);
  protected readonly daySlots = computed(() => this.slots()?.days.find((d) => d.dayIndex === this.slotDay())?.slots ?? []);
  protected readonly isScheduled = computed(() => this.orderType() === 'PICKUP' && this.scheduleMode() && !!this.scheduledFor());
  protected readonly chosenLabel = computed(() => (this.scheduledFor() ? pickupLabel(this.scheduledFor()!) : ''));

  /** Guardar los datos de contacto en este navegador al confirmar. */
  protected readonly remember = signal(true);
  protected readonly prefilled = signal(false);
  protected readonly firstName = computed(() => this.name().trim().split(/\s+/)[0] ?? '');

  protected readonly submitted = signal(false);
  protected readonly submitting = signal(false);
  protected readonly serverErrors = signal<Partial<Record<Field, string>>>({});
  protected readonly formError = signal<string | null>(null);
  protected readonly lineErrors = signal<string[]>([]);
  protected readonly uncertain = signal(false);

  protected readonly total = computed(() => {
    const fee = this.orderType() === 'DELIVERY' ? (this.menu.settings()?.deliveryFee ?? 0) : 0;
    return this.cart.subtotal() + fee;
  });

  private readonly clientErrors = computed<Partial<Record<Field, string>>>(() => {
    const e: Partial<Record<Field, string>> = {};
    if (this.name().trim().length < 2) e.name = 'Ingresa tu nombre.';
    if (!normalizeHnPhone(this.phone())) e.phone = 'Ingresa un teléfono válido de 8 dígitos (ej.: 9999-9999).';
    if (!this.orderType()) e.orderType = 'Selecciona cómo quieres recibir tu pedido.';
    if (this.orderType() === 'PICKUP' && this.scheduleMode() && !this.scheduledFor()) e.scheduledFor = 'Elige la hora a la que pasarás por tu pedido.';
    if (this.orderType() === 'DELIVERY') {
      if (this.neighborhood().trim().length < 3) e.neighborhood = 'Indica la colonia o barrio.';
      if (this.street().trim().length < 3) e.street = 'Indica la calle o avenida.';
      if (this.reference().trim().length < 3) e.reference = 'Agrega una referencia para encontrarte.';
    }
    if (!this.paymentMethod()) e.paymentMethod = 'Selecciona un método de pago.';
    return e;
  });

  ngOnInit(): void {
    void this.menu.ensureLoaded().then(() => {
      const s = this.menu.settings();
      if (!s) return;
      if (s.pickupEnabled !== s.deliveryEnabled) this.orderType.set(s.pickupEnabled ? 'PICKUP' : 'DELIVERY');
      if (s.paymentMethods.length === 1) this.paymentMethod.set(s.paymentMethods[0].code);
      this.prefill();
    });
  }

  /** Datos del último pedido: solo se usan opciones que el restaurante aún ofrece. */
  private prefill(): void {
    const p = this.profiles.profile();
    const s = this.menu.settings();
    if (!p || !s) return;
    this.name.set(p.name);
    this.phone.set(maskHnPhone(p.phone));
    this.neighborhood.set(p.address.neighborhood);
    this.street.set(p.address.street);
    this.house.set(p.address.house);
    this.reference.set(p.address.reference);
    const typeOk = (p.orderType === 'PICKUP' && s.pickupEnabled) || (p.orderType === 'DELIVERY' && s.deliveryEnabled);
    if (typeOk && !(s.pickupEnabled !== s.deliveryEnabled)) this.orderType.set(p.orderType);
    if (p.paymentMethod && s.paymentMethods.some((m) => m.code === p.paymentMethod)) this.paymentMethod.set(p.paymentMethod);
    this.prefilled.set(true);
  }

  protected forgetMe(): void {
    this.profiles.clear();
    this.prefilled.set(false);
    this.remember.set(false);
    for (const f of [this.name, this.phone, this.neighborhood, this.street, this.house, this.reference]) f.set('');
    this.submitted.set(false);
  }

  protected readonly paymentIcon = paymentIcon;
  protected readonly paymentHint = paymentHint;
  protected readonly clock = clockLabel;
  protected readonly weekday = weekdayLabel;

  protected setScheduleMode(on: boolean): void {
    this.scheduleMode.set(on);
    this.serverErrors.update(({ scheduledFor: _, ...rest }) => rest);
    if (on) void this.loadSlots();
  }

  protected pickSlot(at: string): void {
    this.scheduledFor.set(at);
    this.serverErrors.update(({ scheduledFor: _, ...rest }) => rest);
  }

  /** Los horarios dependen de la hora actual y del promedio de cocina: se piden al servidor cada vez. */
  private async loadSlots(): Promise<void> {
    this.slotsLoading.set(true);
    try {
      const data = await this.backend.rpc<PickupSlots>('get_pickup_slots');
      this.slots.set(data);
      const chosen = this.scheduledFor();
      const chosenDay = data.days.find((d) => d.slots.some((x) => x.at === chosen));
      if (chosen && !chosenDay) this.scheduledFor.set(null); // la hora elegida ya pasó
      if (!data.days.some((d) => d.dayIndex === this.slotDay())) this.slotDay.set(data.days[0]?.dayIndex ?? 0);
      if (chosenDay) this.slotDay.set(chosenDay.dayIndex);
    } catch {
      this.slots.set({ leadMinutes: 0, days: [] });
    } finally {
      this.slotsLoading.set(false);
    }
  }

  /** Máscara: solo dígitos y formato 9999-9999 (el +504 es fijo). */
  protected onPhoneInput(input: HTMLInputElement): void {
    const masked = maskHnPhone(input.value);
    input.value = masked;
    this.phone.set(masked);
  }

  /** Bloquea letras y símbolos al teclear (permite edición, navegación y atajos). */
  protected onPhoneKeydown(e: KeyboardEvent): void {
    if (e.ctrlKey || e.metaKey || e.altKey || e.key.length > 1) return;
    if (!/\d/.test(e.key)) e.preventDefault();
  }

  protected err(field: Field): string | undefined {
    return this.serverErrors()[field] ?? (this.submitted() ? this.clientErrors()[field] : undefined);
  }

  protected async submit(): Promise<void> {
    if (this.submitting()) return; // evita doble envío
    this.submitted.set(true);
    this.serverErrors.set({});
    this.formError.set(null);
    this.lineErrors.set([]);

    if (Object.keys(this.clientErrors()).length) {
      this.formError.set('Revisa los campos marcados.');
      queueMicrotask(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus());
      return;
    }
    if (this.cart.issues().length) {
      this.formError.set('El menú cambió. Actualiza tu carrito antes de confirmar.');
      return;
    }

    const items = this.cart.items();
    const payload: Omit<CreateOrderInput, 'idempotencyKey'> = {
      customer: { name: this.name().trim(), phone: normalizeHnPhone(this.phone())! },
      orderType: this.orderType()!,
      ...(this.orderType() === 'DELIVERY'
        ? { address: { neighborhood: this.neighborhood().trim(), street: this.street().trim(), house: this.house().trim(), reference: this.reference().trim() } }
        : {}),
      ...(this.isScheduled() ? { scheduledFor: this.scheduledFor() } : {}),
      paymentMethod: this.paymentMethod()!,
      notes: this.notes().trim(),
      items: items.map((i) => ({ productId: i.productId, quantity: i.quantity, notes: i.notes, optionValueIds: i.selections.map((s) => s.valueId) })),
    };

    // Misma clave mientras el contenido no cambie: un reintento tras corte de red no duplica el pedido.
    const fingerprint = JSON.stringify(payload);
    let pending: { key: string; fingerprint: string } | null = null;
    try {
      pending = JSON.parse(sessionStorage.getItem(PENDING_KEY) ?? 'null');
    } catch {
      /* ignore */
    }
    const key = pending?.fingerprint === fingerprint ? pending.key : crypto.randomUUID();
    try {
      sessionStorage.setItem(PENDING_KEY, JSON.stringify({ key, fingerprint }));
    } catch {
      /* ignore */
    }

    this.submitting.set(true);
    try {
      const result = await this.backend.rpc<CreateOrderResult>('create_guest_order', { ...payload, idempotencyKey: key });
      sessionStorage.removeItem(PENDING_KEY);
      if (this.remember()) {
        this.profiles.save({
          name: this.name().trim(),
          phone: this.phone(),
          orderType: this.orderType(),
          // Si esta vez fue para recoger, se conserva la dirección guardada antes.
          address: this.orderType() === 'DELIVERY'
            ? { neighborhood: this.neighborhood().trim(), street: this.street().trim(), house: this.house().trim(), reference: this.reference().trim() }
            : (this.profiles.profile()?.address ?? { neighborhood: '', street: '', house: '', reference: '' }),
          paymentMethod: this.paymentMethod(),
        });
      } else {
        this.profiles.clear();
      }
      this.recent.add({ orderNumber: result.orderNumber, token: result.trackingToken, total: result.total, createdAt: new Date().toISOString() });
      this.visitors.ordered(result.trackingToken);
      this.cart.clear();
      this.uncertain.set(false);
      await this.router.navigate(['/pedido', result.trackingToken], { state: { justCreated: true } });
    } catch (e) {
      this.handleError(e, items.map((i) => i.productName));
    } finally {
      this.submitting.set(false);
    }
  }

  private handleError(e: unknown, names: string[]): void {
    if (!(e instanceof ApiError)) {
      this.formError.set('Ocurrió un error inesperado. Intenta de nuevo.');
      return;
    }
    if (e.isNetwork) {
      this.uncertain.set(true);
      return;
    }
    this.formError.set(e.message);
    if (e.code === 'VALIDATION') {
      const d = (e.details ?? {}) as ValidationDetails;
      this.serverErrors.set((d.fields ?? {}) as Partial<Record<Field, string>>);
      this.lineErrors.set((d.lines ?? []).map((l) => (names[l.index] && !l.message.includes(names[l.index]) ? `${names[l.index]}: ${l.message}` : l.message)));
      if (d.lines?.length) void this.menu.refresh(true);
      if (d.fields?.['scheduledFor']) void this.loadSlots();
    }
    if (e.code === 'RESTAURANT_CLOSED') void this.menu.refresh(true);
  }
}
