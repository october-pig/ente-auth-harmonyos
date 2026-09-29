/**
 * 98_router_back_semantics.test.mjs — the Router.back() invariant.
 *
 * DEVICE-DRIVEN REGRESSION. On the real device the scanner completed a scan,
 * pushed the code, and then stayed on "扫描 / 扫描验证码" with a spinner forever.
 * hilog from the old code:
 *
 *   [DIAG] Router.back:      size=1 paramLen=1
 *   [DIAG] Router.back done: size=1 paramLen=0
 *
 * The guard was `size() > 1`. Because the `Navigation` ROOT is the Navigation's
 * *content* and not part of `NavPathStack`, a single pushed route has size 1, so
 * the guard refused to pop while the parallel parameter array WAS popped — the
 * route stayed and the two fell out of step.
 *
 * These are BEHAVIOURAL tests against the real production `Router`; `Router` is
 * deliberately free of ArkUI so the host can execute it. Test 2 fails on the
 * previous revision.
 */
import { assert, assertEquals, describe, it } from '../framework.mjs';

const { Router } = await import('../gen/entry/src/main/ets/pages/Router.ts');

/** Duck-typed NavPathStack, matching the SDK contract. */
class FakeNavPathStack {
  constructor() {
    this.entries = [];
  }
  pushPath(info) {
    this.entries.push(info);
  }
  pop() {
    return this.entries.pop();
  }
  size() {
    return this.entries.length;
  }
  clear() {
    this.entries = [];
  }
  names() {
    return this.entries.map((e) => e.name);
  }
  getParamByIndex(index) {
    const e = this.entries[index];
    return e === undefined ? undefined : e.param;
  }
  getAllPathName() {
    return this.entries.map((e) => e.name);
  }
}

function freshStack() {
  const stack = new FakeNavPathStack();
  const host = {
    root: undefined,
    showAuthenticatedRoot() {
      this.root = 'authenticated';
    },
    showOnboardingRoot() {
      this.root = 'onboarding';
    },
  };
  Router.setStack(stack);
  Router.setRootHost(host);
  return { stack, host };
}

describe('Router.back() — pops exactly one pushed destination', () => {
  it('1. empty pushed stack: back() is a no-op and does not fail', () => {
    const { stack } = freshStack();
    Router.back();
    assertEquals(stack.size(), 0, 'still empty');
    assertEquals(Router.currentParam(), undefined, 'no param');
    Router.clearRootHost();
  });

  it('2. ONE pushed route: back() pops it  <-- FAILED before the fix', () => {
    const { stack } = freshStack();
    Router.push('scanner', undefined);
    assertEquals(stack.size(), 1, 'one pushed route');

    Router.back();

    // The root is the Navigation's content, NOT a stack entry, so a single
    // pushed route must be poppable. `size() > 1` refused, stranding the page.
    assertEquals(stack.size(), 0, 'the pushed route must be popped');
    assertEquals(stack.names(), [], 'nothing left pushed');
    Router.clearRootHost();
  });

  it('3. two pushed routes: back() leaves only the first', () => {
    const { stack } = freshStack();
    Router.push('setup', undefined);
    Router.push('export', undefined);
    assertEquals(stack.names(), ['setup', 'export'], 'pushed in order');

    Router.back();

    assertEquals(stack.names(), ['setup'], 'only A remains');
    Router.clearRootHost();
  });

  it('4. parameter access stays aligned with the route stack', () => {
    const { stack } = freshStack();
    const paramA = { marker: 'A' };
    const paramB = { marker: 'B' };
    Router.push('A', paramA);
    Router.push('B', paramB);

    assertEquals(Router.currentParam(), paramB, 'top param is B');
    Router.back();
    assertEquals(Router.currentParam(), paramA, 'after back the param is A');
    Router.back();
    assertEquals(Router.currentParam(), undefined, 'and then none');
    assertEquals(stack.size(), 0, 'stack drained in step');
    Router.clearRootHost();
  });

  it('5. a single pushed route WITH a param drains both together', () => {
    const { stack } = freshStack();
    Router.push('scanner', { mode: 'scan' });
    assertEquals(Router.currentParam(), { mode: 'scan' }, 'param present');

    Router.back();

    assertEquals(stack.size(), 0, 'route stack empty');
    assertEquals(Router.currentParam(), undefined, 'param stack empty');
    Router.clearRootHost();
  });

  it('6. repeated back() never underflows below the root', () => {
    const { stack } = freshStack();
    Router.push('scanner', undefined);
    for (let i = 0; i < 5; i++) {
      Router.back();
    }
    assertEquals(stack.size(), 0, 'never negative, never throws');
    assertEquals(Router.currentParam(), undefined, 'param still undefined');
    Router.clearRootHost();
  });

  it('7. the scanner sequence: push -> back -> push -> back', () => {
    // The exact device flow, repeated: this is what the scan/cancel cycles do.
    const { stack } = freshStack();
    for (let cycle = 0; cycle < 3; cycle++) {
      Router.push('scanner', undefined);
      assertEquals(stack.size(), 1, `cycle ${cycle}: scanner pushed`);
      Router.back();
      assertEquals(stack.size(), 0, `cycle ${cycle}: returned to root`);
      assertEquals(Router.currentParam(), undefined, `cycle ${cycle}: param cleared`);
    }
    Router.clearRootHost();
  });

  it('8. a system back gesture cannot desynchronise the param', () => {
    // ArkUI pops the NavPathStack directly for a system back gesture; Router.back
    // is never called. Because currentParam reads the real stack, it stays right.
    const { stack } = freshStack();
    Router.push('A', { marker: 'A' });
    Router.push('B', { marker: 'B' });
    stack.pop();                       // system gesture, bypassing Router
    assertEquals(Router.currentParam(), { marker: 'A' },
      'param follows the real stack, not a parallel array');
    Router.back();
    assertEquals(stack.size(), 0, 'and a subsequent back still works');
    Router.clearRootHost();
  });

  it('9. root transitions discard the whole pushed stack', () => {
    const { stack, host } = freshStack();
    Router.push('A', { marker: 'A' });
    Router.push('B', { marker: 'B' });
    Router.goToOnboardingRoot();
    assertEquals(stack.size(), 0, 'pushed routes discarded');
    assertEquals(Router.currentParam(), undefined, 'no stale param');
    assertEquals(host.root, 'onboarding', 'root switched');
    Router.clearRootHost();
  });

  it('10. Router no longer keeps a parallel parameter array', () => {
    // Structural, but it guards the invariant that makes 8 impossible to break.
    // (The behavioural proof is tests 4 and 8.)
    const src = Router.toString();
    assert(!src.includes('paramStack'),
      'a hand-maintained parallel array cannot stay correct across system-back pops');
  });
});
