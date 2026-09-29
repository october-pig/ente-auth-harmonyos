/**
 * CodeCard — ArkUI mirror of upstream `ui/code_widget.dart` +
 * `ui/code_timer_progress.dart`:
 *  - per-card 500 ms poller; OTP text refreshes only at period boundaries;
 *  - separate countdown bar (progress), orange below 40%;
 *  - tap copies the current OTP; long-press enters selection mode;
 *  - bullet masking when hide-codes is enabled; digit grouping 3+3 etc.
 */
import { promptAction } from '@kit.ArkUI';
import { Code } from '../models/Code';
import { OtpAlgorithm, OtpType } from '../otp/OtpTypes';
import { getOTP, getNextTotp, millisecondsSinceEpoch } from '../otp/TotpUtil';
import { Clipboard } from '../utils/Clipboard';
import { S } from '../app/AppStrings';

const POLL_MS: number = 500;
const BAR_MS: number = 250;

@Component
export struct CodeCard {
  @Prop code: Code = new Code('', '', 6, 30, '', OtpAlgorithm.sha1, OtpType.totp, 0, '');
  @Prop isSelectionMode: boolean = false;
  @Prop isSelected: boolean = false;
  /**
   * `@Watch` is required here, not decorative.
   *
   * `currentCode`/`nextCode` hold the FORMATTED (possibly masked) string, so a
   * change to `hideCodes` cannot be reflected by re-rendering alone: the text is
   * already a `@State` string and would only be recomputed at the next
   * `computeCodes()` call, i.e. on the next 30-second TOTP boundary. Toggling
   * 隐藏验证码 would appear to do nothing for up to half a minute (finding T).
   *
   * The raw OTP values are therefore kept so the watch can re-format at once.
   */
  @Prop @Watch('onHideCodesChanged') hideCodes: boolean = false;
  @Prop accountConfigured: boolean = false;
  @Prop index: number = 0;

  onLongPressAction: () => void = () => {
  };
  /** Optional metadata-update hook (tapCount/lastUsedAt) mirroring upstream. */
  onCopied: (() => void) | undefined = undefined;

  @State currentCode: string = '';
  @State nextCode: string = '';
  @State errorText: string = '';
  @State progress: number = 1.0;
  @State maskedNow: boolean = false;

  private codeTimeStep: number = -1;
  private lastRefreshTime: number = 0;
  /** Raw (unformatted) values, so masking can be re-applied without recomputing. */
  private rawCurrent: string = '';
  private rawNext: string = '';
  private pollTimer: number | undefined = undefined;
  private barTimer: number | undefined = undefined;
  private codePeriod: number = 30;

  aboutToAppear(): void {
    this.codePeriod = this.code.period;
    this.scheduleTimers();
  }

  aboutToDisappear(): void {
    if (this.pollTimer !== undefined) {
      clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }
    if (this.barTimer !== undefined) {
      clearInterval(this.barTimer);
      this.barTimer = undefined;
    }
  }

  private scheduleTimers(): void {
    this.refreshCode();
    this.refreshBar();
    this.pollTimer = setInterval(() => {
      this.refreshCode();
    }, POLL_MS);
    this.barTimer = setInterval(() => {
      this.refreshBar();
    }, BAR_MS);
  }

  private refreshCode(): void {
    const epochSeconds: number = Math.floor(millisecondsSinceEpoch() / 1000);
    let newStep: number;
    if (this.code.type === OtpType.hotp) {
      newStep = this.code.counter;
    } else {
      newStep = Math.floor(epochSeconds / this.codePeriod);
    }
    if (this.codeTimeStep !== newStep || epochSeconds - this.lastRefreshTime > this.codePeriod) {
      this.codeTimeStep = newStep;
      this.lastRefreshTime = epochSeconds;
      this.computeCodes();
    }
  }

  private async computeCodes(): Promise<void> {
    try {
      const value: string = await getOTP(this.code);
      this.rawCurrent = value;
      this.currentCode = this.formatCode(value);
      if (this.code.type === OtpType.totp || this.code.type === OtpType.steam) {
        const next: string = await getNextTotp(this.code);
        this.rawNext = next;
        this.nextCode = this.formatCode(next);
      } else {
        this.rawNext = '';
        this.nextCode = '';
      }
      this.errorText = '';
    } catch (e) {
      this.rawCurrent = '';
      this.rawNext = '';
      this.errorText = S.error();
      this.currentCode = S.error();
      this.nextCode = '';
    }
  }

  /**
   * Re-apply masking to the ALREADY COMPUTED values, without waiting for the next
   * TOTP window. Called by `@Watch` when `hideCodes` changes.
   */
  private onHideCodesChanged(): void {
    if (this.rawCurrent.length > 0) {
      this.currentCode = this.formatCode(this.rawCurrent);
    }
    if (this.rawNext.length > 0) {
      this.nextCode = this.formatCode(this.rawNext);
    }
  }

  private refreshBar(): void {
    const periodMs: number = this.codePeriod * 1000;
    const elapsed: number = millisecondsSinceEpoch() % periodMs;
    const remaining: number = periodMs - elapsed;
    let p: number = remaining / periodMs;
    if (p < 0) {
      p = 0;
    }
    this.progress = p;
  }

  /** Upstream digit grouping + masking. */
  private formatCode(value: string): string {
    let code: string = value;
    if (this.hideCodes || this.maskedNow) {
      code = code.replace(/\S/g, '•');
    }
    const len: number = code.length;
    if (len === 6) {
      return `${code.substring(0, 3)} ${code.substring(3, 6)}`;
    } else if (len === 7) {
      return `${code.substring(0, 3)} ${code.substring(3, 4)} ${code.substring(4, 7)}`;
    } else if (len === 8) {
      return `${code.substring(0, 3)} ${code.substring(3, 5)} ${code.substring(5, 8)}`;
    } else if (len === 9) {
      return `${code.substring(0, 3)} ${code.substring(3, 6)} ${code.substring(6, 9)}`;
    }
    return code;
  }

  /**
   * These are METHODS, not `get` accessors.
   *
   * ArkUI does not compile accessors on a `@Component struct`: `private get
   * codeText()` evaluated to `undefined` at runtime, and `this.codeText.length`
   * in `build()` threw `TypeError: Cannot read property length of undefined`
   * during `initialRender`. ArkUI treats a build-time exception as fatal, so the
   * whole app died on every cold start once the account had codes to render.
   *
   * DEVICE-VERIFIED crash (HUAWEI Mate 80 Pro Max, API 26):
   *   faultlog jscrash-...-20260926211451162.log, Reason:TypeError,
   *   exit code 254, first frame
   *   `at anonymous entry (entry/src/main/ets/components/CodeCard.ets:191:30)`.
   *
   * The other two accessors did not throw but were equally broken - they were
   * always falsy, so the sync badge and the "next code" preview never rendered.
   */
  private codeText(): string {
    return this.currentCode;
  }

  private isTOTPCompatible(): boolean {
    return this.code.type === OtpType.totp || this.code.type === OtpType.steam;
  }

  private showSyncIcon(): boolean {
    return this.accountConfigured && this.code.hasSynced === false && !this.code.hasError;
  }

  build() {
    Column() {
      Progress({ value: this.progress * 100, total: 100, type: ProgressType.Linear })
        .color(this.progress > 0.4 ? $r('app.color.accent') : $r('app.color.warning'))
        .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
        .style({ strokeWidth: 3 }).width('100%')

      Column() {
        // Top row: issuer + account
        Row() {
          Text(this.code.issuer.length > 0 ? this.code.issuer : ' ')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.code.isPinned) {
            SymbolGlyph($r('sys.symbol.pin')).fontSize(16).fontColor([$r('app.color.accent')])
              .accessibilityText(S.pinnedCode())
          }
          if (this.isSelected) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(22).fontColor([$r('app.color.accent')])
          }
          if (this.showSyncIcon()) {
            SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16).fontColor([$r('app.color.warning')])
              .accessibilityText(S.pendingSync())
          }
        }
        .width('100%')

        Row() {
          Text(this.code.account.length > 0 ? this.code.account : ' ')
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 4 })

        // Bottom row: OTP + next
        Row() {
          Text(this.codeText().length > 0 ? this.codeText() : ' ')
            .fontSize(32)
            .fontFamily('monospace')
            .minFontSize(22).maxFontSize(32).maxLines(1)
            .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.errorText !== '' ? $r('app.color.danger') : $r('sys.color.ohos_id_color_primary'))
            .letterSpacing(2)
            .layoutWeight(1)
          if (this.isTOTPCompatible() && this.nextCode !== '') {
            Column() {
              Text(S.nextTotpTitle())
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_secondary'))
              Text(this.nextCode)
                .fontSize(14)
                .fontFamily('monospace')
                .fontColor($r('sys.color.ohos_id_color_secondary'))
            }
            .alignItems(HorizontalAlign.End)
            .constraintSize({ minHeight: 48, minWidth: 72 })
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.copyNext();
            })
          }
        }
        .width('100%')
        .margin({ top: 10 })
      }
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .width('100%')
    }
    .width('100%')
    .borderRadius(20)
    .clip(true)
    .backgroundColor(this.isSelected ? $r('app.color.accent_surface') : $r('app.color.surface'))
    .border({ width: 2, color: this.isSelected ? $r('app.color.accent') : Color.Transparent })
    .onClick(() => {
      if (this.isSelectionMode) {
        this.onLongPressAction();
      } else {
        this.copyCurrent();
        if (this.onCopied !== undefined) {
          this.onCopied();
        }
      }
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.onLongPressAction();
        })
    )
    .gesture(
      TapGesture({ count: 2 })
        .onAction(() => {
          this.maskedNow = !this.maskedNow;
          this.computeCodes();
        })
    )
  }

  private async copyCurrent(): Promise<void> {
    try {
      const value: string = await getOTP(this.code);
      await Clipboard.copy(value);
      promptAction.showToast({ message: S.copiedToClipboard() });
    } catch (e) {
    }
  }

  private async copyNext(): Promise<void> {
    try {
      const value: string = await getNextTotp(this.code);
      await Clipboard.copy(value);
      promptAction.showToast({ message: S.copiedNextToClipboard() });
    } catch (e) {
    }
  }
}
