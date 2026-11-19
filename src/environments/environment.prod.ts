// Entorno de PRODUCCIÓN (ng build). Reemplaza a environment.ts vía fileReplacements.
// Hoy apunta al mismo proyecto Supabase que desarrollo; si creas un proyecto de
// producción separado (recomendado, §17), cambia url y key aquí.
//
// url: la URL base del proyecto (sin /rest/v1). key: la publishable/anon key.
// Es pública por diseño: la seguridad la dan RLS y las RPCs. NUNCA pongas aquí la
// service_role / secret key.
export const environment = {
  production: true,
  supabase: {
    url: 'https://rbtnpgysqhrnczvxqoqx.supabase.co',
    anonKey: 'sb_publishable_bA7lN7EKS1T4rOd34FFgdA_SZu92gUq',
    menuImagesBucket: 'menu-images',
  },
};
