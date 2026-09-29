/**
 * kit-crypto.mjs — host shim for `@kit.CryptoArchitectureKit`
 * (`cryptoFramework`), implemented on node:crypto.
 *
 * Covers exactly what the port uses:
 *   cryptoFramework.createMac(algName)        -> HMAC (SHA1/SHA256/SHA512/MD5)
 *   cryptoFramework.createMd(algName)         -> message digest
 *   cryptoFramework.createSymKeyGenerator(a)  -> 'HMAC' / 'AES256' key convert
 *
 * DataBlob = { data: Uint8Array }.
 * Mac.init(symKey) / Mac.update(blob) are async on device; doFinal() resolves
 * to a DataBlob.
 */
import { createHash, createHmac } from 'node:crypto';

const MAC_ALGOS = {
  SHA1: 'sha1',
  SHA224: 'sha224',
  SHA256: 'sha256',
  SHA384: 'sha384',
  SHA512: 'sha512',
  MD5: 'md5',
  SM3: null, // not available on host
};

class DataBlob {
  constructor(data) {
    this.data = data;
  }
}

class SymKey {
  constructor(bytes) {
    this._bytes = bytes;
  }
  getEncoded() {
    return this._bytes;
  }
}

class SymKeyGenerator {
  constructor(algo) {
    this.algo = algo;
  }
  async convertKey(blob) {
    if (!blob || !(blob.data instanceof Uint8Array)) {
      throw new Error('BusinessError: convertKey expects a DataBlob with Uint8Array data');
    }
    return new SymKey(blob.data);
  }
  async generateSymKey() {
    const len = this.algo === 'AES256' ? 32 : this.algo === 'AES128' ? 16 : 32;
    const b = new Uint8Array(len);
    for (let i = 0; i < len; i++) b[i] = Math.floor(Math.random() * 256);
    return new SymKey(b);
  }
}

class Mac {
  constructor(algName) {
    this.algName = String(algName).toUpperCase();
    this._key = null;
    this._chunks = [];
  }
  async init(key) {
    if (!(key instanceof SymKey)) {
      throw new Error('BusinessError: Mac.init expects a SymKey');
    }
    this._key = key.getEncoded();
  }
  async update(blob) {
    if (!this._key) throw new Error('BusinessError: Mac not initialised');
    if (!blob || !(blob.data instanceof Uint8Array)) {
      throw new Error('BusinessError: Mac.update expects a DataBlob');
    }
    this._chunks.push(Buffer.from(blob.data));
  }
  async doFinal() {
    if (!this._key) throw new Error('BusinessError: Mac not initialised');
    const algo = MAC_ALGOS[this.algName];
    if (!algo) throw new Error(`BusinessError: Unsupported Mac algorithm ${this.algName}`);
    const h = createHmac(algo, Buffer.from(this._key));
    for (const c of this._chunks) h.update(c);
    const out = new Uint8Array(h.digest());
    this._chunks = [];
    return new DataBlob(out);
  }
}

class Md {
  constructor(algName) {
    this.algName = String(algName).toUpperCase();
    this._chunks = [];
  }
  async update(blob) {
    if (!blob || !(blob.data instanceof Uint8Array)) {
      throw new Error('BusinessError: Md.update expects a DataBlob');
    }
    this._chunks.push(Buffer.from(blob.data));
  }
  async digest() {
    const algo = MAC_ALGOS[this.algName];
    if (!algo) throw new Error(`BusinessError: Unsupported Md algorithm ${this.algName}`);
    const h = createHash(algo);
    for (const c of this._chunks) h.update(c);
    const out = new Uint8Array(h.digest());
    this._chunks = [];
    return new DataBlob(out);
  }
  async digestSync() {
    return this.digest();
  }
}

/** cryptoFramework.createRandom() — secure random source. */
class Random {
  generateRandomSync(len) {
    const b = new Uint8Array(len);
    globalThis.crypto.getRandomValues(b);
    return new DataBlob(b);
  }
  async generateRandom(len) {
    return this.generateRandomSync(len);
  }
  setSeed() {}
}

export const cryptoFramework = {
  createMac: (algName) => new Mac(algName),
  createMd: (algName) => new Md(algName),
  createSymKeyGenerator: (algo) => new SymKeyGenerator(algo),
  createRandom: () => new Random(),
  DataBlob,
};

export default cryptoFramework;
