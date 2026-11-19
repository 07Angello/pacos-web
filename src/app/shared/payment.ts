import { OrderType } from '../core/models';

/** Presentación de cada método de pago (los métodos habilitados vienen de restaurant_settings). */
export function paymentIcon(code: string): string {
  return code === 'TRANSFER' ? 'fa-building-columns text-sky-600' : code === 'CASH' ? 'fa-money-bill-wave text-emerald-600' : 'fa-wallet text-ink-500';
}

export function paymentHint(code: string, orderType: OrderType | null): string {
  if (code === 'TRANSFER') return 'El restaurante te compartirá los datos de la cuenta';
  if (code === 'CASH') return orderType === 'DELIVERY' ? 'Contra entrega' : 'Al recoger';
  return '';
}
