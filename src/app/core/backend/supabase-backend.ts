import type { RealtimeChannel, SupabaseClient } from '@supabase/supabase-js';
import { ApiError } from '../models';
import { licenseRejected } from '../license-signal';
import { PublicBackend, PublicRpc, VisitorPresence } from './backend';
import { supabaseBaseUrl } from './supabase-url';

/**
 * Adaptador Supabase. Las RPCs reciben `{ params }` (ver supabase/migrations/*_rpc.sql).
 * El cliente anónimo NO puede leer la tabla de pedidos, así que el seguimiento
 * se actualiza por sondeo (y al volver a la pestaña).
 */
export class SupabaseBackend implements PublicBackend {
  private client?: Promise<SupabaseClient>;

  constructor(
    private readonly url: string,
    private readonly anonKey: string,
  ) {
    if (!url || !anonKey) console.error("[Paco's] Falta supabase.url / supabase.anonKey en environment.");
  }

  private getClient(): Promise<SupabaseClient> {
    this.client ??= import('@supabase/supabase-js').then(({ createClient }) =>
      createClient(supabaseBaseUrl(this.url), this.anonKey, { auth: { persistSession: false, autoRefreshToken: false } }),
    );
    return this.client;
  }

  async rpc<T>(name: PublicRpc, params: object = {}): Promise<T> {
    const client = await this.getClient();
    const { data, error } = await client.rpc(name, { params });
    if (error) {
      const e = toApiError(error);
      if (e.code === 'LICENSE_INACTIVE') licenseRejected.set(e.message); // el servidor bloqueó la web
      throw e;
    }
    return data as T;
  }

  watchLicense(onChange: () => void): () => void {
    let channel: { unsubscribe(): unknown } | undefined;
    void this.getClient().then((client) => {
      channel = client.channel('license').on('postgres_changes', { event: '*', schema: 'public', table: 'app_license' }, onChange).subscribe();
    });
    const stopPoll = poll(onChange, 60000); // respaldo si se pierde un evento
    return () => {
      stopPoll();
      channel?.unsubscribe();
    };
  }

  joinVisitors(key: string): VisitorPresence {
    let channel: RealtimeChannel | undefined;
    let meta: object | null = null;
    let joined = false;
    let closed = false;
    void this.getClient().then((client) => {
      if (closed) return;
      // Sin listeners de 'presence': el servidor no le envía a este cliente la lista de los demás.
      channel = client.channel('web-visitors', { config: { presence: { key } } });
      channel.subscribe((status) => {
        joined = status === 'SUBSCRIBED';
        // También al reconectar: se vuelve a anunciar.
        if (joined && meta) void channel!.track(meta);
      });
    });
    return {
      set(next) {
        meta = next;
        if (!joined || !channel) return;
        void (next ? channel.track(next) : channel.untrack());
      },
      leave() {
        closed = true;
        void channel?.unsubscribe();
      },
    };
  }

  watchTracking(_token: string, onChange: () => void): () => void {
    return poll(onChange, 10000);
  }

  watchMenu(onChange: () => void): () => void {
    let channel: { unsubscribe(): unknown } | undefined;
    void this.getClient().then((client) => {
      // Menú, categorías, grupos de opciones, enlaces y configuración (RLS: el anónimo
      // solo recibe tablas públicas del menú, nunca pedidos).
      const tables = ['restaurant_settings', 'categories', 'products', 'product_options', 'product_option_values', 'product_option_links'];
      const ch = client.channel('public-menu');
      for (const table of tables) ch.on('postgres_changes', { event: '*', schema: 'public', table }, onChange);
      channel = ch.subscribe();
    });
    const stopPoll = poll(onChange, 60000);
    return () => {
      stopPoll();
      channel?.unsubscribe();
    };
  }
}

function poll(fn: () => void, ms: number): () => void {
  const id = setInterval(fn, ms);
  const onVisible = () => document.visibilityState === 'visible' && fn();
  document.addEventListener('visibilitychange', onVisible);
  return () => {
    clearInterval(id);
    document.removeEventListener('visibilitychange', onVisible);
  };
}

/** Las RPCs lanzan SQLSTATE PTxxx (=> HTTP xxx) con el código de negocio en `hint`. */
export function toApiError(error: { message: string; code?: string; hint?: string | null; details?: string | null }): ApiError {
  if (!error.code && /fetch|network/i.test(error.message)) {
    return new ApiError(0, 'NETWORK', 'No pudimos conectar con el restaurante. Revisa tu conexión.');
  }
  const status = error.code?.startsWith('PT') ? Number(error.code.slice(2)) : 500;
  let details: unknown;
  try {
    details = error.details ? JSON.parse(error.details) : undefined;
  } catch {
    details = error.details;
  }
  return new ApiError(status, error.hint || 'ERROR', status === 500 ? 'Ocurrió un error inesperado.' : error.message, details);
}
