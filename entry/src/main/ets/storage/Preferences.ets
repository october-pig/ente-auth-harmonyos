/**
 * Preferences — small wrapper over HarmonyOS `preferences` (ArkData),
 * mirroring the shared_preferences usage of upstream `services/` and
 * `core/configuration.dart`. All keys and types match upstream.
 *
 * The reserved secstore: namespace holds SecureStore's wrapped ciphertext.
 * Ordinary preference clearing must never delete that secure-storage domain.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREFS_NAME = 'ente_auth_preferences';

export class Preferences {
  private static store: preferences.Preferences | undefined = undefined;

  static async init(context: common.Context): Promise<void> {
    if (Preferences.store === undefined) {
      Preferences.store = await preferences.getPreferences(context, PREFS_NAME);
    }
  }

  private static requireStore(): preferences.Preferences {
    if (Preferences.store === undefined) {
      throw new Error('Preferences not initialized');
    }
    return Preferences.store;
  }

  static async getString(key: string): Promise<string | undefined> {
    const v = await Preferences.requireStore().get(key, '');
    if (v === '') {
      return undefined;
    }
    return v as string;
  }

  static async getStringOr(key: string, def: string): Promise<string> {
    const v = await Preferences.requireStore().get(key, def);
    return v as string;
  }

  static async setString(key: string, value: string): Promise<void> {
    await Preferences.requireStore().put(key, value);
    await Preferences.requireStore().flush();
  }

  static async getInt(key: string): Promise<number | undefined> {
    const v = await Preferences.requireStore().get(key, -1);
    if ((v as number) === -1) {
      return undefined;
    }
    return v as number;
  }

  static async getIntOr(key: string, def: number): Promise<number> {
    const v = await Preferences.requireStore().get(key, def);
    return v as number;
  }

  static async setInt(key: string, value: number): Promise<void> {
    await Preferences.requireStore().put(key, value);
    await Preferences.requireStore().flush();
  }

  static async getBool(key: string): Promise<boolean> {
    const v = await Preferences.requireStore().get(key, false);
    return v as boolean === true;
  }

  static async setBool(key: string, value: boolean): Promise<void> {
    await Preferences.requireStore().put(key, value);
    await Preferences.requireStore().flush();
  }

  static async remove(key: string): Promise<void> {
    await Preferences.requireStore().delete(key);
    await Preferences.requireStore().flush();
  }

  static async has(key: string): Promise<boolean> {
    return Preferences.requireStore().has(key);
  }

  static async clear(): Promise<void> {
    const store = Preferences.requireStore();
    const keys: string[] = Object.keys(await store.getAll());
    for (const key of keys) {
      if (!key.startsWith('secstore:')) {
        await store.delete(key);
      }
    }
    // No clear-and-restore window: a crash cannot erase unrelated secure blobs.
    await store.flush();
  }
}
