import { HdsNavigation, HdsNavDestination, HdsNavigationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
/**
 * Index — root page and the single owner of the ROOT NAVIGATION HOST.
 * HDS supplies the native gradient/material title bar around the SAME stack.
 *
 * The `Navigation` component is mounted for the entire life of the app, once the
 * session has been decided. Only its ROOT CONTENT changes with the session:
 *
 *   authenticated  -> HomePage
 *   signed out     -> OnboardingPage
 *
 * This is what makes onboarding reachable at all. Previously `Navigation` was
 * mounted ONLY on the authenticated branch and `OnboardingPage` was rendered
 * bare, so `Router.push('login-email')` pushed onto a `NavPathStack` that no
 * mounted `Navigation` was rendering — every onboarding route silently did
 * nothing on a fresh install (finding K).
 *
 * Session transitions are explicit and live here, not in each page:
 *   Router.goToAuthenticatedRoot()  — sign-in / signup / recovery / offline
 *   Router.goToOnboardingRoot()     — logout / signed out
 * Both discard the pushed stack, so Back cannot return a signed-out user to an
 * authenticated page (finding L).
 */
import { SettingsSection, SettingsDetail } from './SettingsSections';
import { S } from '../app/AppStrings';
import { Configuration } from '../account/Configuration';
import { AuthenticatorService } from '../services/AuthenticatorService';
import { Router, RootNavigationHost } from './Router';
import { RootSessionController } from '../account/RootSessionController';
import { SessionRecoveryPage } from './SessionRecoveryPage';
import { HomePage, HOME_TITLE_FADE_HEIGHT } from './HomePage';
import { OnboardingPage, EmailEntryPage, OtpEntryPage, PasswordSetPage,
  PasswordReentryPage, RecoveryKeyPage, RecoverAccountPage, SrpLoginPage,
  TwoFactorPage } from './OnboardingFlow';
import { SetupSecretKeyPage } from './SetupSecretKeyPage';
import { ScannerPage } from './ScannerPage';
import { ImportPage } from './ImportPage';
import { ExportPage, PasswordPromptPage, QrPage, SharePage, ReorderPage,
  TagInputPage, DuplicatesPage } from './ExportPage';

/**
 * Root-host implementation bound to the `Index` component's `@State`.
 *
 * A class rather than an object literal: ArkTS rejects untyped object literals
 * (`arkts-no-untyped-obj-literals`), so an interface with methods has to be
 * implemented explicitly.
 */
class IndexRootHost implements RootNavigationHost {
  private onAuthenticated: () => void;
  private onOnboarding: () => void;
  private onRecovery: () => void;

  constructor(onAuthenticated: () => void, onOnboarding: () => void, onRecovery: () => void) {
    this.onAuthenticated = onAuthenticated;
    this.onOnboarding = onOnboarding;
    this.onRecovery = onRecovery;
  }

  showAuthenticatedRoot(): void {
    this.onAuthenticated();
  }

  showSessionRecoveryRoot(): void { this.onRecovery(); }

  showOnboardingRoot(): void {
    this.onOnboarding();
  }
}

@Entry
@Component
struct Index {
  @State ready: boolean = false;
  /** Which ROOT the mounted Navigation renders. Never gates the Navigation itself. */
  @State authenticatedRoot: boolean = false;
  @State recoveryRoot: boolean = false;
  private readonly sessionController: RootSessionController = new RootSessionController();
  private navStack: NavPathStack = new NavPathStack();
  private homeScroller: Scroller = new Scroller();
  @State homeSortRequest: number = 0;

  aboutToAppear(): void {
    Router.setStack(this.navStack);
    Router.setRootHost(new IndexRootHost(
      () => {
        this.recoveryRoot = false;
        this.authenticatedRoot = true;
      },
      () => {
        this.recoveryRoot = false;
        this.authenticatedRoot = false;
      },
      () => { this.recoveryRoot = true; this.authenticatedRoot = false; this.ready = true; }));
    this.sessionController.mount();
    this.decide();
  }

  aboutToDisappear(): void {
    this.sessionController.unmount();
    Router.clearRootHost();
  }

  private async decide(): Promise<void> {
    if (Configuration.instance.isSessionExpired()) { Router.goToSessionRecoveryRoot(); return; }
    const revision = Configuration.instance.getAccountRevision();
    const hasAccount: boolean = Configuration.instance.hasConfiguredAccount();
    if (hasAccount) {
      this.authenticatedRoot = true;
      this.ready = true;
      AuthenticatorService.instance.init();
      return;
    }
    const hasOffline: boolean = await Configuration.instance.hasOptedForOfflineMode();
    if (revision !== Configuration.instance.getAccountRevision()) { return; }
    // Keep opted-in users on Home so missing/unusable data keys produce an
    // explicit read error, not a misleading new-account flow.
    const offlineKeyAvailable: boolean = Configuration.instance.getOfflineSecretKey() !== undefined;
    const showOnboarding: boolean = !hasOffline;
    this.authenticatedRoot = !showOnboarding;
    this.ready = true;
    if (hasOffline && offlineKeyAvailable) {
      AuthenticatorService.instance.init();
    }
  }

  /**
   * Destination builder for the Navigation stack.
   *
   * It MUST resolve to a `NavDestination` node. ArkUI finds one by walking down
   * from the builder's root through its FIRST child at each level; if it never
   * finds a `NavDestination`, the route renders with the framework's default
   * shell (a back button) and NO content — `errorcode-router` 100006,
   * "NavDestination not found" (`arkts-navigation-faq`).
   *
   * Previously every branch returned a bare page component whose `build()`
   * returns a plain `Column`, so EVERY pushed route rendered blank on device.
   * DEVICE VERIFIED (HUAWEI Mate 80 Pro Max, API 26): "Enter a setup key" showed
   * the back chevron and nothing else.
   *
   * Wrapping the whole map in ONE destination fixes that without touching
   * the page flows. HdsNavDestination now pairs with HdsNavigation; Settings
   * uses its native title, while other pages retain their existing headers.
   */
  @Builder
  PageMap(name: string) {
    HdsNavDestination() {
      if (name === 'settings') {
        SettingsSection({ accountConfigured: Configuration.instance.hasConfiguredAccount() })
      } else if (name.startsWith('settings-')) {
        SettingsDetail({ section: name, accountConfigured: Configuration.instance.hasConfiguredAccount() })
      } else if (name === 'login-email') {
        EmailEntryPage()
      } else if (name === 'login-ott') {
        OtpEntryPage()
      } else if (name === 'password-set') {
        PasswordSetPage()
      } else if (name === 'password-reenter') {
        PasswordReentryPage()
      } else if (name === 'recovery-key') {
        RecoveryKeyPage()
      } else if (name === 'recover') {
        RecoverAccountPage()
      } else if (name === 'login-srp') {
        SrpLoginPage()
      } else if (name === 'two-factor') {
        TwoFactorPage()
      } else if (name === 'setup') {
        SetupSecretKeyPage()
      } else if (name === 'scanner') {
        ScannerPage()
      } else if (name === 'import') {
        ImportPage()
      } else if (name === 'export') {
        ExportPage()
      } else if (name === 'passprompt') {
        PasswordPromptPage()
      } else if (name === 'qr') {
        QrPage()
    } else if (name === 'share') {
      SharePage()
    } else if (name === 'reorder') {
      ReorderPage()
    } else if (name === 'tag-input') {
      TagInputPage()
    } else if (name === 'duplicates') {
      DuplicatesPage()
    }
    }
    .hideTitleBar(!name.startsWith('settings'))
    .titleBar({ avoidLayoutSafeArea: true, content: { title: { mainTitle: this.settingsTitle(name) } } })
    .backgroundColor($r('app.color.page'))
  }

  private settingsTitle(name: string): string {
    if (name === 'settings-security') { return S.security(); }
    if (name === 'settings-data') { return S.data(); }
    if (name === 'settings-account') { return S.accountSection(); }
    if (name === 'settings-appearance') { return S.appearance(); }
    if (name === 'settings-about') { return S.about(); }
    return S.settings();
  }

  build() {
    if (!this.ready) {
      Stack() {
        LoadingProgress()
          .width(42)
          .height(42)
          .color($r('app.color.accent'))
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page'))
    } else {
      // The Navigation host is ALWAYS mounted. Session state selects the root
      // CONTENT; it must never remove the host, or pushed routes have nothing
      // to render into.
      HdsNavigation(this.navStack) {
        if (this.recoveryRoot) {
          SessionRecoveryPage()
        } else if (this.authenticatedRoot) {
          HomePage({ sortRequest: this.homeSortRequest,
            scroller: this.homeScroller })
        } else {
          OnboardingPage()
        }
      }
      .mode(NavigationMode.Stack)
      .hideTitleBar(!this.authenticatedRoot || this.recoveryRoot)
      .hideBackButton(true)
      .titleMode(HdsNavigationTitleMode.MINI)
      .bindToScrollable([this.homeScroller])
      .titleBar({
        avoidLayoutSafeArea: true,
        content: {
          title: { mainTitle: S.appName() },
          menu: { value: [
            { content: {
              label: S.editOrder(),
              icon: new SymbolGlyphModifier($r('sys.symbol.sort')).fontColor([$r('sys.color.ohos_id_color_primary')]),
              action: () => { this.homeSortRequest++; }
            } },
            { content: {
              label: S.settings(),
              icon: new SymbolGlyphModifier($r('sys.symbol.gearshape')).fontColor([$r('sys.color.ohos_id_color_primary')]),
              action: () => { Router.push('settings', undefined); }
            } }
          ] }
        },
        style: {
          scrollEffectOpts: { enableScrollEffect: false, scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          },
          originalStyle: {
            backgroundStyle: { backgroundColor: $r('app.color.page'), maskExtraHeight: HOME_TITLE_FADE_HEIGHT },
            contentStyle: {
              titleStyle: { mainTitleColor: $r('sys.color.ohos_id_color_primary') },
              menuStyle: { iconColor: $r('sys.color.ohos_id_color_primary'), backgroundColor: $r('app.color.surface') }
            }
          }
        }
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], this.authenticatedRoot && !this.recoveryRoot
        ? [LayoutSafeAreaEdge.TOP] : [])
      .backgroundColor($r('app.color.page'))
      .navDestination(this.PageMap)
    }
  }
}
