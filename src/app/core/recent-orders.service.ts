import { Injectable, signal } from '@angular/core';

export interface RecentOrder {
  orderNumber: string;
  token: string;
  total: number;
  createdAt: string;
}

const KEY = 'pacos.recent-orders.v1';

/** Pedidos hechos desde ESTE dispositivo (solo enlaces privados; no hay búsqueda pública). */
@Injectable({ providedIn: 'root' })
export class RecentOrdersService {
  readonly orders = signal<RecentOrder[]>(this.read());

  add(order: RecentOrder): void {
    const next = [order, ...this.orders().filter((o) => o.token !== order.token)].slice(0, 10);
    this.orders.set(next);
    try {
      localStorage.setItem(KEY, JSON.stringify(next));
    } catch {
      /* sin almacenamiento */
    }
  }

  private read(): RecentOrder[] {
    try {
      return JSON.parse(localStorage.getItem(KEY) ?? '[]') as RecentOrder[];
    } catch {
      return [];
    }
  }
}
