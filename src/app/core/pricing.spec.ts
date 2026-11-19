import { Product } from './models';
import { selectionErrors, unitPrice } from './pricing';
import { maskHnPhone, normalizeHnPhone } from '../shared/phone';

const burger: Product = {
  id: 'p', categoryId: 'c', name: 'Paco Clásica', description: '', price: 165, isAvailable: true, sortOrder: 1,
  options: [
    { id: 'term', name: 'Término', optionType: 'SINGLE', isRequired: true, minSelect: 1, maxSelect: 1, sortOrder: 1,
      values: [{ id: 't1', label: 'Medio', priceDelta: 0, isAvailable: true }] },
    { id: 'ex', name: 'Extras', optionType: 'MULTIPLE', isRequired: false, minSelect: 0, maxSelect: 2, sortOrder: 2,
      values: [
        { id: 'e1', label: 'Tocino', priceDelta: 30, isAvailable: true },
        { id: 'e2', label: 'Queso', priceDelta: 20, isAvailable: true },
        { id: 'e3', label: 'Huevo', priceDelta: 20, isAvailable: true },
      ] },
  ],
};

describe('pricing', () => {
  it('suma extras al precio base', () => {
    expect(unitPrice(burger, ['t1', 'e1', 'e2'])).toBe(215);
  });

  it('exige opciones obligatorias y respeta el máximo', () => {
    expect(selectionErrors(burger, [])).toHaveProperty('term');
    expect(selectionErrors(burger, ['t1'])).toEqual({});
    expect(selectionErrors(burger, ['t1', 'e1', 'e2', 'e3'])).toHaveProperty('ex');
  });
});

describe('normalizeHnPhone', () => {
  it('acepta formatos locales e internacionales de Honduras', () => {
    expect(normalizeHnPhone('9999-8888')).toBe('+50499998888');
    expect(normalizeHnPhone('+504 3344 5566')).toBe('+50433445566');
    expect(normalizeHnPhone('50422223344')).toBe('+50422223344');
  });

  it('rechaza números inválidos', () => {
    expect(normalizeHnPhone('1234-5678')).toBeNull();
    expect(normalizeHnPhone('999')).toBeNull();
  });
});

describe('maskHnPhone', () => {
  it('solo deja dígitos y aplica el formato 9999-9999', () => {
    expect(maskHnPhone('9abc9!99')).toBe('9999');
    expect(maskHnPhone('98765')).toBe('9876-5');
    expect(maskHnPhone('987654321234')).toBe('9876-5432');
  });

  it('quita el prefijo 504 al pegar un número completo', () => {
    expect(maskHnPhone('+504 9876-5432')).toBe('9876-5432');
  });
});
