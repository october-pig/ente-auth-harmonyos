/**
 * SetupSecretKeyPage — manual code entry / edit, mirror of upstream
 * `onboarding/view/setup_enter_secret_key_page.dart` (validation rules and
 * steam detection exact).
 */
import { promptAction } from '@kit.ArkUI';
import { Code } from '../models/Code';
import { CodeDisplay } from '../models/CodeDisplay';
import { OtpType, OtpAlgorithm } from '../otp/OtpTypes';
import { getOTP } from '../otp/TotpUtil';
import { CodeStore, AddResult } from '../store/CodeStore';
import { Router } from './Router.ets';
import { CodeParam } from './PageParams.ets';
import { S } from '../app/AppStrings';
import { Toast } from '../utils/Toast';
import { ConfirmDialog } from './HomePage.ets';

const MAX_DIGITS: number = 10;
const MIN_DIGITS: number = 1;
const MIN_PERIOD: number = 10;
const MAX_PERIOD: number = 60;
const MAX_NOTE_LENGTH: number = 500;

@Component
export struct SetupSecretKeyPage {
  @State issuer: string = '';
  @State secret: string = '';
  @State account: string = '';
  @State notes: string = '';
  @State algorithm: OtpAlgorithm = OtpAlgorithm.sha1;
  @State type: OtpType = OtpType.totp;
  @State period: string = '30';
  @State digits: string = '6';
  @State showAdvanced: boolean = false;
  @State tags: string[] = [];
  @State busy: boolean = false;

  editingCode: Code | undefined = undefined;
  existingTags: string[] = [];

  aboutToAppear(): void {
    const param = Router.currentParam() as CodeParam | undefined;
    if (param !== undefined && param.code !== undefined) {
      const code = param.code;
      this.editingCode = code;
      this.issuer = code.issuer;
      this.secret = code.secret;
      this.account = code.account;
      this.notes = code.note;
      this.algorithm = code.algorithm;
      this.type = code.type;
      this.period = code.period.toString();
      this.digits = code.digits.toString();
      this.tags = code.display.tags.slice();
    }
  }

  private isValidInteger(s: string): boolean {
    return /^[+-]?\d+$/.test(s);
  }

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(18)
          .onClick(() => {
            Router.back();
          })
        Text(S.importAccountPageTitle())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
      }
      .width('100%')
      .height(52)
      .padding({ left: 8, right: 16 })

      Scroll() {
        Column() {
          FieldLabel({ label: S.codeIssuerHint() })
          TextInput({ text: this.issuer, placeholder: S.codeIssuerHint() })
            .height(44)
            .maxLength(200)
            .onChange((v: string) => {
              this.issuer = v;
            })

          FieldLabel({ label: S.secret() })
          TextInput({ text: this.secret, placeholder: S.secret() })
            .height(44)
            .type(InputType.Password)
            .onChange((v: string) => {
              this.secret = v;
            })

          FieldLabel({ label: S.account() })
          TextInput({ text: this.account, placeholder: S.account() })
            .height(44)
            .onChange((v: string) => {
              this.account = v;
            })

          FieldLabel({ label: S.notes() })
          TextArea({ text: this.notes, placeholder: S.notes() })
            .height(96)
            .maxLength(MAX_NOTE_LENGTH)
            .onChange((v: string) => {
              this.notes = v;
            })

          Row() {
            Text(S.advanced())
              .fontSize(15)
              .fontColor('#4E5BA6')
              .layoutWeight(1)
            Text(this.showAdvanced ? '▲' : '▼')
              .fontSize(12)
              .fontColor('#8A8A8E')
          }
          .width('100%')
          .height(44)
          .margin({ top: 8 })
          .onClick(() => {
            this.showAdvanced = !this.showAdvanced;
          })

          if (this.showAdvanced && this.editingCode === undefined) {
            Row() {
              Text(S.algorithm())
                .fontSize(14)
                .layoutWeight(1)
              Select([
                { value: 'SHA1' },
                { value: 'SHA256' },
                { value: 'SHA512' },
              ])
                .selected(this.algorithmIndex())
                .value(this.algorithmLabel())
                .onSelect((index: number) => {
                  this.algorithm = index === 1 ? OtpAlgorithm.sha256 :
                    (index === 2 ? OtpAlgorithm.sha512 : OtpAlgorithm.sha1);
                })
            }
            .width('100%')
            .margin({ top: 8 })

            Row() {
              Text(S.type())
                .fontSize(14)
                .layoutWeight(1)
              Select([
                { value: 'TOTP' },
                { value: 'HOTP' },
                { value: 'STEAM' },
              ])
                .selected(this.typeIndex())
                .value(this.typeLabel())
                .onSelect((index: number) => {
                  this.type = index === 1 ? OtpType.hotp : (index === 2 ? OtpType.steam : OtpType.totp);
                })
            }
            .width('100%')
            .margin({ top: 8 })

            Row() {
              Text(S.period())
                .fontSize(14)
                .layoutWeight(1)
              TextInput({ text: this.period })
                .width(90)
                .type(InputType.Number)
                .onChange((v: string) => {
                  this.period = v;
                })
            }
            .width('100%')
            .margin({ top: 8 })

            Row() {
              Text(S.digits())
                .fontSize(14)
                .layoutWeight(1)
              TextInput({ text: this.digits })
                .width(90)
                .type(InputType.Number)
                .onChange((v: string) => {
                  this.digits = v;
                })
            }
            .width('100%')
            .margin({ top: 8 })
          }

          Button(S.save())
            .width('100%')
            .height(46)
            .margin({ top: 24, bottom: 24 })
            .backgroundColor('#4E5BA6')
            .enabled(!this.busy)
            .onClick(() => {
              this.validateAndSave();
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  private algorithmLabel(): string {
    return this.algorithm === OtpAlgorithm.sha256 ? 'SHA256' :
      (this.algorithm === OtpAlgorithm.sha512 ? 'SHA512' : 'SHA1');
  }

  private algorithmIndex(): number {
    return this.algorithm === OtpAlgorithm.sha256 ? 1 : (this.algorithm === OtpAlgorithm.sha512 ? 2 : 0);
  }

  private typeLabel(): string {
    return this.type === OtpType.hotp ? 'HOTP' : (this.type === OtpType.steam ? 'STEAM' : 'TOTP');
  }

  private typeIndex(): number {
    return this.type === OtpType.hotp ? 1 : (this.type === OtpType.steam ? 2 : 0);
  }

  /** Upstream _validateAndSave rules (errors exact). */
  private async validateAndSave(): Promise<void> {
    if (this.secret.trim().length === 0) {
      this.incorrectDetails(S.secretCanNotBeEmpty());
      return;
    }
    if (this.issuer.trim().length === 0 && this.account.trim().length === 0) {
      this.incorrectDetails(S.bothIssuerAndAccountCanNotBeEmpty());
      return;
    }
    let digits: number = this.editingCode !== undefined ? this.editingCode.digits : 0;
    let period: number = this.editingCode !== undefined ? this.editingCode.period : 0;
    if (this.editingCode === undefined) {
      if (this.digits.trim().length === 0) {
        this.incorrectDetails('Digits cannot be empty');
        return;
      }
      if (!this.isValidInteger(this.digits)) {
        this.incorrectDetails('Digits is not an integer');
        return;
      }
      digits = parseInt(this.digits, 10);
      if (digits < MIN_DIGITS || digits > MAX_DIGITS) {
        this.incorrectDetails('Digits must be between 1 and 10');
        return;
      }
      if (this.period.trim().length === 0) {
        this.incorrectDetails('Period cannot be empty');
        return;
      }
      if (!this.isValidInteger(this.period)) {
        this.incorrectDetails('Period is not an integer');
        return;
      }
      period = parseInt(this.period, 10);
      if (period < MIN_PERIOD || period > MAX_PERIOD) {
        this.incorrectDetails('Period must be between 10 and 60 seconds');
        return;
      }
    }
    if (this.notes.length > MAX_NOTE_LENGTH) {
      Toast.show(S.notesLengthLimit(MAX_NOTE_LENGTH));
      return;
    }

    let codeType: OtpType = this.type;
    let codeDigits: number = digits;
    const issuerLower: string = this.issuer.toLowerCase();
    if (issuerLower === 'steam' || issuerLower.includes('steampowered.com')) {
      codeType = OtpType.steam;
      codeDigits = Code.steamDigits;
    }

    if (this.editingCode !== undefined && this.editingCode.secret !== this.secret.trim()) {
      const ok = await ConfirmDialog.show(S.warning(), S.confirmUpdatingkey(), S.yes());
      if (!ok) {
        return;
      }
    }

    let newCode: Code;
    if (this.editingCode !== undefined) {
      const display = this.editingCode.display.copyWith(undefined, undefined, undefined, undefined,
        this.tags, this.notes.trim());
      newCode = this.editingCode.copyWith(this.account.trim(), this.issuer.trim(), undefined,
        undefined, this.secret.trim(), undefined, undefined, undefined, display);
    } else {
      const display = new CodeDisplay();
      display.tags = this.tags;
      display.note = this.notes.trim();
      newCode = Code.fromAccountAndSecret(codeType, this.account.trim(), this.issuer.trim(),
        this.secret.trim(), display, codeDigits, this.algorithm, period);
    }

    try {
      await getOTP(newCode);
    } catch (e) {
      this.incorrectDetails(S.incorrectDetails());
      return;
    }
    this.busy = true;
    try {
      await CodeStore.instance.addCode(newCode, true);
      Router.back();
    } finally {
      this.busy = false;
    }
  }

  private incorrectDetails(message: string): void {
    promptAction.showDialog({
      title: S.incorrectDetails(),
      message: `${message}\n\n${S.pleaseVerifyDetails()}`,
      buttons: [{ text: S.ok(), color: '#4E5BA6' }],
    });
  }
}

@Component
struct FieldLabel {
  label: string = '';

  build() {
    Text(this.label)
      .fontSize(13)
      .fontColor('#8A8A8E')
      .width('100%')
      .margin({ top: 16, bottom: 6 })
  }
}