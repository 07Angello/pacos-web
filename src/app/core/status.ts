import { OrderStatus, OrderType } from './models';

export interface StatusInfo {
  label: string;
  description: string;
  icon: string;
  tone: 'amber' | 'blue' | 'orange' | 'green' | 'violet' | 'gray' | 'red';
}

/** Textos visibles al cliente (§7: columna "Visible al cliente"). */
export const CUSTOMER_STATUS: Record<OrderStatus, StatusInfo> = {
  PENDING: { label: 'Recibido', description: 'El restaurante está revisando tu pedido.', icon: 'fa-receipt', tone: 'amber' },
  ACCEPTED: { label: 'Aceptado', description: '¡Confirmado! Tu pedido está en la fila de cocina.', icon: 'fa-circle-check', tone: 'blue' },
  PREPARING: { label: 'En preparación', description: 'Nuestros cocineros están preparando tu pedido.', icon: 'fa-fire-burner', tone: 'orange' },
  READY: { label: 'Listo', description: 'Tu pedido está listo.', icon: 'fa-bell-concierge', tone: 'green' },
  OUT_FOR_DELIVERY: { label: 'En camino', description: 'Tu pedido va en camino a tu dirección.', icon: 'fa-motorcycle', tone: 'violet' },
  COMPLETED: { label: 'Completado', description: '¡Gracias por tu compra! Buen provecho.', icon: 'fa-face-smile-beam', tone: 'green' },
  REJECTED: { label: 'No aceptado', description: 'El restaurante no pudo aceptar tu pedido.', icon: 'fa-circle-xmark', tone: 'red' },
  CANCELLED: { label: 'Cancelado', description: 'Este pedido fue cancelado.', icon: 'fa-ban', tone: 'gray' },
};

/** Igual que CUSTOMER_STATUS, pero "Listo" dice si es para recoger o para enviar. */
export function customerStatus(status: OrderStatus, type: OrderType): StatusInfo {
  const info = CUSTOMER_STATUS[status];
  if (status !== 'READY') return info;
  return { ...info, label: type === 'DELIVERY' ? 'Listo para enviar' : type === 'DINE_IN' ? 'Listo para servir' : 'Listo para recoger' };
}

export function readyDescription(type: OrderType): string {
  if (type === 'DINE_IN') return 'Tu pedido está listo. ¡Buen provecho!';
  return type === 'PICKUP' ? 'Tu pedido está listo. ¡Pasa a recogerlo!' : 'Tu pedido está listo y saldrá pronto a tu dirección.';
}

export function progressSteps(type: OrderType): OrderStatus[] {
  return type === 'DELIVERY'
    ? ['PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'OUT_FOR_DELIVERY', 'COMPLETED']
    : ['PENDING', 'ACCEPTED', 'PREPARING', 'READY', 'COMPLETED'];
}
