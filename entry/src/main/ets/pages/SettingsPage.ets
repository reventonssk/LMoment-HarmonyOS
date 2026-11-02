/**
 * 设置页（Batch B）：默认分类 / 记住分类 / 关于 可交互；后续批次功能的行先渲染
 * 但禁用并标「后续批次启用」（逐批解锁）。修改默认分类不影响主界面当前分类，
 * 仅影响下次冷启动（与原版 SettingsActivity 口径一致）。
 */

import { SettingsStore } from '../engine/SettingsStore';
import { StyleCategories } from '../engine/StyleDefs';

@Entry
@Component
struct SettingsPage {
  @State defaultLabel: string = '';
  @State rememberOn: boolean = false;
  /** 关闭「记住分类」时恢复的固定分类（会话内记忆，默认 L-Moment）。 */
  private fixedBackup: string = 'all';

  aboutToAppear(): void {
    this.refresh();
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

  private pickRemember(): void {
    const onSheet: SheetInfo = {
      title: '开启（每次启动进入上次分类）',
      action: () => {
        this.setRemember(true);
      }
    };
    const offSheet: SheetInfo = {
      title: '关闭（恢复默认分类）',
      action: () => {
        this.setRemember(false);
      }
    };
    this.getUIContext().showActionSheet({
      title: '记住分类',
      message: '选择是否记忆上次使用的分类',
      sheets: [onSheet, offSheet]
    });
  }

  private setRemember(on: boolean): void {
    SettingsStore.setDefaultSetting(on ? SettingsStore.VALUE_LAST : this.fixedBackup);
    this.refresh();
  }

  private openAbout(): void {
    this.getUIContext().showAlertDialog({
      title: '关于',
      message: 'L-Moment for HarmonyOS\n离线色彩风格引擎 · 对齐原版 1.4.1\n\n'
        + '已启用：风格 / 八档调整（含柔光）/ 拍照 · 换图 / 设置',
      autoCancel: true,
      confirm: {
        value: '确定',
        action: () => {
        }
      }
    });
  }

  private pickHdrBoost(): void {
    const light: SheetInfo = { title: '轻（1.5EV）', action: () => {
      SettingsStore.setHdrBoostLevel(0);
    } };
    const standard: SheetInfo = { title: '标准（2.0EV）', action: () => {
      SettingsStore.setHdrBoostLevel(1);
    } };
    const strong: SheetInfo = { title: '强（2.5EV）', action: () => {
      SettingsStore.setHdrBoostLevel(2);
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

  @Builder
  private srow(title: string, value: string, hint: string, tag: string, enabled: boolean,
    tap: () => void) {
    Row() {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(enabled ? '#EDEDED' : '#7C7C80')
        if (hint !== '') {
          Text(hint)
            .fontSize(11)
            .fontColor('#8A8A8A')
            .lineHeight(16)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (tag !== '') {
        Text(tag)
          .fontSize(10)
          .fontColor('#6E6E72')
          .backgroundColor('#1E1E22')
          .borderRadius(6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ right: 8 })
      }
      Text(value)
        .fontSize(13)
        .fontColor(enabled ? '#E8B84B' : '#6E6E72')
        .maxLines(1)
        .constraintSize({ maxWidth: '42%' })
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (enabled) {
        tap();
      }
    })
  }

  @Builder
  private dividerLine() {
    Divider()
      .color('#1C1C20')
      .margin({ left: 20 })
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

      Scroll() {
        Column() {
          this.srow('默认分类', this.defaultLabel, '冷启动进入的分类；修改不影响当前界面', '',
            true, () => {
              this.pickDefault();
            })
          this.dividerLine()
          this.srow('记住分类', this.rememberOn ? '开' : '关',
            '开启后每次启动进入上次使用的分类', '', true, () => {
              this.pickRemember();
            })
          this.dividerLine()
          this.srow('置顶跨分类', SettingsStore.pinnedCrossCategory() ? '开' : '关',
            '置顶色彩是否在所有分类排最前（默认关）', '后续批次启用', false, () => {
            })
          this.dividerLine()
          this.srow('全像素导出', SettingsStore.fullResEnabled() ? '开' : '关',
            '50MP / 200MP 图的最高导出像素（默认开）', '后续批次启用', false, () => {
            })
          this.dividerLine()
          this.srow('M9 8192', SettingsStore.m9HiResEnabled() ? '开' : '关',
            'M9 / M9D 的 50MP 级实验导出档（需先开全像素）', '后续批次启用', false, () => {
            })
          this.dividerLine()
          this.srow('RAW 亮度档', this.rawLevelLabel(),
            'RAW 解码亮度：标准 0.01 / 提亮 0.03 / 强力提亮 0.04', '后续批次启用', false, () => {
            })
          this.dividerLine()
          this.srow('伪 16bit 线性', SettingsStore.pseudoLinearEnabled() ? '开' : '关',
            'JPG / HEIF 的七档影调在 16 位域运算（默认关）', '后续批次启用', false, () => {
            })
          this.dividerLine()
          this.srow('HDR 强度', SettingsStore.hdrBoostLevelName(SettingsStore.hdrBoostLevel()),
            'HDR 增益图幅度：轻 1.5EV / 标准 2.0EV / 强 2.5EV', '', true, () => {
              this.pickHdrBoost();
            })
          this.dividerLine()
          this.srow('HDR 默认开', SettingsStore.hdrDefaultOn() ? '开' : '关',
            '导入普通图片时 HDR 按钮的默认状态（默认关）', '', true, () => {
              this.toggleHdrDefault();
            })
          this.dividerLine()
          this.srow('超分档位', '主界面入口',
            '主界面标题栏：超分快 / 超分质；导出时按当前档位放大 2×', '', true, () => {
              this.getUIContext().getPromptAction().showToast({ message: '请在主界面标题栏切换超分档位' });
            })
          this.dividerLine()
          this.srow('徕卡徽章', SettingsStore.leicaBadgeEnabled() ? '开' : '关',
            '导出写入徕卡识别元数据（默认开）', '后续批次启用', false, () => {
            })
          this.dividerLine()
          this.srow('应用内拍摄', SettingsStore.inappCaptureMode(),
            'auto = 运行时探测（RAW / YUV / 系统相机）；off = 直接系统相机',
            '后续批次启用', false, () => {
            })
          this.dividerLine()
          this.srow('关于', '1.4.1', 'L-Moment for HarmonyOS · 对齐原版 1.4.1', '', true, () => {
            this.openAbout();
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0E0E10')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
