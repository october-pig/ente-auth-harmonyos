/**
 * ExportPage + PasswordPromptPage + misc small pages: export (encrypted /
 * plain text / HTML), QR sheet, share sheet, reorder, duplicates,
 * tag input.
 */
import { promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { ExportFileWriter } from '../storage/ExportFileWriter';
import { common, Want } from '@kit.AbilityKit';
import { Code } from '../models/Code';
import { Router, resolveTagInput } from './Router.ets';
import { S } from '../app/AppStrings';
import { EnteExport, ExportResult } from '../services/EnteExport';
import { CodeStore, AddResult } from '../store/CodeStore';
import { AuthenticatorService, UnreadableAuthenticatorDataError } from '../services/AuthenticatorService';
import { Toast } from '../utils/Toast';
import { ConfirmDialog } from './HomePage.ets';
import { promptPassword, resolvePasswordPrompt } from '../utils/Prompts.ets';
import { ConfirmParam, CodeParam, TagsParam, CodesParam } from './PageParams.ets';

@Component
export struct ExportPage {
  @State busy: boolean = false;
  @State password: string = '';

  build() {
    Column() {
      TopBar({ title: S.export(), onBack: () => {
        Router.back();
      }})
      Column() {
        ExportOption({
          label: 'Encrypted',
          onTap: () => {
            this.exportEncrypted();
          },
        })
        ExportOption({
          label: 'Plain text',
          onTap: () => {
            this.exportPlain();
          },
        })
        ExportOption({
          label: 'Plain HTML',
          onTap: () => {
            this.exportHtml();
          },
        })
      }
      .width('100%')
      .layoutWeight(1)
      .margin({ top: 12 })
    }
    .width('100%')
    .height('100%')
  }

  private async saveFile(result: ExportResult): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const docPicker = new picker.DocumentViewPicker(context);
    const saveOptions: picker.DocumentSaveOptions = { newFileNames: [result.fileName] };
    const uris: string[] = await docPicker.save(saveOptions);
    if (uris === undefined || uris.length === 0) {
      return;
    }
    const bytes: Uint8Array = utf8Encode(result.content);
    ExportFileWriter.write(uris[0], bytes);
    Toast.show(S.export());
  }

  private async exportEncrypted(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const password: string | undefined = await promptPassword(false);
      if (password === undefined) {
        return;
      }
      if (password.length < 4) {
        Toast.show(S.passwordTooShort());
        return;
      }
      const result: ExportResult = await EnteExport.exportEncrypted(password,
        getContext(this) as common.UIAbilityContext);
      await this.saveFile(result);
    } catch (e) {
      Toast.show(e instanceof UnreadableAuthenticatorDataError ? S.unableToReadCodes() : S.somethingWentWrong());
    } finally {
      this.busy = false;
    }
  }

  private async exportPlain(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ok = await ConfirmDialog.show(S.warning(),
        S.plainTextExportWarning(),
        S.ok());
      if (!ok) {
        return;
      }
      const result: ExportResult = await EnteExport.exportPlainText();
      await this.saveFile(result);
    } catch (e) {
      Toast.show(e instanceof UnreadableAuthenticatorDataError ? S.unableToReadCodes() : S.somethingWentWrong());
    } finally {
      this.busy = false;
    }
  }

  private async exportHtml(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ok = await ConfirmDialog.show(S.warning(),
        S.plainHtmlExportWarning(),
        S.ok());
      if (!ok) {
        return;
      }
      const result: ExportResult = await EnteExport.exportHtml();
      await this.saveFile(result);
    } catch (e) {
      Toast.show(e instanceof UnreadableAuthenticatorDataError ? S.unableToReadCodes() : S.somethingWentWrong());
    } finally {
      this.busy = false;
    }
  }
}

/** Password prompt page (used by encrypted import/export when no in-place field). */
@Component
export struct PasswordPromptPage {
  @State password: string = '';
  @State confirm: string = '';
  @State mode: number = 0;

  aboutToAppear(): void {
    const param = Router.currentParam() as ConfirmParam | undefined;
    if (param !== undefined && param.confirm) {
      this.mode = 1;
    }
  }

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(18)
          .onClick(() => {
            resolvePasswordPrompt(undefined);
            Router.back();
          })
        Text(S.password())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
      }
      .width('100%')
      .height(52)
      .padding({ left: 8, right: 16 })

      Column() {
        TextInput({ text: this.password, placeholder: S.password() })
          .height(44)
          .type(InputType.Password)
          .onChange((v: string) => {
            this.password = v;
          })
        if (this.mode === 1) {
          TextInput({ text: this.confirm, placeholder: S.confirmPassword() })
            .height(44)
            .type(InputType.Password)
            .margin({ top: 12 })
            .onChange((v: string) => {
              this.confirm = v;
            })
        }
        Button(S.continuePage())
          .width('100%')
          .height(44)
          .margin({ top: 24 })
          .backgroundColor('#4E5BA6')
          .onClick(() => {
            if (this.mode === 1 && this.password !== this.confirm) {
              Toast.show(S.passwordsDoNotMatch());
              return;
            }
            resolvePasswordPrompt(this.password);
            Router.back();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24, top: 24 })
    }
    .width('100%')
    .height('100%')
  }
}

/** QR sheet page (ScanKit-generated QR for a code). */
@Component
export struct QrPage {
  @State qrSource: string = '';
  @State issuer: string = '';
  @State account: string = '';
  @State ready: boolean = false;
  private code: Code | undefined = undefined;

  aboutToAppear(): void {
    const param = Router.currentParam() as CodeParam | undefined;
    if (param !== undefined && param.code !== undefined) {
      this.code = param.code;
      this.issuer = this.code.issuer;
      this.account = this.code.account;
      this.qrSource = this.code.rawData.replaceAll('algorithm=Algorithm.', 'algorithm=')
        .replaceAll('algorithm=sha1', 'algorithm=SHA1')
        .replaceAll('algorithm=sha256', 'algorithm=SHA256')
        .replaceAll('algorithm=sha512', 'algorithm=SHA512');
      this.ready = true;
    }
  }

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(18)
          .onClick(() => {
            Router.back();
          })
        Text(S.qrCode())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
      }
      .width('100%')
      .height(52)
      .padding({ left: 8, right: 16 })
      if (this.ready) {
        Column() {
          QrImage({ data: this.qrSource })
          Text(this.issuer)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .margin({ top: 16 })
          Text(this.account)
            .fontSize(14)
            .fontColor('#8A8A8E')
            .margin({ top: 4 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Component
struct QrImage {
  data: string = '';

  build() {
    QRCode(this.data)
      .width(260)
      .height(260)
      .color(Color.Black)
      .backgroundColor(Color.White)
  }
}

/** Share sheet page — native system share of the otpauth URI. */
@Component
export struct SharePage {
  @State shareText: string = '';

  aboutToAppear(): void {
    const param = Router.currentParam() as CodeParam | undefined;
    if (param !== undefined && param.code !== undefined) {
      this.shareText = param.code.rawData;
    }
  }

  build() {
    Column() {
      TopBar({ title: S.share(), onBack: () => {
        Router.back();
      }})
      Column() {
        Text(S.shareYourCode())
          .fontSize(15)
          .fontColor('#1A1A1A')
        TextInput({ text: this.shareText })
          .height(44)
          .margin({ top: 12 })
        Button(S.share())
          .width('100%')
          .height(44)
          .margin({ top: 16 })
          .backgroundColor('#4E5BA6')
          .onClick(() => {
            systemShareLauncher(this.shareText, getContext(this) as common.UIAbilityContext);
          })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24, top: 24 })
    }
    .width('100%')
    .height('100%')
  }
}

/** Reorder page — manual sort (display.position persistence). */
@Component
export struct ReorderPage {
  @State codes: Code[] = [];

  aboutToAppear(): void {
    const param = Router.currentParam() as CodesParam | undefined;
    if (param !== undefined) {
      const all = param.codes;
      const candidates: Code[] = [];
      for (let i = 0; i < all.length; i++) {
        const c = all[i];
        if (!c.hasError && !c.isTrashed) {
          candidates.push(c);
        }
      }
      candidates.sort((a: Code, b: Code) => a.display.position - b.display.position);
      this.codes = candidates;
    }
  }

  async move(index: number, delta: number): Promise<void> {
    const target = index + delta;
    if (target < 0 || target >= this.codes.length) {
      return;
    }
    const list = this.codes.slice();
    const item = list.splice(index, 1)[0];
    list.splice(target, 0, item);
    this.codes = list;
    await CodeStore.instance.saveUpadedIndexes(list, await AuthenticatorService.instance.getAccountMode());
  }

  build() {
    Column() {
      TopBar({ title: S.editOrder(), onBack: () => {
        Router.back();
      }})
      List() {
        ForEach(this.codes, (code: Code, index: number) => {
          ListItem() {
            Row() {
              Column() {
                Text(code.issuer)
                  .fontSize(16)
                  .fontColor('#1A1A1A')
                Text(code.account)
                  .fontSize(13)
                  .fontColor('#8A8A8E')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('▲')
                .fontSize(18)
                .padding({ left: 12, right: 12 })
                .onClick(() => {
                  this.move(index as number, -1);
                })
              Text('▼')
                .fontSize(18)
                .padding({ left: 12, right: 12 })
                .onClick(() => {
                  this.move(index as number, 1);
                })
            }
            .width('100%')
            .padding({ left: 24, right: 24, top: 10, bottom: 10 })
          }
        }, (code: Code) => code.selectionKey)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      Button(S.save())
        .width('100%')
        .height(46)
        .backgroundColor('#4E5BA6')
        .margin({ left: 24, right: 24, bottom: 16 })
        .onClick(() => {
          Router.back();
        })
    }
    .width('100%')
    .height('100%')
  }
}

/** Tag input page — returns the entered tag via resolveTagInput. */
@Component
export struct TagInputPage {
  @State tag: string = '';

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(18)
          .onClick(() => {
            resolveTagInput('');
            Router.back();
          })
        Text(S.createNewTag())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
      }
      .width('100%')
      .height(52)
      .padding({ left: 8, right: 16 })
      Column() {
        TextInput({ text: this.tag, placeholder: S.tag() })
          .height(44)
          .maxLength(100)
          .onChange((v: string) => {
            this.tag = v;
          })
        Button(S.create())
          .width('100%')
          .height(44)
          .margin({ top: 16 })
          .backgroundColor('#4E5BA6')
          .onClick(() => {
            const value: string = this.tag.trim();
            if (value.length === 0) {
              Toast.show(S.tag());
              return;
            }
            resolveTagInput(value);
            Router.back();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24, top: 20 })
    }
    .width('100%')
    .height('100%')
  }
}

/** Duplicates page — groups by secret_issuer_account, trash all but first. */
@Component
export struct DuplicatesPage {
  @State groups: Array<Array<Code>> = [];
  @State loaded: boolean = false;
  @State loadError: boolean = false;

  aboutToAppear(): void {
    this.loadGroups();
  }

  async loadGroups(): Promise<void> {
    let codes: Code[];
    try {
      codes = await CodeStore.instance.getAllCodes();
    } catch (e) {
      this.groups = [];
      this.loadError = true;
      this.loaded = true;
      return;
    }
    this.loadError = false;
    const map: Map<string, Code[]> = new Map<string, Code[]>();
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      if (c.hasError || c.isTrashed) {
        continue;
      }
      const key: string = `${c.secret}_${c.issuer}_${c.account}`;
      let list = map.get(key);
      if (list === undefined) {
        list = [];
        map.set(key, list);
      }
      list.push(c);
    }
    const groups: Array<Array<Code>> = [];
    map.forEach((list: Code[]) => {
      if (list.length > 1) {
        groups.push(list);
      }
    });
    this.groups = groups;
    this.loaded = true;
  }

  build() {
    Column() {
      TopBar({ title: S.duplicateCodes(), onBack: () => {
        Router.back();
      }})
      if (this.loadError) {
        Text(S.unableToReadCodes())
          .fontSize(16)
          .layoutWeight(1)
      } else if (this.loaded && this.groups.length === 0) {
        Column() {
          Text(S.noDuplicateCodes())
            .fontSize(15)
            .fontColor('#8A8A8E')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.groups, (group: Code[]) => {
            ListItem() {
              Column() {
                Text(`${group[0].issuer} (${group.length})`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                  .width('100%')
                Text(S.deleteDuplicates())
                  .fontSize(14)
                  .fontColor('#D03232')
                  .margin({ top: 8 })
                  .onClick(() => {
                    this.trashDuplicates(group);
                  })
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#F7F7F9')
              .borderRadius(8)
              .margin({ left: 16, right: 16 })
            }
          }, (group: Code[]) => this.groups.indexOf(group).toString())
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .margin({ top: 12 })
      }
    }
    .width('100%')
    .height('100%')
  }

  private async trashDuplicates(group: Code[]): Promise<void> {
    const count: number = group.length - 1;
    const ok = await ConfirmDialog.show(S.deleteDuplicates(),
      S.moveMultipleToTrashMessage(count), S.delete());
    if (!ok) {
      return;
    }
    for (let i = 1; i < group.length; i++) {
      const c = group[i];
      const updated = c.copyWith(undefined, undefined, undefined, undefined, undefined,
        undefined, undefined, undefined, c.display.copyWith(undefined, true));
      await CodeStore.instance.addCode(updated, false);
    }
    await AuthenticatorService.instance.onlineSync();
    this.loadGroups();
  }
}

/** Helpers */
function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let code: number = s.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length) {
      const low: number = s.charCodeAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        i++;
      }
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
    } else if (code < 0x10000) {
      out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
    } else {
      out.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F), 0x80 | ((code >> 6) & 0x3F),
        0x80 | (code & 0x3F));
    }
  }
  return Uint8Array.from(out);
}

function systemShareLauncher(text: string, context: common.UIAbilityContext): void {
  // ShareKit text share: open the native share panel via want.
  const want: Want = {
    action: 'ohos.want.action.sendData',
    type: 'text/plain',
    parameters: {
      'ability.params.stream': text,
      'ability.params.contentTitle': S.share(),
    },
  };
  context.startAbility(want);
}

@Component
struct TopBar {
  title: string = '';
  onBack: () => void = () => {
  };

  build() {
    Row() {
      Text('←')
        .fontSize(18)
        .onClick(() => {
          this.onBack();
        })
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ left: 12 })
    }
    .width('100%')
    .height(52)
    .padding({ left: 8, right: 16 })
  }
}

@Component
struct ExportOption {
  label: string = '';
  onTap: () => void = () => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor('#1A1A1A')
        .layoutWeight(1)
      Text('>')
        .fontSize(14)
        .fontColor('#C4C4C8')
    }
    .width('100%')
    .height(50)
    .padding({ left: 24, right: 24 })
    .onClick(() => {
      this.onTap();
    })
  }
}
