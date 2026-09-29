/**
 * Onboarding + login flow pages — mirror of upstream onboarding_page.dart and
 * the accounts package pages: create account / log in / offline mode,
 * email step → OTT step → password step (set or reentry) → recovery key
 * (signup) / SRP login / 2FA / recovery-by-key branches.
 */
import { PageHeader, BusyButton } from '../components/NativeControls';
import { promptAction } from '@kit.ArkUI';
import { Configuration } from '../account/Configuration';
import { UserService, SrpAttributes, PostLoginStep } from '../account/UserService';
import { Router } from './Router.ets';
import { S } from '../app/AppStrings';
import { Toast } from '../utils/Toast';
import { Bip39 } from '../account/Bip39';
import { KeyGenResult, KeyAttributes } from '../models/KeyAttributes';
import { LoginResponse } from '../account/UserService';
import { LoginModeParam, EmailFlowParam, SrpLoginParam, KeyGenResultParam, SessionIDParam } from './PageParams.ets';
import { AuthenticatorService } from '../services/AuthenticatorService';
import { isValidEmail } from '../utils/Clipboard';
import { Events, EventBus } from '../events/EventBus';

const MILD_STRENGTH_THRESHOLD: number = 0.4;

/** Simple password strength estimator (0..1) mirroring the upstream library's spirit. */
export function estimatePasswordStrength(password: string): number {
  if (password.length === 0) {
    return 0;
  }
  let variety = 0;
  if (/[a-z]/.test(password)) {
    variety++;
  }
  if (/[A-Z]/.test(password)) {
    variety++;
  }
  if (/[0-9]/.test(password)) {
    variety++;
  }
  if (/[^a-zA-Z0-9]/.test(password)) {
    variety++;
  }
  const lengthScore: number = Math.min(1, password.length / 12);
  return lengthScore * (0.4 + 0.2 * variety);
}

@Component
export struct OnboardingPage {
  @State busy: boolean = false;

  build() {
    Column() {
      Column() {
        Text('ente')
          .fontSize(40)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent'))
        Text('Auth')
          .fontSize(18)
          .fontColor($r('sys.color.ohos_id_color_secondary'))
          .margin({ top: 4 })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)

      Column() {
        Button(S.login())
          .width('100%')
          .height(48)
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            Router.push('login-email', new LoginModeParam(false));
          })
        Button(S.createAccount())
          .width('100%')
          .height(48)
          .margin({ top: 12 })
          .backgroundColor($r('app.color.page'))
          .fontColor($r('app.color.accent'))
          .border({ width: 1, color: $r('app.color.accent') })
          .onClick(() => {
            Router.push('login-email', new LoginModeParam(true));
          })
        Text(S.useOffline())
          .fontSize(15)
          .fontColor($r('app.color.accent'))
          .margin({ top: 16 })
          .onClick(() => {
            this.optOffline();
          })
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 40 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page'))
  }

  private async optOffline(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await Configuration.instance.optForOfflineMode();
      await AuthenticatorService.instance.init();
      Router.goToAuthenticatedRoot();
    } catch (e) {
      Toast.show(S.unableToReadCodes());
    } finally {
      this.busy = false;
    }
  }
}

/** Combined login surface; signup and email verification retain their staged flows. */
@Component
export struct EmailEntryPage {
  @State email: string = '';
  @State password: string = '';
  @State isSignup: boolean = false;
  @State busy: boolean = false;

  aboutToAppear(): void {
    const param = Router.currentParam() as LoginModeParam | undefined;
    if (param !== undefined) { this.isSignup = param.isSignup; }
    const saved = Configuration.instance.getEmail();
    if (saved !== undefined) { this.email = saved; }
  }

  aboutToDisappear(): void { this.password = ''; }

  build() {
    Column() {
      PageHeader({ title: this.isSignup ? S.createAccount() : S.login(), backEnabled: !this.busy,
        onBack: () => { Router.back(); } })
      Scroll() {
        Column({ space: 12 }) {
          Image($r('app.media.ente_auth')).width(64).height(64).borderRadius(16)
            .accessibilityText(S.appName()).margin({ bottom: 8 })
          Text(this.isSignup ? S.createAccount() : S.loginIntro()).fontSize(26).fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.ohos_id_color_primary')).width('100%')
          Text(this.isSignup ? S.signupHelp() : S.loginHelp()).fontSize(15).fontColor($r('sys.color.ohos_id_color_secondary'))
            .width('100%').margin({ bottom: 16 })
          Text(S.email()).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
          TextInput({ text: this.email, placeholder: S.email() })
            .height(52).type(InputType.Email).enabled(!this.busy)
            .onChange((v: string) => { this.email = v; })
          if (!this.isSignup) {
            Text(S.password()).fontSize(14).fontWeight(FontWeight.Medium).width('100%').margin({ top: 8 })
            TextInput({ text: this.password, placeholder: S.password() })
              .height(52).type(InputType.Password).enabled(!this.busy)
              .onChange((v: string) => { this.password = v; })
              .onSubmit(() => { this.submit(); })
          }
          BusyButton({ label: this.isSignup ? S.continuePage() : S.login(), busy: this.busy,
            onAction: () => { this.submit(); } }).margin({ top: 16 })
          if (!this.isSignup) {
            Button(S.forgotPassword()).type(ButtonType.Normal).backgroundColor(Color.Transparent)
              .fontColor($r('app.color.accent')).height(48).enabled(!this.busy)
              .onClick(() => { this.requestEmailLogin(); })
          }
          Text(S.unofficialPort()).fontSize(12).fontColor($r('sys.color.ohos_id_color_secondary'))
            .width('100%').margin({ top: 20 })
        }.width('100%').constraintSize({ maxWidth: 520 }).padding({ left: 24, right: 24, top: 20, bottom: 32 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor($r('app.color.page'))
  }

  private async requestEmailLogin(): Promise<void> {
    if (this.busy) { return; }
    const email = this.email.trim();
    if (!isValidEmail(email)) { Toast.show(S.enterValidEmail()); return; }
    this.busy = true;
    this.password = '';
    try {
      await Configuration.instance.setEmail(email);
      await UserService.sendOtt(email, '', true);
      Router.push('login-ott', new EmailFlowParam(false, email));
    } catch (e) { Toast.show((e as Error).message); }
    finally { this.busy = false; }
  }

  private async submit(): Promise<void> {
    if (this.busy) {
      return;
    }
    const email: string = this.email.trim();
    if (!isValidEmail(email)) {
      Toast.show(S.enterValidEmail());
      return;
    }
    const password = this.password;
    this.busy = true;
    try {
      // Persisted before any network call, and awaited: an un-awaited write
      // could be lost while the OTT request is already in flight.
      await Configuration.instance.setEmail(email);
      if (!this.isSignup) {
        // The SRP-vs-OTT decision is a service-level state-machine step, not a
        // page detail, so it is executed (and tested) in UserService. It returns
        // undefined for a 404 AND for every other failure, which is upstream
        // parity — upstream's catch falls through to OTT for any error and only
        // logs the non-404 ones (finding M).
        const attrs: SrpAttributes | undefined =
          await UserService.resolveSrpAttributesForLogin(email);
        if (attrs !== undefined) {
          if (password.length === 0) { Toast.show(S.password()); return; }
          await completePasswordLogin(email, password, attrs);
          this.password = '';
          return;
        }
      }
      this.password = '';
      await UserService.sendOtt(email, this.isSignup ? 'signup' : 'login', true);
      Router.push('login-ott', new EmailFlowParam(this.isSignup, email));
    } catch (e) {
      Toast.show((e as Error).message);
    } finally {
      this.busy = false;
    }
  }
}

@Component
export struct OtpEntryPage {
  @State code: string = '';
  @State busy: boolean = false;
  @State isSignup: boolean = false;
  @State email: string = '';

  aboutToAppear(): void {
    const param = Router.currentParam() as EmailFlowParam | undefined;
    if (param !== undefined) {
      this.isSignup = param.isSignup;
      this.email = param.email;
    }
  }

  build() {
    Column() {
      TopBarSimple({ title: S.enterCode(), onBack: () => {
        Router.back();
      }})
      Column() {
        Text(S.enterCode())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        TextInput({ text: this.code, placeholder: '123456' })
          .height(52)
          .type(InputType.Number)
          .maxLength(6)
          .fontSize(22)
          .textAlign(TextAlign.Center)
          .margin({ top: 24 })
          .onChange((v: string) => {
            this.code = v;
          })
        BusyButton({ label: S.verify(), busy: this.busy, onAction: () => { this.verify(); } })
          .margin({ top: 24 })
        Text(S.resendCode())
          .fontSize(14)
          .fontColor($r('app.color.accent'))
          .margin({ top: 16 })
          .onClick(() => {
            UserService.sendOtt(this.email, this.isSignup ? 'signup' : 'login', true)
              .then(() => Toast.show(S.resendCode()));
          })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24, top: 48 })
    }
    .width('100%')
    .height('100%')
  }

  private async verify(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const response = await UserService.verifyEmail(this.email, this.code.trim(),
        Configuration.instance.isLoggedIn() ? undefined : 'auth:');
      if (response.passkeySessionID.length > 0) {
        Toast.show(S.passkeyNotSupported());
        return;
      }
      if (response.twoFactorSessionID.length > 0) {
        Router.push('two-factor', new SessionIDParam(response.twoFactorSessionID));
        return;
      }
      await UserService.saveLoginResponse(response, Configuration.instance);
      if (response.encryptedToken !== undefined) {
        // Existing account → password reentry (or recovery).
        Router.push('password-reenter', undefined);
      } else {
        // New account → set password.
        Router.push('password-set', undefined);
      }
    } catch (e) {
      Toast.show((e as Error).message);
    } finally {
      this.busy = false;
    }
  }
}

@Component
export struct PasswordSetPage {
  @State password: string = '';
  @State confirmPassword: string = '';
  @State busy: boolean = false;

  build() {
    Column() {
      TopBarSimple({ title: S.createAccount(), onBack: () => {
        Router.back();
      }})
      Column() {
        Text(S.password())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        TextInput({ text: this.password, placeholder: S.password() })
          .height(46)
          .type(InputType.Password)
          .margin({ top: 24 })
          .onChange((v: string) => {
            this.password = v;
          })
        TextInput({ text: this.confirmPassword, placeholder: S.confirmPassword() })
          .height(46)
          .type(InputType.Password)
          .margin({ top: 12 })
          .onChange((v: string) => {
            this.confirmPassword = v;
          })
        BusyButton({ label: S.continuePage(), busy: this.busy, onAction: () => { this.completeSignup(); } })
          .margin({ top: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24, top: 48 })
    }
    .width('100%')
    .height('100%')
  }

  private async completeSignup(): Promise<void> {
    if (this.password !== this.confirmPassword) {
      Toast.show(S.passwordsDoNotMatch());
      return;
    }
    if (estimatePasswordStrength(this.password) <= MILD_STRENGTH_THRESHOLD) {
      Toast.show(S.passwordStrengthError());
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const config = Configuration.instance;
      const revision = config.getAccountRevision();
      const result: KeyGenResult = await config.generateKey(this.password);
      config.assertRevision(revision);
      // NOTHING irreversible happens here. Upstream generates the keys and then
      // routes straight to the recovery-key page
      // (password_entry_page.dart:526 -> :563-574); the account-setup
      // transaction (PUT /users/attributes + all persistence + SRP) runs only
      // from RecoveryKeyPage's onDone, i.e. after the user confirms they saved
      // the recovery key. Uploading or persisting keyAttributes here would
      // commit the account before the user has ever seen the recovery key
      // (finding C).
      Router.push('recovery-key', new KeyGenResultParam(result, revision));
    } catch (e) {
      Toast.show((e as Error).message);
    } finally {
      this.busy = false;
    }
  }
}

@Component
export struct RecoveryKeyPage {
  @State mnemonic: string = '';
  @State ready: boolean = false;
  @State busy: boolean = false;
  private result: KeyGenResult | undefined = undefined;
  private revision: number = -1;

  aboutToAppear(): void {
    const param = Router.currentParam() as KeyGenResultParam | undefined;
    if (param !== undefined) {
      this.result = param.result;
      this.revision = param.revision;
      Bip39.entropyToMnemonic(this.result.recoveryKey).then((m) => {
        this.mnemonic = m;
        this.ready = true;
      });
    }
  }

  build() {
    Column() {
      TopBarSimple({ title: S.recoveryKeyTitle(), onBack: () => {
      }})
      Column() {
        Text(S.recoveryKeyDescription())
          .fontSize(15)
          .fontColor($r('sys.color.ohos_id_color_primary'))
          .textAlign(TextAlign.Center)
        if (this.ready) {
          Text(this.mnemonic)
            .fontSize(17)
            .fontColor($r('sys.color.ohos_id_color_primary'))
            .lineHeight(28)
            .textAlign(TextAlign.Center)
            .margin({ top: 24 })
            .padding(16)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(8)
        }
        Button(S.iHaveSavedMyRecoveryKey())
          .width('100%')
          .height(46)
          .margin({ top: 24 })
          .backgroundColor($r('app.color.accent'))
          .enabled(this.ready && !this.busy)
          .onClick(() => {
            this.finishSignup();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 24, right: 24 })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * Runs only after the user taps "I have saved my recovery key" — the port of
   * upstream `RecoveryKeyPage._saveKeys` -> `onDone`
   * (recovery_key_page.dart:306-312 -> password_entry_page.dart:532-560).
   *
   * `UserService.setAttributes` owns the whole transaction (PUT, master key,
   * secret key, keyAttributes, non-fatal SRP). The UI must not perform any part
   * of it.
   */
  private async finishSignup(): Promise<void> {
    if (this.busy || this.result === undefined) {
      return;
    }
    this.busy = true;
    try {
      const config = Configuration.instance;
      await UserService.setAttributes(this.result, config, this.revision);
      EventBus.fire(Events.SIGNED_IN, null);
      AuthenticatorService.instance.onlineSync();
      Router.goToAuthenticatedRoot();
    } catch (e) {
      Toast.show((e as Error).message);
    } finally {
      this.busy = false;
    }
  }
}

@Component
export struct PasswordReentryPage {
  @State password: string = '';
  @State busy: boolean = false;
  @State showRecovery: boolean = false;
  private attrs: object | undefined = undefined;
  /** Needed by the SRP retry; upstream reads `config.getEmail()` (page :40). */
  private email: string = '';

  aboutToAppear(): void {
    // Password reentry reads everything from Configuration; no params needed.
    this.email = Configuration.instance.getEmail() ?? '';
  }

  build() {
    Column() {
      TopBarSimple({ title: S.login(), onBack: () => {
      }})
      Column() {
        Text(S.password())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        TextInput({ text: this.password, placeholder: S.password() })
          .height(46)
          .type(InputType.Password)
          .margin({ top: 24 })
          .onChange((v: string) => {
            this.password = v;
          })
        BusyButton({ label: S.continuePage(), busy: this.busy, onAction: () => { this.reenter(); } })
          .margin({ top: 24 })
        Text(S.loginWithRecoveryKey())
          .fontSize(14)
          .fontColor($r('app.color.accent'))
          .margin({ top: 16 })
          .onClick(() => {
            Router.push('recover', undefined);
          })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24, top: 48 })
    }
    .width('100%')
    .height('100%')
  }

  private async reenter(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const config = Configuration.instance;
      const keyAttributes = config.getKeyAttributes();
      if (keyAttributes === undefined) {
        // Nothing to unlock: the account is NOT configured, so the correct root
        // is onboarding. (This path is reachable if the key attributes were lost
        // — the exact damage finding B used to cause on a 2FA login.)
        Toast.show(S.sessionExpired());
        Router.goToOnboardingRoot();
        return;
      }
      // The KEK is the SRP retry's only input, so it must be captured here.
      let kek: Uint8Array;
      try {
        kek = await config.decryptSecretsAndGetKeyEncKey(this.password, keyAttributes);
      } catch (e) {
        Toast.show(S.incorrectPassword());
        this.busy = false;
        return;
      }
      // Port of upstream `_registerSRPForExistingUsers(kek).ignore()`
      // (password_reentry_page.dart:113, :190-208). This is what makes the
      // "SRP setup is retried on next password reentry" promise real; the
      // previous revision left the comment with no implementation (finding D).
      // Deliberately NOT awaited, exactly like upstream: the retry must not
      // block or fail an otherwise successful login.
      UserService.registerSrpForExistingUsers(this.email, kek)
        .catch(() => {
          // Already contained inside the helper; belt and braces so an
          // unhandled rejection can never surface as an app error.
        });
      EventBus.fire(Events.SIGNED_IN, null);
      AuthenticatorService.instance.onlineSync();
      Router.goToAuthenticatedRoot();
    } catch (e) {
      Toast.show((e as Error).message);
    } finally {
      this.busy = false;
    }
  }
}

@Component
export struct RecoverAccountPage {
  @State recoveryKey: string = '';
  @State busy: boolean = false;

  build() {
    Column() {
      TopBarSimple({ title: S.recoverAccount(), onBack: () => {
        Router.back();
      }})
      Column() {
        Text(S.recoveryKeyDescription())
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_secondary'))
          .textAlign(TextAlign.Center)
        TextArea({ text: this.recoveryKey, placeholder: S.recoveryKeyTitle() })
          .height(120)
          .margin({ top: 16 })
          .onChange((v: string) => {
            this.recoveryKey = v;
          })
        BusyButton({ label: S.continuePage(), busy: this.busy, onAction: () => { this.recover(); } })
          .margin({ top: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24, top: 48 })
    }
    .width('100%')
    .height('100%')
  }

  private async recover(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await Configuration.instance.recover(this.recoveryKey);
      EventBus.fire(Events.SIGNED_IN, null);
      AuthenticatorService.instance.onlineSync();
      Router.goToAuthenticatedRoot();
    } catch (e) {
      const msg = (e as Error).message;
      let shown: string = S.incorrectRecoveryKeyMessage();
      if (msg.includes('words')) {
        shown = msg;
      }
      promptAction.showDialog({
        title: S.incorrectRecoveryKey(),
        message: shown,
        buttons: [{ text: S.ok(), color: $r('app.color.accent') }],
      });
    } finally {
      this.busy = false;
    }
  }
}

/** SRP password login page. */
@Component
export struct SrpLoginPage {
  @State password: string = '';
  @State busy: boolean = false;
  private email: string = '';
  private attrs: SrpAttributes | undefined = undefined;

  aboutToAppear(): void {
    const param = Router.currentParam() as SrpLoginParam | undefined;
    if (param !== undefined) {
      this.email = param.email;
      this.attrs = param.attrs;
    }
  }

  build() {
    Column() {
      TopBarSimple({ title: S.login(), onBack: () => {
        Router.back();
      }})
      Column() {
        Text(S.password())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        TextInput({ text: this.password, placeholder: S.password() })
          .height(46)
          .type(InputType.Password)
          .margin({ top: 24 })
          .onChange((v: string) => {
            this.password = v;
          })
        BusyButton({ label: S.continuePage(), busy: this.busy, onAction: () => { this.login(); } })
          .margin({ top: 24 })
        Text(S.forgotPassword())
          .fontSize(14)
          .fontColor($r('app.color.accent'))
          .margin({ top: 16 })
          .onClick(() => {
            UserService.sendOtt(this.email, '', true).then(() => {
              Router.push('login-ott', new EmailFlowParam(false, this.email));
            });
          })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24, top: 48 })
    }
    .width('100%')
    .height('100%')
  }

  private async login(): Promise<void> {
    if (this.busy) {
      return;
    }
    const attrs = this.attrs;
    if (attrs === undefined) {
      Router.back();
      return;
    }
    this.busy = true;
    try {
      await completePasswordLogin(this.email, this.password, attrs);
    } catch (e) {
      Toast.show((e as Error).message);
    } finally {
      this.busy = false;
    }
  }
}

/** Two-factor TOTP verification page. */
@Component
export struct TwoFactorPage {
  @State code: string = '';
  @State busy: boolean = false;
  private sessionID: string = '';

  aboutToAppear(): void {
    const param = Router.currentParam() as SessionIDParam | undefined;
    if (param !== undefined) {
      this.sessionID = param.sessionID;
    }
  }

  build() {
    Column() {
      TopBarSimple({ title: S.twoFactorAuthentication(), onBack: () => {
        Router.back();
      }})
      Column() {
        Text(S.enterSixDigitCode())
          .fontSize(15)
          .fontColor($r('sys.color.ohos_id_color_secondary'))
          .textAlign(TextAlign.Center)
        TextInput({ text: this.code, placeholder: '123456' })
          .height(52)
          .type(InputType.Number)
          .maxLength(6)
          .fontSize(22)
          .textAlign(TextAlign.Center)
          .margin({ top: 24 })
          .onChange((v: string) => {
            this.code = v;
          })
        BusyButton({ label: S.verify(), busy: this.busy, onAction: () => { this.verify2fa(); } })
          .margin({ top: 24 })
        Text(S.lostDevice())
          .fontSize(14)
          .fontColor($r('app.color.accent'))
          .margin({ top: 16 })
          .onClick(() => {
            Toast.show(S.lostDevice());
          })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24, top: 48 })
    }
    .width('100%')
    .height('100%')
  }

  private async verify2fa(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      // The endpoint call, the status handling AND the LoginResponse parsing all
      // live in UserService. The page must never build the DTO itself: doing so
      // previously dropped `keyAttributes`, which `saveLoginResponse` then
      // cleared from secure state on a SUCCESSFUL 2FA login (finding B).
      const response: LoginResponse = await UserService.verifyTwoFactor(this.sessionID, this.code.trim());
      await UserService.saveLoginResponse(response, Configuration.instance);
      // The 2FA session is now consumed, so the 2FA page (and whatever login
      // page led here) must not remain reachable via Back. Upstream does the same
      // with `pushAndRemoveUntil(..., (route) => route.isFirst)`
      // (user_service.dart:890-897).
      Router.resetTo('password-reenter', undefined);
    } catch (e) {
      const message: string = (e as Error).message;
      if (message.includes('Session expired')) {
        Toast.show(S.sessionExpired());
        Router.back();
      } else {
        Toast.show(message);
      }
    } finally {
      this.busy = false;
    }
  }
}

@Component
struct TopBarSimple {
  @Prop title: string = '';
  onBack: () => void = () => {};
  build() { PageHeader({ title: this.title, onBack: this.onBack }) }
}

/** Presentation orchestration copied from the verified SRP page; service semantics unchanged. */
async function completePasswordLogin(email: string, password: string, attrs: SrpAttributes): Promise<void> {
  const response = await UserService.loginWithPassword(email, password, attrs);
  // Mirrors upstream `verifyEmailViaPassword` (user_service.dart:782-793),
  // which checks passkey FIRST, then two-factor, and only persists the
  // session in the else branch. The decision is made in UserService so it is
  // covered by the host tests rather than re-derived here.
  const step: PostLoginStep = UserService.postLoginStep(response);
  if (step === PostLoginStep.passkey) {
    // Passkey remains PARTIAL in this port. Explicit and user-visible —
    // never a silent bypass, and never a silent discard of the session.
    Toast.show(S.passkeyNotSupported());
    return;
  }
  if (step === PostLoginStep.twoFactor) {
    // Previously this showed "Additional verification required. Please login
    // with OTT." and navigated BACK, discarding a perfectly usable SRP
    // session and forcing the user to restart via e-mail (finding N).
    Router.push('two-factor', new SessionIDParam(response.twoFactorSessionID));
    return;
  }
  await UserService.saveLoginResponse(response, Configuration.instance);
  const keyAttributes: KeyAttributes = Configuration.instance.getKeyAttributes() as KeyAttributes;
  await Configuration.instance.decryptSecretsAndGetKeyEncKey(password, keyAttributes);
  EventBus.fire(Events.SIGNED_IN, null);
  AuthenticatorService.instance.onlineSync();
  Router.goToAuthenticatedRoot();
}
