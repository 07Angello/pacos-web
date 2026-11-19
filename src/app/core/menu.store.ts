import { computed, inject, Injectable, signal } from '@angular/core';
import { BACKEND } from './backend/backend';
import { ApiError, Category, Product, PublicMenu } from './models';

@Injectable({ providedIn: 'root' })
export class MenuStore {
  private readonly backend = inject(BACKEND);
  private stopWatch?: () => void;

  readonly menu = signal<PublicMenu | null>(null);
  readonly loading = signal(false);
  readonly error = signal<string | null>(null);

  readonly settings = computed(() => this.menu()?.settings ?? null);
  readonly categories = computed<Category[]>(() => this.menu()?.categories ?? []);
  readonly products = computed<Product[]>(() => this.menu()?.products ?? []);
  readonly productsById = computed(() => new Map(this.products().map((p) => [p.id, p])));
  readonly featured = computed(() => this.products().filter((p) => p.isFeatured && p.isAvailable));

  /** Carga el menú (una vez) y se suscribe a cambios de disponibilidad/horario. */
  async ensureLoaded(): Promise<void> {
    if (!this.menu() && !this.loading()) await this.refresh();
    // Un cambio en el editor toca varias filas: se agrupan en una sola recarga.
    let timer: ReturnType<typeof setTimeout> | undefined;
    this.stopWatch ??= this.backend.watchMenu(() => {
      clearTimeout(timer);
      timer = setTimeout(() => void this.refresh(true), 500);
    });
  }

  async refresh(silent = false): Promise<void> {
    if (!silent) this.loading.set(true);
    try {
      this.menu.set(await this.backend.rpc<PublicMenu>('get_public_menu'));
      this.error.set(null);
    } catch (e) {
      if (!silent || !this.menu()) this.error.set(e instanceof ApiError ? e.message : 'No pudimos cargar el menú.');
    } finally {
      this.loading.set(false);
    }
  }

  categoryOf(product: Product): Category | undefined {
    return this.categories().find((c) => c.id === product.categoryId);
  }
}
