/**
 * PreferenceService — mirror of upstream
 * `mobile/apps/auth/lib/services/preference_service.dart` (keys exact).
 */
import { Preferences } from '../storage/Preferences';
import { TimeOffset } from '../otp/TotpUtil';
import { Events, EventBus } from '../events/EventBus';

export enum CodeSortKey {
  issuerName = 0,
  accountName = 1,
  mostFrequentlyUsed = 2,
  recentlyUsed = 3,
  manual = 4,
}

export class PreferenceService {
  private static initialized: boolean = false;

  static async init(): Promise<void> {
    if (PreferenceService.initialized) {
      return;
    }
    PreferenceService.initialized = true;
    // Reload the persisted time offset into the OTP clock.
    const offset = await Preferences.getIntOr('local_time_offset', 0);
    TimeOffset.setOffset(offset);
  }

  static async isHasShownCoachMark(): Promise<boolean> {
    return Preferences.getBool('has_shown_coach_mark_v2');
  }

  static async setHasShownCoachMark(value: boolean): Promise<void> {
    await Preferences.setBool('has_shown_coach_mark_v2', value);
  }

  static async codeSortKey(): Promise<CodeSortKey> {
    const v = await Preferences.getIntOr('codeSortKey', 0);
    if (v < 0 || v > 4) {
      return CodeSortKey.issuerName;
    }
    return v as CodeSortKey;
  }

  static async setCodeSortKey(key: CodeSortKey): Promise<void> {
    await Preferences.setInt('codeSortKey', key);
  }

  static async shouldShowLargeIcons(): Promise<boolean> {
    return Preferences.getBool('should_show_large_icons');
  }

  static async setShouldShowLargeIcons(v: boolean): Promise<void> {
    await Preferences.setBool('should_show_large_icons', v);
    EventBus.fire(Events.ICONS_CHANGED, null);
  }

  static async shouldHideCodes(): Promise<boolean> {
    return Preferences.getBool('should_hide_codes');
  }

  static async setShouldHideCodes(v: boolean): Promise<void> {
    await Preferences.setBool('should_hide_codes', v);
    // The write is awaited BEFORE the event fires, so a listener that re-reads the
    // preference always observes the new value. Firing `ICONS_CHANGED` here was
    // wrong (see Events.HIDE_CODES_CHANGED) and left the UI unable to react.
    EventBus.fire(Events.HIDE_CODES_CHANGED, null);
  }

  static async shouldAutoFocusOnSearchBar(): Promise<boolean> {
    return Preferences.getBool('should_auto_focus_on_search_bar');
  }

  static async setShouldAutoFocusOnSearchBar(v: boolean): Promise<void> {
    await Preferences.setBool('should_auto_focus_on_search_bar', v);
    EventBus.fire(Events.ICONS_CHANGED, null);
  }

  static async shouldMinimizeOnCopy(): Promise<boolean> {
    return Preferences.getBool('should_minimize_on_copy');
  }

  static async setShouldMinimizeOnCopy(v: boolean): Promise<void> {
    await Preferences.setBool('should_minimize_on_copy', v);
  }

  static async appInstallTime(): Promise<number> {
    let v = await Preferences.getInt('appInstallTime');
    if (v === undefined) {
      v = Date.now();
      await Preferences.setInt('appInstallTime', v);
    }
    return v;
  }

  static timeOffsetInMilliSeconds(): number {
    return TimeOffset.getOffset();
  }

  /**
   * Stores server-clock vs local-clock offset in ms; null removes the key
   * (upstream computeAndStoreTimeOffset semantics; input is MICROSECONDS).
   */
  static async computeAndStoreTimeOffset(epochTimeInMicroseconds: number | undefined): Promise<void> {
    if (epochTimeInMicroseconds === undefined) {
      await Preferences.remove('local_time_offset');
      TimeOffset.setOffset(0);
      return;
    }
    const serverMs: number = Math.floor(epochTimeInMicroseconds / 1000);
    const offset: number = serverMs - Date.now();
    await Preferences.setInt('local_time_offset', offset);
    TimeOffset.setOffset(offset);
  }
}