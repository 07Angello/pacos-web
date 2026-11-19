import { Provider } from '@angular/core';
import { environment } from '../../../environments/environment';
import { BACKEND } from './backend';
import { SupabaseBackend } from './supabase-backend';
import { supabaseBaseUrl } from './supabase-url';

export function provideBackend(): Provider {
  return {
    provide: BACKEND,
    useFactory: () => new SupabaseBackend(environment.supabase.url, environment.supabase.anonKey),
  };
}

/** URL pública de una imagen del catálogo (Supabase Storage) o null. */
export function menuImageUrl(path: string | null | undefined): string | null {
  if (!path) return null;
  if (/^https?:\/\//.test(path)) return path;
  return `${supabaseBaseUrl(environment.supabase.url)}/storage/v1/object/public/${environment.supabase.menuImagesBucket}/${path}`;
}
