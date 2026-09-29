import { Configuration } from './Configuration';
import { EventBus, Events } from '../events/EventBus';
import { Router } from '../pages/Router.ets';

/** Mounted by Index, not by Home: expiry also works over pushed destinations.
 * Stable handler identities ensure root recreation cannot accumulate listeners.
 */
export class RootSessionController {
  private readonly signedOut: (payload: object) => void = () => { Router.goToOnboardingRoot(); };
  private readonly expired: (payload: object) => void = () => {
    if (Configuration.instance.isSessionExpired()) { Router.goToSessionRecoveryRoot(); }
  };

  mount(): void {
    EventBus.on(Events.SIGNED_OUT, this.signedOut);
    EventBus.on(Events.TRIGGER_LOGOUT, this.expired);
    // Bootstrap sync can fail before Index mounts; persisted state is authority.
    if (Configuration.instance.isSessionExpired()) { Router.goToSessionRecoveryRoot(); }
  }

  unmount(): void {
    EventBus.off(Events.SIGNED_OUT, this.signedOut);
    EventBus.off(Events.TRIGGER_LOGOUT, this.expired);
  }
}
