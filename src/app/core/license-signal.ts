import { signal } from '@angular/core';

/** Lo marca el backend cuando una llamada falla con LICENSE_INACTIVE (mensaje del servidor). */
export const licenseRejected = signal<string | null>(null);
