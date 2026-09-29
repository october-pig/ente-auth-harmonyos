/**
 * HomePage — ArkUI mirror of upstream `ui/home_page.dart`:
 * code list with search, sort, tag/trash filters, selection mode,
 * pin/trash/tag/edit actions, add FAB (scan / manual entry / import),
 * Settings navigation.
 */
import { promptAction } from '@kit.ArkUI';
import { Code } from '../models/Code';
import { CodeStore, AddResult, compareAsciiLowerCaseNatural } from '../store/CodeStore';
import { AuthenticatorService } from '../services/AuthenticatorService';
import { PreferenceService, CodeSortKey } from '../services/PreferenceService';
import { EventBus, Events } from '../events/EventBus';
import { Configuration } from '../account/Configuration';
import { S } from '../app/AppStrings';
import { CodeCard } from '../components/CodeCard';
import {
  ScannerLauncher, ImportLauncher, ReorderLauncher, ShareLauncher, QrLauncher,
  TagInputLauncher, EditEntryLauncher, Router,
} from './Router';
import { Toast } from '../utils/Toast';

/**
 * Which sheet the single sheet host is showing.
 *
 * ArkUI supports only ONE `bindSheet` per component: attaching several (as this
 * page previously did — one each for add / settings / sort) suppresses ALL of
 * them, so every sheet trigger fired its handler and nothing appeared.
 * HarmonyOS FAQ `faqs-arkui-1160` documents the constraint ("使用 bindSheet 时，
 * 只能显示一个弹窗内容") and recommends switching the sheet CONTENT instead.
 * DEVICE VERIFIED (HUAWEI Mate 80 Pro Max, API 26): three bindSheet -> none
 * opens; one bindSheet -> opens, and switching content works.
 */
enum SheetKind {
  none = 0,
  add = 1,
  sort = 3,
}

// HDS MINI title height is 56vp. Keep the gradient tail and content clearance
// in sync; status-bar height comes from Window, not a device-specific constant.
export const HOME_TITLE_HEIGHT: number = 56;
export const HOME_TITLE_FADE_HEIGHT: number = 16;

@Component
export struct HomePage {
  @State allCodes: Code[] = [];
  @State filteredCodes: Code[] = [];
  @State tags: string[] = [];
  @State selectedTag: string = '';
  @State isTrashOpen: boolean = false;
  @State searchText: string = '';
  private searchController: SearchController = new SearchController();
  @StorageProp('uiStatusTopPx') statusTopPx: number = 0;
  @Prop @Watch('onSortRequested') sortRequest: number = 0;
  @StorageProp('uiNavigationBottomPx') navigationBottomPx: number = 0;
  scroller: Scroller = new Scroller();
  @State sortKey: CodeSortKey = CodeSortKey.issuerName;
  @State isSelectionMode: boolean = false;
  @State selectedKeys: string[] = [];
  @State loaded: boolean = false;
  @State loadError: boolean = false;
  @State migrationStatus: string = '';
  @State migrationRunning: boolean = false;
  private migrationInFlight: boolean = false;
  /**
   * An async read can finish after an appearance ends. Validate this token
   * after awaiting, as well as unsubscribing the stable event handlers.
   */
  private static generation: number = 0;
  private generation: number = 0;
  private active: boolean = false;
  private loadRequest: number = 0;
  @State hideCodes: boolean = false;
  @State accountConfigured: boolean = false;
  /** Single sheet host: `sheetVisible` drives bindSheet, `sheetKind` picks content. */
  @State sheetVisible: boolean = false;
  @State sheetKind: number = SheetKind.none;
  /**
   * Route requested from inside a sheet, performed once the sheet has actually
   * dismissed. See `navigateFromSheet` (finding U).
   */
  @State pendingRoute: string = '';

  private sortEntries: SortEntry[] = [
    new SortEntry(S.codeIssuerHint(), CodeSortKey.issuerName),
    new SortEntry(S.account(), CodeSortKey.accountName),
    new SortEntry(S.mostFrequentlyUsed(), CodeSortKey.mostFrequentlyUsed),
    new SortEntry(S.mostRecentlyUsed(), CodeSortKey.recentlyUsed),
    new SortEntry(S.manualSort(), CodeSortKey.manual),
  ];

  aboutToAppear(): void {
    this.active = true;
    this.migrationInFlight = false;
    this.migrationRunning = CodeStore.instance.isOfflineMigrationRunning();
    EventBus.on<object>(Events.OFFLINE_MIGRATION_CHANGED, this.onMigrationChanged);
    this.accountConfigured = Configuration.instance.hasConfiguredAccount();
    // A NEW generation for this appearance. Any handler left behind by a previous
    // instance is inert from here on (see the guards in the handlers below).
    HomePage.generation++;
    this.generation = HomePage.generation;
    const appearance: number = this.generation;
    EventBus.on<object>(Events.CODES_UPDATED, this.onCodesUpdated);
    PreferenceService.codeSortKey().then((k: CodeSortKey) => {
      if (!this.isCurrentAppearance(appearance)) {
        return;
      }
      this.sortKey = k;
    });
    PreferenceService.shouldHideCodes().then((v: boolean) => {
      if (!this.isCurrentAppearance(appearance)) {
        return;
      }
      this.hideCodes = v;
    });
    // Layer 3 of finding T: Home read the preference ONLY in aboutToAppear, and
    // `setShouldHideCodes` fired `ICONS_CHANGED`, which nothing here consumed — so
    // toggling 隐藏验证码 never reached the rendered codes. Re-reading on the
    // dedicated event (which fires AFTER the awaited write) keeps this correct
    // without a second copy of the value to drift.
    EventBus.on<object>(Events.HIDE_CODES_CHANGED, this.onHideCodesChanged);
    this.loadCodes();
    if (this.accountConfigured) {
      this.migrateOfflineCodes();
    }
  }

  private async migrateOfflineCodes(): Promise<void> {
    if (this.migrationInFlight) {
      return;
    }
    const appearance = this.generation;
    this.migrationInFlight = true;
    this.migrationRunning = CodeStore.instance.isOfflineMigrationRunning();
    this.migrationStatus = '';
    const result = await CodeStore.instance.importOfflineCodes();
    if (!this.isCurrentAppearance(appearance)) {
      return;
    }
    this.migrationInFlight = false;
    this.migrationRunning = false;
    this.migrationStatus = result === 'complete' || result === 'cancelled' ? '' : result;
    this.loadCodes();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.loadRequest++;
    // Release both subscriptions. Without this, ArkUI may leave them registered
    // and the next appearance would stack a second pair — every CODES_UPDATED
    // then running loadCodes() N times concurrently on the same state.
    EventBus.off<object>(Events.CODES_UPDATED, this.onCodesUpdated);
    EventBus.off<object>(Events.HIDE_CODES_CHANGED, this.onHideCodesChanged);
    EventBus.off<object>(Events.OFFLINE_MIGRATION_CHANGED, this.onMigrationChanged);
  }

  private onMigrationChanged: (payload: object) => void = () => {
    if (!this.isCurrentAppearance(this.generation)) { return; }
    this.migrationRunning = CodeStore.instance.isOfflineMigrationRunning();
  };

  /** Stable identity so it can be unsubscribed; inert once superseded. */
  private onCodesUpdated: (payload: object) => void = () => {
    if (this.generation !== HomePage.generation) {
      return;
    }
    this.loadCodes();
  };

  private onHideCodesChanged: (payload: object) => void = () => {
    if (this.generation !== HomePage.generation) {
      return;
    }
    const appearance: number = this.generation;
    PreferenceService.shouldHideCodes().then((v: boolean) => {
      if (this.isCurrentAppearance(appearance)) {
        this.hideCodes = v;
      }
    });
  };

  private isCurrentAppearance(appearance: number): boolean {
    return this.active && appearance === this.generation && appearance === HomePage.generation;
  }

  async loadCodes(): Promise<void> {
    const appearance: number = this.generation;
    const request: number = ++this.loadRequest;
    let codes: Code[];
    try {
      codes = await CodeStore.instance.getAllCodes();
    } catch (e) {
      if (this.isCurrentAppearance(appearance) && request === this.loadRequest) {
        this.allCodes = [];
        this.filteredCodes = [];
        this.tags = [];
        this.selectedKeys = [];
        this.isSelectionMode = false;
        this.loadError = true;
        this.loaded = true;
      }
      return;
    }
    if (!this.isCurrentAppearance(appearance) || request !== this.loadRequest) {
      return;
    }
    this.loadError = false;
    this.allCodes = codes;
    this.reconcileTrashFilter();
    const tagSet: string[] = [];
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      if (c.hasError || c.isTrashed) {
        continue;
      }
      for (let j = 0; j < c.display.tags.length; j++) {
        if (!tagSet.includes(c.display.tags[j])) {
          tagSet.push(c.display.tags[j]);
        }
      }
    }
    tagSet.sort((a: string, b: string) => a.localeCompare(b));
    this.tags = tagSet;
    if (!tagSet.includes(this.selectedTag)) {
      this.selectedTag = '';
    }
    this.loaded = true;
    this.applyFiltering();
  }

  /** Upstream search ranking: issuer matches first, then account, then note. */
  applyFiltering(): void {
    const all: Code[] = this.allCodes;
    let result: Code[] = [];
    if (this.searchText.length > 0) {
      const val: string = this.searchText.toLowerCase();
      const issuerMatch: Code[] = [];
      const accountMatch: Code[] = [];
      const noteMatch: Code[] = [];
      for (let i = 0; i < all.length; i++) {
        const c = all[i];
        if (c.hasError || c.isTrashed !== this.isTrashOpen) {
          continue;
        }
        if (this.selectedTag !== '' && !c.display.tags.includes(this.selectedTag)) {
          continue;
        }
        if (c.issuer.toLowerCase().includes(val)) {
          issuerMatch.push(c);
        } else if (c.account.toLowerCase().includes(val)) {
          accountMatch.push(c);
        } else if (c.note.toLowerCase().includes(val)) {
          noteMatch.push(c);
        }
      }
      result = issuerMatch.concat(accountMatch).concat(noteMatch);
    } else if (this.isTrashOpen) {
      for (let i = 0; i < all.length; i++) {
        const c = all[i];
        if (!c.hasError && c.isTrashed) {
          result.push(c);
        }
      }
    } else {
      for (let i = 0; i < all.length; i++) {
        const c = all[i];
        if (c.hasError || c.isTrashed) {
          continue;
        }
        if (this.selectedTag === '' || c.display.tags.includes(this.selectedTag)) {
          result.push(c);
        }
      }
    }
    this.filteredCodes = this.sortCodes(result);
  }

  sortCodes(codes: Code[]): Code[] {
    const list: Code[] = codes.slice();
    const key = this.sortKey;
    list.sort((a: Code, b: Code) => {
      if (key === CodeSortKey.accountName) {
        return compareAsciiLowerCaseNatural(a.account, b.account);
      } else if (key === CodeSortKey.mostFrequentlyUsed) {
        return b.display.tapCount - a.display.tapCount;
      } else if (key === CodeSortKey.recentlyUsed) {
        return b.display.lastUsedAt - a.display.lastUsedAt;
      } else if (key === CodeSortKey.manual) {
        return a.display.position - b.display.position;
      }
      return compareAsciiLowerCaseNatural(a.issuer, b.issuer);
    });
    if (key !== CodeSortKey.manual) {
      // Stable-hoist pinned codes to the front (upstream).
      const pinned: Code[] = [];
      const rest: Code[] = [];
      for (let i = 0; i < list.length; i++) {
        if (list[i].isPinned) {
          pinned.push(list[i]);
        } else {
          rest.push(list[i]);
        }
      }
      return pinned.concat(rest);
    }
    return list;
  }

  hasErrorCodes(): boolean {
    for (let i = 0; i < this.allCodes.length; i++) {
      if (this.allCodes[i].hasError) {
        return true;
      }
    }
    return false;
  }

  /**
   * True when the account has no codes at all (active or trashed).
   *
   * A METHOD, not a `get` accessor. ArkUI does not compile accessors on a
   * `@Component struct`: the previous `get noCodesAnywhere()` returned
   * `undefined` at runtime while ordinary methods on the same struct worked, so
   * the empty-state guard `... && this.noCodesAnywhere` was always falsy and the
   * "Setup your first account" panel never rendered — a blank Home with no way
   * to add a code. DEVICE VERIFIED (HUAWEI Mate 80 Pro Max, API 26): hilog
   * showed `noCodesAnywhere=undefined` while `hasErrorCodes=false` (a method)
   * evaluated correctly; after the change it reports `true` and the empty state
   * renders.
   *
   * Upstream computes this as a local (`home_page.dart:1736`), not as a getter.
   */
  noCodesAnywhere(): boolean {
    return this.allCodes.length === 0 && !this.loadError;
  }

  /** Upstream `hasTrashedCodes` (home_page.dart:1748). */
  hasTrashedCodes(): boolean {
    for (let i = 0; i < this.allCodes.length; i++) {
      if (!this.allCodes[i].hasError && this.allCodes[i].isTrashed) {
        return true;
      }
    }
    return false;
  }

  toggleSelection(key: string): void {
    const idx = this.selectedKeys.indexOf(key);
    if (idx >= 0) {
      this.selectedKeys = this.selectedKeys.filter((k: string) => k !== key);
    } else {
      const next = this.selectedKeys.slice();
      next.push(key);
      this.selectedKeys = next;
    }
    this.isSelectionMode = this.selectedKeys.length > 0;
  }

  clearSelection(): void {
    this.selectedKeys = [];
    this.isSelectionMode = false;
  }

  codesForKeys(): Code[] {
    const out: Code[] = [];
    for (let i = 0; i < this.allCodes.length; i++) {
      if (this.selectedKeys.includes(this.allCodes[i].selectionKey)) {
        out.push(this.allCodes[i]);
      }
    }
    return out;
  }

  async onPinSelected(): Promise<void> {
    const codes = this.codesForKeys();
    let changed = false;
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      const updated = c.copyWith(undefined, undefined, undefined, undefined, undefined,
        undefined, undefined, undefined, c.display.copyWith(!c.isPinned));
      const res = await CodeStore.instance.addCode(updated, false);
      if (res !== AddResult.duplicate) {
        changed = true;
      }
    }
    this.clearSelection();
    if (changed) {
      await AuthenticatorService.instance.onlineSync();
      Toast.show(codes.length === 1
        ? S.pinnedCodeMessage(codes[0].issuerAccount)
        : S.pinnedCount(codes.length));
    }
  }

  async onTrashSelected(): Promise<void> {
    const codes = this.codesForKeys();
    const ok = await ConfirmDialog.show(
      S.trashCode(),
      codes.length === 1 ? S.trashCodeMessage(codes[0].issuerAccount)
        : S.moveMultipleToTrashMessage(codes.length),
      S.trash());
    if (!ok) {
      return;
    }
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      const updated = c.copyWith(undefined, undefined, undefined, undefined, undefined,
        undefined, undefined, undefined, c.display.copyWith(undefined, true));
      await CodeStore.instance.addCode(updated, false);
    }
    this.clearSelection();
    await AuthenticatorService.instance.onlineSync();
    this.loadCodes();
  }

  async onRestoreSelected(): Promise<void> {
    const codes = this.codesForKeys();
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      const updated = c.copyWith(undefined, undefined, undefined, undefined, undefined,
        undefined, undefined, undefined, c.display.copyWith(undefined, false));
      await CodeStore.instance.addCode(updated, false);
    }
    this.clearSelection();
    await AuthenticatorService.instance.onlineSync();
    this.loadCodes();
  }

  async onDeleteSelected(): Promise<void> {
    const codes = this.codesForKeys();
    const ok = await ConfirmDialog.show(S.deleteCodeTitle(), S.deleteCodeMessage(), S.delete());
    if (!ok) {
      return;
    }
    for (let i = 0; i < codes.length; i++) {
      await CodeStore.instance.removeCode(codes[i]);
    }
    this.clearSelection();
    this.loadCodes();
  }

  async onEditCode(code: Code): Promise<void> {
    this.clearSelection();
    (new EditEntryLauncher()).launchEntry(code);
  }

  async onShareCode(code: Code): Promise<void> {
    if (code.type.toString() === 'hotp') {
      return;
    }
    (new ShareLauncher()).launch(code);
  }

  async onShowQr(code: Code): Promise<void> {
    (new QrLauncher()).launch(code);
  }

  async onAddTag(): Promise<void> {
    const tagName: string = await (new TagInputLauncher()).prompt(this.tags);
    if (tagName === '') {
      return;
    }
    const codes = this.codesForKeys();
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      const updatedTags = c.display.tags.slice();
      if (!updatedTags.includes(tagName)) {
        updatedTags.push(tagName);
      }
      const updated = c.copyWith(undefined, undefined, undefined, undefined, undefined,
        undefined, undefined, undefined, c.display.copyWith(undefined, undefined, undefined,
          undefined, updatedTags));
      await CodeStore.instance.addCode(updated, false);
    }
    this.clearSelection();
    await AuthenticatorService.instance.onlineSync();
    this.loadCodes();
  }

  updateMetadataAfterCopy(code: Code): void {
    const key = this.sortKey;
    if (key !== CodeSortKey.mostFrequentlyUsed && key !== CodeSortKey.recentlyUsed) {
      return;
    }
    setTimeout(async () => {
      const updated = code.copyWith(undefined, undefined, undefined, undefined, undefined,
        undefined, undefined, undefined,
        code.display.copyWith(undefined, undefined, Date.now() * 1000, code.display.tapCount + 1));
      await CodeStore.instance.addCode(updated, false);
    }, 100);
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.buildListArea()
        this.buildSelectionBar()
      }
      .width('100%')
      .height('100%')

      // FAB
      if (this.loaded && this.allCodes.length > 0 && !this.isSelectionMode) {
        Column() {
          Button() {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(26).fontColor([$r('app.color.on_accent')])
          }
          .width(56)
          .height(56)
          .type(ButtonType.Circle).borderRadius(28).clip(true)
          .accessibilityText(S.addCode())
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            this.openSheet(SheetKind.add);
          })
        }
        .margin({ right: 20, bottom: 24 + this.bottomInset() })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    // ONE sheet host for add / sort. See the SheetKind comment: ArkUI
    // renders only a single bindSheet per component, so the content is switched
    // by state. Settings uses the Navigation stack.
    .bindSheet($$this.sheetVisible, this.buildActiveSheet(), {
      height: this.sheetKind === SheetKind.add ? 300 : 380,
      showClose: true,
      title: { title: this.sheetTitle() },
      onDisappear: () => {
        this.sheetVisible = false;
        this.sheetKind = SheetKind.none;
        // Perform any navigation that was requested from inside the sheet ONLY
        // now that the sheet has really gone. Doing it at tap time put the
        // destination page behind the sheet (finding U).
        const route: string = this.pendingRoute;
        this.pendingRoute = '';
        if (route.length > 0) {
          Router.push(route, undefined);
        }
      },
    })
  }

  private openSheet(kind: number): void {
    this.sheetKind = kind;
    this.sheetVisible = true;
  }

  private closeSheet(): void {
    this.sheetVisible = false;
  }

  /**
   * Navigation requested from INSIDE a sheet (finding U).
   *
   * Pushing while the sheet is still mounted rendered the destination page
   * BEHIND the sheet: the route changed underneath and the sheet stayed on top.
   * The Add sheet already closed first; Settings did not.
   *
   * The route is remembered and performed in `bindSheet`'s `onDisappear`, which
   * is the real dismissal completion — not a guessed animation delay.
   */
  private navigateFromSheet(route: string): void {
    this.pendingRoute = route;
    this.closeSheet();
  }

  private sheetTitle(): string {
    if (this.sheetKind === SheetKind.add) {
      return S.addCode();
    }
    return S.editOrder();
  }

  @Builder
  buildActiveSheet() {
    if (this.sheetKind === SheetKind.add) {
      this.buildAddSheet()

    } else if (this.sheetKind === SheetKind.sort) {
      this.buildSortSheet()
    }
  }

  /** Hidden empty Trash must not leave Home trapped in an unreachable scope. */
  private reconcileTrashFilter(): void {
    if (this.isTrashOpen && !this.hasTrashedCodes()) {
      this.isTrashOpen = false;
      this.clearSelection();
    }
  }

  private topClearance(): number {
    return this.getUIContext().px2vp(this.statusTopPx) + HOME_TITLE_HEIGHT + HOME_TITLE_FADE_HEIGHT;
  }

  private onSortRequested(): void {
    this.openSheet(SheetKind.sort);
  }

  private bottomInset(): number {
    return this.getUIContext().px2vp(this.navigationBottomPx);
  }

  @Builder
  buildSearch() {
    Search({ value: this.searchText, placeholder: S.searchHint(), controller: this.searchController })
      .height(48).width('100%')
      .backgroundColor($r('app.color.surface'))
      .onChange((v: string) => { this.searchText = v; this.applyFiltering(); })
      .onSubmit(() => { this.searchController.stopEditing(); })
  }

  @Builder
  buildChips() {
    Scroll() {
      Row({ space: 8 }) {
        // User-requested HarmonyOS presentation: both scope chips disappear
        // with an empty Trash. Tags remain independently toggleable.
        if (this.hasTrashedCodes()) {
          ChipItem({
            label: S.all(),
            selected: this.selectedTag === '' && !this.isTrashOpen,
            onTap: () => {
              this.selectedTag = '';
              this.isTrashOpen = false;
              this.clearSelection();
              this.applyFiltering();
            },
          })
        }
        if (this.hasTrashedCodes()) {
          ChipItem({
            label: S.trash(),
            selected: this.isTrashOpen,
            onTap: () => {
              this.isTrashOpen = !this.isTrashOpen;
              this.selectedTag = '';
              this.clearSelection();
              this.applyFiltering();
            },
          })
        }
        ForEach(this.tags, (tag: string) => {
          ChipItem({
            label: tag,
            selected: this.selectedTag === tag && !this.isTrashOpen,
            onTap: () => {
              this.selectedTag = this.selectedTag === tag ? '' : tag;
              this.isTrashOpen = false;
              this.clearSelection();
              this.applyFiltering();
            },
          })
        }, (tag: string) => tag)
      }
    }
    .align(Alignment.Start)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .height(52)
    .width('100%')
  }

  @Builder
  buildListArea() {
    List({ space: 12, scroller: this.scroller }) {
      ListItem() { this.buildSearch() }
      if (this.hasTrashedCodes() || this.tags.length > 0) {
        ListItem() { this.buildChips() }
      }
      if (!this.loaded) {
        ListItem() {
          Row() {
            LoadingProgress().width(40).height(40).color($r('app.color.accent'))
          }.width('100%').height(200).justifyContent(FlexAlign.Center)
        }
      } else {
        if (this.migrationRunning) {
          ListItem() {
            Text(S.offlineMigrationRunning()).fontSize(14).padding(12)
          }
        } else if (this.migrationStatus !== '') {
          ListItem() {
            Column() {
              Text(this.migrationStatus === 'unreadable' ? S.offlineMigrationUnreadable() :
              (this.migrationStatus === 'uncertain' ? S.offlineMigrationUncertain() : S.offlineMigrationPending()))
              .fontSize(14)
              Button(S.retryReadCodes()).onClick(() => { this.migrateOfflineCodes(); })
            }.padding(12)
          }
        }
        if (this.loadError) {
          ListItem() {
            Column() {
              Text(S.unableToReadCodes())
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              Text(S.storedCodesReadError())
              .fontSize(16)
              .textAlign(TextAlign.Center)
              .margin({ top: 16 })
              Button(S.retryReadCodes())
              .margin({ top: 24 })
              .onClick(() => {
                this.loadCodes();
              })
            }
            .padding(24)
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
        } else if (this.filteredCodes.length === 0 && this.searchText === '' && this.noCodesAnywhere()) {
          ListItem() {
            Column() {
              SymbolGlyph($r('sys.symbol.lock_shield')).fontSize(64).fontColor([$r('app.color.accent')])
              .margin({ bottom: 24 })
              Text(S.setupFirstAccount())
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.ohos_id_color_primary'))
              .textAlign(TextAlign.Center)
              Button(S.scanAQrCode())
              .width(220)
              .height(46)
              .margin({ top: 24 })
              .backgroundColor($r('app.color.accent'))
              .onClick(() => {
                ScannerLauncher.launchScan();
              })
              Button(S.importEnterSetupKey())
              .width(220)
              .height(46)
              .margin({ top: 12 })
              .backgroundColor($r('app.color.page'))
              .fontColor($r('app.color.accent'))
              .border({ width: 1, color: $r('app.color.accent') })
              .onClick(() => {
                (new EditEntryLauncher()).launchEntry(undefined);
              })
              Text(S.importCodes())
              .fontSize(14)
              .fontColor($r('app.color.accent'))
              .margin({ top: 16 })
              .onClick(() => {
                ImportLauncher.launch();
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ left: 24, right: 24, top: 32, bottom: 32 })
          }
        } else if (this.filteredCodes.length === 0 && !this.hasErrorCodes()) {
          ListItem() {
            Text(S.noMatchingCodes()).fontSize(16).fontColor($r('sys.color.ohos_id_color_secondary'))
            .padding(24).width('100%').textAlign(TextAlign.Center)
          }
        } else {
          if (this.hasErrorCodes()) {
            ListItem() {
              Row() {
                Text(S.error())
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.danger'))
                Text(S.somethingWentWrongParsingCode(this.allCodes.length))
                .fontSize(13)
                .fontColor($r('sys.color.ohos_id_color_primary'))
                .margin({ left: 8 })
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(8)
            }
          }
          ForEach(this.filteredCodes, (code: Code) => {
            ListItem() {
              CodeCard({
                code: code,
                isSelectionMode: this.isSelectionMode,
                isSelected: this.selectedKeys.includes(code.selectionKey),
                hideCodes: this.hideCodes,
                accountConfigured: this.accountConfigured,
                index: this.filteredCodes.indexOf(code),
                onLongPressAction: () => {
                  this.toggleSelection(code.selectionKey);
                },
                onCopied: () => {
                  this.updateMetadataAfterCopy(code);
                },
              })
            }
          }, (code: Code) => `${code.selectionKey}_${this.sortKey}`)
        }
      }
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
    .padding({ left: 16, right: 16 })
    .contentStartOffset(this.topClearance())
    .contentEndOffset(96 + this.bottomInset())
  }

  @Builder
  buildSelectionBar() {
    // Selection action bar
    if (this.isSelectionMode) {
      Scroll() {
        Row() {
          Text(S.selectedCount(this.selectedKeys.length))
          .fontSize(15)
          .fontColor($r('sys.color.ohos_id_color_primary'))
          .margin({ left: 20 })
          ActionChip({
            label: S.pinText(),
            onTap: () => {
              this.onPinSelected();
            },
          })
          ActionChip({
            label: S.addTag(),
            onTap: () => {
              this.onAddTag();
            },
          })
          ActionChip({
            label: S.edit(),
            onTap: () => {
              const codes = this.codesForKeys();
              if (codes.length === 1) {
                this.onEditCode(codes[0]);
              }
            },
          })
          if (this.isTrashOpen) {
            ActionChip({
              label: S.restore(),
              onTap: () => {
                this.onRestoreSelected();
              },
            })
            ActionChip({
              label: S.delete(),
              destructive: true,
              onTap: () => {
                this.onDeleteSelected();
              },
            })
          } else {
            ActionChip({
              label: S.trash(),
              destructive: true,
              onTap: () => {
                this.onTrashSelected();
              },
            })
          }
          ActionChip({
            label: S.cancel(),
            onTap: () => {
              this.clearSelection();
            },
          })
        }
        .height(56)
        .padding({ right: 16 })
        .backgroundColor($r('app.color.surface'))
        .border({ width: { top: 1 }, color: $r('sys.color.ohos_id_color_list_separator') })
      }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      .margin({ bottom: this.bottomInset() })
    }
  }

  @Builder
  buildAddSheet() {
    Column() {
      MenuRow({
        label: S.scanAQrCode(),
        onTap: () => {
          this.navigateFromSheet('scanner');
        },
      })
      MenuRow({
        label: S.enterDetailsManually(),
        onTap: () => {
          this.navigateFromSheet('setup');
        },
      })
      MenuRow({
        label: S.importCodes(),
        onTap: () => {
          this.navigateFromSheet('import');
        },
      })
    }
    .width('100%')
    .padding({ top: 8 })
  }

  @Builder
  buildSortSheet() {
    Column() {
      ForEach(this.sortEntries, (entry: SortEntry) => {
        MenuRow({
          label: entry.label,
          checked: this.sortKey === entry.key,
          onTap: () => {
            this.sortKey = entry.key;
            PreferenceService.setCodeSortKey(entry.key);
            this.closeSheet();
            this.applyFiltering();
            if (entry.key === CodeSortKey.manual) {
              ReorderLauncher.launch(this.allCodes);
            }
          },
        })
      }, (entry: SortEntry) => entry.label)
    }
    .width('100%')
    .padding({ top: 8 })
  }
}

/**
 * Simple chip for the filter row.
 *
 * `label` and `selected` MUST be `@Prop`: a plain (undecorated) member of a
 * child `@Component` is initialised once from the parent and never updated, so
 * the All/Trash selection highlight never moved even though the parent's state
 * did. DEVICE VERIFIED: tapping Trash fired its handler and `isTrashOpen`
 * became true, but the chip stayed grey. `CodeCard` already used `@Prop`.
 */
@Component
struct ChipItem {
  @Prop label: string = '';
  @Prop selected: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .height(40)
      .fontSize(14)
      .fontColor(this.selected ? $r('app.color.on_accent') : $r('sys.color.ohos_id_color_primary'))
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      .backgroundColor(this.selected ? $r('app.color.accent') : $r('sys.color.ohos_id_color_component_normal'))
      .type(ButtonType.Normal).borderRadius(18).clip(true)
      .onClick(() => {
        this.onTap();
      })
  }
}

/** Sort option entry model. */
class SortEntry {
  label: string = '';
  key: CodeSortKey = CodeSortKey.issuerName;

  constructor(label: string, key: CodeSortKey) {
    this.label = label;
    this.key = key;
  }
}

@Component
struct ActionChip {
  label: string = '';
  onTap: () => void = () => {
  };
  destructive: boolean = false;

  build() {
    Button(this.label)
      .height(44)
      .fontSize(13)
      .fontColor(this.destructive ? $r('app.color.danger') : $r('app.color.accent'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor($r('sys.color.ohos_id_color_component_normal'))
      .type(ButtonType.Normal).borderRadius(14).clip(true)
      .margin({ left: 8 })
      .onClick(() => {
        this.onTap();
      })
  }
}

@Component
struct MenuRow {
  @Prop label: string = '';
  onTap: () => void = () => {
  };
  @Prop checked: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(16)
        .fontColor($r('sys.color.ohos_id_color_primary'))
        .layoutWeight(1)
      if (this.checked) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([$r('app.color.accent')])
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 24, right: 24 })
    .onClick(() => {
      this.onTap();
    })
  }
}

/** Confirm dialog helper (native AlertDialog). */
export class ConfirmDialog {
  static async show(title: string, message: string, confirmLabel: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      promptAction.showDialog({
        title: title,
        message: message,
        buttons: [
          { text: S.cancel(), color: $r('sys.color.ohos_id_color_secondary') },
          { text: confirmLabel, color: confirmLabel === S.delete() ? $r('app.color.danger') : $r('app.color.accent') },
        ],
      }).then((result) => {
        resolve(result.index === 1);
      }).catch(() => {
        resolve(false);
      });
    });
  }
}
