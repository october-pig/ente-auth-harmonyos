import { fileIo as fs } from '@kit.CoreFileKit';

/** SDK fs.writeSync returns actual bytes written; omitted length means full buffer.
 * Own the descriptor here so every successful open is paired with a close.
 */
export class ExportFileWriter {
  static write(uri: string, bytes: Uint8Array): void {
    const file = fs.openSync(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let offset: number = 0;
      while (offset < bytes.length) {
        // slice creates an exact-size buffer (including byteOffset/subarray inputs).
        const chunk = bytes.slice(offset, Math.min(bytes.length, offset + (1 << 20)));
        const written = fs.writeSync(file.fd, chunk.buffer as ArrayBuffer);
        if (!Number.isInteger(written) || written <= 0 || written > chunk.length) {
          throw new Error('Export file write made no valid progress');
        }
        offset += written;
      }
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
  }
}
