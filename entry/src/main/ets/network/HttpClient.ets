/**
 * HttpClient — the app's single network layer, mirroring the role of
 * upstream `packages/network` (Network.instance.enteDio) for the auth app:
 *  - base URL = Configuration.getHttpEndpoint() (default https://api.ente.com)
 *  - headers: X-Auth-Token (when logged in), x-request-id (UUID),
 *    X-Client-Version, X-Client-Package: io.ente.auth, User-Agent
 *  - JSON request/response; timeouts; status-code-driven errors.
 *
 * TLS verification stays at the system default (never disabled).
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CryptoBridge } from '../crypto/CryptoBridge';

export const DEFAULT_ENDPOINT: string = 'https://api.ente.com';

export class ApiError extends Error {
  statusCode: number;
  body: string;

  constructor(message: string, statusCode: number, body: string) {
    super(message);
    this.statusCode = statusCode;
    this.body = body;
  }
}

export class UnauthorizedError extends Error {
  constructor() {
    super('UnauthorizedError');
  }
}

/** 404 from the authenticator key endpoint. */
export class AuthenticatorKeyNotFound extends Error {
  constructor() {
    super('AuthenticatorKeyNotFound');
  }
}

export class HttpResult {
  statusCode: number;
  /** Parsed JSON body when content-type is JSON, else raw string. */
  body: object;
  rawText: string;

  constructor(statusCode: number, body: object, rawText: string) {
    this.statusCode = statusCode;
    this.body = body;
    this.rawText = rawText;
  }
}

/**
 * Typed request options holder (implements the SDK interface).
 *
 * `usingCache = false` is deliberate and is NOT the SDK default. NetworkKit
 * documents `usingCache` as:
 *
 *   "Whether to use the cache. The value true indicates that the cache is
 *    preferentially read when a request is initiated, and the value false
 *    indicates that the cache is not used. The default value is true."
 *   — @ohos.net.http.d.ts:136-146 (verified against DevEco SDK 26.0.0.105 and
 *     the HarmonyOS Developer Knowledge MCP, js-apis-http)
 *
 * So the platform default would make every API call prefer a cached response.
 * Nothing in this app's endpoint set is a cacheable static resource: /users/*
 * and /authenticator/* are live, stateful, credential-bearing calls (SRP
 * attributes, 2FA verification, session tokens, sync diffs), where a stale body
 * is a correctness and security hazard. Upstream's Dio clients have no HTTP
 * response cache for these calls either, so `false` is also the parity value.
 *
 * TLS is untouched: caPath / caData / certificatePinning are never set, so the
 * system default trust store continues to apply.
 */
class ReqOptions implements http.HttpRequestOptions {
  method: http.RequestMethod = http.RequestMethod.GET;
  extraData: string | Object | ArrayBuffer | undefined = undefined;
  expectDataType: http.HttpDataType = http.HttpDataType.STRING;
  usingCache: boolean = false;
  priority: number = 0;
  header: Object = new Map<string, string>();
  readTimeout: number = 60000;
  connectTimeout: number = 60000;
  usingProtocol: http.HttpProtocol = http.HttpProtocol.HTTP1_1;
  usingProxy: boolean | http.HttpProxy = false;
}

function uuidV4(): string {
  const b = CryptoBridge.randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const hex: string[] = [];
  for (let i = 0; i < 16; i++) {
    hex.push(b[i].toString(16).padStart(2, '0'));
  }
  return `${hex[0]}${hex[1]}${hex[2]}${hex[3]}-${hex[4]}${hex[5]}-${hex[6]}${hex[7]}-${hex[8]}${hex[9]}-${hex[10]}${hex[11]}${hex[12]}${hex[13]}${hex[14]}${hex[15]}`;
}

export class HttpSession {
  readonly endpoint: string;
  readonly token: string | undefined;
  constructor(endpoint: string, token: string | undefined) { this.endpoint = endpoint; this.token = token; }
}

export class HttpClient {
  /** Callback the interceptor uses to attach the session token. */
  static tokenProvider: () => string | undefined = () => undefined;
  static endpointProvider: () => string = () => DEFAULT_ENDPOINT;
  static packageName: string = 'io.ente.auth';
  static clientVersion: string = '1.0.0';

  static setTokenProvider(p: () => string | undefined): void {
    HttpClient.tokenProvider = p;
  }

  static setEndpointProvider(p: () => string): void {
    HttpClient.endpointProvider = p;
  }

  static async request(method: http.RequestMethod, pathAndQuery: string,
    body?: object, session?: HttpSession): Promise<HttpResult> {
    const endpoint: string = session === undefined ? HttpClient.endpointProvider() : session.endpoint;
    const url: string = endpoint + pathAndQuery;
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'x-request-id': uuidV4(),
      'X-Client-Version': HttpClient.clientVersion,
      'X-Client-Package': HttpClient.packageName,
      'User-Agent': `ente-auth-harmony/${HttpClient.clientVersion}`,
    };
    const token = session === undefined ? HttpClient.tokenProvider() : session.token;
    if (token !== undefined && token !== null && token.length > 0) {
      headers['X-Auth-Token'] = token;
    }
    const req = http.createHttp();
    try {
      const options: ReqOptions = new ReqOptions();
      options.method = method;
      options.header = headers;
      options.connectTimeout = 15000;
      options.readTimeout = 60000;
      if (body !== undefined) {
        options.extraData = JSON.stringify(body);
      }
      const resp = await req.request(url, options);
      const status = resp.responseCode;
      let rawText = '';
      if (typeof resp.result === 'string') {
        rawText = resp.result;
      } else if (resp.result !== undefined) {
        rawText = resp.result.toString();
      }
      let parsed: Record<string, Object> = {};
      if (rawText.length > 0) {
        try {
          parsed = JSON.parse(rawText) as Record<string, Object>;
        } catch (e) {
          const rawObj: Record<string, Object> = {};
          rawObj['__raw'] = rawText;
          parsed = rawObj;
        }
      }
      return new HttpResult(status, parsed, rawText);
    } finally {
      req.destroy();
    }
  }

  static async get(pathAndQuery: string, session?: HttpSession): Promise<HttpResult> {
    return HttpClient.request(http.RequestMethod.GET, pathAndQuery, undefined, session);
  }

  /**
   * `body` is optional so a request can be sent with NO body at all, matching
   * upstream call sites that pass none (e.g. `POST /users/logout`). When it is
   * omitted, `extraData` stays undefined and nothing is written to the wire.
   */
  static async post(path: string, body?: object, session?: HttpSession): Promise<HttpResult> {
    return HttpClient.request(http.RequestMethod.POST, path, body, session);
  }

  static async put(path: string, body?: object): Promise<HttpResult> {
    return HttpClient.request(http.RequestMethod.PUT, path, body);
  }

  static async delete(pathAndQuery: string): Promise<HttpResult> {
    return HttpClient.request(http.RequestMethod.DELETE, pathAndQuery);
  }
}

/** Whether the server rejected the session (HTTP 401). */
export function isUnauthorized(statusCode: number): boolean {
  return statusCode === 401;
}