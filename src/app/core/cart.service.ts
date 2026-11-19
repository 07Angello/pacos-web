import { computed, effect, inject, Injectable, signal } from '@angular/core';
import { MenuStore } from './menu.store';
import { CartSelection, round, unitPrice } from './pricing';
import { Product } from './models';

export interface CartItem {
  key: string;
  productId: string;
  productName: string;
  categoryIcon: string | null;
  quantity: number;
  notes: string;
  selections: CartSelection[];
  /** Precio unitario que vio el cliente al agregarlo. */
  unitPrice: number;
}

export type CartIssue = { key: string; kind: 'unavailable' | 'price'; message: string; newPrice?: number };

const STORAGE_KEY = 'pacos.cart.v1';

@Injectable({ providedIn: 'root' })
export class CartService {
  private readonly menu = inject(MenuStore);

  readonly items = signal<CartItem[]>(this.restore());
  readonly count = computed(() => this.items().reduce((n, i) => n + i.quantity, 0));
  readonly subtotal = computed(() => round(this.items().reduce((s, i) => s + i.unitPrice * i.quantity, 0)));

  /** Diferencias entre el carrito y el menú vigente (agotados o cambios de precio). */
  readonly issues = computed<CartIssue[]>(() => {
    const byId = this.menu.productsById();
    if (byId.size === 0) return [];
    const issues: CartIssue[] = [];
    for (const item of this.items()) {
      const product = byId.get(item.productId);
      const valueIds = item.selections.map((s) => s.valueId);
      const values = product?.options.flatMap((o) => o.values) ?? [];
      const missingValue = valueIds.some((id) => !values.find((v) => v.id === id && v.isAvailable));
      if (!product || !product.isAvailable || missingValue) {
        issues.push({ key: item.key, kind: 'unavailable', message: `${item.productName} ya no está disponible.` });
        continue;
      }
      const current = unitPrice(product, valueIds);
      if (current !== item.unitPrice) {
        issues.push({ key: item.key, kind: 'price', newPrice: current, message: `El precio de ${item.productName} cambió.` });
      }
    }
    return issues;
  });

  constructor() {
    effect(() => {
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(this.items()));
      } catch {
        /* almacenamiento no disponible: el carrito vive solo en memoria */
      }
    });
  }

  add(product: Product, quantity: number, selections: CartSelection[], notes: string, categoryIcon: string | null): void {
    const price = unitPrice(product, selections.map((s) => s.valueId));
    const signature = JSON.stringify([product.id, selections.map((s) => s.valueId).sort(), notes.trim()]);
    this.items.update((items) => {
      const same = items.find(
        (i) => JSON.stringify([i.productId, i.selections.map((s) => s.valueId).sort(), i.notes.trim()]) === signature,
      );
      if (same) {
        return items.map((i) => (i === same ? { ...i, quantity: Math.min(20, i.quantity + quantity), unitPrice: price } : i));
      }
      return [
        ...items,
        { key: crypto.randomUUID(), productId: product.id, productName: product.name, categoryIcon, quantity, notes: notes.trim(), selections, unitPrice: price },
      ];
    });
  }

  /** Reemplaza un artículo editado (opciones, notas, cantidad). Si queda igual a otro, se combinan. */
  update(key: string, product: Product, quantity: number, selections: CartSelection[], notes: string, categoryIcon: string | null): void {
    const price = unitPrice(product, selections.map((s) => s.valueId));
    const sig = (productId: string, sel: CartSelection[], n: string) => JSON.stringify([productId, sel.map((s) => s.valueId).sort(), n.trim()]);
    const target = sig(product.id, selections, notes);
    this.items.update((items) => {
      const twin = items.find((i) => i.key !== key && sig(i.productId, i.selections, i.notes) === target);
      if (twin) {
        return items
          .filter((i) => i.key !== key)
          .map((i) => (i === twin ? { ...i, quantity: Math.min(20, i.quantity + quantity), unitPrice: price } : i));
      }
      return items.map((i) =>
        i.key === key
          ? { ...i, productName: product.name, categoryIcon, quantity, notes: notes.trim(), selections, unitPrice: price }
          : i,
      );
    });
  }

  setQuantity(key: string, quantity: number): void {
    if (quantity < 1) return this.remove(key);
    this.items.update((items) => items.map((i) => (i.key === key ? { ...i, quantity: Math.min(20, quantity) } : i)));
  }

  remove(key: string): void {
    this.items.update((items) => items.filter((i) => i.key !== key));
  }

  /** Acepta el menú vigente: quita lo agotado y actualiza precios. */
  applyMenuChanges(): void {
    const issues = this.issues();
    this.items.update((items) =>
      items
        .filter((i) => !issues.some((x) => x.key === i.key && x.kind === 'unavailable'))
        .map((i) => {
          const p = issues.find((x) => x.key === i.key && x.kind === 'price');
          return p?.newPrice !== undefined ? { ...i, unitPrice: p.newPrice } : i;
        }),
    );
  }

  clear(): void {
    this.items.set([]);
  }

  private restore(): CartItem[] {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      const parsed = raw ? (JSON.parse(raw) as CartItem[]) : [];
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }
}
