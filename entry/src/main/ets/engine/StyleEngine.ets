/**
 * 统一风格处理链（移植自 LeicaEngine 的 repo 构建口径）。
 *
 * LUT 链：[P9 pre] → LUT 查表 → [P9 post] → 颗粒/暗角；
 * M3 链：M3Mono 黑白滤镜；SA 链：Lab 仿射；
 * 神经链（MODEL_M9 等）：由 NeuralEngine 推理，不经过本文件。
 *
 * applyPx 仅收纯标量参数（不含 StyleDef 类实例），可直接在 taskpool 工作线程调用。
 */

import { Lut3D } from './Lut3D';
import { GrainVignette } from './GrainVignette';
import { StyleAModel } from './StyleAEngine';
import { M3MonoEngine } from './M3MonoEngine';
import { P9Post } from './P9Post';
import { StyleDef, StyleMode } from './StyleDefs';
import { yieldUI } from './PixAsync';

export class StyleEngine {
  /**
   * 原地改写 RGBA 字节流。
   * @return 提示文案（'' = 正常无提示；非空 = 降级说明，由 UI 展示）
   */
  static apply(px: Uint8Array, w: number, h: number, def: StyleDef,
    lut: Lut3D | undefined, saModel: StyleAModel | undefined): string {
    return StyleEngine.applyPx(px, w, h, def.mode, def.grain, def.vignette, def.p9, lut, saModel);
  }

  /** 纯参数版（taskpool 可用）。 */
  static applyPx(px: Uint8Array, w: number, h: number, mode: StyleMode,
    grain: number, vignette: number, p9: boolean,
    lut: Lut3D | undefined, saModel: StyleAModel | undefined): string {
    switch (mode) {
      case StyleMode.LUT: {
        if (lut === undefined) {
          return 'LUT 资产缺失，已输出原图';
        }
        if (p9) {
          P9Post.pre(px, w, h);
        }
        lut.applyPx(px);
        if (p9) {
          P9Post.post(px, w, h);
        }
        GrainVignette.apply(px, w, h, grain, vignette, h, 0);
        return '';
      }
      case StyleMode.M3: {
        M3MonoEngine.apply(px, w, h);
        return '';
      }
      case StyleMode.SA: {
        if (saModel === undefined) {
          return 'Style A 参数缺失，已输出原图';
        }
        saModel.applyPx(px);
        return '';
      }
      case StyleMode.MODEL_PASSTHROUGH: {
        return '模型链路未随仓库分发，已按降级口径输出原图';
      }
      case StyleMode.CUSTOM: {
        if (lut === undefined) {
          return '自定义色彩数据缺失，已输出原图';
        }
        lut.applyPx(px);
        return '';
      }
      default: {
        return '';
      }
    }
  }

  /** ColorMatrix 饱和度+暖偏+对比度后推（M9P 激进推子），量化后 TPDF ±1 抖动。主线程分块让出。 */
  static async boost(px: Uint8Array, w: number, h: number, sat: number, contrast: number,
    warmGain: number): Promise<void> {
    const inc = 1 - sat;
    const m00 = 0.213 + 0.787 * sat;
    const m01 = 0.715 * inc;
    const m02 = 0.072 * inc;
    const m10 = 0.213 * inc;
    const m11 = 0.715 + 0.285 * sat;
    const m12 = 0.072 * inc;
    const m20 = 0.213 * inc;
    const m21 = 0.715 * inc;
    const m22 = 0.072 + 0.928 * sat;
    const wr = 1 + warmGain;
    const wb = 1 - warmGain;
    const ct = 128 * (1 - contrast);
    let st = (0x9E3779B9 ^ Date.now()) | 0;
    const rows = Math.max(1, Math.floor(262144 / w));
    for (let y0 = 0; y0 < h; y0 += rows) {
      const end = (y0 + rows < h ? y0 + rows : h) * w * 4;
      for (let i4 = y0 * w * 4; i4 + 3 < end; i4 += 4) {
        const r = px[i4];
        const g = px[i4 + 1];
        const b = px[i4 + 2];
        let r2 = (m00 * r + m01 * g + m02 * b) * wr;
        let g2 = m10 * r + m11 * g + m12 * b;
        let b2 = (m20 * r + m21 * g + m22 * b) * wb;
        r2 = contrast * r2 + ct;
        g2 = contrast * g2 + ct;
        b2 = contrast * b2 + ct;
        px[i4] = StyleEngine.quantizeDither(r2, st);
        st = StyleEngine.nextSeed(StyleEngine.nextSeed(st));
        px[i4 + 1] = StyleEngine.quantizeDither(g2, st);
        st = StyleEngine.nextSeed(StyleEngine.nextSeed(st));
        px[i4 + 2] = StyleEngine.quantizeDither(b2, st);
        st = StyleEngine.nextSeed(StyleEngine.nextSeed(st));
      }
      await yieldUI();
    }
  }

  private static nextSeed(st: number): number {
    let s = (st ^ (st << 13)) | 0;
    s = (s ^ (s >>> 17)) | 0;
    s = (s ^ (s << 5)) | 0;
    return s;
  }

  /** 量化到 8bit 后叠加 ±1 TPDF 抖动。 */
  private static quantizeDither(v: number, st: number): number {
    let q = Math.floor(v + 0.5);
    const u1 = (st & 0xFFFFFF) / 16777216;
    const s2 = StyleEngine.nextSeed(st);
    const u2 = (s2 & 0xFFFFFF) / 16777216;
    const dv = u1 + u2 - 1;
    q += dv >= 0.5 ? 1 : (dv < -0.5 ? -1 : 0);
    if (q < 0) {
      return 0;
    }
    if (q > 255) {
      return 255;
    }
    return q;
  }
}
