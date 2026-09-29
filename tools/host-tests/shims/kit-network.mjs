/**
 * kit-network.mjs — host shim for `@kit.NetworkKit` (`http`).
 *
 * Provides `http.createHttp()` with the same shape the port uses, but the
 * actual transport is a programmable in-process handler so tests can simulate
 * 200/401/403/500/timeouts/malformed bodies deterministically. Every request
 * is recorded (method, url, headers, body) so tests can assert on the wire
 * format without a live server.
 */

export const RequestMethod = Object.freeze({
  OPTIONS: 'OPTIONS',
  GET: 'GET',
  HEAD: 'HEAD',
  POST: 'POST',
  PUT: 'PUT',
  DELETE: 'DELETE',
  TRACE: 'TRACE',
  CONNECT: 'CONNECT',
});

export const HttpDataType = Object.freeze({ STRING: 0, OBJECT: 1, ARRAY_BUFFER: 2 });
export const HttpProtocol = Object.freeze({ HTTP1_1: 0, HTTP2: 1, HTTP3: 2 });

/** Recorded requests, newest last. */
export const requestLog = [];

let handler = async () => ({ responseCode: 200, result: '{}' });

/** Install the transport. handler(req) -> { responseCode, result, header? } */
export function setHttpHandler(fn) {
  handler = fn;
}

export function resetHttp() {
  requestLog.length = 0;
  handler = async () => ({ responseCode: 200, result: '{}' });
}

class HttpRequest {
  constructor() {
    this._destroyed = false;
  }
  async request(url, options = {}) {
    const entry = {
      method: options.method ?? RequestMethod.GET,
      url,
      header: options.header ?? {},
      extraData: options.extraData,
      connectTimeout: options.connectTimeout,
      readTimeout: options.readTimeout,
      // Recorded so tests can assert the production request options against the
      // documented contract. `usingCache` is the SDK default `true` ("the cache
      // is preferentially read when a request is initiated",
      // @ohos.net.http.d.ts:136-146) — an API client must opt OUT of that.
      usingCache: options.usingCache,
      // Recorded so tests can prove TLS stays at the system default.
      caPath: options.caPath,
      caData: options.caData,
      certificatePinning: options.certificatePinning,
    };
    requestLog.push(entry);
    const resp = await handler(entry);
    return {
      responseCode: resp.responseCode,
      result: resp.result,
      header: resp.header ?? {},
      cookies: '',
    };
  }
  destroy() {
    this._destroyed = true;
  }
  on() {}
  off() {}
}

export const http = {
  RequestMethod,
  HttpDataType,
  HttpProtocol,
  createHttp: () => new HttpRequest(),
};

export default { http, RequestMethod, HttpDataType, HttpProtocol };
