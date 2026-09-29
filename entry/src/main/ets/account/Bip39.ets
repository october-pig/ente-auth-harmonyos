/**
 * BIP39 mnemonic ↔ entropy conversion, mirroring the Dart `bip39` package as
 * used by upstream Ente Auth (packages/accounts): recovery keys are
 * 24-word mnemonics derived from 32-byte entropy (256 bits, 24 words,
 * checksum = first 8 bits of SHA-256(entropy)).
 *
 * SHA-256 comes from the Crypto Architecture Kit (no hand-rolled crypto).
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BIP39_ENGLISH_WORDS } from './Bip39Words';

export class Bip39 {
  static readonly isValid: boolean = true;

  /** Entropy (hex string) → mnemonic phrase (space separated). */
  static async entropyToMnemonic(entropyHex: string): Promise<string> {
    const entropy: Uint8Array = Bip39.hexToBytes(entropyHex);
    if (entropy.length % 4 !== 0 || entropy.length < 16 || entropy.length > 32) {
      throw new Error('Invalid entropy');
    }
    const ent: number = entropy.length * 8;
    const cs: number = ent / 32;
    const digest: Uint8Array = await Bip39.sha256(entropy);
    const bits: boolean[] = [];
    for (let i = 0; i < entropy.length; i++) {
      Bip39.pushBits(bits, entropy[i], 8);
    }
    Bip39.pushBits(bits, digest[0], cs);
    const words: string[] = [];
    for (let i = 0; i < bits.length; i += 11) {
      let idx: number = 0;
      for (let j = 0; j < 11; j++) {
        idx = idx * 2 + (bits[i + j] ? 1 : 0);
      }
      words.push(BIP39_ENGLISH_WORDS[idx]);
    }
    return words.join(' ');
  }

  /** Mnemonic phrase → entropy hex string (validates checksum). */
  static async mnemonicToEntropy(mnemonic: string): Promise<string> {
    const words: string[] = mnemonic.trim().split(/\s+/);
    if (words.length % 3 !== 0) {
      throw new Error('Invalid mnemonic');
    }
    const bits: boolean[] = [];
    for (let i = 0; i < words.length; i++) {
      const idx: number = Bip39.wordIndex(words[i]);
      if (idx < 0) {
        throw new Error(`Invalid mnemonic word: ${words[i]}`);
      }
      Bip39.pushBits(bits, idx, 11);
    }
    const ent: number = Math.floor(bits.length * 32 / 33);
    const cs: number = bits.length - ent;
    if (ent % 32 !== 0 || ent < 128 || ent > 256 || cs !== ent / 32) {
      throw new Error('Invalid mnemonic');
    }
    const entropyBytes: Uint8Array = new Uint8Array(ent / 8);
    for (let i = 0; i < ent; i++) {
      if (bits[i]) {
        entropyBytes[Math.floor(i / 8)] |= (1 << (7 - (i % 8)));
      }
    }
    const digest: Uint8Array = await Bip39.sha256(entropyBytes);
    for (let i = 0; i < cs; i++) {
      const b: boolean = bits[ent + i];
      const expected: boolean = ((digest[Math.floor(i / 8)] >> (7 - (i % 8))) & 1) === 1;
      if (b !== expected) {
        throw new Error('Invalid mnemonic checksum');
      }
    }
    return Bip39.bytesToHex(entropyBytes);
  }

  /** Word count validation used by upstream recovery (24 words exactly). */
  static countWords(mnemonic: string): number {
    if (mnemonic.trim().length === 0) {
      return 0;
    }
    return mnemonic.trim().split(/\s+/).length;
  }

  private static wordIndex(word: string): number {
    // Binary search over the sorted wordlist.
    let lo = 0;
    let hi = BIP39_ENGLISH_WORDS.length - 1;
    while (lo <= hi) {
      const mid = Math.floor((lo + hi) / 2);
      const cmp = BIP39_ENGLISH_WORDS[mid].localeCompare(word);
      if (cmp === 0) {
        return mid;
      } else if (cmp < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }

  private static pushBits(bits: boolean[], value: number, count: number): void {
    for (let i = count - 1; i >= 0; i--) {
      bits.push(((value >> i) & 1) === 1);
    }
  }

  private static hexToBytes(hex: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i + 1 < hex.length; i += 2) {
      out.push(parseInt(hex.substring(i, i + 2), 16));
    }
    return Uint8Array.from(out);
  }

  private static bytesToHex(bytes: Uint8Array): string {
    let out: string = '';
    for (let i = 0; i < bytes.length; i++) {
      const h = bytes[i].toString(16);
      out += h.length === 1 ? '0' + h : h;
    }
    return out;
  }

  static async sha256(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: data } as cryptoFramework.DataBlob);
    const out = await md.digest();
    return out.data;
  }
}