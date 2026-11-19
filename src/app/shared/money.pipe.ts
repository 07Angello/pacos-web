import { Pipe, PipeTransform } from '@angular/core';

const fmt = new Intl.NumberFormat('es-HN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/** Formatea montos en Lempiras: 165 → "L 165.00". */
@Pipe({ name: 'money' })
export class MoneyPipe implements PipeTransform {
  transform(value: number | null | undefined, symbol = 'L'): string {
    return `${symbol} ${fmt.format(value ?? 0)}`;
  }
}
