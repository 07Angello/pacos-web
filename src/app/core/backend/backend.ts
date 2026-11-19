import { InjectionToken } from '@angular/core';

/** RPCs públicas que puede invocar la web (cliente invitado, sin autenticación). */
export type PublicRpc = 'get_public_menu' | 'create_guest_order' | 'get_order_tracking' | 'cancel_guest_order' | 'get_pickup_slots' | 'get_license_status' | 'track_web_visit';

/**
 * Puerto de acceso a datos. Implementación: SupabaseBackend (supabase.rpc() + Realtime).
 * Las pantallas dependen de esta interfaz, no de Supabase directamente.
 */
export interface PublicBackend {
  rpc<T>(name: PublicRpc, params?: object): Promise<T>;
  /** Notifica cambios de un pedido seguido por token. Devuelve la función para cancelar. */
  watchTracking(token: string, onChange: () => void): () => void;
  /** Notifica cambios de menú o configuración (abierto/cerrado, precios…). */
  watchMenu(onChange: () => void): () => void;
  /** Notifica cambios en la licencia del sistema (tabla app_license). */
  watchLicense(onChange: () => void): () => void;
  /**
   * Presencia anónima en el canal 'web-visitors' (contador en vivo de la app del personal).
   * Este cliente solo REPORTA su estado; no recibe el de los demás visitantes.
   */
  joinVisitors(key: string): VisitorPresence;
}

export interface VisitorPresence {
  /** Publica el estado actual; null deja de aparecer (p. ej. pestaña en segundo plano). */
  set(meta: object | null): void;
  leave(): void;
}

export const BACKEND = new InjectionToken<PublicBackend>('PublicBackend');
