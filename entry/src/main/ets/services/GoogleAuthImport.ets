/**
 * GoogleAuthImport — parses `otpauth-migration://offline?data=...` URIs.
 * Mirrors upstream google_auth_qr_parser.dart + models/protos/googleauth.pb.dart
 * (protobuf schema exact; base32 encode via Base32; padding stripped).
 */
import { util } from '@kit.ArkTS';
import { Code } from '../models/Code';
import { OtpType, OtpAlgorithm } from '../otp/OtpTypes';
import { Base32 } from '../otp/Base32';
import { UriComponent } from '../models/UriComponent';

const b64: util.Base64Helper = new util.Base64Helper();

// protobuf wire types
const WIRE_VARINT = 0;
const WIRE_FIXED64 = 1;
const WIRE_LEN = 2;
const WIRE_FIXED32 = 5;

// MigrationPayload.OtpParameters field numbers
const FIELD_SECRET = 1;   // bytes
const FIELD_NAME = 2;     // string
const FIELD_ISSUER = 3;   // string
const FIELD_ALGORITHM = 4; // enum (varint)
const FIELD_DIGITS = 5;   // enum (varint)
const FIELD_TYPE = 6;     // enum (varint)
const FIELD_COUNTER = 7;  // int64 (varint)

// MigrationPayload fields
const FIELD_OTP_PARAMETERS = 1; // repeated message
const FIELD_VERSION = 2;        // int32
const FIELD_BATCH_SIZE = 3;     // int32
const FIELD_BATCH_INDEX = 4;    // int32
const FIELD_BATCH_ID = 5;       // int32

interface ProtoField {
  field: number;
  wire: number;
  varint: number;
  bytes: Uint8Array;
}

function parseProto(bytes: Uint8Array): ProtoField[] {
  const fields: ProtoField[] = [];
  let i = 0;
  while (i < bytes.length) {
    let key = 0;
    let shift = 0;
    while (true) {
      const b = bytes[i];
      i++;
      key |= (b & 0x7f) << shift;
      shift += 7;
      if ((b & 0x80) === 0) {
        break;
      }
    }
    const field = key >> 3;
    const wire = key & 7;
    const entry: ProtoField = { field: field, wire: wire, varint: 0, bytes: new Uint8Array(0) };
    if (wire === WIRE_VARINT) {
      let value = 0;
      shift = 0;
      while (true) {
        const b = bytes[i];
        i++;
        value |= (b & 0x7f) << shift;
        shift += 7;
        if ((b & 0x80) === 0) {
          break;
        }
      }
      entry.varint = value;
    } else if (wire === WIRE_LEN) {
      let len = 0;
      shift = 0;
      while (true) {
        const b = bytes[i];
        i++;
        len |= (b & 0x7f) << shift;
        shift += 7;
        if ((b & 0x80) === 0) {
          break;
        }
      }
      entry.bytes = bytes.subarray(i, i + len);
      i += len;
    } else {
      throw new Error('unsupported wire type');
    }
    fields.push(entry);
  }
  return fields;
}

function protoString(fields: ProtoField[], fieldNum: number): string {
  for (let i = 0; i < fields.length; i++) {
    if (fields[i].field === fieldNum && fields[i].wire === WIRE_LEN) {
      return new util.TextDecoder().decodeWithStream(fields[i].bytes);
    }
  }
  return '';
}

function protoVarint(fields: ProtoField[], fieldNum: number, def: number): number {
  for (let i = 0; i < fields.length; i++) {
    if (fields[i].field === fieldNum && fields[i].wire === WIRE_VARINT) {
      return fields[i].varint;
    }
  }
  return def;
}

function protoBytes(fields: ProtoField[], fieldNum: number): Uint8Array | undefined {
  for (let i = 0; i < fields.length; i++) {
    if (fields[i].field === fieldNum && fields[i].wire === WIRE_LEN) {
      return fields[i].bytes;
    }
  }
  return undefined;
}

export class GoogleAuthImport {
  /**
   * Parses the migration URI (percent-decoded data → base64 → protobuf).
   * Returns Codes grouped by (batchIndex) order; throws on MD5/invalid input.
   */
  static importFromMigrationUri(uri: string): Code[] {
    const parsed: UriComponent = UriComponent.parse(uri);
    const dataParam = parsed.queryParams.get('data');
    if (dataParam === undefined) {
      throw new Error('missing data');
    }
    // Percent-decode already applied by query parsing; decode base64.
    const payload: Uint8Array = b64.decodeSync(dataParam);
    const rootFields: ProtoField[] = parseProto(payload);

    const entries: Code[] = [];
    for (let i = 0; i < rootFields.length; i++) {
      if (rootFields[i].field !== FIELD_OTP_PARAMETERS || rootFields[i].wire !== WIRE_LEN) {
        continue;
      }
      const entry = parseProto(rootFields[i].bytes);
      const secretBytes: Uint8Array | undefined = protoBytes(entry, FIELD_SECRET);
      if (secretBytes === undefined) {
        continue;
      }
      const secret: string = Base32.encode(secretBytes).replace(/=+$/, '');
      const name: string = protoString(entry, FIELD_NAME);
      const issuer: string = protoString(entry, FIELD_ISSUER);
      const algorithmEnum: number = protoVarint(entry, FIELD_ALGORITHM, 0);
      const digitsEnum: number = protoVarint(entry, FIELD_DIGITS, 0);
      const typeEnum: number = protoVarint(entry, FIELD_TYPE, 0);
      const counter: number = protoVarint(entry, FIELD_COUNTER, 0);

      if (algorithmEnum === 4) { // ALGORITHM_MD5
        throw new Error('GoogleAuthImport: MD5 is not supported');
      }
      const algorithm: OtpAlgorithm = algorithmEnum === 2 ? OtpAlgorithm.sha256 :
        (algorithmEnum === 3 ? OtpAlgorithm.sha512 : OtpAlgorithm.sha1);
      const digits: number = digitsEnum === 2 ? 8 : 6;
      const kind: OtpType = typeEnum === 1 ? OtpType.hotp : OtpType.totp;
      let raw: string;
      if (kind === OtpType.hotp) {
        raw = `otpauth://hotp/${issuer}:${name}?secret=${secret}&issuer=${issuer}` +
          `&algorithm=${algorithm.toString().toUpperCase()}&digits=${digits}&counter=${counter}`;
      } else {
        raw = `otpauth://totp/${issuer}:${name}?secret=${secret}&issuer=${issuer}` +
          `&algorithm=${algorithm.toString().toUpperCase()}&digits=${digits}&period=30`;
      }
      entries.push(Code.fromOTPAuthUrl(raw));
    }
    return entries;
  }
}