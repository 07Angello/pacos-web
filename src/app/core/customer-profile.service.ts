import { Injectable, signal } from '@angular/core';
import { OrderType } from './models';

/** Datos del último pedido, guardados solo en este navegador para no volver a escribirlos. */
export interface CustomerProfile {
  name: string;
  /** Formato de la máscara: 9999-9999 (sin +504). */
  phone: string;
  orderType: OrderType | null;
  address: { neighborhood: string; street: string; house: string; reference: string };
  paymentMethod: string | null;
  savedAt: string;
}

const KEY = 'pacos.customer.v1';

/**
 * Perfil local del cliente invitado (sin cuenta). Vive en localStorage del dispositivo:
 * se pierde si se borran los datos del sitio y nunca se envía al servidor por sí solo.
 * Las notas del pedido no se guardan (son de cada pedido).
 */
@Injectable({ providedIn: 'root' })
export class CustomerProfileService {
  readonly profile = signal<CustomerProfile | null>(this.read());

  save(p: Omit<CustomerProfile, 'savedAt'>): void {
    const value: CustomerProfile = { ...p, savedAt: new Date().toISOString() };
    try {
      localStorage.setItem(KEY, JSON.stringify(value));
    } catch {
      /* almacenamiento no disponible (modo privado): no se recuerda */
    }
    this.profile.set(value);
  }

  clear(): void {
    try {
      localStorage.removeItem(KEY);
    } catch {
      /* ignore */
    }
    this.profile.set(null);
  }

  private read(): CustomerProfile | null {
    try {
      const raw = localStorage.getItem(KEY);
      if (!raw) return null;
      const p = JSON.parse(raw) as Partial<CustomerProfile>;
      if (typeof p.name !== 'string' || typeof p.phone !== 'string') return null;
      return {
        name: p.name,
        phone: p.phone,
        orderType: p.orderType === 'PICKUP' || p.orderType === 'DELIVERY' ? p.orderType : null,
        address: {
          neighborhood: p.address?.neighborhood ?? '',
          street: p.address?.street ?? '',
          house: p.address?.house ?? '',
          reference: p.address?.reference ?? '',
        },
        paymentMethod: typeof p.paymentMethod === 'string' ? p.paymentMethod : null,
        savedAt: p.savedAt ?? '',
      };
    } catch {
      return null;
    }
  }
}
