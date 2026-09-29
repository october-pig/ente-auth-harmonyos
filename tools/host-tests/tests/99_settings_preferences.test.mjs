/**
 * 99_settings_preferences.test.mjs — findings T, U and X.
 *
 * DEVICE-DRIVEN. Reported from the real device:
 *   T 设置 → 隐藏验证码 toggled visually, reverted on reopen, and never hid codes
 *   U 设置 → 导入/导出 opened the page BEHIND the still-open Settings sheet
 *   X offline mode still showed a destructive 退出登录 with no warning
 *
 * Levels are labelled honestly: `BEHAVIOURAL` runs the real production module;
 * `STRUCTURAL CHECK` reads ArkUI `@Component` sources the harness cannot render.
 * A structural check is never reported as device verification.
 */
import { assert, assertEquals, describe, it } from '../framework.mjs';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..', '..');
const read = (rel) => readFileSync(join(REPO, rel), 'utf8');

const { EventBus, Events } = await import('../gen/entry/src/main/ets/events/EventBus.ts');
const { PreferenceService } = await import('../gen/entry/src/main/ets/services/PreferenceService.ts');

describe('finding T — hideCodes preference is reactive end to end', () => {
  it('STRUCTURAL CHECK — the switch draft changes before busy-state redraw, committed state only after persistence', () => {
    const src = read('entry/src/main/ets/pages/SettingsSections.ets');
    assert(src.includes('value: this.hideCodesDraft'), 'native switch binds to immediate UI draft');
    const callback = src.slice(src.indexOf('onChange: async (v: boolean)'));
    assert(callback.indexOf('this.hideCodesDraft = v') < callback.indexOf('this.hideCodesSaving = true'),
      'busy redraw must not put the old isOn back into the switch');
    assert(callback.indexOf('await PreferenceService.setShouldHideCodes(v)') < callback.indexOf('this.hideCodes = v'),
      'committed value only changes after persistence');
    assert(callback.includes('this.hideCodesDraft = this.hideCodes'), 'failure restores last committed value');
  });
  it('STRUCTURAL CHECK — native programmatic/disabled callbacks do not start a second save', () => {
    const src = read('entry/src/main/ets/pages/SettingsSections.ets');
    assert(src.includes('if (!this.toggleEnabled || v === this.value)'), 'ignore programmatic echo and disabled events');
  });
  it('BEHAVIOURAL — setShouldHideCodes round-trips through the preference store', async () => {
    await PreferenceService.setShouldHideCodes(true);
    assertEquals(await PreferenceService.shouldHideCodes(), true, 'stored true');
    await PreferenceService.setShouldHideCodes(false);
    assertEquals(await PreferenceService.shouldHideCodes(), false, 'stored false');
  });

  it('BEHAVIOURAL — the change signal fires on the DEDICATED event', async () => {
    let hideFired = 0;
    let iconsFired = 0;
    EventBus.on(Events.HIDE_CODES_CHANGED, () => {
      hideFired++;
    });
    EventBus.on(Events.ICONS_CHANGED, () => {
      iconsFired++;
    });
    await PreferenceService.setShouldHideCodes(true);
    assert(hideFired >= 1, 'HIDE_CODES_CHANGED must fire so Home can react');
    assertEquals(iconsFired, 0,
      'ICONS_CHANGED means "icon size changed" and must not be reused for masking');
    await PreferenceService.setShouldHideCodes(false);
  });

  it('BEHAVIOURAL — the write is awaited BEFORE the signal', async () => {
    // A listener that re-reads the preference must already see the new value;
    // otherwise Home would read the stale one and appear not to react.
    let observed = null;
    EventBus.on(Events.HIDE_CODES_CHANGED, () => {
      PreferenceService.shouldHideCodes().then((v) => {
        observed = v;
      });
    });
    await PreferenceService.setShouldHideCodes(true);
    await new Promise((r) => setTimeout(r, 10));
    assertEquals(observed, true, 'listener must observe the NEW value');
    await PreferenceService.setShouldHideCodes(false);
  });

  it('STRUCTURAL CHECK — the toggle value is a @Prop, not a copied @State', () => {
    const src = read('entry/src/main/ets/pages/SettingsSections.ets');
    assert(/@Prop\s+value:\s*boolean/.test(src),
      'SettingToggle.value must be @Prop: a plain member copied in aboutToAppear '
      + 'always captures the default before the parent\'s async load resolves');
    assert(!/^\s*initValue\s*:/m.test(src), 'the non-reactive initValue member must be gone');
  });

  it('STRUCTURAL CHECK — CodeCard re-formats on change instead of waiting 30s', () => {
    const src = read('entry/src/main/ets/components/CodeCard.ets');
    assert(/@Prop\s+@Watch\('onHideCodesChanged'\)\s+hideCodes/.test(src),
      'hideCodes needs @Watch: the displayed text is a formatted @State string and '
      + 'would otherwise only update at the next TOTP boundary');
    assert(/private rawCurrent: string/.test(src), 'raw value must be retained');
    assert(/private onHideCodesChanged\(\): void/.test(src), 'watch handler must exist');
  });

  it('STRUCTURAL CHECK — Home subscribes to the hide-codes signal', () => {
    const src = read('entry/src/main/ets/pages/HomePage.ets');
    assert(src.includes('Events.HIDE_CODES_CHANGED'),
      'Home read the preference only in aboutToAppear, so toggling never reached '
      + 'the rendered codes');
  });
});

describe('finding U — Settings is pushed; remaining sheets dismiss before navigation', () => {
  it('STRUCTURAL CHECK — Settings pushes a destination without a covering sheet', () => {
    const home = read('entry/src/main/ets/pages/HomePage.ets');
    const index = read('entry/src/main/ets/pages/Index.ets');
    assert(index.includes("Router.push('settings', undefined)"), 'native title action uses the mounted stack');
    assert(!home.includes('SheetKind.settings'), 'no Settings sheet may cover pushed pages');
    const src = read('entry/src/main/ets/pages/SettingsSections.ets');
    assert(!src.includes('.bindSheet('), 'Settings has no modal host');
    assert(src.includes('Router.push(route, undefined)'), 'section routes use the same stack');
  });

  it('STRUCTURAL CHECK — sections delegate through onNavigate', () => {
    const src = read('entry/src/main/ets/pages/SettingsSections.ets');
    for (const route of ['export', 'import', 'duplicates']) {
      assert(src.includes(`this.onNavigate('${route}')`), `${route} must be delegated`);
    }
    assert(/onNavigate:\s*\(route:\s*string\)\s*=>\s*void/.test(src), 'callback declared');
  });

  it('STRUCTURAL CHECK — Home performs the push in onDisappear, not on tap', () => {
    const src = read('entry/src/main/ets/pages/HomePage.ets');
    assert(/private navigateFromSheet\(route: string\): void/.test(src),
      'the route must be remembered, not pushed immediately');
    const dis = src.slice(src.indexOf('onDisappear: () => {'));
    assert(dis.slice(0, 500).includes('Router.push(route, undefined)'),
      'the deferred push must happen in bindSheet onDisappear — the real dismissal '
      + 'completion, not a guessed animation delay');
    assert(!/setTimeout\([^)]*,\s*\d{2,}/.test(src),
      'no arbitrary delay may be used to wait for the sheet animation');
  });
});

describe('finding X — offline-only users get no destructive logout', () => {
  it('STRUCTURAL CHECK — the account row depends on the account mode', () => {
    const src = read('entry/src/main/ets/pages/SettingsSections.ets');
    assert(/@Prop\s+accountConfigured:\s*boolean/.test(src),
      'the panel must know whether a real session exists');
    assert(/if \(this\.accountConfigured\) \{[\s\S]{0,400}?S\.logout\(\)/.test(src),
      '退出登录 must be shown ONLY for a configured account');
  });

  it('STRUCTURAL CHECK — offline mode offers the non-destructive direction', () => {
    const src = read('entry/src/main/ets/pages/SettingsSections.ets');
    assert(/else \{[\s\S]{0,400}?Router\.goToOnboardingRoot\(\)/.test(src),
      'offline-only must offer sign-in instead of a logout that orphans codes');
  });

  it('STRUCTURAL CHECK — logout explicitly clears only the ONLINE database', () => {
    // Shape only. This did NOT detect indirect destruction through Preferences.
    // 99_storage_safety executes the real logout/storage/crypto chain instead.
    const src = read('entry/src/main/ets/account/Configuration.ets');
    const body = src.slice(src.indexOf('async logout('));
    const end = body.indexOf('\n  }');
    const logout = body.slice(0, end);
    assert(logout.includes('AuthenticatorDB.clearTable()'), 'online DB is cleared');
    assert(!logout.includes('OfflineAuthenticatorDB'),
      'the offline DB must NOT be cleared by logout');
    assert(!/SecureStore\.delete\('offline_auth_secret_key'\)/.test(logout),
      'the offline key must NOT be deleted by logout');
  });

  it('API presence only — UserService.logout exists (truth table tested in suite 70)', async () => {
    const { UserService } = await import('../gen/entry/src/main/ets/account/UserService.ts');
    assert(typeof UserService.logout === 'function', 'UserService.logout still exists');
  });
});

describe('EventBus subscription lifetime', () => {
  it('BEHAVIOURAL — 100 appearance cycles release all historical handlers', () => {
    EventBus.clear();
    let calls = 0;
    for (let i = 0; i < 100; i++) {
      const handler = () => { calls++; };
      EventBus.on(Events.CODES_UPDATED, handler);
      EventBus.fire(Events.CODES_UPDATED, null);
      assertEquals(calls, i + 1);
      EventBus.off(Events.CODES_UPDATED, handler);
      EventBus.fire(Events.CODES_UPDATED, null);
      assertEquals(calls, i + 1);
      assertEquals(EventBus.listenerCount(Events.CODES_UPDATED), 0);
    }
  });
  it('BEHAVIOURAL — distinct function identities both receive events', () => {
    EventBus.clear();
    let calls = 0;
    const first = () => { calls++; };
    const second = () => { calls++; };
    EventBus.on(Events.CODES_UPDATED, first);
    EventBus.on(Events.CODES_UPDATED, second);
    EventBus.fire(Events.CODES_UPDATED, null);
    assertEquals(calls, 2);
    EventBus.clear();
  });
  it('BEHAVIOURAL — re-registering the same handler does not stack it', () => {
    EventBus.clear();
    let calls = 0;
    const handler = () => {
      calls++;
    };
    EventBus.on(Events.CODES_UPDATED, handler);
    EventBus.on(Events.CODES_UPDATED, handler);
    EventBus.on(Events.CODES_UPDATED, handler);
    assertEquals(EventBus.listenerCount(Events.CODES_UPDATED), 1,
      'the same handler must be registered once');
    EventBus.fire(Events.CODES_UPDATED, null);
    assertEquals(calls, 1, 'and therefore invoked once per event');
    EventBus.clear();
  });

  it('BEHAVIOURAL — off() releases a subscription', () => {
    EventBus.clear();
    let calls = 0;
    const handler = () => {
      calls++;
    };
    EventBus.on(Events.CODES_UPDATED, handler);
    EventBus.off(Events.CODES_UPDATED, handler);
    assertEquals(EventBus.listenerCount(Events.CODES_UPDATED), 0, 'released');
    EventBus.fire(Events.CODES_UPDATED, null);
    assertEquals(calls, 0, 'no longer invoked');
    EventBus.clear();
  });

  it('BEHAVIOURAL — off() on an unknown handler is a harmless no-op', () => {
    EventBus.clear();
    const a = () => {
    };
    const b = () => {
    };
    EventBus.on(Events.CODES_UPDATED, a);
    EventBus.off(Events.CODES_UPDATED, b);
    EventBus.off('NeverRegistered', a);
    assertEquals(EventBus.listenerCount(Events.CODES_UPDATED), 1, 'a survives');
    EventBus.clear();
  });

  it('STRUCTURAL CHECK — HomePage unsubscribes and guards stale instances', () => {
    const src = read('entry/src/main/ets/pages/HomePage.ets');
    assert(src.includes('aboutToDisappear') && src.includes('EventBus.off'),
      'HomePage must release its subscriptions on disappear');
    assert(/private onCodesUpdated:/.test(src) && /private onHideCodesChanged:/.test(src),
      'handlers need stable identities or they cannot be unsubscribed');
    assert(/HomePage\.generation/.test(src) || /HomePage\.generation/.test(src),
      'a generation guard keeps a superseded instance inert');
  });
});
