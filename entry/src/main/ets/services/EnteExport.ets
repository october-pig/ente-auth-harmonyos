/**
 * EnteExport — export formats mirroring upstream `ui/settings/data/export_widget.dart`
 * and `html_export.dart`:
 *  1. Encrypted JSON (EnteAuthExport v1: {version, kdfParams{memLimit,opsLimit,salt},
 *     encryptedData, encryptionNonce}) — Argon2id KEK.
 *  2. Plain text: one rawData per line (algorithm enum normalized, commas → %2C).
 *  3. Plain HTML with embedded QR PNGs (ScanKit generation, like upstream's
 *     QR generation for export).
 */
import { Code } from '../models/Code';
import { CodeStore } from '../store/CodeStore';
import { CryptoUtil } from '../crypto/CryptoUtil';
import { image } from '@kit.ImageKit';
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { common } from '@kit.AbilityKit';

export class ExportResult {
  fileName: string;
  content: string;

  constructor(fileName: string, content: string) {
    this.fileName = fileName;
    this.content = content;
  }
}

function timestampName(): string {
  const d = new Date();
  const pad = (n: number): string => n.toString().padStart(2, '0');
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}-` +
    `${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}`;
}

/** Upstream _getAuthDataForExport: rawData lines with normalizations. */
export async function getAuthDataForExport(): Promise<string> {
  const codes: Code[] = await CodeStore.instance.getAllCodes(undefined, false);
  let data: string = '';
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i];
    if (code.hasError) {
      continue;
    }
    data += `${code.rawData.replaceAll('algorithm=Algorithm.', 'algorithm=').replaceAll(',', '%2C')}\n`;
  }
  return data;
}

export class EnteExport {
  static async exportEncrypted(password: string, context: common.Context): Promise<ExportResult> {
    const kekSalt: Uint8Array = CryptoUtil.getSaltToDeriveKey();
    const derived = await CryptoUtil.deriveSensitiveKey(CryptoUtil.strToBin(password), kekSalt);
    const plaintext: string = await getAuthDataForExport();
    const encrypted = await CryptoUtil.encryptData(CryptoUtil.strToBin(plaintext), derived.key);
    const kdfParams: Record<string, Object> = {
      'memLimit': derived.memLimit,
      'opsLimit': derived.opsLimit,
      'salt': CryptoUtil.bin2base64(kekSalt),
    };
    const payload: Record<string, Object> = {
      'version': 1,
      'encryptedData': CryptoUtil.bin2base64(encrypted.encryptedData as Uint8Array),
      'encryptionNonce': CryptoUtil.bin2base64(encrypted.header as Uint8Array),
      'kdfParams': kdfParams,
    };
    return new ExportResult(`ente-auth-codes-encrypted-${timestampName()}.json`,
      JSON.stringify(payload));
  }

  static async exportPlainText(): Promise<ExportResult> {
    const data: string = await getAuthDataForExport();
    return new ExportResult(`ente-auth-codes-plaintext-${timestampName()}.txt`, data);
  }

  static async exportHtml(): Promise<ExportResult> {
    const codes: Code[] = await CodeStore.instance.getAllCodes(undefined, false);
    let body: string = '';
    for (let i = 0; i < codes.length; i++) {
      const code = codes[i];
      if (code.hasError) {
        continue;
      }
      let qrData: string = code.rawData.replaceAll('algorithm=Algorithm.', 'algorithm=')
        .replaceAll('algorithm=sha1', 'algorithm=SHA1')
        .replaceAll('algorithm=sha256', 'algorithm=SHA256')
        .replaceAll('algorithm=sha512', 'algorithm=SHA512');
      const qrPng: string | undefined = await EnteExport.qrPngBase64(qrData);
      const noteHtml: string = code.note.length > 0 ? `<p class="group">Note: <b>${esc(code.note)}</b></p>` : '';
      body += `<section class="otp-entry-card"><table class="otp-entry"><tr><td>` +
        `<p><b>${esc(code.issuer)}</b></p><p><b>${esc(code.account)}</b></p>` +
        `<p class="group">Type: <b>${code.type.toString()}</b></p>` +
        `<p>Algorithm: <b>${code.algorithm.toString()}</b></p>` +
        `<p>Digits: <b>${code.digits}</b></p><p>Secret: <b>${esc(code.secret)}</b></p>${noteHtml}</td>` +
        `<td class="otp-qr">${qrPng === undefined ? '' : `<img src="data:image/png;base64,${qrPng}" alt="QR Code">`}</td>` +
        `</tr></table><hr class="red-separator" /></section>`;
    }
    const html: string = '<!DOCTYPE html><html><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width, initial-scale=1">' +
      '<title>Ente Auth - OTP Data Export</title>' +
      '<style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;' +
      'max-width:720px;margin:0 auto;padding:16px;color:#111}' +
      '.otp-entry-card{break-inside:avoid;}' +
      '.otp-entry{width:100%;border-collapse:collapse;margin-bottom:8px}' +
      '.otp-entry td{vertical-align:top}' +
      '.otp-qr img{width:250px;height:250px}' +
      '.red-separator{border:none;border-top:1px solid #d32f2f;}</style></head><body>' +
      '<h1>Ente Auth - OTP Data Export</h1><p>Exported from the HarmonyOS client.</p>' +
      body + '</body></html>';
    return new ExportResult(`ente-auth-codes-plainhtml-${timestampName()}.html`, html);
  }

  private static async qrPngBase64(data: string): Promise<string | undefined> {
    try {
      const options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        height: 250,
        width: 250,
        level: generateBarcode.ErrorCorrectionLevel.LEVEL_L,
      };
      const pixelMap: image.PixelMap = (await generateBarcode.createBarcode(data, options)) as image.PixelMap;
      const packer = image.createImagePacker();
      const packOptions: image.PackingOption = { format: 'image/png', quality: 100 };
      const buffer = await packer.packing(pixelMap, packOptions);
      packer.release();
      return EnteExport.bytesToBase64(new Uint8Array(buffer));
    } catch (e) {
      return undefined;
    }
  }

  private static bytesToBase64(bytes: Uint8Array): string {
    return CryptoUtil.bin2base64(bytes);
  }
}

function esc(s: string): string {
  return s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}