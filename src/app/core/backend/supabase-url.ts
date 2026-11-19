/** Acepta la URL con o sin `/rest/v1` y devuelve la URL base del proyecto. */
export function supabaseBaseUrl(url: string): string {
  return url.trim().replace(/\/+$/, '').replace(/\/rest\/v1$/, '');
}
