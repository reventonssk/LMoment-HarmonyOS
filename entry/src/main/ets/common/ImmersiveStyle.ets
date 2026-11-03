/**
 * 沉浸光感（Immersive Light Sense）挡位与能力检测。
 * 挡位对齐 hdsMaterial.MaterialLevel 四挡：自适应 / 精美 / 轻柔 / 流畅。
 * 能力检测启动时执行一次并经 AppStorage 广播；组件不得在 build 中反复查询设备。
 * 实现参考 zhihu-plus-plus-HMOS（Apache-2.0）ImmersiveMaterialStyles / MaterialCanvas。
 */

import { hdsMaterial } from '@kit.UIDesignKit';

/** 沉浸光感挡位（存储值即枚举值，与 HDS 四挡一一对应）。 */
export enum ImmersiveLevel {
  ADAPTIVE = 'adaptive',
  EXQUISITE = 'exquisite',
  GENTLE = 'gentle',
  SMOOTH = 'smooth'
}

/** AppStorage 广播键（@StorageProp 需字面量，勿动态拼接）。 */
const KEY_LEVEL: string = 'immersiveMaterialLevel';
const KEY_SUPPORT: string = 'immersiveMaterialSupported';

export class ImmersiveStyle {
  /** 启动时探测一次：设备是否支持 IMMERSIVE 沉浸材质（不支持则组件走模糊降级）。 */
  static probe(): void {
    let supported = false;
    try {
      supported = hdsMaterial.getSystemMaterialTypes().includes(hdsMaterial.MaterialType.IMMERSIVE);
    } catch (e) {
      supported = false;
    }
    AppStorage.setOrCreate(KEY_SUPPORT, supported);
  }

  /** 当前设备是否支持沉浸材质（probe 后有效；未 probe 按不支持处理走降级）。 */
  static supported(): boolean {
    return AppStorage.get<boolean>(KEY_SUPPORT) === true;
  }

  /** 广播当前挡位（设置页切换时调用，组件经 @StorageProp 即时生效）。 */
  static publish(mode: string): void {
    AppStorage.setOrCreate(KEY_LEVEL, mode);
  }

  /** 挡位 → HDS MaterialLevel；设备不支持时精美/轻柔回落流畅（对齐参考项目策略）。 */
  static hdsLevelOf(mode: string): hdsMaterial.MaterialLevel {
    const supported = ImmersiveStyle.supported();
    if (mode === ImmersiveLevel.EXQUISITE && supported) {
      return hdsMaterial.MaterialLevel.EXQUISITE;
    }
    if (mode === ImmersiveLevel.GENTLE && supported) {
      return hdsMaterial.MaterialLevel.GENTLE;
    }
    if (mode === ImmersiveLevel.SMOOTH) {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  /** 挡位显示名（设置行与 ActionSheet 共用）。 */
  static labelOf(mode: string): string {
    if (mode === ImmersiveLevel.EXQUISITE) {
      return '精美';
    }
    if (mode === ImmersiveLevel.GENTLE) {
      return '轻柔';
    }
    if (mode === ImmersiveLevel.SMOOTH) {
      return '流畅';
    }
    return '自适应';
  }

  /** 挡位说明文案。 */
  static descOf(mode: string): string {
    if (mode === ImmersiveLevel.EXQUISITE) {
      return '更精美的材质效果，性能开销较高';
    }
    if (mode === ImmersiveLevel.GENTLE) {
      return '使用轻柔的材质效果';
    }
    if (mode === ImmersiveLevel.SMOOTH) {
      return '优先保证流畅，减少材质性能开销';
    }
    return '根据设备性能自动选择材质效果';
  }

  /** 选项顺序：自适应 / 精美 / 轻柔 / 流畅。 */
  static allModes(): string[] {
    return [ImmersiveLevel.ADAPTIVE, ImmersiveLevel.EXQUISITE,
      ImmersiveLevel.GENTLE, ImmersiveLevel.SMOOTH];
  }

  /** 存储值归一化：未知/缺失回落自适应。 */
  static normalize(mode: string): string {
    if (mode === ImmersiveLevel.EXQUISITE || mode === ImmersiveLevel.GENTLE
      || mode === ImmersiveLevel.SMOOTH) {
      return mode;
    }
    return ImmersiveLevel.ADAPTIVE;
  }
}
