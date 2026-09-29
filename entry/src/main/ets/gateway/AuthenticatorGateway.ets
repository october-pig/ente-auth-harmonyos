/**
 * AuthenticatorGateway — mirror of upstream
 * `mobile/apps/auth/lib/gateway/authenticator.dart`:
 *   POST /authenticator/key, GET /authenticator/key (404 → AuthenticatorKeyNotFound)
 *   POST/PUT/DELETE /authenticator/entity
 *   GET  /authenticator/entity/diff?sinceTime&limit (401 → UnauthorizedError)
 */
import { HttpClient, HttpResult, UnauthorizedError, AuthenticatorKeyNotFound, isUnauthorized } from '../network/HttpClient';
import { AuthEntity, AuthKey } from '../models/AuthenticatorEntities';

export class AuthenticatorGateway {
  static async createKey(encKey: string, header: string): Promise<void> {
    const body: Record<string, Object> = {
      'encryptedKey': encKey,
      'header': header,
    };
    const result: HttpResult = await HttpClient.post('/authenticator/key', body);
    if (result.statusCode >= 400) {
      throw new Error(`createKey failed with status ${result.statusCode}`);
    }
  }

  static async getKey(): Promise<AuthKey> {
    const result: HttpResult = await HttpClient.get('/authenticator/key');
    if (result.statusCode === 404) {
      throw new AuthenticatorKeyNotFound();
    }
    if (result.statusCode >= 400) {
      throw new Error(`getKey failed with status ${result.statusCode}`);
    }
    return AuthKey.fromMap(result.body);
  }

  static async createEntity(encryptedData: string, header: string): Promise<AuthEntity> {
    const body: Record<string, Object> = {
      'encryptedData': encryptedData,
      'header': header,
    };
    const result: HttpResult = await HttpClient.post('/authenticator/entity', body);
    if (result.statusCode >= 400) {
      throw new Error(`createEntity failed with status ${result.statusCode}`);
    }
    return AuthEntity.fromMap(result.body);
  }

  static async updateEntity(id: string, encryptedData: string, header: string): Promise<void> {
    const body: Record<string, Object> = {
      'id': id,
      'encryptedData': encryptedData,
      'header': header,
    };
    const result: HttpResult = await HttpClient.put('/authenticator/entity', body);
    if (result.statusCode >= 400) {
      throw new Error(`updateEntity failed with status ${result.statusCode}`);
    }
  }

  static async deleteEntity(id: string): Promise<void> {
    const result: HttpResult = await HttpClient.delete(`/authenticator/entity?id=${encodeURIComponent(id)}`);
    if (result.statusCode >= 400) {
      throw new Error(`deleteEntity failed with status ${result.statusCode}`);
    }
  }

  /** Returns (entities, serverTimeMicros). */
  static async getDiff(sinceTime: number, limit: number = 500,
    requireCompleteResponse: boolean = false): Promise<[AuthEntity[], number | undefined]> {
    const result: HttpResult = await HttpClient.get(
      `/authenticator/entity/diff?sinceTime=${sinceTime}&limit=${limit}`);
    if (isUnauthorized(result.statusCode)) {
      throw new UnauthorizedError();
    }
    if (result.statusCode >= 400) {
      throw new Error(`getDiff failed with status ${result.statusCode}`);
    }
    const body: Record<string, Object> = result.body as Record<string, Object>;
    const entities: AuthEntity[] = [];
    const diff = body['diff'] as object[];
    // Migration uses this response to authorize irreversible source cleanup.
    // A malformed success body must not masquerade as an empty server account.
    if (requireCompleteResponse && (result.statusCode !== 200 || !Array.isArray(diff))) {
      throw new Error('Invalid migration diff response');
    }
    if (diff !== undefined) {
      for (let i = 0; i < diff.length; i++) {
        if (requireCompleteResponse) {
          const row = diff[i] as Record<string, Object>;
          if (row === null || typeof row['id'] !== 'string' || typeof row['isDeleted'] !== 'boolean' ||
            typeof row['updatedAt'] !== 'number' ||
            (row['isDeleted'] === false &&
              (typeof row['encryptedData'] !== 'string' || typeof row['header'] !== 'string'))) {
            throw new Error('Invalid migration diff entity');
          }
        }
        entities.push(AuthEntity.fromMap(diff[i]));
      }
    }
    let timestamp: number | undefined = undefined;
    const ts = body['timestamp'];
    if (ts !== undefined && ts !== null) {
      timestamp = ts as number;
    }
    return [entities, timestamp];
  }
}
