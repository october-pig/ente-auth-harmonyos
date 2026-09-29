/**
 * CodeDisplay — mirror of upstream `mobile/apps/auth/lib/models/code_display.dart`
 * (`ente@3cc9103a3126de07f79a4465cf0b9922903de54b`).
 *
 * All display metadata for a code, serialized as JSON into the `codeDisplay`
 * query parameter of the otpauth rawData (see Code.toOTPAuthUrlFormat).
 */
import { UriComponent } from './UriComponent';
import { toError } from '../utils/Errors';

export class CodeDisplay {
  pinned: boolean;
  trashed: boolean;
  lastUsedAt: number;
  tapCount: number;
  tags: string[];
  note: string;
  position: number;
  iconSrc: string;
  iconID: string;

  constructor(pinned: boolean = false, trashed: boolean = false, lastUsedAt: number = 0,
    tapCount: number = 0, tags: string[] = [], note: string = '', position: number = 0,
    iconSrc: string = '', iconID: string = '') {
    this.pinned = pinned;
    this.trashed = trashed;
    this.lastUsedAt = lastUsedAt;
    this.tapCount = tapCount;
    this.tags = tags;
    this.note = note;
    this.position = position;
    this.iconSrc = iconSrc;
    this.iconID = iconID;
  }

  get isCustomIcon(): boolean {
    return this.iconSrc !== '' && this.iconID !== '';
  }

  copyWith(pinned?: boolean, trashed?: boolean, lastUsedAt?: number, tapCount?: number,
    tags?: string[], note?: string, position?: number, iconSrc?: string, iconID?: string): CodeDisplay {
    return new CodeDisplay(
      pinned === undefined ? this.pinned : pinned,
      trashed === undefined ? this.trashed : trashed,
      lastUsedAt === undefined ? this.lastUsedAt : lastUsedAt,
      tapCount === undefined ? this.tapCount : tapCount,
      tags === undefined ? this.tags : tags,
      note === undefined ? this.note : note,
      position === undefined ? this.position : position,
      iconSrc === undefined ? this.iconSrc : iconSrc,
      iconID === undefined ? this.iconID : iconID,
    );
  }

  static fromJsonObject(json: object | undefined | null): CodeDisplay {
    if (json === undefined || json === null) {
      return new CodeDisplay();
    }
    const map: Record<string, Object> = json as Record<string, Object>;
    const getStr = (k: string, def: string): string => {
      const v = map[k];
      return v === undefined || v === null ? def : (v as string);
    };
    const getNum = (k: string, def: number): number => {
      const v = map[k];
      return v === undefined || v === null ? def : (v as number);
    };
    const getBool = (k: string, def: boolean): boolean => {
      const v = map[k];
      return v === undefined || v === null ? def : (v as boolean);
    };
    let tagsArr: string[] = [];
    const tagsV = map['tags'];
    if (tagsV !== undefined && tagsV !== null) {
      tagsArr = (tagsV as string[]).slice();
    }
    return new CodeDisplay(
      getBool('pinned', false),
      getBool('trashed', false),
      getNum('lastUsedAt', 0),
      getNum('tapCount', 0),
      tagsArr,
      getStr('note', ''),
      getNum('position', 0),
      getStr('iconSrc', 'ente'),
      getStr('iconID', ''),
    );
  }

  toJsonObject(): Record<string, Object> {
    return {
      'pinned': this.pinned,
      'trashed': this.trashed,
      'lastUsedAt': this.lastUsedAt,
      'tapCount': this.tapCount,
      'tags': this.tags,
      'note': this.note,
      'position': this.position,
      'iconSrc': this.iconSrc,
      'iconID': this.iconID,
    };
  }

  /** Parses the `codeDisplay` query parameter if present; returns undefined when absent. */
  static fromUri(uri: UriComponent): CodeDisplay | undefined {
    if (!uri.queryParams.has('codeDisplay')) {
      return undefined;
    }
    const codeDisplay: string = (uri.queryParams.get('codeDisplay') as string).replaceAll('%2C', ',');
    return CodeDisplay.parseCodeDisplayJson(codeDisplay);
  }

  static parseCodeDisplayJson(json: string): CodeDisplay {
    try {
      const decoded: object = JSON.parse(json) as object;
      return CodeDisplay.fromJsonObject(decoded);
    } catch (e) {
      // Ignore legacy codeDisplay JSON followed by an unescaped URL fragment.
      if (!json.endsWith('}') && json.includes('}#')) {
        return new CodeDisplay();
      }
      throw toError(e);
    }
  }

  equals(o: CodeDisplay): boolean {
    if (this === o) {
      return true;
    }
    if (o === undefined || o === null) {
      return false;
    }
    if (this.pinned !== o.pinned || this.trashed !== o.trashed ||
      this.lastUsedAt !== o.lastUsedAt || this.tapCount !== o.tapCount ||
      this.note !== o.note || this.position !== o.position ||
      this.iconSrc !== o.iconSrc || this.iconID !== o.iconID) {
      return false;
    }
    if (this.tags.length !== o.tags.length) {
      return false;
    }
    for (let i = 0; i < this.tags.length; i++) {
      if (this.tags[i] !== o.tags[i]) {
        return false;
      }
    }
    return true;
  }
}