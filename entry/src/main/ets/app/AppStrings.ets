/**
 * UI string accessor - a THIN layer over the HarmonyOS resource system.
 *
 * GENERATED FILE - do not edit by hand. Run `node tools/gen-appstrings.mjs`.
 *
 * Source of truth for every user-visible string:
 *   entry/src/main/resources/base/element/app_strings.json    (Chinese, DEFAULT)
 *   entry/src/main/resources/en_US/element/app_strings.json   (English)
 *
 * `base` is Chinese, so an unmatched locale falls back to Chinese; `en_US`
 * supplies English. Brand and technical terms (Ente, TOTP, HOTP, QR, GitHub,
 * URL, API) are deliberately identical in both files.
 *
 * Resolution is by NAME (`getStringByNameSync`) rather than by `$r(...)` id so
 * that this module stays loadable by the host test harness, which has no ArkUI
 * runtime. Before `init()` - i.e. on the host, or before the ability starts -
 * every accessor returns its own key, which is exactly what the localization
 * guards assert against.
 */
import { resourceManager } from '@kit.LocalizationKit';

let mgr: resourceManager.ResourceManager | undefined = undefined;

export class S {
  /** Called once from EntryAbility with the ability context. */
  static init(m: resourceManager.ResourceManager): void {
    mgr = m;
  }

  /** True once the resource manager is available (false on the host). */
  static isReady(): boolean {
    return mgr !== undefined;
  }

  /**
   * Resolve a key. Falls back to the key itself when the resource manager is
   * unavailable or the key is missing, so a bad key degrades to a visible
   * identifier instead of crashing the UI.
   */
  private static r(key: string, args?: Array<string | number>): string {
    if (mgr === undefined) {
      return key;
    }
    try {
      return args === undefined
        ? mgr.getStringByNameSync(key)
        : mgr.getStringByNameSync(key, args[0]);
    } catch (e) {
      return key;
    }
  }

  static offlineMigrationRunning(): string {
    return S.r('offlineMigrationRunning');
  }
  static offlineMigrationPending(): string {
    return S.r('offlineMigrationPending');
  }
  static offlineMigrationUnreadable(): string {
    return S.r('offlineMigrationUnreadable');
  }
  static offlineMigrationUncertain(): string {
    return S.r('offlineMigrationUncertain');
  }
  static plainTextExportWarning(): string {
    return S.r('plainTextExportWarning');
  }
  static plainHtmlExportWarning(): string {
    return S.r('plainHtmlExportWarning');
  }
  static unableToReadCodes(): string {
    return S.r('unableToReadCodes');
  }
  static storedCodesReadError(): string {
    return S.r('storedCodesReadError');
  }
  static retryReadCodes(): string {
    return S.r('retryReadCodes');
  }
  static settingsSaveFailed(): string {
    return S.r('settingsSaveFailed');
  }
  static appName(): string {
    return S.r('appName');
  }
  static setupFirstAccount(): string {
    return S.r('setupFirstAccount');
  }
  static allTabEmptyHint(): string {
    return S.r('allTabEmptyHint');
  }
  static noResult(): string {
    return S.r('noResult');
  }
  static error(): string {
    return S.r('error');
  }
  static somethingWentWrong(): string {
    return S.r('somethingWentWrong');
  }
  static somethingWentWrongParsingCode(arg: number): string {
    return S.r('somethingWentWrongParsingCode', [arg]);
  }
  static viewRawCodes(): string {
    return S.r('viewRawCodes');
  }
  static contactSupport(): string {
    return S.r('contactSupport');
  }
  static rawCodeData(): string {
    return S.r('rawCodeData');
  }
  static deleteUnparseableCodeTitle(): string {
    return S.r('deleteUnparseableCodeTitle');
  }
  static deleteUnparseableCodeMessage(): string {
    return S.r('deleteUnparseableCodeMessage');
  }
  static incorrectDetails(): string {
    return S.r('incorrectDetails');
  }
  static pleaseVerifyDetails(): string {
    return S.r('pleaseVerifyDetails');
  }
  static addCode(): string {
    return S.r('addCode');
  }
  static search(): string {
    return S.r('search');
  }
  static searchHint(): string {
    return S.r('searchHint');
  }
  static settings(): string {
    return S.r('settings');
  }
  static appLock(): string {
    return S.r('appLock');
  }
  static appLockNotEnabled(): string {
    return S.r('appLockNotEnabled');
  }
  static appLockNotEnabledDescription(): string {
    return S.r('appLockNotEnabledDescription');
  }
  static editOrder(): string {
    return S.r('editOrder');
  }
  static customOrder(): string {
    return S.r('customOrder');
  }
  static codeIssuerHint(): string {
    return S.r('codeIssuerHint');
  }
  static account(): string {
    return S.r('account');
  }
  static mostFrequentlyUsed(): string {
    return S.r('mostFrequentlyUsed');
  }
  static mostRecentlyUsed(): string {
    return S.r('mostRecentlyUsed');
  }
  static manualSort(): string {
    return S.r('manualSort');
  }
  static all(): string {
    return S.r('all');
  }
  static trash(): string {
    return S.r('trash');
  }
  static scanAQrCode(): string {
    return S.r('scanAQrCode');
  }
  static enterDetailsManually(): string {
    return S.r('enterDetailsManually');
  }
  static importFromGallery(): string {
    return S.r('importFromGallery');
  }
  static importEnterSetupKey(): string {
    return S.r('importEnterSetupKey');
  }
  static importCodes(): string {
    return S.r('importCodes');
  }
  static faq(): string {
    return S.r('faq');
  }
  static selected(): string {
    return S.r('selected');
  }
  static selectedCount(arg: number): string {
    return S.r('selectedCount', [arg]);
  }
  static selectAll(): string {
    return S.r('selectAll');
  }
  static cancel(): string {
    return S.r('cancel');
  }
  static close(): string {
    return S.r('close');
  }
  static ok(): string {
    return S.r('ok');
  }
  static pinText(): string {
    return S.r('pinText');
  }
  static unpinText(): string {
    return S.r('unpinText');
  }
  static addTag(): string {
    return S.r('addTag');
  }
  static edit(): string {
    return S.r('edit');
  }
  static share(): string {
    return S.r('share');
  }
  static qr(): string {
    return S.r('qr');
  }
  static qrCode(): string {
    return S.r('qrCode');
  }
  static notes(): string {
    return S.r('notes');
  }
  static restore(): string {
    return S.r('restore');
  }
  static delete(): string {
    return S.r('delete');
  }
  static nextTotpTitle(): string {
    return S.r('nextTotpTitle');
  }
  static trashCode(): string {
    return S.r('trashCode');
  }
  static trashCodeMessage(arg: string): string {
    return S.r('trashCodeMessage', [arg]);
  }
  static moveMultipleToTrashMessage(arg: number): string {
    return S.r('moveMultipleToTrashMessage', [arg]);
  }
  static deleteCodeTitle(): string {
    return S.r('deleteCodeTitle');
  }
  static deleteCodeMessage(): string {
    return S.r('deleteCodeMessage');
  }
  static deleteTagTitle(): string {
    return S.r('deleteTagTitle');
  }
  static deleteTagMessage(): string {
    return S.r('deleteTagMessage');
  }
  static editTag(): string {
    return S.r('editTag');
  }
  static tag(): string {
    return S.r('tag');
  }
  static tags(): string {
    return S.r('tags');
  }
  static addNew(): string {
    return S.r('addNew');
  }
  static createNewTag(): string {
    return S.r('createNewTag');
  }
  static create(): string {
    return S.r('create');
  }
  static save(): string {
    return S.r('save');
  }
  static done(): string {
    return S.r('done');
  }
  static deleteCodeAuthMessage(): string {
    return S.r('deleteCodeAuthMessage');
  }
  static editCodeAuthMessage(): string {
    return S.r('editCodeAuthMessage');
  }
  static showQRAuthMessage(): string {
    return S.r('showQRAuthMessage');
  }
  static authenticateGeneric(): string {
    return S.r('authenticateGeneric');
  }
  static copiedToClipboard(): string {
    return S.r('copiedToClipboard');
  }
  static copiedNextToClipboard(): string {
    return S.r('copiedNextToClipboard');
  }
  static notSupportedForHOTP(): string {
    return S.r('notSupportedForHOTP');
  }
  static pinnedCodeMessage(arg: string): string {
    return S.r('pinnedCodeMessage', [arg]);
  }
  static unpinnedCodeMessage(arg: string): string {
    return S.r('unpinnedCodeMessage', [arg]);
  }
  static pinnedCount(arg: number): string {
    return S.r('pinnedCount', [arg]);
  }
  static unpinnedCount(arg: number): string {
    return S.r('unpinnedCount', [arg]);
  }
  static hintForMobile(): string {
    return S.r('hintForMobile');
  }
  static hintForDesktop(): string {
    return S.r('hintForDesktop');
  }
  static scan(): string {
    return S.r('scan');
  }
  static scanACode(): string {
    return S.r('scanACode');
  }
  static invalidQRCode(): string {
    return S.r('invalidQRCode');
  }
  static importSuccessTitle(): string {
    return S.r('importSuccessTitle');
  }
  static importedCount(arg: number): string {
    return S.r('importedCount', [arg]);
  }
  static importAccountPageTitle(): string {
    return S.r('importAccountPageTitle');
  }
  static secret(): string {
    return S.r('secret');
  }
  static secretCanNotBeEmpty(): string {
    return S.r('secretCanNotBeEmpty');
  }
  static bothIssuerAndAccountCanNotBeEmpty(): string {
    return S.r('bothIssuerAndAccountCanNotBeEmpty');
  }
  static appIcon(): string {
    return S.r('appIcon');
  }
  static advanced(): string {
    return S.r('advanced');
  }
  static algorithm(): string {
    return S.r('algorithm');
  }
  static type(): string {
    return S.r('type');
  }
  static period(): string {
    return S.r('period');
  }
  static digits(): string {
    return S.r('digits');
  }
  static notesLengthLimit(arg: number): string {
    return S.r('notesLengthLimit', [arg]);
  }
  static warning(): string {
    return S.r('warning');
  }
  static confirmUpdatingkey(): string {
    return S.r('confirmUpdatingkey');
  }
  static yes(): string {
    return S.r('yes');
  }
  static no(): string {
    return S.r('no');
  }
  static chooseIcon(): string {
    return S.r('chooseIcon');
  }
  static sessionExpired(): string {
    return S.r('sessionExpired');
  }
  static sessionExpiredDescription(): string {
    return S.r('sessionExpiredDescription');
  }
  static logout(): string {
    return S.r('logout');
  }
  static areYouSureYouWantToLogout(): string {
    return S.r('areYouSureYouWantToLogout');
  }
  static changeEmail(): string {
    return S.r('changeEmail');
  }
  static passphraseRecovery(): string {
    return S.r('passphraseRecovery');
  }
  static createAccount(): string {
    return S.r('createAccount');
  }
  static login(): string {
    return S.r('login');
  }
  static useOffline(): string {
    return S.r('useOffline');
  }
  static offlineModeWarningTitle(): string {
    return S.r('offlineModeWarningTitle');
  }
  static offlineModeWarningDescription(): string {
    return S.r('offlineModeWarningDescription');
  }
  static continuePage(): string {
    return S.r('continuePage');
  }
  static verify(): string {
    return S.r('verify');
  }
  static resendCode(): string {
    return S.r('resendCode');
  }
  static enterCode(): string {
    return S.r('enterCode');
  }
  static verifyEmailBody(arg: string): string {
    return S.r('verifyEmailBody', [arg]);
  }
  static password(): string {
    return S.r('password');
  }
  static confirmPassword(): string {
    return S.r('confirmPassword');
  }
  static passwordStrengthError(): string {
    return S.r('passwordStrengthError');
  }
  static passwordsDoNotMatch(): string {
    return S.r('passwordsDoNotMatch');
  }
  static recoveryKeyTitle(): string {
    return S.r('recoveryKeyTitle');
  }
  static saveKey(): string {
    return S.r('saveKey');
  }
  static iHaveSavedMyRecoveryKey(): string {
    return S.r('iHaveSavedMyRecoveryKey');
  }
  static recoveryKeyDescription(): string {
    return S.r('recoveryKeyDescription');
  }
  static recoverAccount(): string {
    return S.r('recoverAccount');
  }
  static loginWithRecoveryKey(): string {
    return S.r('loginWithRecoveryKey');
  }
  static incorrectRecoveryKey(): string {
    return S.r('incorrectRecoveryKey');
  }
  static incorrectRecoveryKeyMessage(): string {
    return S.r('incorrectRecoveryKeyMessage');
  }
  static twoFactorAuthentication(): string {
    return S.r('twoFactorAuthentication');
  }
  static enterSixDigitCode(): string {
    return S.r('enterSixDigitCode');
  }
  static lostDevice(): string {
    return S.r('lostDevice');
  }
  static pleaseWait(): string {
    return S.r('pleaseWait');
  }
  static oops(): string {
    return S.r('oops');
  }
  static yourVerificationCodeHasExpired(): string {
    return S.r('yourVerificationCodeHasExpired');
  }
  static emailNotRegistered(): string {
    return S.r('emailNotRegistered');
  }
  static emailAlreadyRegistered(): string {
    return S.r('emailAlreadyRegistered');
  }
  static accountSetupIncomplete(): string {
    return S.r('accountSetupIncomplete');
  }
  static thisEmailIsAlreadyInUse(): string {
    return S.r('thisEmailIsAlreadyInUse');
  }
  static noInternetConnection(): string {
    return S.r('noInternetConnection');
  }
  static language(): string {
    return S.r('language');
  }
  static theme(): string {
    return S.r('theme');
  }
  static security(): string {
    return S.r('security');
  }
  static data(): string {
    return S.r('data');
  }
  static general(): string {
    return S.r('general');
  }
  static accountSection(): string {
    return S.r('accountSection');
  }
  static export(): string {
    return S.r('export');
  }
  static import(): string {
    return S.r('import');
  }
  static duplicateCodes(): string {
    return S.r('duplicateCodes');
  }
  static noDuplicateCodes(): string {
    return S.r('noDuplicateCodes');
  }
  static deleteDuplicates(): string {
    return S.r('deleteDuplicates');
  }
  static hideCodes(): string {
    return S.r('hideCodes');
  }
  static showLargeIcons(): string {
    return S.r('showLargeIcons');
  }
  static autoFocusSearch(): string {
    return S.r('autoFocusSearch');
  }
  static minimizeOnCopy(): string {
    return S.r('minimizeOnCopy');
  }
  static version(): string {
    return S.r('version');
  }
  static about(): string {
    return S.r('about');
  }
  static emailVerification(): string {
    return S.r('emailVerification');
  }
  static passkeys(): string {
    return S.r('passkeys');
  }
  static passkeyNotSupported(): string {
    return S.r('passkeyNotSupported');
  }
  static biometric(): string {
    return S.r('biometric');
  }
  static notesLengthMsg(): string {
    return S.r('notesLengthMsg');
  }
  static support(): string {
    return S.r('support');
  }
  static privacyPolicy(): string {
    return S.r('privacyPolicy');
  }
  static terms(): string {
    return S.r('terms');
  }
  static github(): string {
    return S.r('github');
  }
  static somethingWentWrongMessage(): string {
    return S.r('somethingWentWrongMessage');
  }
  static email(): string {
    return S.r('email');
  }
  static enterValidEmail(): string {
    return S.r('enterValidEmail');
  }
  static forgotPassword(): string {
    return S.r('forgotPassword');
  }
  static incorrectPassword(): string {
    return S.r('incorrectPassword');
  }
  static incorrectPasswordRetry(): string {
    return S.r('incorrectPasswordRetry');
  }
  static passwordTooShort(): string {
    return S.r('passwordTooShort');
  }
  static shareYourCode(): string {
    return S.r('shareYourCode');
  }
  static notSupportedYet(): string {
    return S.r('notSupportedYet');
  }
  static comingSoon(): string {
    return S.r('comingSoon');
  }
  static aboutSubtitle(): string {
    return S.r('aboutSubtitle');
  }
  static aboutVersion(): string {
    return S.r('aboutVersion');
  }
  static errorWithStatus(arg: number): string {
    return S.r('errorWithStatus', [arg]);
  }
  static notSupportedOnDevice(): string {
    return S.r('notSupportedOnDevice');
  }
  static additionalVerificationRequired(): string {
    return S.r('additionalVerificationRequired');
  }
  static back(): string {
    return S.r('back');
  }
  static loginIntro(): string {
    return S.r('loginIntro');
  }
  static loginHelp(): string {
    return S.r('loginHelp');
  }
  static emailLogin(): string {
    return S.r('emailLogin');
  }
  static unofficialPort(): string {
    return S.r('unofficialPort');
  }
  static futureFeature(): string {
    return S.r('futureFeature');
  }
  static futureFeatureDetail(): string {
    return S.r('futureFeatureDetail');
  }
  static appearance(): string {
    return S.r('appearance');
  }
  static activeSessions(): string {
    return S.r('activeSessions');
  }
  static localBackups(): string {
    return S.r('localBackups');
  }
  static changePassword(): string {
    return S.r('changePassword');
  }
  static deleteAccount(): string {
    return S.r('deleteAccount');
  }
  static logoutFailed(): string {
    return S.r('logoutFailed');
  }
  static understood(): string {
    return S.r('understood');
  }
  static languageMilestone(): string {
    return S.r('languageMilestone');
  }
  static systemTheme(): string {
    return S.r('systemTheme');
  }
  static themeMilestone(): string {
    return S.r('themeMilestone');
  }
  static noMatchingCodes(): string {
    return S.r('noMatchingCodes');
  }
  static pendingSync(): string {
    return S.r('pendingSync');
  }
  static pinnedCode(): string {
    return S.r('pinnedCode');
  }
  static signupHelp(): string {
    return S.r('signupHelp');
  }
}
