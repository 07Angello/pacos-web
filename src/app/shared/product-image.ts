import { afterNextRender, Component, computed, DestroyRef, ElementRef, inject, input, linkedSignal, signal } from '@angular/core';
import { menuImageUrl } from '../core/backend/provide-backend';

const TONES: Record<string, string> = {
  'fa-burger': 'from-brand-400 to-brand-600',
  'fa-drumstick-bite': 'from-mustard-400 to-brand-500',
  'fa-hotdog': 'from-brand-300 to-brand-500',
  'fa-bowl-food': 'from-mustard-300 to-mustard-500',
  'fa-glass-water': 'from-sky-300 to-sky-500',
  'fa-ice-cream': 'from-pink-300 to-pink-500',
};

/**
 * Margen de precarga: la foto se pide cuando está a ~1 tarjeta de entrar en pantalla.
 * El `loading="lazy"` del navegador precarga hasta ~2500 px (casi todo el menú en móvil);
 * con esto solo se descarga lo que el cliente realmente ve.
 */
const PRELOAD_MARGIN = '200px';

/**
 * Imagen del producto. Mientras no hay foto (o no ha cargado, o falló) se ve un
 * mosaico ilustrado con el ícono de la categoría; la foto aparece con un fundido.
 * `eager`: cargar de inmediato (p. ej. la ficha del plato que el cliente abrió).
 */
@Component({
  selector: 'app-product-image',
  host: { class: 'relative block overflow-hidden' },
  template: `
    @if (!src() || !loaded()) {
      <div class="relative grid size-full place-items-center bg-gradient-to-br text-white" [class]="tone()" role="img" [attr.aria-label]="alt()">
        <i class="fa-solid absolute -right-2 -bottom-3 rotate-[-12deg] opacity-15" [class]="icon()" [style.font-size.px]="size() * 1.6"></i>
        <i class="fa-solid drop-shadow-sm" [class]="icon()" [style.font-size.px]="size()" [class.animate-pulse]="!!src() && visible()"></i>
      </div>
    }
    @if (src() && visible()) {
      <img [src]="src()" [alt]="alt()" decoding="async" [attr.fetchpriority]="eager() ? 'high' : null"
        class="absolute inset-0 size-full object-cover transition-opacity duration-300"
        [class.opacity-0]="!loaded()" (load)="loaded.set(true)" (error)="failed.set(true)" />
    }
  `,
})
export class ProductImage {
  readonly path = input<string | null | undefined>(null);
  readonly icon = input<string>('fa-utensils');
  readonly alt = input('');
  readonly size = input(36);
  readonly eager = input(false);

  protected readonly visible = signal(false);
  // Si cambian la foto del plato (tiempo real), se reinicia el estado de carga.
  protected readonly loaded = linkedSignal({ source: this.path, computation: () => false });
  protected readonly failed = linkedSignal({ source: this.path, computation: () => false });
  protected readonly src = computed(() => (this.failed() ? null : menuImageUrl(this.path())));
  protected readonly tone = computed(() => TONES[this.icon()] ?? 'from-brand-400 to-brand-600');

  constructor() {
    const host = inject(ElementRef<HTMLElement>).nativeElement as HTMLElement;
    const destroyRef = inject(DestroyRef);
    afterNextRender(() => {
      if (this.eager() || typeof IntersectionObserver === 'undefined') {
        this.visible.set(true);
        return;
      }
      const io = new IntersectionObserver(
        (entries) => {
          if (entries.some((e) => e.isIntersecting)) {
            this.visible.set(true);
            io.disconnect(); // una vez pedida, se queda
          }
        },
        { rootMargin: PRELOAD_MARGIN },
      );
      io.observe(host);
      destroyRef.onDestroy(() => io.disconnect());
    });
  }
}
