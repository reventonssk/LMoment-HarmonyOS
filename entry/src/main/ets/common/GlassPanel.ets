/**
 * 玻璃画布：空 HdsTabs 仅作沉浸光感材质承载层（复刻 zhihu-plus-plus-HMOS MaterialCanvas，
 * Apache-2.0），透过 HDS 组件自身材质渲染路径呈现真机玻璃，规避 uiMaterial.systemMaterial
 * 的白底遮挡问题。设备不支持时降级为组件模糊。画布不响应点击。
 *
 * 关键：barFloatingStyle.barWidth 必须三档断点都显式传宽并设置组件级 barWidth/barHeight，
 * 否则无页签内容的 bar 会塌缩成最小宽度的竖条（真机表现为「玻璃细棍」）。
 */

import { DividerMode, hdsMaterial, HdsTabs } from '@kit.UIDesignKit';
import { ImmersiveStyle } from './ImmersiveStyle';

/** 按字符宽度估算文本宽度（vp）：CJK/全角按 fontSize，其余按 0.6 倍。 */
export function estimateTextWidth(label: string, fontSizeVp: number): number {
  let w = 0;
  for (let i = 0; i < label.length; i++) {
    const code = label.charCodeAt(i);
    w += code > 0x2E80 ? fontSizeVp : fontSizeVp * 0.6;
  }
  return w;
}

/** 纯玻璃画布：给定宽高渲染材质层，无内容。 */
@Component
export struct GlassCanvas {
  @Prop canvasWidth: number = 0;
  @Prop canvasHeight: number = 0;
  @StorageProp('immersiveMaterialLevel') private level: string = 'adaptive';
  @State private useMaterial: boolean = true;

  aboutToAppear(): void {
    this.useMaterial = ImmersiveStyle.supported();
  }

  build() {
    if (this.useMaterial) {
      HdsTabs({ barPosition: BarPosition.End }) {
      }
      .width(this.canvasWidth)
      .height(this.canvasHeight)
      .barPosition(BarPosition.End)
      .barWidth(this.canvasWidth)
      .barHeight(this.canvasHeight)
      .barOverlap(true)
      .clip(false)
      .backgroundColor(Color.Transparent)
      .vertical(false)
      .divider({ mode: DividerMode.NONE })
      .hitTestBehavior(HitTestMode.None)
      .barFloatingStyle({
        barWidth: {
          smallWidth: this.canvasWidth,
          mediumWidth: this.canvasWidth,
          largeWidth: this.canvasWidth
        },
        barBottomMargin: 0,
        barSideMargin: 0,
        // gradientMask 显式抵消默认渐变遮罩（GlassButton 同款，falsy 值会被 HDS 视为未设置）
        gradientMask: { maskColor: '#00000000', maskHeight: 1 },
        lightColor: Color.White,
        systemMaterialEffect: {
          // materialType 用 IMMERSIVE（PiliPlus 沉浸底栏同款光效），非 zhihu 参考的 ADAPTIVE；
          // materialLevel 按用户挡位 + 设备能力解析。
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: ImmersiveStyle.hdsLevelOf(this.level)
        },
        thermoCtrl: true
      })
      // IMMERSIVE 下缺省 bar 背景是不透明深灰（真机实测 #1D1D1D 遮死透出），
      // 必须显式透明（GlassButton 同款），材质层才能透出后方内容
      .barBackgroundColor('#00000000')
    } else {
      // 降级：组件模糊（不支持沉浸材质的设备）
      Column()
        .width(this.canvasWidth)
        .height(this.canvasHeight)
        .backgroundColor('rgba(22,22,26,0.72)')
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN)
    }
  }
}

/**
 * 方形玻璃遮罩容器：内容决定高度，宽度随容器 100%；背景为矩形高斯模糊
 * （backgroundBlurStyle.COMPONENT_THICK）+ 半透明深色，无圆角——直角玻璃边缘。
 * 与 GlassCanvas（HDS 沉浸材质，柔光圆角）互补：大面板用本组件保证方形遮罩，
 * 小按钮/托盘用 GlassCanvas 保留材质光感。用法：GlassPanel() { 内容组件 }。
 */
@Component
export struct GlassPanel {
  @BuilderParam panelContent: () => void = this.emptyContent;

  @Builder
  private emptyContent(): void {
  }

  build() {
    Column() {
      this.panelContent()
    }
    .width('100%')
    .backgroundColor('rgba(0,0,0,0.6)')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  }
}

/**
 * 玻璃按钮：单页签 HdsTabs 悬浮栏承载 IMMERSIVE/EXQUISITE 材质（复刻 PiliPlus-ohos
 * hdsMsgButton，BSD-3）。触摸按下时由 HDS 材质渲染光响应（PiliPlus 底栏页签同款触摸光效）。
 * 关键点（PiliPlus 踩坑记录）：
 * - gradientMask 必须显式给 '#00000000'/1 抵消默认渐变遮罩；不能写 Color.Transparent/0
 *   （falsy，HDS 视为未设置回退默认，露灰色方块）。
 * - clipShape 兜底把 HDS 画的任何底/遮罩裁成胶囊形。
 * - barFloatingStyle.barWidth 三档断点显式传宽 + 组件级 width/height，否则 bar 塌缩。
 * 设备不支持沉浸材质时降级为普通 Button（原深底金字样式）。
 */
@Component
export struct GlassButton {
  @Prop label: string = '';
  @Prop buttonWidth: number = 84;
  @Prop buttonHeight: number = 38;
  @Prop labelSize: number = 14;
  @Prop labelColor: string = '#E8B84B';
  @Prop selected: boolean = false;
  @State private useMaterial: boolean = true;
  clickAction: () => void = (): void => {};
  longPressAction: () => void = (): void => {};

  aboutToAppear(): void {
    this.useMaterial = ImmersiveStyle.supported();
  }

  @Builder
  private labelBuilder(): void {
    Text(this.label)
      .fontSize(this.labelSize)
      .fontColor(this.labelColor)
      .maxLines(1)
      .align(Alignment.Center)
  }

  build() {
    if (this.useMaterial) {
      Stack() {
        HdsTabs() {
          TabContent() {
          }
          .tabBar(this.labelBuilder())
        }
        .scrollable(false)
        .barOverlap(true)
        .barPosition(BarPosition.End)
        .vertical(false)
        .barMode(BarMode.Fixed)
        .barHeight(this.buttonHeight)
        .barFloatingStyle({
          barWidth: {
            smallWidth: this.buttonWidth,
            mediumWidth: this.buttonWidth,
            largeWidth: this.buttonWidth
          },
          barSideMargin: 0,
          barBottomMargin: 0,
          gradientMask: { maskColor: '#00000000', maskHeight: 1 },
          systemMaterialEffect: {
            // 按钮很小，直接用最高等级（PiliPlus hdsMsgButton 同策略）
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
          }
        })
        .barBackgroundColor('#00000000')
        .divider({ mode: DividerMode.NONE })
        .onTabBarClick((_index: number): void => {
          this.clickAction();
        })
        .width(this.buttonWidth)
        .height(this.buttonHeight)
        .clipShape(new Rect({
          width: this.buttonWidth,
          height: this.buttonHeight,
          radiusWidth: this.buttonHeight / 2,
          radiusHeight: this.buttonHeight / 2
        }))
        if (this.selected) {
          Column()
            .width('100%')
            .height('100%')
            .hitTestBehavior(HitTestMode.None)
            .border({
              width: 1.5,
              color: '#E8B84B',
              radius: this.buttonHeight / 2
            })
        }
      }
      .width(this.buttonWidth)
      .height(this.buttonHeight)
      // 长按手势挂外层 Stack：挂 HdsTabs 上会被 HDS 内部触摸处理吞掉（真机实测不触发）
      .gesture(LongPressGesture({ repeat: false, duration: 350 })
        .onAction((): void => {
          this.longPressAction();
        }))
    } else {
      Button(this.label)
        .width(this.buttonWidth)
        .height(this.buttonHeight)
        .backgroundColor(this.selected ? '#E8B84B' : '#26262A')
        .fontColor(this.selected ? '#1A1A1A' : this.labelColor)
        .fontSize(this.labelSize)
        .borderRadius(this.buttonHeight / 2)
        .onClick((): void => {
          this.clickAction();
        })
        .gesture(LongPressGesture({ repeat: false, duration: 350 })
          .onAction((): void => {
            this.longPressAction();
          }))
    }
  }
}
