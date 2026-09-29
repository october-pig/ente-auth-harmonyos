/**
 * ImportPage — mirror of upstream `ui/settings/data/import_page.dart` flow:
 * pick a source → pick file → parse → save codes (sync after import).
 * Formats: Plain text, Ente Auth (Encrypted), Google Authenticator,
 * Bitwarden, LastPass, Raivo OTP; others listed as unsupported-yet with an
 * explicit message (DEFERRED, documented).
 */
import { promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Router } from './Router.ets';
import { S } from '../app/AppStrings';
import { ImportService, IncorrectPasswordError, ImportEntryParseException } from '../services/ImportService';
import { AuthenticatorService } from '../services/AuthenticatorService';
import { Toast } from '../utils/Toast';
import { Code } from '../models/Code';
import { promptPassword as promisePasswordImport } from '../utils/Prompts.ets';

@Component
export struct ImportPage {
  @State busy: boolean = false;

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(18)
          .onClick(() => {
            Router.back();
          })
        Text(S.import())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
      }
      .width('100%')
      .height(52)
      .padding({ left: 8, right: 16 })

      Scroll() {
        Column() {
          ForEach([
            ['Plain text', 0, false],
            ['Ente Auth (Encrypted)', 1, false],
            ['Google Authenticator', 2, false],
            ['Bitwarden', 3, false],
            ['LastPass Authenticator', 4, false],
            ['Raivo OTP', 5, false],
            ['2FAS Authenticator', 10, true],
            ['Aegis Authenticator', 11, true],
            ['andOTP', 12, true],
            ['Proton Authenticator', 13, true],
            ['OTP Auth', 14, true],
          ] as Array<[string, number, boolean]>, (row: [string, number, boolean]) => {
            ImportRow({
              label: row[0],
              kind: row[1],
              deferred: row[2],
              onTap: (k: number, d: boolean) => {
                this.pickAndImport(k, d);
              },
            })
          }, (row: [string, number, boolean]) => row[0])
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  private async pickAndImport(kind: number, unsupported: boolean): Promise<void> {
    if (unsupported) {
      promptAction.showDialog({
        title: S.import(),
        message: S.notSupportedYet(),
        buttons: [{ text: S.ok(), color: '#4E5BA6' }],
      });
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const docPicker = new picker.DocumentViewPicker(context);
      const selectOptions: picker.DocumentSelectOptions = { maxSelectNumber: 1 };
      const uris: string[] = await docPicker.select(selectOptions);
      if (uris === undefined || uris.length === 0) {
        return;
      }
      const uri: string = uris[0];
      const file = fs.openSync(uri, 0o0);
      const stat = fs.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      const content: string = decodeUtf8(new Uint8Array(buffer));
      await this.handleContent(kind, content);
    } catch (e) {
      if (!(e as Error).message.includes('cancelled')) {
        Toast.show(`${S.error()}`);
      }
    } finally {
      this.busy = false;
    }
  }

  private async handleContent(kind: number, content: string): Promise<void> {
    let codes: Code[];
    if (kind === 0) {
      codes = ImportService.parsePlainText(content);
    } else if (kind === 1) {
      const result = await this.promptPassword();
      if (result === undefined) {
        return;
      }
      try {
        codes = await ImportService.parseEnteEncrypted(content, result);
      } catch (e) {
        if (e instanceof IncorrectPasswordError) {
          promptAction.showDialog({
            title: S.error(),
            message: S.incorrectPasswordRetry(),
            buttons: [{ text: S.ok(), color: '#4E5BA6' }],
          });
          return;
        }
        throw e as Error;
      }
    } else if (kind === 2) {
      codes = ImportService.parseGoogleAuth(content);
    } else if (kind === 3) {
      codes = ImportService.parseBitwarden(content);
    } else if (kind === 4) {
      codes = ImportService.parseLastPass(content);
    } else if (kind === 5) {
      codes = ImportService.parseRaivo(content);
    } else {
      codes = [];
    }
    const count = await ImportService.saveImportedCodes(codes);
    if (count > 0) {
      AuthenticatorService.instance.onlineSync();
    }
    promptAction.showDialog({
      title: S.importSuccessTitle(),
      message: S.importedCount(count),
      buttons: [{ text: S.ok(), color: '#4E5BA6' }],
    });
  }

  private promptPassword(): Promise<string | undefined> {
    return promisePasswordImport(false);
  }
}

@Component
struct ImportRow {
  label: string = '';
  kind: number = 0;
  deferred: boolean = false;
  onTap: (kind: number, deferred: boolean) => void = (k: number, d: boolean) => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor('#1A1A1A')
        .layoutWeight(1)
      if (this.deferred) {
        Text('soon')
          .fontSize(11)
          .fontColor('#8A8A8E')
      } else {
        Text('>')
          .fontSize(14)
          .fontColor('#C4C4C8')
      }
    }
    .width('100%')
    .height(50)
    .padding({ left: 24, right: 24 })
    .onClick(() => {
      this.onTap(this.kind, this.deferred);
    })
  }
}

function decodeUtf8(bytes: Uint8Array): string {
  let out: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const b0 = bytes[i];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      i++;
    } else if ((b0 & 0xE0) === 0xC0) {
      out += String.fromCharCode(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
      i += 2;
    } else if ((b0 & 0xF0) === 0xE0) {
      out += String.fromCharCode(((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F));
      i += 3;
    } else {
      const cp: number = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) |
        ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
      const adj: number = cp - 0x10000;
      out += String.fromCharCode(0xD800 + (adj >> 10), 0xDC00 + (adj & 0x3FF));
      i += 4;
    }
  }
  return out;
}