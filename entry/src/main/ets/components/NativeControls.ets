import { S } from '../app/AppStrings';

/** Shared, labelled 48 vp actions. Symbol names are verified by the SDK build. */
@Component
export struct IconAction {
  @Prop symbol: Resource = $r('sys.symbol.chevron_left');
  @Prop label: string = '';
  @Prop actionEnabled: boolean = true;
  onAction: () => void = () => {};

  build() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(this.symbol).fontSize(22).fontColor([$r('sys.color.ohos_id_color_primary')])
    }
    .width(48).height(48).borderRadius(24).clip(true).backgroundColor(Color.Transparent)
    .accessibilityText(this.label).enabled(this.actionEnabled)
    .onClick(() => { this.onAction(); })
  }
}

@Component
export struct PageHeader {
  @Prop title: string = '';
  @Prop backEnabled: boolean = true;
  onBack: () => void = () => {};

  build() {
    Row({ space: 4 }) {
      IconAction({ label: S.back(), actionEnabled: this.backEnabled, onAction: this.onBack })
      Text(this.title).fontSize(22).fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.ohos_id_color_primary')).layoutWeight(1)
    }.width('100%').constraintSize({ minHeight: 64 }).padding({ left: 8, right: 20 })
  }
}

@Component
export struct BusyButton {
  @Prop label: string = '';
  @Prop busy: boolean = false;
  onAction: () => void = () => {};

  build() {
    Button() {
      Row({ space: 10 }) {
        if (this.busy) {
          LoadingProgress().width(22).height(22).color($r('app.color.on_accent'))
        }
        Text(this.busy ? S.pleaseWait() : this.label).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_accent'))
      }.justifyContent(FlexAlign.Center)
    }.width('100%').height(52).borderRadius(26).clip(true).backgroundColor($r('app.color.accent'))
    .enabled(!this.busy).accessibilityText(this.busy ? S.pleaseWait() : this.label)
    .onClick(() => { if (!this.busy) { this.onAction(); } })
  }
}
