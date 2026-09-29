/**
 * Wire/DB entities mirroring upstream
 * `mobile/apps/auth/lib/models/authenticator/*.dart`.
 * JSON key names match upstream toMap() exactly.
 */

/** AuthEntity — a remote diff/entity row (upstream models/authenticator/auth_entity.dart). */
export class AuthEntity {
  id: string;
  /** Null for deleted diff entries. */
  encryptedData: string | undefined;
  header: string | undefined;
  isDeleted: boolean;
  createdAt: number;
  updatedAt: number;

  constructor(id: string, encryptedData: string | undefined, header: string | undefined,
    isDeleted: boolean, createdAt: number, updatedAt: number) {
    this.id = id;
    this.encryptedData = encryptedData;
    this.header = header;
    this.isDeleted = isDeleted;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
  }

  toMap(): object {
    const m: Record<string, Object> = {};
    m['id'] = this.id;
    m['encryptedData'] = this.encryptedData === undefined ? '' : this.encryptedData;
    m['header'] = this.header === undefined ? '' : this.header;
    m['isDeleted'] = this.isDeleted;
    m['createdAt'] = this.createdAt;
    m['updatedAt'] = this.updatedAt;
    return m;
  }

  static fromMap(map: object): AuthEntity {
    const m: Record<string, Object> = map as Record<string, Object>;
    const getStr = (k: string): string | undefined => {
      const v = m[k];
      return v === undefined || v === null ? undefined : (v as string);
    };
    const getNum = (k: string): number => {
      const v = m[k];
      return v === undefined ? 0 : (v as number);
    };
    return new AuthEntity(
      getStr('id') as string,
      getStr('encryptedData'),
      getStr('header'),
      m['isDeleted'] as boolean === true,
      getNum('createdAt'),
      getNum('updatedAt'),
    );
  }
}

/** LocalAuthEntity — a local DB row (upstream models/authenticator/local_auth_entity.dart). */
export class LocalAuthEntity {
  generatedID: number;
  /** Null for scanned codes that have not reached the server. */
  id: string | undefined;
  encryptedData: string;
  header: string;
  /** Local timestamps until remote sync completes (microseconds). */
  createdAt: number;
  updatedAt: number;
  /** True for local changes awaiting remote sync. */
  shouldSync: boolean;

  constructor(generatedID: number, id: string | undefined, encryptedData: string,
    header: string, createdAt: number, updatedAt: number, shouldSync: boolean) {
    this.generatedID = generatedID;
    this.id = id;
    this.encryptedData = encryptedData;
    this.header = header;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
    this.shouldSync = shouldSync;
  }

  copyWith(generatedID?: number, id?: string, encryptedData?: string, header?: string,
    createdAt?: number, updatedAt?: number, shouldSync?: boolean): LocalAuthEntity {
    return new LocalAuthEntity(
      generatedID === undefined ? this.generatedID : generatedID,
      id === undefined ? this.id : id,
      encryptedData === undefined ? this.encryptedData : encryptedData,
      header === undefined ? this.header : header,
      createdAt === undefined ? this.createdAt : createdAt,
      updatedAt === undefined ? this.updatedAt : updatedAt,
      shouldSync === undefined ? this.shouldSync : shouldSync,
    );
  }

  toMap(): object {
    const m: Record<string, Object> = {};
    m['_generatedID'] = this.generatedID;
    m['id'] = this.id === undefined ? '' : this.id;
    m['encryptedData'] = this.encryptedData;
    m['header'] = this.header;
    m['createdAt'] = this.createdAt;
    m['updatedAt'] = this.updatedAt;
    m['shouldSync'] = this.shouldSync ? 1 : 0;
    return m;
  }

  static fromMap(map: object): LocalAuthEntity {
    const m: Record<string, Object> = map as Record<string, Object>;
    const getNum = (k: string): number => {
      const v = m[k];
      return v === undefined ? 0 : (v as number);
    };
    const rawId = m['id'];
    const idStr: string | undefined = rawId === undefined || rawId === null ? undefined : (rawId as string);
    const rawSync = m['shouldSync'];
    const shouldSync: boolean = rawSync === undefined ? false : !((rawSync as number) === 0);
    return new LocalAuthEntity(
      getNum('_generatedID'),
      idStr,
      m['encryptedData'] as string,
      m['header'] as string,
      getNum('createdAt'),
      getNum('updatedAt'),
      shouldSync,
    );
  }
}

/** AuthKey — encrypted authenticator key from the server. */
export class AuthKey {
  userID: number;
  encryptedKey: string;
  header: string;
  createdAt: number;
  updatedAt: number;

  constructor(userID: number, encryptedKey: string, header: string, createdAt: number,
    updatedAt: number) {
    this.userID = userID;
    this.encryptedKey = encryptedKey;
    this.header = header;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
  }

  static fromMap(map: object): AuthKey {
    const m: Record<string, Object> = map as Record<string, Object>;
    const getNum = (k: string): number => {
      const v = m[k];
      return v === undefined ? 0 : (v as number);
    };
    return new AuthKey(
      getNum('userID'),
      m['encryptedKey'] as string,
      m['header'] as string,
      getNum('createdAt'),
      getNum('updatedAt'),
    );
  }
}

/** EntityResult — decrypted entity (upstream models/authenticator/entity_result.dart). */
export class EntityResult {
  generatedID: number;
  rawData: string;
  hasSynced: boolean;

  constructor(generatedID: number, rawData: string, hasSynced: boolean) {
    this.generatedID = generatedID;
    this.rawData = rawData;
    this.hasSynced = hasSynced;
  }
}