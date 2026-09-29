import { Router } from './Router.ets';
import { LoginModeParam } from './PageParams.ets';
import { UserService } from '../account/UserService';

@Component
export struct SessionRecoveryPage {
  @State busy: boolean = false;
  @State error: string = '';

  build() {
    Column({ space: 20 }) {
      Text('需要重新登录').fontSize(24).fontWeight(FontWeight.Bold)
      Text('登录已失效或尚未完成。本机验证码和加密密钥已保留，暂停同步。请重新登录原账户以继续同步，也可以先导出加密备份。')
        .fontSize(16)
      Button('重新登录原账户').width('100%').onClick(() => {
        Router.push('login-email', new LoginModeParam(false));
      })
      Button('导出备份').width('100%').onClick(() => { Router.push('export', undefined); })
      Button('退出登录').width('100%').enabled(!this.busy).onClick(() => { this.logout(); })
      if (this.error.length > 0) { Text(this.error).fontColor('#D03232').fontSize(16) }
    }
    .padding(24).width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  private async logout(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try { await UserService.logout(); }
    catch (e) { this.error = (e as Error).message; }
    finally { this.busy = false; }
  }
}
