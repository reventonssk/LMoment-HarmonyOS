/**
 * 设置页：原生 List + ListItemGroup 分组卡片；布尔项用 Toggle(Switch) 原生开关，
 * 多选项用自定义底部弹层（bindSheet：行距可控、带选中态，替代系统 ActionSheet）。
 * 行组件必须用 @Component + @Prop 而非 @Builder——
 * @Builder 多参数按值传递时状态变化不刷新内部 UI（官方文档规则）。
 * 已移除死设置「伪 16bit 线性」（管线未读取）与无操作占位行「超分档位」。
 */

import { SettingsStore } from '../engine/SettingsStore';
import { StyleCategories } from '../engine/StyleDefs';
import { InAppCapture } from '../engine/InAppCapture';
import { ImmersiveLevel, ImmersiveStyle } from '../common/ImmersiveStyle';
import { common } from '@kit.AbilityKit';

/** 自定义底部弹层选项条目：label 显示、current 选中态（✓）、action 点击回调。 */
class SheetOption {
  label: string;
  current: boolean;
  action: () => void;

  constructor(label: string, current: boolean, action: () => void) {
    this.label = label;
    this.current = current;
    this.action = action;
  }
}

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
        .selectedColor(this.rowEnabled ? '#E8B84B' : '#5A5A5E')
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
  /** 自定义底部弹层（替代系统 ActionSheet，解决选项行距过小）。 */
  @State sheetVisible: boolean = false;
  @State sheetTitle: string = '';
  @State sheetMessage: string = '';
  @State sheetOptions: SheetOption[] = [];

  private openSheet(title: string, message: string, options: SheetOption[]): void {
    this.sheetTitle = title;
    this.sheetMessage = message;
    this.sheetOptions = options;
    this.sheetVisible = true;
  }

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
    const current = SettingsStore.defaultSetting();
    const options: SheetOption[] = [
      new SheetOption('记忆上次（每次启动进入上次分类）', current === SettingsStore.VALUE_LAST, () => {
        this.applyDefault(SettingsStore.VALUE_LAST);
      })
    ];
    for (let i = 0; i < StyleCategories.LIST.length; i++) {
      const cat = StyleCategories.LIST[i];
      options.push(new SheetOption(cat.title, current === cat.id, () => {
        this.applyDefault(cat.id);
      }));
    }
    this.openSheet('默认分类', '选择应用冷启动时进入的分类', options);
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
    const lv = SettingsStore.hdrBoostLevel();
    const options: SheetOption[] = [
      new SheetOption('轻（1.5EV）', lv === 0, () => {
        SettingsStore.setHdrBoostLevel(0);
        this.refresh();
      }),
      new SheetOption('标准（2.0EV）', lv === 1, () => {
        SettingsStore.setHdrBoostLevel(1);
        this.refresh();
      }),
      new SheetOption('强（2.5EV）', lv === 2, () => {
        SettingsStore.setHdrBoostLevel(2);
        this.refresh();
      })
    ];
    this.openSheet('HDR 强度', '选择增益图幅度', options);
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
    const lv = SettingsStore.rawThrLevel();
    const options: SheetOption[] = [
      new SheetOption('标准（0.01）', lv === 0, () => {
        SettingsStore.setRawThrLevel(0);
        this.refresh();
      }),
      new SheetOption('提亮（0.03）', lv === 1, () => {
        SettingsStore.setRawThrLevel(1);
        this.refresh();
      }),
      new SheetOption('强力提亮（0.04）', lv === 2, () => {
        SettingsStore.setRawThrLevel(2);
        this.refresh();
      })
    ];
    this.openSheet('RAW 亮度档', 'RAW 解码 auto_bright 阈值（原图偏暗时可提亮，导入时生效）', options);
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
    const options: SheetOption[] = [
      new SheetOption('auto（运行时探测：有 RAW 档则应用内直拍，否则系统相机）', this.inappMode === 'auto', () => {
        SettingsStore.setInappCaptureMode('auto');
        this.refresh();
      }),
      new SheetOption('off（直接系统相机）', this.inappMode === 'off', () => {
        SettingsStore.setInappCaptureMode('off');
        this.refresh();
      })
    ];
    this.openSheet('应用内拍摄', '当前设备探测：' + this.inappCapLabel
      + '\n\n多数机型（含 nova 系列）不向第三方应用开放 RAW 拍摄档，'
      + '此时 auto 与 off 均使用系统相机。\nRAW 工作流：系统相机 Pro 模式拍 DNG → 本应用「导入 RAW」', options);
  }

  /** 沉浸光感四挡选择（自定义弹层；选择即广播生效并持久化）。 */
  private pickImmersiveLevel(): void {
    const options: SheetOption[] = [];
    const modes = ImmersiveStyle.allModes();
    const cur = SettingsStore.immersiveLevel();
    for (let i = 0; i < modes.length; i++) {
      const mode = modes[i];
      options.push(new SheetOption(ImmersiveStyle.labelOf(mode) + '（' + ImmersiveStyle.descOf(mode) + '）',
        mode === cur, () => {
          SettingsStore.setImmersiveLevel(mode);
          this.immersiveLabel = ImmersiveStyle.labelOf(mode);
          if ((mode === ImmersiveLevel.EXQUISITE || mode === ImmersiveLevel.GENTLE)
            && !this.immersiveSupported) {
            this.getUIContext().getPromptAction()
              .showToast({ message: '当前设备暂不支持所选效果，已使用兼容效果' });
          }
        }));
    }
    this.openSheet('沉浸光感', this.immersiveSupported
      ? '统一调整顶栏与底栏的玻璃材质表现'
      : '当前设备不支持沉浸材质，已使用模糊兼容效果', options);
  }

  @Builder
  private groupLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor('#8A8A8A')
      .margin({ left: 6, top: 2, bottom: 2 })
  }

  /** 自定义底部弹层内容：标题 + 说明 + 宽行距选项列表（当前值 ✓ 金色高亮）。 */
  @Builder
  private sheetPanel() {
    Column() {
      Text(this.sheetTitle)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F2E6C9')
        .margin({ top: 4 })
      if (this.sheetMessage !== '') {
        Text(this.sheetMessage)
          .fontSize(12)
          .fontColor('#8A8A8A')
          .lineHeight(18)
          .textAlign(TextAlign.Center)
          .margin({ top: 8, bottom: 6 })
          .padding({ left: 24, right: 24 })
      }
      Scroll() {
        Column() {
          ForEach(this.sheetOptions, (opt: SheetOption, idx: number) => {
            Row() {
              Text(opt.label)
                .fontSize(15)
                .fontColor(opt.current ? '#E8B84B' : '#EDEDED')
                .layoutWeight(1)
                .maxLines(2)
              if (opt.current) {
                Text('✓')
                  .fontSize(15)
                  .fontColor('#E8B84B')
                  .margin({ left: 10 })
              }
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 17, bottom: 17 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.sheetVisible = false;
              opt.action();
            })

            if (idx < this.sheetOptions.length - 1) {
              Divider()
                .strokeWidth(1)
                .color('#1C1C20')
                .margin({ left: 20, right: 20 })
            }
          }, (opt: SheetOption, idx: number) => idx.toString())
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 560 })
      .scrollBar(BarState.Off)
      .align(Alignment.Center)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 30 })
    .backgroundColor('#16161A')
    .alignItems(HorizontalAlign.Center)
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
            SwitchRow({ title: '徕卡徽章', hint: '暂不可用：真机实测图库未显示 LEICA 角标，'
              + '已停用徽章元数据写入（EXIF 迁移不受影响）',
              isOn: false, rowEnabled: false,
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
              hint: 'RAW 解码亮度：标准 0.01 / 提亮 0.03 / 强力提亮 0.04，重新导入时生效', rowEnabled: true,
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
    .bindSheet($$this.sheetVisible, this.sheetPanel(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: '#16161A'
    })
  }
}
