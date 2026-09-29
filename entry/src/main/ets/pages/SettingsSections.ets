/** Pushed native Settings destinations; account and persistence services remain unchanged. */
import { promptAction } from '@kit.ArkUI';
import { PreferenceService } from '../services/PreferenceService';
import { S } from '../app/AppStrings';
import { Router } from './Router';
import { UserService } from '../account/UserService';
import { Toast } from '../utils/Toast';

@Component
export struct SettingsSection {
  @Prop accountConfigured: boolean = false;
  onNavigate: (route: string) => void = (route: string) => { Router.push(route, undefined); };
  @State logoutBusy: boolean = false;
  @State hideCodes: boolean = false;
  @State hideCodesDraft: boolean = false;
  @State hideCodesSaving: boolean = false;

  aboutToAppear(): void {
    PreferenceService.shouldHideCodes().then((v) => {
      this.hideCodes = v;
      if (!this.hideCodesSaving) { this.hideCodesDraft = v; }
    });
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        SectionTitle({ title: S.general() })
        // Clip the group contour, including child press effects and gestures
        // outside its rounded corners (ArkUI clip(boolean) contract).
        Column() {
          SettingToggle({
            label: S.hideCodes(),
            value: this.hideCodesDraft,
            toggleEnabled: !this.hideCodesSaving,
            onChange: async (v: boolean) => {
              if (this.hideCodesSaving || v === this.hideCodesDraft) {
                return;
              }
              // Set the UI draft before the busy flag can redraw this component.
              // Otherwise native isOn is reset to the old value and fires a
              // second, opposite onChange even while the switch is disabled.
              this.hideCodesDraft = v;
              this.hideCodesSaving = true;
              try {
                await PreferenceService.setShouldHideCodes(v);
                this.hideCodes = v;
              } catch (e) {
                this.hideCodesDraft = this.hideCodes;
                Toast.show(S.settingsSaveFailed());
              } finally {
                this.hideCodesSaving = false;
              }
            },
          })


          SettingRow({ label: S.appearance(), onTap: () => { this.onNavigate('settings-appearance'); } })
        }.borderRadius(20).clip(true).backgroundColor($r('app.color.surface'))
        SectionTitle({ title: S.settings() })
        Column() {
          SettingRow({ label: S.security(), onTap: () => { this.onNavigate('settings-security'); } })
          SettingRow({ label: S.data(), onTap: () => { this.onNavigate('settings-data'); } })
          if (this.accountConfigured) {
            SettingRow({ label: S.accountSection(), onTap: () => { this.onNavigate('settings-account'); } })
          }
          SettingRow({ label: S.about(), onTap: () => { this.onNavigate('settings-about'); } })
        }.borderRadius(20).clip(true).backgroundColor($r('app.color.surface'))
        SectionTitle({ title: S.accountSection() })
        Column() {
          if (this.accountConfigured) {
            SettingRow({ label: S.logout(), color: $r('app.color.danger'), rowEnabled: !this.logoutBusy,
              onTap: () => { this.logout(); } })
          } else {
            SettingRow({ label: S.login(), color: $r('app.color.accent'),
              onTap: () => { Router.goToOnboardingRoot(); } })
          }
        }.borderRadius(20).clip(true).backgroundColor($r('app.color.surface'))
        Text(S.unofficialPort()).fontSize(13).fontColor($r('sys.color.ohos_id_color_secondary'))
          .width('100%').padding({ top: 12, bottom: 16 })
      }.padding(16).width('100%').constraintSize({ maxWidth: 720 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }

  private async logout(): Promise<void> {
    if (this.logoutBusy) { return; }
    this.logoutBusy = true;
    try {
      await UserService.logout();
    } catch (e) {
      await promptAction.showDialog({ title: S.logoutFailed(), message: (e as Error).message,
        buttons: [{ text: S.understood(), color: $r('app.color.accent') }] });
    } finally { this.logoutBusy = false; }
  }
}


@Component
export struct SettingsDetail {
  @Prop section: string = '';
  @Prop accountConfigured: boolean = false;
  onNavigate: (route: string) => void = (route: string) => { Router.push(route, undefined); };

  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.section === 'settings-data') {
          Column() {
            SettingRow({ label: S.import(), onTap: () => { this.onNavigate('import'); } })
            SettingRow({ label: S.export(), onTap: () => { this.onNavigate('export'); } })
            SettingRow({ label: S.duplicateCodes(), onTap: () => { this.onNavigate('duplicates'); } })
          }.backgroundColor($r('app.color.surface')).borderRadius(20).clip(true)
          DeferredRow({ label: S.localBackups() })
        } else if (this.section === 'settings-security') {
          DeferredRow({ label: S.appLock() })
          if (this.accountConfigured) {
            DeferredRow({ label: S.emailVerification() })
            DeferredRow({ label: S.passkeys() })
            DeferredRow({ label: S.activeSessions() })
          }
          Text(S.appLockNotEnabledDescription()).fontSize(14).fontColor($r('sys.color.ohos_id_color_secondary'))
        } else if (this.section === 'settings-account') {
          DeferredRow({ label: S.changeEmail() })
          DeferredRow({ label: S.changePassword() })
          DeferredRow({ label: S.recoveryKeyTitle() })
          DeferredRow({ label: S.deleteAccount() })
        } else if (this.section === 'settings-appearance') {
          Column() {
            SettingRow({ label: S.language(), detail: S.systemTheme(),
              onTap: () => { this.explain(S.language(), S.languageMilestone()); } })
            SettingRow({ label: S.theme(), detail: S.systemTheme(),
              onTap: () => { this.explain(S.theme(), S.themeMilestone()); } })
          }.backgroundColor($r('app.color.surface')).borderRadius(20).clip(true)
        } else {
          Image($r('app.media.ente_auth')).width(88).height(88).borderRadius(22).margin({ top: 24 })
          Text(S.appName()).fontSize(28).fontWeight(FontWeight.Bold)
          Text(S.aboutVersion()).fontSize(14).fontColor($r('sys.color.ohos_id_color_secondary'))
          Text(S.unofficialPort()).fontSize(16).textAlign(TextAlign.Center).margin({ top: 12 })
          Text('github.com/october-pig/ente-auth-harmonyos').fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_secondary')).textAlign(TextAlign.Center)
        }
      }.width('100%').constraintSize({ maxWidth: 720 }).padding(16)
    }.height('100%').width('100%').scrollBar(BarState.Off)
  }

  private explain(title: string, message: string): void {
    promptAction.showDialog({ title: title, message: message,
      buttons: [{ text: S.understood(), color: $r('app.color.accent') }] });
  }
}

@Component
struct DeferredRow {
  @Prop label: string = '';
  build() {
    SettingRow({ label: this.label, detail: S.futureFeature(), onTap: () => {
      promptAction.showDialog({ title: this.label, message: S.futureFeatureDetail(),
        buttons: [{ text: S.understood(), color: $r('app.color.accent') }] });
    } }).backgroundColor($r('app.color.surface')).borderRadius(20).clip(true)
  }
}

@Component
struct SectionTitle {
  @Prop title: string = '';
  build() {
    Text(this.title).fontSize(14).fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.ohos_id_color_secondary')).width('100%').padding({ left: 16, top: 12 })
  }
}

@Component
struct SettingRow {
  @Prop label: string = '';
  @Prop detail: string = '';
  @Prop color: ResourceColor = $r('sys.color.ohos_id_color_primary');
  @Prop rowEnabled: boolean = true;
  onTap: () => void = () => {};
  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.label).fontSize(16).fontColor(this.color).width('100%')
          if (this.detail.length > 0) {
            Text(this.detail).fontSize(13).fontColor($r('sys.color.ohos_id_color_secondary')).width('100%')
          }
        }.layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16)
          .fontColor([$r('sys.color.ohos_id_color_tertiary')])
      }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 })
    }.width('100%').constraintSize({ minHeight: 56 }).backgroundColor(Color.Transparent)
      .enabled(this.rowEnabled).onClick(() => { this.onTap(); })
  }
}

@Component
struct SettingToggle {
  label: string = '';
  /**
   * The VALUE IS THE PARENT'S. This used to be `initValue: boolean` copied into a
   * local `@State` in `aboutToAppear()`. The parent loads the persisted value
   * ASYNCHRONOUSLY, so the copy always happened first and captured the default
   * `false`; when the real value arrived there was no path to the child. The
   * switch therefore always rendered OFF and could never reflect the stored
   * preference (finding T).
   *
   * `@Prop` makes it a one-way reactive input: when the parent's state changes,
   * this re-renders. There is no second copy to drift.
   */
  @Prop value: boolean = false;
  @Prop toggleEnabled: boolean = true;
  onChange: (v: boolean) => void = (v: boolean) => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor($r('sys.color.ohos_id_color_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .enabled(this.toggleEnabled)
        .onChange((v: boolean) => {
          if (!this.toggleEnabled || v === this.value) {
            return;
          }
          this.onChange(v);
        })
    }
    .width('100%')
    .height(50)
    .padding({ left: 16, right: 16 })
  }
}
