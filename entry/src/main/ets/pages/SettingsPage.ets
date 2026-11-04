/**
 * 设置页：原生 List + ListItemGroup 分组卡片；布尔项用 Toggle(Switch) 原生开关，
 * 多选项用 ActionSheet。行组件必须用 @Component + @Prop 而非 @Builder——
 * @Builder 多参数按值传递时状态变化不刷新内部 UI（官方文档规则）。
 * 已移除死设置「伪 16bit 线性」（管线未读取）与无操作占位行「超分档位」。
 */

import { SettingsStore } from '../engine/SettingsStore';
import { StyleCategories } from '../engine/StyleDefs';
import { InAppCapture } from '../engine/InAppCapture';
import { ImmersiveLevel, ImmersiveStyle } from '../common/ImmersiveStyle';
import { common } from '@kit.AbilityKit';

/** 多选项行（点击弹 ActionSheet）。 */
@Component
struct SettingRow {
  @Prop title: string = '';
  @Prop value: string = '';
  @Prop hint: string = '';
  @Prop rowEnabled: boolean = true;
  onTap: () => void = (): void => {
  };

  build() {
    Row() {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.rowEnabled ? '#EDEDED' : '#7C7C80')
        if (this.hint !== '') {
          Text(this.hint)
            .fontSize(11)
            .fontColor('#8A8A8A')
            .lineHeight(16)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.value)
        .fontSize(13)
        .fontColor(this.rowEnabled ? '#E8B84B' : '#6E6E72')
        .maxLines(1)
        .constraintSize({ maxWidth: '48%' })
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('›')
        .fontSize(16)
        .fontColor('#6E6E72')
        .margin({ left: 6 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.rowEnabled) {
        this.onTap();
      }
    })
  }
}

/** 布尔开关行（原生 Toggle Switch，整行可点）。 */
@Component
struct SwitchRow {
  @Prop title: string = '';
  @Prop hint: string = '';
  @Prop isOn: boolean = false;
  @Prop rowEnabled: boolean = true;
  onToggle: () => void = (): void => {
  };

  build() {
    Row() {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.rowEnabled ? '#EDEDED' : '#7C7C80')
        if (this.hint !== '') {
          Text(this.hint)
            .fontSize(11)
            .fontColor('#8A8A8A')
            .lineHeight(16)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor('#E8B84B')
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.rowEnabled) {
        this.onToggle();
      }
    })
  }
}

@Entry
@Component
struct SettingsPage {
  @State defaultLabel: string = '';
  @State rememberOn: boolean = false;
  /** 设备拍摄能力描述（应用内拍摄行展示）。 */
  @State inappCapLabel: string = '系统相机';
  /** 关闭「记住分类」时恢复的固定分类（会话内记忆，默认 L-Moment）。 */
  private fixedBackup: string = 'all';
  // 行显示镜像（@State）：点击后必须经 refresh() 回填才会刷新行显示。
  @State pinnedCross: boolean = false;
  @State fullRes: boolean = false;
  @State m9HiRes: boolean = false;
  @State hdrDefault: boolean = false;
  @State leicaBadge: boolean = true;
  @State rawLevel: string = '标准';
  @State hdrBoost: string = '标准';
  @State inappMode: string = 'auto';
  /** 沉浸光感挡位显示名。 */
  @State immersiveLabel: string = '自适应';
  /** 设备沉浸材质能力（不支持时行内提示降级）。 */
  @State immersiveSupported: boolean = true;
  /** 主页全屏沉浸布局广播的状态栏高度（vp），标题栏避让用。 */
  @State topInset: number = 0;

  aboutToAppear(): void {
    const inset = AppStorage.get<number>('lmTopInset');
    this.topInset = inset !== undefined ? inset : 0;
    this.refresh();
    const c: common.Context | undefined = this.getUIContext().getHostContext();
    if (c !== undefined) {
      this.inappCapLabel = InAppCapture.probe(c).fallbackLabel;
    }
  }

  private refresh(): void {
    const def = SettingsStore.defaultSetting();
    this.rememberOn = def === SettingsStore.VALUE_LAST;
    if (this.rememberOn) {
      this.defaultLabel = '记忆上次';
    } else {
      this.defaultLabel = this.titleOf(def);
      this.fixedBackup = def;
    }
    this.pinnedCross = SettingsStore.pinnedCrossCategory();
    this.fullRes = SettingsStore.fullResEnabled();
    this.m9HiRes = SettingsStore.m9HiResEnabled();
    this.hdrDefault = SettingsStore.hdrDefaultOn();
    this.leicaBadge = SettingsStore.leicaBadgeEnabled();
    this.rawLevel = this.rawLevelLabel();
    this.hdrBoost = SettingsStore.hdrBoostLevelName(SettingsStore.hdrBoostLevel());
    this.inappMode = SettingsStore.inappCaptureMode();
    this.immersiveLabel = ImmersiveStyle.labelOf(SettingsStore.immersiveLevel());
    this.immersiveSupported = ImmersiveStyle.supported();
  }

  private titleOf(id: string): string {
    for (let i = 0; i < StyleCategories.LIST.length; i++) {
      if (StyleCategories.LIST[i].id === id) {
        return StyleCategories.LIST[i].title;
      }
    }
    return 'L-Moment';
  }

  private rawLevelLabel(): string {
    const lv = SettingsStore.rawThrLevel();
    if (lv === 0) {
      return '标准';
    }
    if (lv === 2) {
      return '强力提亮';
    }
    return '提亮';
  }

  private pickDefault(): void {
    const lastSheet: SheetInfo = {
      title: '记忆上次（每次启动进入上次分类）',
      action: () => {
        this.applyDefault(SettingsStore.VALUE_LAST);
      }
    };
    const sheets: SheetInfo[] = [lastSheet];
    for (let i = 0; i < StyleCategories.LIST.length; i++) {
      const cat = StyleCategories.LIST[i];
      const sheet: SheetInfo = {
        title: cat.title,
        action: () => {
          this.applyDefault(cat.id);
        }
      };
      sheets.push(sheet);
    }
    this.getUIContext().showActionSheet({
      title: '默认分类',
      message: '选择应用冷启动时进入的分类',
      sheets: sheets
    });
  }

  private applyDefault(id: string): void {
    SettingsStore.setDefaultSetting(id);
    this.refresh();
  }

  private setRemember(on: boolean): void {
    SettingsStore.setDefaultSetting(on ? SettingsStore.VALUE_LAST : this.fixedBackup);
    this.refresh();
  }

  private openAbout(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/AboutPage' });
  }

  private pickHdrBoost(): void {
    const light: SheetInfo = { title: '轻（1.5EV）', action: () => {
      SettingsStore.setHdrBoostLevel(0);
      this.refresh();
    } };
    const standard: SheetInfo = { title: '标准（2.0EV）', action: () => {
      SettingsStore.setHdrBoostLevel(1);
      this.refresh();
    } };
    const strong: SheetInfo = { title: '强（2.5EV）', action: () => {
      SettingsStore.setHdrBoostLevel(2);
      this.refresh();
    } };
    this.getUIContext().showActionSheet({
      title: 'HDR 强度',
      message: '选择增益图幅度',
      sheets: [light, standard, strong]
    });
  }

  private toggleHdrDefault(): void {
    SettingsStore.setHdrDefaultOn(!SettingsStore.hdrDefaultOn());
    this.refresh();
  }

  private toggleFullRes(): void {
    SettingsStore.setFullResEnabled(!SettingsStore.fullResEnabled());
    if (!SettingsStore.fullResEnabled()) {
      SettingsStore.setM9HiResEnabled(false);
    }
    this.refresh();
  }

  private toggleM9HiRes(): void {
    if (!SettingsStore.fullResEnabled()) {
      this.getUIContext().getPromptAction().showToast({ message: '请先开启「全像素导出」' });
      return;
    }
    SettingsStore.setM9HiResEnabled(!SettingsStore.m9HiResEnabled());
    this.refresh();
  }

  /** RAW 亮度档：auto_bright 阈值三档（标准 0.01 / 提亮 0.03 / 强力提亮 0.04）。 */
  private pickRawLevel(): void {
    const standard: SheetInfo = { title: '标准（0.01）', action: () => {
      SettingsStore.setRawThrLevel(0);
      this.refresh();
    } };
    const bright: SheetInfo = { title: '提亮（0.03）', action: () => {
      SettingsStore.setRawThrLevel(1);
      this.refresh();
    } };
    const strong: SheetInfo = { title: '强力提亮（0.04）', action: () => {
      SettingsStore.setRawThrLevel(2);
      this.refresh();
    } };
    this.getUIContext().showActionSheet({
      title: 'RAW 亮度档',
      message: 'RAW 解码 auto_bright 阈值（原图偏暗时可提亮）',
      sheets: [standard, bright, strong]
    });
  }

  private toggleLeicaBadge(): void {
    SettingsStore.setLeicaBadgeEnabled(!SettingsStore.leicaBadgeEnabled());
    this.refresh();
  }

  private togglePinnedCross(): void {
    SettingsStore.setPinnedCrossCategory(!SettingsStore.pinnedCrossCategory());
    this.refresh();
  }

  /** 应用内拍摄模式选择：auto（运行时探测回落链）/ off（直接系统相机）。 */
  private pickInappMode(): void {
    const autoSheet: SheetInfo = {
      title: 'auto（运行时探测：有 RAW 档则应用内直拍，否则系统相机）',
      action: () => {
        SettingsStore.setInappCaptureMode('auto');
        this.refresh();
      }
    };
    const offSheet: SheetInfo = {
      title: 'off（直接系统相机）',
      action: () => {
        SettingsStore.setInappCaptureMode('off');
        this.refresh();
      }
    };
    this.getUIContext().showActionSheet({
      title: '应用内拍摄',
      message: '当前设备探测：' + this.inappCapLabel
        + '\n\n多数机型（含 nova 系列）不向第三方应用开放 RAW 拍摄档，'
        + '此时 auto 与 off 均使用系统相机。\nRAW 工作流：系统相机 Pro 模式拍 DNG → 本应用「导入 RAW」',
      sheets: [autoSheet, offSheet]
    });
  }

  /** 沉浸光感四挡选择（ActionSheet；选择即广播生效并持久化）。 */
  private pickImmersiveLevel(): void {
    const sheets: SheetInfo[] = [];
    const modes = ImmersiveStyle.allModes();
    for (let i = 0; i < modes.length; i++) {
      const mode = modes[i];
      const sheet: SheetInfo = {
        title: ImmersiveStyle.labelOf(mode) + '（' + ImmersiveStyle.descOf(mode) + '）',
        action: () => {
          SettingsStore.setImmersiveLevel(mode);
          this.immersiveLabel = ImmersiveStyle.labelOf(mode);
          if (mode === ImmersiveLevel.EXQUISITE || mode === ImmersiveLevel.GENTLE) {
            if (!this.immersiveSupported) {
              this.getUIContext().getPromptAction()
                .showToast({ message: '当前设备暂不支持所选效果，已使用兼容效果' });
            }
          }
        }
      };
      sheets.push(sheet);
    }
    this.getUIContext().showActionSheet({
      title: '沉浸光感',
      message: this.immersiveSupported
        ? '统一调整顶栏与底栏的玻璃材质表现'
        : '当前设备不支持沉浸材质，已使用模糊兼容效果',
      sheets: sheets
    });
  }

  @Builder
  private groupLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor('#8A8A8A')
      .margin({ left: 6, top: 2, bottom: 2 })
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2E6C9')
        Row() {
          Text('返回')
            .fontSize(14)
            .fontColor('#E8B84B')
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
          Blank()
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .width('100%')
      .height(52)

      List({ space: 14 }) {
        ListItemGroup({ header: this.groupLabel('分类') }) {
          ListItem() {
            SettingRow({ title: '默认分类', value: this.defaultLabel,
              hint: '冷启动进入的分类；修改不影响当前界面', rowEnabled: true,
              onTap: (): void => {
                this.pickDefault();
              } })
          }
          ListItem() {
            SwitchRow({ title: '记住分类', hint: '开启后每次启动进入上次使用的分类',
              isOn: this.rememberOn, rowEnabled: true,
              onToggle: (): void => {
                this.setRemember(!this.rememberOn);
              } })
          }
          ListItem() {
            SwitchRow({ title: '置顶跨分类', hint: '置顶色彩是否在所有分类排最前（默认关）',
              isOn: this.pinnedCross, rowEnabled: true,
              onToggle: (): void => {
                this.togglePinnedCross();
              } })
          }
        }
        .backgroundColor('#16161A')
        .borderRadius(14)
        .divider({ strokeWidth: 1, color: '#1C1C20', startMargin: 16, endMargin: 16 })

        ListItemGroup({ header: this.groupLabel('导出') }) {
          ListItem() {
            SwitchRow({ title: '全像素导出', hint: '50MP / 200MP 图的最高导出像素（默认开）',
              isOn: this.fullRes, rowEnabled: true,
              onToggle: (): void => {
                this.toggleFullRes();
              } })
          }
          ListItem() {
            SwitchRow({ title: 'M9 8192', hint: 'M9 / M9D 的 50MP 级实验导出档（需先开全像素）',
              isOn: this.m9HiRes, rowEnabled: this.fullRes,
              onToggle: (): void => {
                this.toggleM9HiRes();
              } })
          }
          ListItem() {
            SwitchRow({ title: '徕卡徽章', hint: '导出照片右下角绘制 LEICA 水印（默认开）',
              isOn: this.leicaBadge, rowEnabled: true,
              onToggle: (): void => {
                this.toggleLeicaBadge();
              } })
          }
          ListItem() {
            SettingRow({ title: 'HDR 强度', value: this.hdrBoost,
              hint: 'HDR 增益图幅度：轻 1.5EV / 标准 2.0EV / 强 2.5EV', rowEnabled: true,
              onTap: (): void => {
                this.pickHdrBoost();
              } })
          }
          ListItem() {
            SwitchRow({ title: 'HDR 默认开', hint: '导入普通图片时 HDR 按钮的默认状态（默认关）',
              isOn: this.hdrDefault, rowEnabled: true,
              onToggle: (): void => {
                this.toggleHdrDefault();
              } })
          }
        }
        .backgroundColor('#16161A')
        .borderRadius(14)
        .divider({ strokeWidth: 1, color: '#1C1C20', startMargin: 16, endMargin: 16 })

        ListItemGroup({ header: this.groupLabel('导入与拍摄') }) {
          ListItem() {
            SettingRow({ title: 'RAW 亮度档', value: this.rawLevel,
              hint: 'RAW 解码亮度：标准 0.01 / 提亮 0.03 / 强力提亮 0.04', rowEnabled: true,
              onTap: (): void => {
                this.pickRawLevel();
              } })
          }
          ListItem() {
            SettingRow({ title: '应用内拍摄', value: this.inappMode,
              hint: 'auto 运行时探测（' + this.inappCapLabel + '）；off 直接系统相机。'
                + '设备未开放 RAW 档时 auto 也走系统相机：Pro 模式拍 DNG 后「导入 RAW」',
              rowEnabled: true,
              onTap: (): void => {
                this.pickInappMode();
              } })
          }
        }
        .backgroundColor('#16161A')
        .borderRadius(14)
        .divider({ strokeWidth: 1, color: '#1C1C20', startMargin: 16, endMargin: 16 })

        ListItemGroup({ header: this.groupLabel('界面') }) {
          ListItem() {
            SettingRow({ title: '沉浸光感', value: this.immersiveLabel,
              hint: this.immersiveSupported
                ? '顶栏与底栏玻璃材质挡位：自适应 / 精美 / 轻柔 / 流畅'
                : '当前设备不支持沉浸材质，已使用模糊兼容效果',
              rowEnabled: true,
              onTap: (): void => {
                this.pickImmersiveLevel();
              } })
          }
        }
        .backgroundColor('#16161A')
        .borderRadius(14)
        .divider({ strokeWidth: 1, color: '#1C1C20', startMargin: 16, endMargin: 16 })

        ListItemGroup() {
          ListItem() {
            SettingRow({ title: '关于', value: '1.4.1',
              hint: 'L-Moment for HarmonyOS · 对齐原版 1.4.1', rowEnabled: true,
              onTap: (): void => {
                this.openAbout();
              } })
          }
        }
        .backgroundColor('#16161A')
        .borderRadius(14)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 14, right: 14, top: 6, bottom: 16 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
    .backgroundColor('#0E0E10')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
