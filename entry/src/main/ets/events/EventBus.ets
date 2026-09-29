/**
 * Minimal typed event bus mirroring the upstream `Bus` (ente_events) used by
 * AuthenticatorService/CodeStore/HomePage:
 *   CodesUpdatedEvent, SignedInEvent, SignedOutEvent, TriggerLogoutEvent,
 *   IconsChangedEvent, MultiSelectActionRequestedEvent, EndpointUpdatedEvent.
 */
export class EventBus {
  private static listeners: Map<string, Array<(payload: object) => void>> =
    new Map<string, Array<(payload: object) => void>>();

  static on<T>(type: string, handler: (payload: T) => void): void {
    let list = EventBus.listeners.get(type);
    if (list === undefined) {
      list = [];
      EventBus.listeners.set(type, list);
    }
    // One subscription per function identity. Distinct handlers remain distinct.
    const h = handler as (payload: object) => void;
    if (list.includes(h)) {
      return;
    }
    list.push(h);
  }

  /**
   * Remove a previously registered handler. Paired with `on` so a component can
   * release its subscriptions when it goes away.
   */
  static off<T>(type: string, handler: (payload: T) => void): void {
    const list = EventBus.listeners.get(type);
    if (list === undefined) {
      return;
    }
    const h = handler as (payload: object) => void;
    const idx: number = list.indexOf(h);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
    if (list.length === 0) {
      EventBus.listeners.delete(type);
    }
  }

  /** Number of live handlers for a type. Used by tests and diagnostics. */
  static listenerCount(type: string): number {
    const list = EventBus.listeners.get(type);
    return list === undefined ? 0 : list.length;
  }

  static fire<T>(type: string, payload: T): void {
    const list = EventBus.listeners.get(type);
    if (list === undefined) {
      return;
    }
    // Copy to allow handlers to unsubscribe.
    const snapshot: Array<(payload: object) => void> = list.slice();
    for (let i = 0; i < snapshot.length; i++) {
      try {
        snapshot[i](payload as object);
      } catch (e) {
        // Handler errors must not break the bus.
      }
    }
  }

  static clear(): void {
    EventBus.listeners.clear();
  }
}

/** Event type constants (string keys keep the bus simple and serializable). */
export class Events {
  static readonly CODES_UPDATED = 'CodesUpdatedEvent';
  /** Presentation progress only; carries no code/account data. */
  static readonly OFFLINE_MIGRATION_CHANGED = 'OfflineMigrationChangedEvent';
  static readonly SIGNED_IN = 'SignedInEvent';
  static readonly SIGNED_OUT = 'SignedOutEvent';
  static readonly TRIGGER_LOGOUT = 'TriggerLogoutEvent';
  static readonly ICONS_CHANGED = 'IconsChangedEvent';
  /**
   * Fired when `should_hide_codes` changes.
   *
   * Deliberately NOT `ICONS_CHANGED`: that event means "the icon size preference
   * changed" and is consumed for layout. Reusing it for code masking meant Home
   * had no correct signal to subscribe to, which is why toggling 隐藏验证码 did
   * not affect the rendered codes (finding T).
   */
  static readonly HIDE_CODES_CHANGED = 'HideCodesChangedEvent';
  static readonly MULTI_SELECT_ACTION_REQUESTED = 'MultiSelectActionRequestedEvent';
  static readonly ENDPOINT_UPDATED = 'EndpointUpdatedEvent';
}

export enum MultiSelectAction {
  pinToggle = 0,
  unpin = 1,
  addTag = 2,
  trash = 3,
  restore = 4,
  deleteForever = 5,
}

export class MultiSelectActionRequestedEventPayload {
  action: MultiSelectAction;

  constructor(action: MultiSelectAction) {
    this.action = action;
  }
}
