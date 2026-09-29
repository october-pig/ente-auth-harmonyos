/**
 * ScannerPage — QR scanning via Scan Kit (system default UI), mirroring the
 * upstream `ui/scanner_page.dart` outcome: parse otpauth:// → add code;
 * Google Authenticator migration URIs are handled by the import layer.
 */
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Code } from '../models/Code';
import { Router, addCodeFromScan } from './Router.ets';
import { S } from '../app/AppStrings';
import { Toast } from '../utils/Toast';
import { GoogleAuthImport } from '../services/GoogleAuthImport';

@Component
export struct ScannerPage {
  @State scanning: boolean = false;

  aboutToAppear(): void {
    this.startScan();
  }

  private async startScan(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    const options: scanBarcode.ScanOptions = {
      enableMultiMode: false,
      enableAlbum: true,
    };
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result: scanBarcode.ScanResult = await new Promise<scanBarcode.ScanResult>((resolve, reject) => {
        scanBarcode.startScanForResult(context, options, (err: BusinessError, value: scanBarcode.ScanResult) => {
          if (err) {
            reject(err as Error);
            return;
          }
          resolve(value);
        });
      });
      const value: string = result.originalValue;
      if (value.startsWith('otpauth-migration://offline')) {
        const codes: Code[] = GoogleAuthImport.importFromMigrationUri(value);
        for (let i = 0; i < codes.length; i++) {
          await addCodeFromScan(codes[i], false);
        }
        if (codes.length === 0) {
          Toast.show(S.invalidQRCode());
        } else {
          Toast.show(S.importedCount(codes.length));
        }
      } else {
        const code: Code = Code.fromOTPAuthUrl(value);
        await addCodeFromScan(code, false);
      }
    } catch (e) {
      // Cancelled scans throw; only surface parse failures as invalid QR.
      const msg = (e as Error).message;
      if (msg !== undefined && (msg.includes('secret') || msg.includes('Unsupported format'))) {
        Toast.show(S.invalidQRCode());
      }
    } finally {
      this.scanning = false;
      Router.back();
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
        Text(S.scan())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
      }
      .width('100%')
      .height(52)
      .padding({ left: 8, right: 16 })

      Column() {
        Text(S.scanACode())
          .fontSize(15)
          .fontColor('#8A8A8E')
        LoadingProgress()
          .width(36)
          .height(36)
          .color('#4E5BA6')
          .margin({ top: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
  }
}