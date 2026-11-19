import { computed, DestroyRef, effect, inject, Injectable, signal } from '@angular/core';
import { NavigationEnd, Router } from '@angular/router';
import { filter } from 'rxjs';
import { BACKEND, VisitorPresence } from './backend/backend';
import { CartService } from './cart.service';

/** Paso en vivo del cliente (lo que ve la app del personal). */
export type VisitorStage = 'MENU' | 'CART' | 'CHECKOUT' | 'TRACKING';
/** Paso guardado en el historial (embudo de compra). */
type FunnelStage = 'MENU' | 'CART' | 'CHECKOUT';

const ID_KEY = 'pacos.visitor.v1';
const DAY_KEY = 'pacos.visit-day.v1';
const LEVEL: Record<FunnelStage, number> = { MENU: 1, CART: 2, CHECKOUT: 3 };
const TZ = 'America/Tegucigalpa';

/**
 * Cuenta a los clientes que están en la web (anónimo: un id aleatorio por dispositivo,
 * sin nombre ni teléfono).
 * - En vivo: Realtime Presence, sin tocar la base de datos.
 * - Historial: como máximo 3 llamadas por dispositivo y día (al llegar a menú, carrito y
 *   datos) + 1 al confirmar un pedido.
 */
@Injectable({ providedIn: 'root' })
export class VisitorTrackerService {
  private readonly backend = inject(BACKEND);
  private readonly router = inject(Router);
  private readonly cart = inject(CartService);
  private readonly destroyRef = inject(DestroyRef);

  private readonly url = signal(this.router.url);
  private readonly visible = signal(typeof document === 'undefined' || document.visibilityState === 'visible');
  private readonly visitorId = readVisitorId();
  private readonly device = isDesktop() ? 'DESKTOP' : 'MOBILE';
  private presence?: VisitorPresence;
  private started = false;

  readonly stage = computed<VisitorStage>(() => {
    const path = this.url().split(/[?#]/)[0];
    if (path.startsWith('/checkout')) return 'CHECKOUT';
    if (path.startsWith('/carrito')) return 'CART';
    if (path.startsWith('/pedido/') || path.startsWith('/mis-pedidos')) return 'TRACKING';
    return this.cart.count() > 0 ? 'CART' : 'MENU';
  });

  constructor() {
    effect(() => {
      const stage = this.stage();
      const visible = this.visible();
      if (!this.started) return;
      // En segundo plano deja de contar como "en la web ahora".
      this.presence?.set(visible ? { stage, device: this.device } : null);
      if (visible) this.record(stage === 'TRACKING' ? 'MENU' : stage);
    });
  }

  start(): void {
    if (this.started || !this.visitorId) return;
    this.started = true;
    this.url.set(this.router.url);
    const sub = this.router.events.pipe(filter((e) => e instanceof NavigationEnd)).subscribe((e) => this.url.set(e.urlAfterRedirects));
    const onVisible = () => this.visible.set(document.visibilityState === 'visible');
    document.addEventListener('visibilitychange', onVisible);
    this.presence = this.backend.joinVisitors(this.visitorId);
    this.presence.set(this.visible() ? { stage: this.stage(), device: this.device } : null);
    this.destroyRef.onDestroy(() => {
      sub.unsubscribe();
      document.removeEventListener('visibilitychange', onVisible);
      this.presence?.leave();
    });
  }

  /** Pedido confirmado desde este dispositivo (el servidor verifica el token). */
  ordered(trackingToken: string): void {
    if (!this.visitorId) return;
    this.send({ visitorId: this.visitorId, stage: 'ORDERED', device: this.device, token: trackingToken });
    this.saveLevel(LEVEL.CHECKOUT);
  }

  /** Solo avisa al servidor cuando el cliente llega a un paso nuevo del día. */
  private record(stage: FunnelStage): void {
    if (!this.visitorId) return;
    const today = todayYmd();
    const saved = readDay();
    const level = saved?.day === today ? saved.level : 0;
    if (LEVEL[stage] <= level) return;
    this.saveLevel(LEVEL[stage]);
    this.send({ visitorId: this.visitorId, stage, device: this.device });
  }

  private saveLevel(level: number): void {
    try {
      localStorage.setItem(DAY_KEY, JSON.stringify({ day: todayYmd(), level }));
    } catch {
      /* sin almacenamiento: puede repetir el aviso, el servidor no duplica */
    }
  }

  private send(params: object): void {
    // Estadística: si falla, no se molesta al cliente.
    void this.backend.rpc('track_web_visit', params).catch(() => undefined);
  }
}

function readVisitorId(): string | null {
  try {
    let id = localStorage.getItem(ID_KEY);
    if (!id || !/^[0-9a-f-]{36}$/i.test(id)) {
      id = crypto.randomUUID();
      localStorage.setItem(ID_KEY, id);
    }
    return id;
  } catch {
    // Navegación privada sin almacenamiento: id solo para esta visita.
    try {
      return crypto.randomUUID();
    } catch {
      return null;
    }
  }
}

function readDay(): { day: string; level: number } | null {
  try {
    return JSON.parse(localStorage.getItem(DAY_KEY) ?? 'null');
  } catch {
    return null;
  }
}

function todayYmd(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
}

function isDesktop(): boolean {
  try {
    return window.matchMedia('(hover: hover) and (pointer: fine)').matches && window.innerWidth >= 1024;
  } catch {
    return false;
  }
}
