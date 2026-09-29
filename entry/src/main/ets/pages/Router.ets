/**
 * Router — NavPathStack-based navigation + cross-page launchers.
 *
 * NAVIGATION MODEL (single, explicit)
 * ----------------------------------
 * The `Navigation` host is owned by `Index` and is mounted for the whole life of
 * the app, independently of session state. Its ROOT CONTENT changes with the
 * session; the stack holds only PUSHED pages.
 *
 *   root content = authenticated ? HomePage : OnboardingPage
 *   stack        = pages pushed on top of that root
 *
 * Session changes go through exactly two transitions, so no page has to guess
 * where to go:
 *
 *   Router.goToAuthenticatedRoot()  — sign-in / signup / recovery / offline
 *   Router.goToOnboardingRoot()     — logout / signed out
 *
 * Both discard the pushed stack. That is what stops a signed-out user from
 * navigating back into authenticated pages.
 *
 * `onboarding` and `home` are deliberately NOT push destinations: they are root
 * states, reachable only through the two transitions above.
 *
 * Pages: setup, scanner, import, export, qr, reorder, share, login-email,
 * login-ott, password-set, password-reenter, recovery-key, recover, login-srp,
 * two-factor, passprompt, tag-input, duplicates.
 */
import { Configuration } from '../account/Configuration';
import { Code } from '../models/Code';
import { CodeStore, AddResult } from '../store/CodeStore';
import { AuthenticatorService } from '../services/AuthenticatorService';
import { Toast } from '../utils/Toast';
import { S } from '../app/AppStrings';
import { CodesParam, CodeParam, TagsParam } from './PageParams.ets';

/**
 * Implemented by the root page (`Index`) so the session transitions can change
 * what the mounted `Navigation` renders. Keeping this an interface — rather than
 * having Router reach into a component — is what lets the navigation model be
 * unit-tested on the host with a fake host and a fake stack.
 */
export interface RootNavigationHost {
  showAuthenticatedRoot(): void;

  showOnboardingRoot(): void;

  showSessionRecoveryRoot(): void;
}

export class Router {
  private static stack: NavPathStack | undefined = undefined;
  private static rootHost: RootNavigationHost | undefined = undefined;

  static setStack(stack: NavPathStack): void {
    Router.stack = stack;
  }

  static setRootHost(host: RootNavigationHost): void {
    Router.rootHost = host;
  }

  static clearRootHost(): void {
    Router.rootHost = undefined;
  }

  /** True once a root host is registered — i.e. the app shell is alive. */
  static hasRootHost(): boolean {
    return Router.rootHost !== undefined;
  }

  /**
   * Push one destination. The parameter is carried BY the NavPathStack itself
   * (see `currentParam`), so there is no parallel array to keep in step.
   */
  static push(name: string, param: object | undefined): void {
    if (Router.stack === undefined) {
      return;
    }
    Router.stack.pushPath({ name: name, param: param });
  }

  /**
   * Pop exactly one PUSHED destination.
   *
   * The `Navigation` ROOT is not part of `NavPathStack` — it is the
   * `Navigation`'s content, so `size()` counts only pushed destinations. The
   * previous guard was `size() > 1`, which refused to pop when exactly one route
   * was pushed. That stranded the scanner: `ScannerPage.startScan()` runs
   * `Router.back()` in its `finally`, the route never popped, and the app stayed
   * on the "扫描 / 扫描验证码" spinner forever even though the scan had already
   * completed and synced.
   *
   * DEVICE-VERIFIED (HUAWEI Mate 80 Pro Max, API 26), hilog from the old code:
   *   [DIAG] Router.back:      size=1 paramLen=1
   *   [DIAG] Router.back done: size=1 paramLen=0
   * i.e. the route stayed and the parallel parameter array did not — the two
   * were desynchronised by the same guard.
   *
   * Invariant, and the only one callers may rely on:
   *   root + []          -> no-op
   *   root + [scanner]   -> root + []
   *   root + [A, B]      -> root + [A]
   * The root is never popped, so Back on the root remains a no-op and the
   * platform's own root-back behaviour is untouched.
   */
  static back(): void {
    if (Router.stack === undefined) {
      return;
    }
    if (Router.stack.size() > 0) {
      Router.stack.pop();
    }
  }

  /**
   * The parameter of the topmost pushed destination, read from the real stack.
   *
   * This used to be a second, hand-maintained `object[]` pushed and popped
   * alongside the routes. That array could not stay correct: a system back
   * gesture pops the `NavPathStack` without going through `Router.back()`, and
   * the old guard popped the array without popping the route. Reading
   * `getParamByIndex` makes the stack the single source of truth, so
   * desynchronisation is not possible by construction.
   */
  static currentParam(): object | undefined {
    if (Router.stack === undefined) {
      return undefined;
    }
    const depth: number = Router.stack.size();
    if (depth === 0) {
      return undefined;
    }
    return Router.stack.getParamByIndex(depth - 1) as object | undefined;
  }

  /**
   * SESSION TRANSITION — discard every pushed page and show the authenticated
   * root. Used after sign-in, signup, recovery, offline opt-in, and after a
   * successful logout from a non-production endpoint.
   */
  static goToAuthenticatedRoot(): void {
    if (Configuration.instance.isSessionExpired()) { Router.goToSessionRecoveryRoot(); return; }
    Router.clearStack();
    if (Router.rootHost !== undefined) {
      Router.rootHost.showAuthenticatedRoot();
    }
  }

  /**
   * SESSION TRANSITION — discard every pushed page and show the onboarding root.
   * Driven by `SignedOutEvent`, so every logout path lands here, including the
   * ones that do not originate in the Settings UI.
   */
  static goToSessionRecoveryRoot(): void {
    Router.clearStack();
    if (Router.rootHost !== undefined) { Router.rootHost.showSessionRecoveryRoot(); }
  }

  static goToOnboardingRoot(): void {
    Router.clearStack();
    if (Router.rootHost !== undefined) {
      Router.rootHost.showOnboardingRoot();
    }
  }

  /**
   * Replace the pushed stack with a single page — the equivalent of upstream's
   * `pushAndRemoveUntil(..., (route) => route.isFirst)`. Used when a flow must
   * not be re-enterable via Back (e.g. after 2FA has consumed its session).
   */
  static resetTo(name: string, param: object | undefined): void {
    if (Router.stack === undefined) {
      return;
    }
    Router.clearStack();
    Router.push(name, param);
  }

  private static clearStack(): void {
    if (Router.stack !== undefined) {
      Router.stack.clear();
    }
  }
}

export class ScannerLauncher {
  static launchScan(): void {
    Router.push('scanner', undefined);
  }
}

export class ImportLauncher {
  static launch(): void {
    Router.push('import', undefined);
  }
}

export class ReorderLauncher {
  static launch(codes: Code[]): void {
    Router.push('reorder', new CodesParam(codes));
  }
}

export class ShareLauncher {
  launch(code: Code): void {
    Router.push('share', code);
  }
}

export class QrLauncher {
  launch(code: Code): void {
    Router.push('qr', code);
  }
}

export class EditEntryLauncher {
  /** Opens the manual entry page for a new (undefined) or existing code. */
  launchEntry(code: Code | undefined): void {
    Router.push('setup', new CodeParam(code));
  }
}

export class TagInputLauncher {
  async prompt(existingTags: string[]): Promise<string> {
    return new Promise<string>((resolve) => {
      pendingTagResolver = resolve;
      Router.push('tag-input', new TagsParam(existingTags));
    });
  }
}

let pendingTagResolver: ((tag: string) => void) | undefined = undefined;

export function resolveTagInput(tag: string): void {
  if (pendingTagResolver !== undefined) {
    pendingTagResolver(tag);
    pendingTagResolver = undefined;
  }
}

/** Adds a scanned/imported code like upstream home handlers. */
export async function addCodeFromScan(code: Code, fromGallery: boolean): Promise<void> {
  const result: AddResult = await CodeStore.instance.addCode(code, !fromGallery);
  if (result === AddResult.duplicate) {
    Toast.show(S.invalidQRCode());
  }
  AuthenticatorService.instance.onlineSync();
}