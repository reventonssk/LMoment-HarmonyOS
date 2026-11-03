/**
 * 轻量设置存储（@ohos.data.preferences），键名与默认值对齐原版 SettingsStore.kt。
 *
 * 单例：Index aboutToAppear 首次 init(context)；未初始化时读取返回 Kotlin 同款
 * 默认值、写入静默丢弃。raw_thr_level 键带机型（deviceInfo.productModel），不进备份。
 * E+ 扩展键 inapp_capture_mode（auto/off）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { StyleCategories } from './StyleDefs';
import { ImmersiveStyle } from '../common/ImmersiveStyle';

const FILE_NAME: string = 'lm_settings';
const KEY_DEFAULT: string = 'default_category';
const KEY_LAST: string = 'last_category';
const KEY_COACH: string = 'coach_shown';
const KEY_PINNED: string = 'pinned_ids';
const KEY_PINNED_CROSS: string = 'pinned_cross_category';
const KEY_SHARE_SEEN: string = 'share_seen_sig';
const KEY_RAW_THR: string = 'raw_thr_level';
const KEY_RAW_HINT: string = 'raw_hint_shown';
const KEY_FULL_RES: string = 'full_res_export';
const KEY_M9_HIRES: string = 'm9_hires_export';
const KEY_LEICA_BADGE: string = 'leica_badge';
const KEY_PSEUDO_LINEAR: string = 'pseudo_linear_work';
const KEY_HDR_BOOST: string = 'hdr_boost_level';
const KEY_HDR_HINT: string = 'hdr_hint_shown';
const KEY_HDR_DEFAULT_ON: string = 'hdr_default_on';
const KEY_INAPP_CAPTURE: string = 'inapp_capture_mode';
const KEY_IMMERSIVE_LEVEL: string = 'immersive_material_mode';

export class SettingsStore {
  /** 「记忆上次」在 default_category 里的取值。 */
  static readonly VALUE_LAST: string = 'last';

  private static p: preferences.Preferences | undefined = undefined;

  static init(context: common.Context): void {
    if (SettingsStore.p === undefined) {
      SettingsStore.p = preferences.getPreferencesSync(context, { name: FILE_NAME });
    }
  }

  // ---- 基础读写 ----

  private static str(key: string, def: string): string {
    const p = SettingsStore.p;
    if (p === undefined) {
      return def;
    }
    return p.getSync(key, def) as string;
  }

  private static bool(key: string, def: boolean): boolean {
    const p = SettingsStore.p;
    if (p === undefined) {
      return def;
    }
    return p.getSync(key, def) as boolean;
  }

  private static num(key: string, def: number): number {
    const p = SettingsStore.p;
    if (p === undefined) {
      return def;
    }
    const v = p.getSync(key, def) as number;
    return isNaN(v) ? def : v;
  }

  private static put(key: string, value: preferences.ValueType): void {
    const p = SettingsStore.p;
    if (p === undefined) {
      return;
    }
    p.putSync(key, value);
    p.flush().catch(() => {
    });
  }

  // ---- 默认分类 / 上次分类 ----

  static defaultSetting(): string {
    return SettingsStore.str(KEY_DEFAULT, 'all');
  }

  static setDefaultSetting(value: string): void {
    SettingsStore.put(KEY_DEFAULT, value);
  }

  static lastCategory(): string {
    return SettingsStore.str(KEY_LAST, '');
  }

  static setLastCategory(id: string): void {
    SettingsStore.put(KEY_LAST, id);
  }

  /** 冷启动进入的分类：固定值直接用，「记忆上次」取 last，无效回落 L-Moment。 */
  static startCategory(): string {
    const def = SettingsStore.defaultSetting();
    const target = def === SettingsStore.VALUE_LAST ? SettingsStore.lastCategory() : def;
    return SettingsStore.validCategory(target);
  }

  private static validCategory(id: string): string {
    for (let i = 0; i < StyleCategories.LIST.length; i++) {
      if (StyleCategories.LIST[i].id === id) {
        return id;
      }
    }
    return 'all';
  }

  // ---- 首用引导 ----

  static isCoachShown(): boolean {
    return SettingsStore.bool(KEY_COACH, false);
  }

  static markCoachShown(): void {
    SettingsStore.put(KEY_COACH, true);
  }

  // ---- 置顶（内置与自定义共用 id 空间，Batch G 接 UI）----

  /** 置顶项 id，最近置顶的在最前（保序 JSON 数组；StringSet 无序不可用）。 */
  static pinnedIds(): string[] {
    const raw = SettingsStore.str(KEY_PINNED, '');
    if (raw === '') {
      return [];
    }
    const out: string[] = [];
    try {
      const parsed: Object | null = JSON.parse(raw);
      if (parsed instanceof Array) {
        const arr: string[] = parsed as string[];
        for (let i = 0; i < arr.length; i++) {
          const s = arr[i];
          if (typeof s === 'string' && s.length > 0) {
            out.push(s);
          }
        }
      }
    } catch (e) {
    }
    return out;
  }

  static setPinnedIds(ids: string[]): void {
    SettingsStore.put(KEY_PINNED, JSON.stringify(ids));
  }

  static isPinned(id: string): boolean {
    return SettingsStore.pinnedIds().includes(id);
  }

  /** 切换置顶状态，返回切换后是否置顶。 */
  static togglePinned(id: string): boolean {
    const cur = SettingsStore.pinnedIds();
    if (cur.includes(id)) {
      SettingsStore.setPinnedIds(cur.filter((v: string) => v !== id));
      return false;
    }
    SettingsStore.setPinnedIds([id].concat(cur));
    return true;
  }

  static removePinned(id: string): void {
    const cur = SettingsStore.pinnedIds();
    if (cur.includes(id)) {
      SettingsStore.setPinnedIds(cur.filter((v: string) => v !== id));
    }
  }

  /** 置顶跨分类显示（默认关：置顶只出现在 L-Moment 与所属分类）。 */
  static pinnedCrossCategory(): boolean {
    return SettingsStore.bool(KEY_PINNED_CROSS, false);
  }

  static setPinnedCrossCategory(enabled: boolean): void {
    SettingsStore.put(KEY_PINNED_CROSS, enabled);
  }

  // ---- 分享指令 ----

  /** 最近一次已导入（或已损坏提示过）的指令指纹，避免切前台重复弹窗。 */
  static shareSeenSignature(): string {
    return SettingsStore.str(KEY_SHARE_SEEN, '');
  }

  static markShareSeen(sig: string): void {
    SettingsStore.put(KEY_SHARE_SEEN, sig);
  }

  // ---- RAW 解码亮度（按机型记忆，Batch E 接入）----

  static rawThrLevel(): number {
    const v = SettingsStore.num(SettingsStore.rawThrKey(), 1);
    return Math.min(2, Math.max(0, Math.round(v)));
  }

  static setRawThrLevel(level: number): void {
    SettingsStore.put(SettingsStore.rawThrKey(), Math.min(2, Math.max(0, Math.round(level))));
  }

  /** 档位 → LibRaw auto_bright_thr：0 标准 0.01 / 1 提亮 0.03（默认）/ 2 强力 0.04。 */
  static rawThr(): number {
    const lv = SettingsStore.rawThrLevel();
    if (lv === 1) {
      return 0.03;
    }
    if (lv === 2) {
      return 0.04;
    }
    return 0.01;
  }

  private static rawThrKey(): string {
    const model = deviceInfo.productModel;
    return KEY_RAW_THR + ':' + (model.length > 0 ? model : 'unknown');
  }

  /** 首次导入 RAW 的提示是否已展示（全局一次）。 */
  static isRawHintShown(): boolean {
    return SettingsStore.bool(KEY_RAW_HINT, false);
  }

  static markRawHintShown(): void {
    SettingsStore.put(KEY_RAW_HINT, true);
  }

  // ---- HDR（Batch C 接入）----

  /** HDR 说明弹窗是否已展示（展示即标记，不区分用户是否确认）。 */
  static isHdrHintShown(): boolean {
    return SettingsStore.bool(KEY_HDR_HINT, false);
  }

  static markHdrHintShown(): void {
    SettingsStore.put(KEY_HDR_HINT, true);
  }

  /** HDR 按钮记忆值（跨重启 + 换图保持，默认关；只在用户点按钮时写入）。 */
  static hdrDefaultOn(): boolean {
    return SettingsStore.bool(KEY_HDR_DEFAULT_ON, false);
  }

  static setHdrDefaultOn(on: boolean): void {
    SettingsStore.put(KEY_HDR_DEFAULT_ON, on);
  }

  /** HDR 增益图幅度档：0 轻 1.5EV（默认）/ 1 标准 2.0EV / 2 强 2.5EV。 */
  static hdrBoostLevel(): number {
    const v = SettingsStore.num(KEY_HDR_BOOST, 0);
    return Math.min(2, Math.max(0, Math.round(v)));
  }

  static setHdrBoostLevel(level: number): void {
    SettingsStore.put(KEY_HDR_BOOST, Math.min(2, Math.max(0, Math.round(level))));
  }

  /** 档位显示名（弹窗与设置页共用）。 */
  static hdrBoostLevelName(level: number): string {
    if (level === 0) {
      return '轻';
    }
    if (level === 2) {
      return '强';
    }
    return '标准';
  }

  /** RAW 的 HDR 档位是强度系数（真实增益由线性数据决定，档位只整体缩放）。 */
  static rawHdrStrength(level: number): number {
    if (level === 0) {
      return 0.6;
    }
    if (level === 2) {
      return 1.4;
    }
    return 1.0;
  }

  // ---- 全像素导出（Batch F 接入）----

  /** 全像素导出（默认开；低端机由像素预算分档强制回落）。 */
  static fullResEnabled(): boolean {
    return SettingsStore.bool(KEY_FULL_RES, true);
  }

  static setFullResEnabled(enabled: boolean): void {
    SettingsStore.put(KEY_FULL_RES, enabled);
  }

  /** M9 / M9D 8192 超高分辨率实验档（默认关，需全像素导出开启）。 */
  static m9HiResEnabled(): boolean {
    return SettingsStore.bool(KEY_M9_HIRES, false);
  }

  static setM9HiResEnabled(enabled: boolean): void {
    SettingsStore.put(KEY_M9_HIRES, enabled);
  }

  // ---- 徕卡徽章（Batch F 接入）----

  static leicaBadgeEnabled(): boolean {
    return SettingsStore.bool(KEY_LEICA_BADGE, true);
  }

  static setLeicaBadgeEnabled(enabled: boolean): void {
    SettingsStore.put(KEY_LEICA_BADGE, enabled);
  }

  // ---- 高位深工作域（Batch E 接入）----

  static pseudoLinearEnabled(): boolean {
    return SettingsStore.bool(KEY_PSEUDO_LINEAR, false);
  }

  static setPseudoLinearEnabled(enabled: boolean): void {
    SettingsStore.put(KEY_PSEUDO_LINEAR, enabled);
  }

  // ---- 应用内拍摄（Batch E+ 接入）----

  /** auto = 运行时探测（RAW 直拍 → YUV → cameraPicker）；off = 直接系统相机。 */
  static inappCaptureMode(): string {
    return SettingsStore.str(KEY_INAPP_CAPTURE, 'auto');
  }

  static setInappCaptureMode(mode: string): void {
    SettingsStore.put(KEY_INAPP_CAPTURE, mode === 'off' ? 'off' : 'auto');
  }

  // ---- 沉浸光感（对齐 zhihu-plus-plus-HMOS 四挡）----

  /** 沉浸光感挡位：adaptive（默认）/ exquisite / gentle / smooth。 */
  static immersiveLevel(): string {
    return SettingsStore.str(KEY_IMMERSIVE_LEVEL, 'adaptive');
  }

  static setImmersiveLevel(mode: string): void {
    SettingsStore.put(KEY_IMMERSIVE_LEVEL, mode);
    ImmersiveStyle.publish(mode);
  }
}
