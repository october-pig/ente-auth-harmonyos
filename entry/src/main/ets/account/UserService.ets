/**
 * UserService — account login/signup/session endpoints, mirroring the
 * upstream `packages/accounts` UserService as used by the auth app.
 *
 * Endpoint specifics (exact request/response fields) captured from
 * `ente@3cc9103a3126de07f79a4465cf0b9922903de54b`.
 */
import { Configuration } from './Configuration';
import { HttpClient, HttpResult, HttpSession, DEFAULT_ENDPOINT, UnauthorizedError } from '../network/HttpClient';
import { CryptoUtil } from '../crypto/CryptoUtil';
import { KeyAttributes, KeyGenResult, SetKeysRequest } from '../models/KeyAttributes';
import { Srp, SrpCredentials } from './Srp';
import { CryptoBridge } from '../crypto/CryptoBridge';
import { Preferences } from '../storage/Preferences';
import { toError } from '../utils/Errors';

/**
 * Raised by `getSrpAttributes` when the server has no SRP credentials for the
 * account — upstream `SrpSetupNotCompleteError` (models/errors.dart), produced
 * only by a 404 (user_service.dart:623-627).
 *
 * `name` is set explicitly so the type survives transpilation and can be
 * identified even if `instanceof` is unavailable in a given runtime.
 */
export class SrpSetupNotCompleteError extends Error {
  constructor() {
    super('SrpSetupNotCompleteError');
    this.name = 'SrpSetupNotCompleteError';
  }
}

export class SrpAttributes {
  srpUserID: string;
  srpSalt: string;
  memLimit: number;
  opsLimit: number;
  kekSalt: string;
  isEmailMFAEnabled: boolean;

  constructor(srpUserID: string, srpSalt: string, memLimit: number, opsLimit: number,
    kekSalt: string, isEmailMFAEnabled: boolean) {
    this.srpUserID = srpUserID;
    this.srpSalt = srpSalt;
    this.memLimit = memLimit;
    this.opsLimit = opsLimit;
    this.kekSalt = kekSalt;
    this.isEmailMFAEnabled = isEmailMFAEnabled;
  }

  static fromMap(map: object): SrpAttributes {
    const m: Record<string, Object> = map as Record<string, Object>;
    const attrs = m['attributes'] as Record<string, Object>;
    const gs = (k: string, def: string): string => {
      const v = attrs[k];
      return v === undefined ? def : (v as string);
    };
    const gn = (k: string, def: number): number => {
      const v = attrs[k];
      return v === undefined ? def : (v as number);
    };
    return new SrpAttributes(
      gs('srpUserID', ''), gs('srpSalt', ''), gn('memLimit', 0), gn('opsLimit', 0),
      gs('kekSalt', ''), attrs['isEmailMFAEnabled'] as boolean === true);
  }
}

export class LoginResponse {
  /** Local provenance only; never part of the Ente wire payload. */
  accountRevision: number | undefined = undefined;
  id: number = 0;
  encryptedToken: string | undefined = undefined;
  keyAttributes: KeyAttributes | undefined = undefined;
  token: string | undefined = undefined;
  passkeySessionID: string = '';
  twoFactorSessionID: string = '';
  accountsUrl: string | undefined = undefined;

  constructor() {
  }
}

/**
 * What a successful login response requires next.
 *
 * A state-machine decision, not a UI detail — so it lives here, where the host
 * tests can execute it, instead of being re-derived inside a page.
 */
export enum PostLoginStep {
  /** Passkey verification — still PARTIAL in this port; never a silent bypass. */
  passkey = 0,
  /** TOTP two-factor — route to the 2FA page with the session id. */
  twoFactor = 1,
  /** No further verification — persist the session. */
  complete = 2,
}

export class UserService {
  private static instanceValue: UserService | undefined = undefined;

  static get instance(): UserService {
    if (UserService.instanceValue === undefined) {
      UserService.instanceValue = new UserService();
    }
    return UserService.instanceValue;
  }

  private constructor() {
  }

  /** POST /users/ott — request verification code. */
  static async sendOtt(email: string, purpose: string, isMobile: boolean): Promise<void> {
    const body: Record<string, Object> = {
      'email': email,
      'purpose': purpose,
      'mobile': isMobile,
    };
    const result: HttpResult = await HttpClient.post('/users/ott', body);
    if (result.statusCode >= 400) {
      throw UserService.mapOttError(result);
    }
  }

  private static mapOttError(result: HttpResult): Error {
    const body = result.body as Record<string, Object>;
    const code = body['code'] as string;
    if (code === 'USER_ALREADY_REGISTERED') {
      return new Error('Email already registered.');
    } else if (code === 'USER_NOT_REGISTERED') {
      return new Error('Email not registered.');
    } else if (code === 'USER_SIGNUP_INCOMPLETE') {
      return new Error('Account setup incomplete. Create account to finish setup.');
    }
    if (result.statusCode === 403) {
      return new Error('This email is already in use.');
    }
    return new Error(`sendOtt failed with status ${result.statusCode}`);
  }

  /** POST /users/verify-email. */
  static async verifyEmail(email: string, ott: string, source: string | undefined): Promise<LoginResponse> {
    const revision = Configuration.instance.getAccountRevision();
    Configuration.instance.assertRevision(revision);
    const body: Record<string, Object> = {
      'email': email,
      'ott': ott,
    };
    if (source !== undefined) {
      body['source'] = source;
    }
    const result: HttpResult = await HttpClient.post('/users/verify-email', body);
    if (result.statusCode !== 200) {
      throw new Error(`verify-email failed with status ${result.statusCode}`);
    }
    return UserService.parseLoginResponse(result, revision);
  }

  /** GET /users/srp/attributes. */
  static async getSrpAttributes(email: string, session?: HttpSession): Promise<SrpAttributes> {
    const result: HttpResult = await HttpClient.get(`/users/srp/attributes?email=${encodeURIComponent(email)}`, session);
    if (result.statusCode === 200) {
      return SrpAttributes.fromMap(result.body);
    }
    if (result.statusCode === 404) {
      throw new SrpSetupNotCompleteError();
    }
    throw new Error(`get-srp-attributes action failed: ${result.statusCode}`);
  }

  /**
   * Retry SRP setup for an account whose signup completed but whose SRP
   * registration failed — the port of upstream `_registerSRPForExistingUsers`
   * (password_reentry_page.dart:190-208).
   *
   * The branch is the whole point and must not be widened:
   *
   *   getSrpAttributes(email)
   *     404 / SrpSetupNotCompleteError  -> register exactly once
   *     any other failure               -> DO NOT register, warn, return
   *     success                         -> DO NOT register
   *
   * A catch-all that treated every error as "SRP is missing" would fire a
   * registration on a transient 500 and could overwrite working credentials.
   * Registration failure is swallowed with a non-secret warning and must never
   * disturb the login session that has already succeeded.
   */
  static async registerSrpForExistingUsers(email: string, kek: Uint8Array): Promise<void> {
    const config = Configuration.instance;
    const revision = config.getAccountRevision();
    if (!config.isAccountWorkAllowed() || config.getEmail() !== email) { return; }
    const session = new HttpSession(config.getHttpEndpoint(), config.getToken());
    let shouldSetupSrp: boolean = false;
    try {
      await UserService.getSrpAttributes(email, session);
    } catch (e) {
      if (e instanceof SrpSetupNotCompleteError) {
        shouldSetupSrp = true;
      } else {
        // Unexpected failure: upstream logs and leaves shouldSetupSRP false.
        console.warn('error while fetching srp attributes');
        return;
      }
    }
    if (!shouldSetupSrp || revision !== config.getAccountRevision() || !config.isAccountWorkAllowed()) {
      return;
    }
    try {
      const loginKey: Uint8Array = await CryptoUtil.deriveLoginKey(kek);
      config.assertAccountWork(revision);
      await UserService.registerOrUpdateSrp(loginKey, undefined, false, revision, session);
    } catch (e) {
      // Non-blocking by design: the user is already logged in.
      console.warn('error while setting up srp for existing users');
    }
  }

  /** Full SRP password login (email + password → session). */
  static async loginWithPassword(email: string, userPassword: string,
    attrs: SrpAttributes): Promise<LoginResponse> {
    const revision = Configuration.instance.getAccountRevision();
    Configuration.instance.assertRevision(revision);
    const kek: Uint8Array = await CryptoUtil.deriveKey(
      CryptoUtil.strToBin(userPassword), CryptoUtil.base642bin(attrs.kekSalt),
      attrs.memLimit, attrs.opsLimit);
    const loginKey: Uint8Array = await CryptoUtil.deriveLoginKey(kek);
    const identity: Uint8Array = CryptoUtil.strToBin(attrs.srpUserID);
    const salt: Uint8Array = CryptoUtil.base642bin(attrs.srpSalt);
    const creds: SrpCredentials = await Srp.generateCredentials(salt, identity, loginKey,
      () => CryptoBridge.randomBytes(32));
    const A = Srp.getPadded(creds.A, 512);
    const createBodyReq: Record<string, Object> = {
      'srpUserID': attrs.srpUserID,
      'srpA': CryptoUtil.bin2base64(A),
    };
    Configuration.instance.assertRevision(revision);
    const create = await HttpClient.post('/users/srp/create-session', createBodyReq);
    if (create.statusCode !== 200) {
      if (create.statusCode === 401) {
        throw new Error('Incorrect password');
      }
      throw new Error(`create-session failed with status ${create.statusCode}`);
    }
    const createBody: Record<string, Object> = create.body as Record<string, Object>;
    const sessionID: string = createBody['sessionID'] as string;
    // Upstream reduces and validates B inside SRP6Client.calculateSecret
    // (srp6_client.dart:57-63 -> srp6_util.dart:69-78) and then computes u and
    // M1 from the REDUCED value. The reduction is therefore done once, here, and
    // the same validated value feeds both calculateSecret and calculateM1.
    const serverB: bigint = Srp.validatePublicValue(
      Srp.decodeBigInt(CryptoUtil.base642bin(createBody['srpB'] as string)));
    const S: bigint = await Srp.calculateSecret(serverB, creds.A, creds.a, creds.x);
    const M1: bigint = await Srp.calculateM1(creds.A, serverB, S);
    const verifyBodyReq: Record<string, Object> = {
      'sessionID': sessionID,
      'srpUserID': attrs.srpUserID,
      'srpM1': CryptoUtil.bin2base64(Srp.getPadded(M1, 32)),
    };
    Configuration.instance.assertRevision(revision);
    const verify = await HttpClient.post('/users/srp/verify-session', verifyBodyReq);
    if (verify.statusCode !== 200) {
      if (verify.statusCode === 401) {
        throw new Error('Incorrect password. Please try again');
      }
      throw new Error(`verify-session failed with status ${verify.statusCode}`);
    }
    return UserService.parseLoginResponse(verify, revision);
  }

  /**
   * THE canonical LoginResponse parser. Every login-shaped response goes through
   * this one function — OTT verify-email, SRP verify-session and 2FA verify.
   * There is deliberately no second parser and the UI never builds the DTO
   * itself; duplicating this logic is what caused finding B.
   *
   * Mirrors upstream `_saveConfiguration`'s field selection
   * (user_service.dart:1129-1144) plus the session-id selection that upstream
   * performs at each call site (e.g. :433-438, :775-780):
   *   - `keyAttributes` is read ONLY when `encryptedToken` is present;
   *   - `twoFactorSessionIDV2` is used only when `twoFactorSessionID` is empty.
   */
  private static parseLoginResponse(result: HttpResult, revision: number): LoginResponse {
    Configuration.instance.assertRevision(revision);
    const m: Record<string, Object> = result.body as Record<string, Object>;
    const gs = (k: string): string | undefined => {
      const v = m[k];
      return v === undefined || v === null ? undefined : (v as string);
    };
    const encToken = gs('encryptedToken');
    const response: LoginResponse = new LoginResponse();
    response.accountRevision = revision;
    response.id = (m['id'] as number) ?? 0;
    response.encryptedToken = encToken;
    if (encToken !== undefined) {
      const rawKeyAttributes = m['keyAttributes'];
      response.keyAttributes = rawKeyAttributes === undefined || rawKeyAttributes === null
        ? undefined
        : KeyAttributes.fromMap(rawKeyAttributes as object);
    }
    response.token = gs('token');
    response.passkeySessionID = (gs('passkeySessionID') as string) ?? '';
    const twoFa: string = (gs('twoFactorSessionID') as string) ?? '';
    response.twoFactorSessionID = twoFa.length > 0 ? twoFa : ((gs('twoFactorSessionIDV2') as string) ?? '');
    response.accountsUrl = gs('accountsUrl');
    return response;
  }

  /**
   * POST /users/two-factor/verify — mirrors upstream `verifyTwoFactor`
   * (user_service.dart:872-899), which posts the code and then runs the SHARED
   * `_saveConfiguration` parser.
   *
   * The UI must call this rather than posting the endpoint itself: the previous
   * implementation built a `LoginResponse` by hand in `TwoFactorPage.verify2fa()`
   * and omitted `keyAttributes`, so `saveLoginResponse` cleared the account's
   * key attributes on a SUCCESSFUL 2FA login (finding B).
   */
  static async verifyTwoFactor(sessionID: string, code: string): Promise<LoginResponse> {
    const revision = Configuration.instance.getAccountRevision();
    Configuration.instance.assertRevision(revision);
    const body: Record<string, Object> = {
      'sessionID': sessionID,
      'code': code,
    };
    const result: HttpResult = await HttpClient.post('/users/two-factor/verify', body);
    if (result.statusCode === 404) {
      throw new Error('Session expired');
    }
    if (result.statusCode !== 200) {
      throw new Error(`two-factor verify failed with status ${result.statusCode}`);
    }
    return UserService.parseLoginResponse(result, revision);
  }

  /**
   * Decide whether an email can go straight to SRP password login, or must fall
   * back to the OTT (e-mail code) flow.
   *
   * Mirrors upstream `LoginPage.onPressed` (login_page.dart:30-60) EXACTLY:
   *
   *   - a 404 (`SrpSetupNotCompleteError`) leaves the attributes null and falls
   *     through to OTT;
   *   - ANY other failure — network error, 500, malformed body — ALSO leaves the
   *     attributes null and falls through to OTT. Upstream does not rethrow; it
   *     only logs when the error is not `SrpSetupNotCompleteError`.
   *
   * So the broad fallback is upstream parity, not a bug (finding M). What was
   * missing was the diagnostic: the previous revision had an empty catch and
   * silently discarded every non-404 failure. That is restored here, as a
   * non-secret warning.
   *
   * The decision lives in the service rather than in the page so the state
   * machine can actually be executed by the host tests.
   *
   * @returns the attributes when SRP login is possible, otherwise `undefined`.
   */
  static async resolveSrpAttributesForLogin(email: string): Promise<SrpAttributes | undefined> {
    let attrs: SrpAttributes | undefined = undefined;
    try {
      attrs = await UserService.getSrpAttributes(email);
    } catch (e) {
      if (!(e instanceof SrpSetupNotCompleteError)) {
        // Non-secret diagnostic only. Upstream: `_logger.severe(...)`.
        console.warn('Error getting SRP attributes');
      }
      return undefined;
    }
    // Upstream gates on `attr != null && !isEmailVerificationEnabled`. The extra
    // srpUserID guard is this port's own: an account with no SRP user id cannot
    // complete an SRP exchange, so sending it to the OTT flow is strictly better
    // than routing it into a login that must fail.
    if (attrs.isEmailMFAEnabled || attrs.srpUserID.length === 0) {
      return undefined;
    }
    return attrs;
  }

  /**
   * Which step a successful login response requires next.
   *
   * Mirrors upstream `verifyEmailViaPassword`'s branch order
   * (user_service.dart:782-793): passkey is checked BEFORE two-factor, and the
   * session id is the one the server returned (`twoFactorSessionIDV2` already
   * folded into `twoFactorSessionID` by the parser).
   */
  static postLoginStep(response: LoginResponse): PostLoginStep {
    if (response.passkeySessionID.length > 0) {
      return PostLoginStep.passkey;
    }
    if (response.twoFactorSessionID.length > 0) {
      return PostLoginStep.twoFactor;
    }
    return PostLoginStep.complete;
  }

  /**
   * Persist a parsed login response — the port's `_saveConfiguration`
   * (upstream user_service.dart:1129-1144).
   *
   * Validate before modifying security state. Installation closes admission
   * until password/recovery decryption completes; existing local keys permit
   * only the same user ID. Local response provenance rejects stale login work.
   * Unlike upstream's sequential setters, a malformed response writes nothing.
   */
  static async saveLoginResponse(response: LoginResponse, config: Configuration): Promise<void> {
    if (response.accountRevision !== undefined) { config.assertRevision(response.accountRevision); }
    await config.installLoginResponse(response.id, response.encryptedToken, response.keyAttributes, response.token);
  }

  /**
   * Account setup transaction — the port's `UserService.setAttributes`
   * (upstream user_service.dart:591-610).
   *
   * This is a SINGLE operation and belongs to UserService, not to the UI. The
   * previous revision split it: `PasswordSetPage.completeSignup()` uploaded
   * `/users/attributes` and persisted the attributes BEFORE the recovery key was
   * ever shown, and `RecoveryKeyPage.finishSignup()` persisted the keys and
   * attempted SRP afterwards (finding C).
   *
   * Upstream order, reproduced exactly:
   *   PUT /users/attributes
   *     -> persist master key
   *     -> persist secret key
   *     -> persist keyAttributes
   *     -> try registerOrUpdateSrp(loginKey)      (NON-FATAL, upstream :600-605)
   *
   * Called only after the user has explicitly confirmed the recovery key.
   */
  static async setAttributes(result: KeyGenResult, config: Configuration, expectedRevision?: number): Promise<void> {
    const revision = expectedRevision === undefined ? config.getAccountRevision() : expectedRevision;
    config.assertRevision(revision);
    if (config.hasLocalAccount()) { throw new Error('Account is already configured'); }
    const token = config.getToken();
    try {
      const body: Record<string, Object> = {
        'keyAttributes': result.keyAttributes.toMap(),
      };
      const response: HttpResult = await HttpClient.put('/users/attributes', body);
      if (response.statusCode >= 400) {
        throw new Error(`set-attributes action failed: ${response.statusCode}`);
      }
      await config.installAccountKeys(revision, CryptoUtil.base642bin(result.key),
        CryptoUtil.base642bin(result.secretKey), token, result.keyAttributes);
      try {
        await UserService.registerOrUpdateSrp(result.loginKey);
      } catch (e) {
        // Keys are stored; password reentry after OTT login retries SRP setup.
        // Upstream logs a warning here and continues (user_service.dart:602-605).
        // Non-secret warning only - never the login key or its inputs.
        console.warn('Continuing signup after SRP setup failure');
      }
      config.assertAccountWork(revision);
    } catch (e) {
      throw toError(e);
    }
  }

  /** POST /users/srp/setup + complete (signup) or update (password change). */
  static async registerOrUpdateSrp(loginKey: Uint8Array, setKeysRequest?: SetKeysRequest,
    logOutOtherDevices: boolean = false, expectedRevision?: number, boundSession?: HttpSession): Promise<void> {
    const config = Configuration.instance;
    const revision = expectedRevision === undefined ? config.getAccountRevision() : expectedRevision;
    const session = boundSession === undefined ? new HttpSession(config.getHttpEndpoint(), config.getToken()) : boundSession;
    config.assertAccountWork(revision);
    const srpUserID: string = UserService.uuidV4();
    const salt: Uint8Array = CryptoBridge.randomBytes(16);
    const identity: Uint8Array = CryptoUtil.strToBin(srpUserID);
    const v: bigint = await Srp.generateVerifier(salt, identity, loginKey);
    const creds: SrpCredentials = await Srp.generateCredentials(salt, identity, loginKey,
      () => CryptoBridge.randomBytes(32));
    // Upstream computes x over identity = utf8(srpUserID) and sends the same
    // srpUserID; the server recomputes x identically.
    //
    // ENCODING ASYMMETRY (upstream user_service.dart:660-662) — do not "tidy":
    //   srpVerifier = base64(encodeBigInt(v))        <- MINIMAL, variable length
    //   srpA        = base64(getPadded(A, 512))      <- padded to the group size
    //   isUpdate    = false                          <- HARD-CODED, also on the
    //                                                   password-update path
    const requestBody: Record<string, Object> = {
      'srpUserID': srpUserID,
      'srpSalt': CryptoUtil.bin2base64(salt),
      'srpVerifier': CryptoUtil.bin2base64(Srp.encodeBigInt(v)),
      'srpA': CryptoUtil.bin2base64(Srp.getPadded(creds.A, 512)),
      'isUpdate': false,
    };
    config.assertAccountWork(revision);
    const setup = await HttpClient.post('/users/srp/setup', requestBody, session);
    config.assertAccountWork(revision);
    if (setup.statusCode !== 200) {
      throw new Error('register-srp action failed');
    }
    const setupBody: Record<string, Object> = setup.body as Record<string, Object>;
    const setupID: string = setupBody['setupID'] as string;
    const serverB: bigint = Srp.validatePublicValue(
      Srp.decodeBigInt(CryptoUtil.base642bin(setupBody['srpB'] as string)));
    const S: bigint = await Srp.calculateSecret(serverB, creds.A, creds.a, creds.x);
    const M1: bigint = await Srp.calculateM1(creds.A, serverB, S);
    const srpM1: string = CryptoUtil.bin2base64(Srp.getPadded(M1, 32));
    config.assertAccountWork(revision);
    if (setKeysRequest === undefined) {
      const completeBody: Record<string, Object> = {
        'setupID': setupID,
        'srpM1': srpM1,
      };
      const complete = await HttpClient.post('/users/srp/complete', completeBody, session);
      if (complete.statusCode !== 200) {
        throw new Error('register-srp action failed');
      }
    } else {
      const updateBody: Record<string, Object> = {
        'setupID': setupID,
        'srpM1': srpM1,
        'updatedKeyAttr': setKeysRequest.toMap(),
        'logOutOtherDevices': logOutOtherDevices,
      };
      const update = await HttpClient.post('/users/srp/update', updateBody, session);
      if (update.statusCode !== 200) {
        throw new Error('register-srp action failed');
      }
    }
  }

  /**
   * POST /users/logout, then the LOCAL logout — the complete orchestration, and
   * the port of upstream `UserService.logout` (user_service.dart:284-328).
   *
   * It owns both the decision and the action, so they can never disagree. The
   * previous revision swallowed every failure here and left the Settings UI to
   * call `Configuration.logout()` unconditionally, which meant a production 500
   * or a transport error cleared local state while the SERVER SESSION REMAINED
   * VALID (finding E).
   *
   * Truth table, upstream-exact:
   *
   *   | server outcome              | local logout | error surfaced |
   *   |-----------------------------|--------------|----------------|
   *   | 200                         | yes          | no             |
   *   | 401 (token already invalid) | yes          | no             |
   *   | 5xx / other, production     | NO           | yes (throws)   |
   *   | transport error, production | NO           | yes (throws)   |
   *   | any failure, custom endpoint| yes          | no             |
   *
   * Upstream expresses the 401 test as `e is DioException && e.response
   * ?.statusCode == 401`, because Dio rejects non-2xx. This port's HttpClient
   * returns the status instead of throwing, so the same condition is written on
   * `statusCode` directly.
   */
  private static logoutInFlight: Promise<void> | undefined = undefined;

  static logout(): Promise<void> {
    if (UserService.logoutInFlight !== undefined) { return UserService.logoutInFlight; }
    const promise = UserService.runLogout().finally(() => { UserService.logoutInFlight = undefined; });
    UserService.logoutInFlight = promise;
    return promise;
  }

  private static async runLogout(): Promise<void> {
    const config = Configuration.instance;
    const session = new HttpSession(config.getHttpEndpoint(), config.getToken());
    let lease = config.beginLogout();
    try {
      // Drain admitted local commits before checking, before revoking the token.
      lease = await config.prepareLogout(lease);
      let status: number = 0;
      let transportError: Error | undefined = undefined;
      try {
        const result = await HttpClient.post('/users/logout', undefined, session);
        status = result.statusCode;
      } catch (e) { transportError = toError(e); }
      if (status === 200 || status === 401 || session.endpoint !== DEFAULT_ENDPOINT) {
        await config.logout(lease);
        return;
      }
      if (transportError !== undefined) { throw transportError; }
      throw new Error(`logout failed with status ${status}`);
    } finally { config.finishLogoutTransition(lease); }
  }

  private static uuidV4(): string {
    const b = CryptoBridge.randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex: string[] = [];
    for (let i = 0; i < 16; i++) {
      hex.push(b[i].toString(16).padStart(2, '0'));
    }
    return `${hex[0]}${hex[1]}${hex[2]}${hex[3]}-${hex[4]}${hex[5]}-${hex[6]}${hex[7]}-${hex[8]}${hex[9]}-${hex[10]}${hex[11]}${hex[12]}${hex[13]}${hex[14]}${hex[15]}`;
  }
}