import { Component, computed, effect, ElementRef, HostListener, inject, input, output, signal, viewChild } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { CartItem, CartService } from '../../core/cart.service';
import { MenuStore } from '../../core/menu.store';
import { Product, ProductOption } from '../../core/models';
import { CartSelection, selectionErrors, unitPrice } from '../../core/pricing';
import { MoneyPipe } from '../../shared/money.pipe';
import { ProductImage } from '../../shared/product-image';

/** Detalle y personalización de un producto (§4.3). Hoja inferior en móvil, diálogo en escritorio. */
@Component({
  selector: 'app-product-sheet',
  imports: [FormsModule, MoneyPipe, ProductImage],
  template: `
    <div class="fixed inset-0 z-50 flex items-end justify-center bg-ink-900/50 sm:items-center sm:p-6 animate-fade-in" (click)="dismissed.emit()">
      <div #dialog role="dialog" aria-modal="true" [attr.aria-labelledby]="'p-title-' + product().id" tabindex="-1"
        class="flex max-h-[92dvh] w-full max-w-lg flex-col overflow-hidden rounded-t-[2rem] bg-cream-50 shadow-float outline-none sm:rounded-[2rem] animate-sheet-up"
        (click)="$event.stopPropagation()">
        <div class="relative">
          <app-product-image class="h-44 w-full sm:h-52" [path]="product().imagePath" [icon]="icon()" [size]="64" [alt]="product().name" [eager]="true" />
          <button type="button" class="absolute top-3 right-3 grid size-11 place-items-center rounded-full bg-white/95 text-ink-900 shadow" (click)="dismissed.emit()" aria-label="Cerrar">
            <i class="fa-solid fa-xmark text-lg"></i>
          </button>
          <span class="absolute top-3 left-1/2 h-1.5 w-12 -translate-x-1/2 rounded-full bg-white/70 sm:hidden"></span>
        </div>

        <div class="flex-1 overflow-y-auto px-5 pt-5 pb-4">
          @if (editItem()) {
            <p class="mb-1 flex items-center gap-1.5 text-xs font-bold tracking-wide text-brand-600 uppercase"><i class="fa-solid fa-pen"></i> Editando tu pedido</p>
          }
          <h2 [id]="'p-title-' + product().id" class="text-2xl font-bold">{{ product().name }}</h2>
          <p class="mt-1 text-ink-500">{{ product().description }}</p>
          <p class="mt-2 text-lg font-bold text-brand-600">{{ product().price | money }}</p>

          @for (group of product().options; track group.id) {
            <fieldset class="mt-6">
              <legend class="flex w-full items-center justify-between gap-2">
                <span class="font-display text-base font-bold">{{ group.name }}</span>
                <span class="chip" [class]="errors()[group.id] && touched() ? 'bg-red-100 text-red-700' : group.isRequired ? 'bg-ink-900 text-white' : 'bg-cream-200 text-ink-700'">
                  {{ hint(group) }}
                </span>
              </legend>
              <div class="mt-2 space-y-2">
                @for (value of group.values; track value.id) {
                  <label class="flex min-h-14 items-center gap-3 rounded-2xl bg-white px-4 ring-1 transition"
                    [class]="isSelected(value.id) ? 'ring-2 ring-brand-500' : 'ring-cream-200'"
                    [class.opacity-50]="!value.isAvailable">
                    <input [type]="group.optionType === 'SINGLE' ? 'radio' : 'checkbox'" class="size-5 accent-brand-500"
                      [name]="group.id" [checked]="isSelected(value.id)" [disabled]="!value.isAvailable || (group.optionType === 'MULTIPLE' && !isSelected(value.id) && countIn(group) >= group.maxSelect)"
                      (change)="toggle(group, value.id)" />
                    <span class="flex-1 font-medium">{{ value.label }}</span>
                    @if (!value.isAvailable) {
                      <span class="text-xs font-semibold text-ink-500">Agotado</span>
                    } @else if (value.priceDelta > 0) {
                      <span class="text-sm font-semibold text-ink-700">+ {{ value.priceDelta | money }}</span>
                    }
                  </label>
                }
              </div>
              @if (errors()[group.id] && touched()) {
                <p class="field-error"><i class="fa-solid fa-circle-exclamation"></i>{{ errors()[group.id] }}</p>
              }
            </fieldset>
          }

          <div class="mt-6">
            <label class="field-label" [for]="'notes-' + product().id"><i class="fa-solid fa-pen-to-square mr-1 text-brand-500"></i> Notas para cocina <span class="font-normal text-ink-500">(opcional)</span></label>
            <textarea [id]="'notes-' + product().id" class="field min-h-20 resize-none" maxlength="140" placeholder="Ej.: sin cebolla, salsa aparte…" [(ngModel)]="notes"></textarea>
            <p class="mt-1 text-right text-xs text-ink-500">{{ notes().length }}/140</p>
          </div>
        </div>

        <div class="flex items-center gap-3 border-t border-cream-200 bg-white px-5 pt-4 pb-[max(1rem,env(safe-area-inset-bottom))]">
          <div class="flex items-center gap-2">
            <button type="button" class="qty-btn" (click)="quantity.set(quantity() - 1)" [disabled]="quantity() <= 1" aria-label="Menos"><i class="fa-solid fa-minus"></i></button>
            <span class="w-7 text-center text-lg font-bold" aria-live="polite">{{ quantity() }}</span>
            <button type="button" class="qty-btn" (click)="quantity.set(quantity() + 1)" [disabled]="quantity() >= 20" aria-label="Más"><i class="fa-solid fa-plus"></i></button>
          </div>
          <button type="button" class="btn btn-primary flex-1" (click)="add()" [disabled]="!product().isAvailable">
            @if (product().isAvailable) {
              {{ editItem() ? 'Guardar' : 'Agregar' }} <span class="font-bold whitespace-nowrap">{{ total() | money }}</span>
            } @else {
              Agotado
            }
          </button>
        </div>
      </div>
    </div>
  `,
})
export class ProductSheet {
  readonly product = input.required<Product>();
  /** Si viene, la hoja abre en modo edición con lo que el cliente ya eligió. */
  readonly editItem = input<CartItem | null>(null);
  readonly dismissed = output<void>();
  readonly added = output<string>();

  private readonly cart = inject(CartService);
  private readonly menu = inject(MenuStore);
  private readonly dialog = viewChild.required<ElementRef<HTMLElement>>('dialog');

  protected readonly selected = signal<string[]>([]);
  protected readonly quantity = signal(1);
  protected readonly notes = signal('');
  protected readonly touched = signal(false);

  protected readonly icon = computed(() => this.menu.categoryOf(this.product())?.icon ?? 'fa-utensils');
  protected readonly errors = computed(() => selectionErrors(this.product(), this.selected()));
  protected readonly total = computed(() => unitPrice(this.product(), this.selected()) * this.quantity());

  constructor() {
    effect(() => {
      const product = this.product();
      const item = this.editItem();
      if (item) {
        // Edición: restaurar lo elegido (solo opciones que sigan existiendo y disponibles).
        const available = new Set(product.options.flatMap((g) => g.values.filter((v) => v.isAvailable).map((v) => v.id)));
        this.selected.set(item.selections.map((s) => s.valueId).filter((id) => available.has(id)));
        this.quantity.set(item.quantity);
        this.notes.set(item.notes);
      } else {
        // Nuevo: opciones preseleccionadas por el administrador; si un grupo obligatorio
        // de selección única no tiene ninguna, se marca la primera disponible.
        this.selected.set(
          product.options.flatMap((g) => {
            const defaults = g.values.filter((v) => v.isDefault && v.isAvailable).slice(0, g.maxSelect).map((v) => v.id);
            if (defaults.length || !(g.isRequired && g.optionType === 'SINGLE')) return defaults;
            const first = g.values.find((v) => v.isAvailable);
            return first ? [first.id] : [];
          }),
        );
      }
      queueMicrotask(() => this.dialog().nativeElement.focus());
    });
  }

  @HostListener('document:keydown.escape')
  protected onEscape(): void {
    this.dismissed.emit();
  }

  protected isSelected(id: string): boolean {
    return this.selected().includes(id);
  }

  protected countIn(group: ProductOption): number {
    return group.values.filter((v) => this.isSelected(v.id)).length;
  }

  protected hint(group: ProductOption): string {
    if (group.optionType === 'SINGLE') return group.isRequired ? 'Obligatorio' : 'Opcional';
    return group.maxSelect > 1 ? `Hasta ${group.maxSelect}` : 'Opcional';
  }

  protected toggle(group: ProductOption, valueId: string): void {
    const groupIds = new Set(group.values.map((v) => v.id));
    this.selected.update((sel) => {
      if (group.optionType === 'SINGLE') return [...sel.filter((id) => !groupIds.has(id)), valueId];
      return sel.includes(valueId) ? sel.filter((id) => id !== valueId) : [...sel, valueId];
    });
  }

  protected add(): void {
    this.touched.set(true);
    if (Object.keys(this.errors()).length) return;
    const p = this.product();
    const selections: CartSelection[] = p.options.flatMap((g) =>
      g.values
        .filter((v) => this.isSelected(v.id))
        .map((v) => ({ optionId: g.id, optionName: g.name, valueId: v.id, label: v.label, priceDelta: v.priceDelta })),
    );
    const item = this.editItem();
    if (item) this.cart.update(item.key, p, this.quantity(), selections, this.notes(), this.icon());
    else this.cart.add(p, this.quantity(), selections, this.notes(), this.icon());
    this.added.emit(p.name);
    this.dismissed.emit();
  }
}
