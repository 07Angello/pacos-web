// Contratos públicos (DTO) que devuelven las RPCs. Definidos por las funciones SQL de supabase/migrations.

export type OrderStatus =
  | 'PENDING'
  | 'ACCEPTED'
  | 'PREPARING'
  | 'READY'
  | 'OUT_FOR_DELIVERY'
  | 'COMPLETED'
  | 'REJECTED'
  | 'CANCELLED';

export type OrderType = 'PICKUP' | 'DELIVERY' | 'DINE_IN'; // DINE_IN: pedidos tomados en el local

export interface PaymentMethod {
  code: string;
  label: string;
}

export interface BusinessHour {
  weekday: number;
  label: string;
  opensAt: string | null;
  closesAt: string | null;
  isClosed: boolean;
}

export interface RestaurantSettings {
  name: string;
  slug: string;
  tagline: string | null;
  phone: string | null;
  address: string | null;
  timezone: string;
  currency: string;
  currencySymbol: string;
  isOpen: boolean;
  pickupEnabled: boolean;
  deliveryEnabled: boolean;
  deliveryFee: number;
  estimatedPrepMinutes: number | null;
  paymentMethods: PaymentMethod[];
  businessHours: BusinessHour[];
}

export interface Category {
  id: string;
  name: string;
  description: string | null;
  icon: string | null;
  sortOrder: number;
  isActive: boolean;
}

export interface OptionValue {
  id: string;
  label: string;
  priceDelta: number;
  isAvailable: boolean;
  /** Configurado por el administrador: viene marcada al abrir el plato. */
  isDefault?: boolean;
}

export interface ProductOption {
  id: string;
  name: string;
  optionType: 'SINGLE' | 'MULTIPLE';
  isRequired: boolean;
  minSelect: number;
  maxSelect: number;
  sortOrder: number;
  values: OptionValue[];
}

export interface Product {
  id: string;
  categoryId: string;
  name: string;
  description: string | null;
  price: number;
  imagePath?: string | null;
  isAvailable: boolean;
  isFeatured?: boolean;
  sortOrder: number;
  options: ProductOption[];
}

export interface PublicMenu {
  settings: RestaurantSettings;
  categories: Category[];
  products: Product[];
}

export interface CreateOrderInput {
  idempotencyKey: string;
  customer: { name: string; phone: string };
  orderType: OrderType;
  address?: { neighborhood: string; street: string; house: string; reference: string };
  paymentMethod: string;
  notes: string;
  items: { productId: string; quantity: number; notes: string; optionValueIds: string[] }[];
  /** Solo PICKUP: hora de recogida elegida (ISO de un horario de get_pickup_slots). null = lo antes posible. */
  scheduledFor?: string | null;
}

export interface CreateOrderResult {
  orderNumber: string;
  trackingToken: string;
  total: number;
  status: OrderStatus;
  replayed: boolean;
  scheduledFor: string | null;
}

export interface PickupSlot {
  /** ISO 8601 (se envía tal cual en scheduledFor). */
  at: string;
  /** Hora local del restaurante, ej. "4:00 PM". */
  label: string;
}

export interface PickupSlots {
  leadMinutes: number;
  /** dayIndex 0 = hoy, 1 = mañana; date = YYYY-MM-DD local del restaurante. */
  days: { dayIndex: number; date: string; slots: PickupSlot[] }[];
}

export interface OrderTracking {
  orderNumber: string;
  status: OrderStatus;
  orderType: OrderType;
  customerFirstName: string;
  items: { productName: string; quantity: number; lineTotal: number; options: string[] }[];
  subtotal: number;
  deliveryFee: number;
  total: number;
  paymentMethodLabel: string;
  createdAt: string;
  /** Hora de recogida programada (null = lo antes posible). */
  scheduledFor: string | null;
  /** El cliente puede cancelar mientras el restaurante no lo haya aceptado. */
  canCancel: boolean;
  cancelledAt: string | null;
  cancellationReason: string | null;
  timeline: { status: OrderStatus; at: string }[];
  rejectionReason: string | null;
  restaurant: { name: string; phone: string | null; address: string | null };
  estimatedPrepMinutes: number | null;
}

/** Error normalizado de backend (Supabase). */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }

  get isNetwork(): boolean {
    return this.status === 0;
  }
}

export interface ValidationDetails {
  fields?: Record<string, string>;
  lines?: { index: number; productId?: string; message: string }[];
}
