import { AbilityConstant, UIAbility, Want, Configuration as AbilityConfiguration, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Preferences } from '../storage/Preferences';
import { AuthenticatorDB } from '../storage/AuthenticatorDB';
import { OfflineAuthenticatorDB } from '../storage/OfflineAuthenticatorDB';
import { Configuration } from '../account/Configuration';
import { PreferenceService } from '../services/PreferenceService';
import { AuthenticatorService } from '../services/AuthenticatorService';
import { S } from '../app/AppStrings';

const DOMAIN = 0x0E41;

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;
  private onAvoidAreaChanged: (data: window.AvoidAreaOptions) => void = (data: window.AvoidAreaOptions) => {
    if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
      AppStorage.setOrCreate<number>('uiStatusTopPx', data.area.topRect.height);
    }
    if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      AppStorage.setOrCreate<number>('uiNavigationBottomPx', data.area.bottomRect.height);
    }
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'EnteAuth', 'Ability onCreate');
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    // Localization must be wired BEFORE any UI string is resolved. The resource
    // manager resolves against the CURRENT system locale, and `base` holds
    // Chinese, so an unmatched locale falls back to Chinese and `en_US` supplies
    // English.
    S.init(this.context.resourceManager);
    // Window presentation only: HDS insets its title; Home independently reserves
    // the same system area for content underneath the overlaid title.
    try {
      this.mainWindow = windowStage.getMainWindowSync();
      await this.mainWindow.setWindowLayoutFullScreen(true);
      const statusArea = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate<number>('uiStatusTopPx', statusArea.topRect.height);
      const area = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate<number>('uiNavigationBottomPx', area.bottomRect.height);
      this.mainWindow.on('avoidAreaChange', this.onAvoidAreaChanged);
      await this.applyWindowTheme(this.context.config);
    } catch (e) {
      hilog.warn(DOMAIN, 'EnteAuth', 'Window appearance setup failed');
    }
    // Bootstrap order mirrors upstream main.dart init sequence.
    try {
      await Preferences.init(this.context);
      await AuthenticatorDB.init(this.context);
      await OfflineAuthenticatorDB.init(this.context);
      await Configuration.instance.init();
      await PreferenceService.init();
      await AuthenticatorService.instance.init();
    } catch (e) {
      hilog.error(DOMAIN, 'EnteAuth', 'Bootstrap failed: %{public}s', String(e));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'EnteAuth', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
    });
  }

  onWindowStageDestroy(): void {
    if (this.mainWindow !== undefined) {
      try {
        this.mainWindow.off('avoidAreaChange', this.onAvoidAreaChanged);
      } catch (e) {
        hilog.warn(DOMAIN, 'EnteAuth', 'Window appearance listener cleanup failed');
      }
      this.mainWindow = undefined;
    }
  }

  onConfigurationUpdate(config: AbilityConfiguration): void {
    this.applyWindowTheme(config).catch(() => {
      hilog.warn(DOMAIN, 'EnteAuth', 'System bar appearance update failed');
    });
  }

  private async applyWindowTheme(config: AbilityConfiguration): Promise<void> {
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) { return; }
    const dark = config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const color = this.context.resourceManager.getColorByNameSync('page');
    mainWindow.setWindowBackgroundColor(`#${(color >>> 0).toString(16).padStart(8, '0')}`);
    await mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000', navigationBarColor: '#00000000',
      isStatusBarLightIcon: dark, isNavigationBarLightIcon: dark,
      statusBarContentColor: dark ? '#FFFFFF' : '#000000',
      navigationBarContentColor: dark ? '#FFFFFF' : '#000000'
    });
  }

  onForeground(): void {
    // Upstream resumes sync when the app returns to foreground.
    if (Configuration.instance.hasConfiguredAccount()) {
      AuthenticatorService.instance.onlineSync();
    }
  }

  onBackground(): void {
  }
}
