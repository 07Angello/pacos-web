import { Product } from './models';

export interface CartSelection {
  optionId: string;
  optionName: string;
  valueId: string;
  label: string;
  priceDelta: number;
}

/** Precio unitario mostrado al cliente (el backend siempre lo recalcula). */
export function unitPrice(product: Product, selectedValueIds: readonly string[]): number {
  const selected = new Set(selectedValueIds);
  const extras = product.options
    .flatMap((o) => o.values)
    .filter((v) => selected.has(v.id))
    .reduce((sum, v) => sum + v.priceDelta, 0);
  return round(product.price + extras);
}

export function round(n: number): number {
  return Math.round(n * 100) / 100;
}

/** Devuelve el mensaje de error de selección de cada grupo, o null si es válido. */
export function selectionErrors(product: Product, selectedValueIds: readonly string[]): Record<string, string> {
  const selected = new Set(selectedValueIds);
  const errors: Record<string, string> = {};
  for (const group of product.options) {
    const count = group.values.filter((v) => selected.has(v.id)).length;
    const min = group.isRequired ? Math.max(1, group.minSelect) : group.minSelect;
    if (count < min) errors[group.id] = group.optionType === 'SINGLE' ? 'Elige una opción' : `Elige al menos ${min}`;
    else if (count > group.maxSelect) errors[group.id] = `Máximo ${group.maxSelect}`;
  }
  return errors;
}
