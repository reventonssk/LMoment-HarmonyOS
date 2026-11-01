/**
 * 颗粒 + 暗角引擎（移植自 MadridShader.java）。
 *
 * 三层结构：
 *  1. 中心感知亮度 LUT（P_LUT[i] = 1/100^(1-x)）
 *  2. 径向暗角：smoothstep(1.4, 0.2, dist)，强度缩放「压暗量」保持中心不变量
 *  3. 亮度调制颗粒：NOISE[65536]（6 组 sin-hash 均值场），(1-luma) 加权
 */

import { yieldUI } from './PixAsync';

export class GrainVignette {
  private static pLut: Float32Array = new Float32Array(256);
  private static noise: Float32Array = new Float32Array(65536);
  private static inited: boolean = false;

  /** 原地改写 RGBA 字节流。fullH/yOffset 用于条带场景（预览传 h/0）。同步全量（taskpool 内使用）。 */
  static apply(px: Uint8Array, w: number, h: number, density: number, vignetteStrength: number,
    fullH: number, yOffset: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    GrainVignette.init();
    if (fullH <= 0) {
      fullH = h;
    }
    GrainVignette.applyRows(px, w, 0, h, density, vignetteStrength, fullH, yOffset);
  }

  /** 主线程分块版：行块间让出主线程，避免长任务阻塞触发 THREAD_BLOCK 看门狗。 */
  static async applyChunked(px: Uint8Array, w: number, h: number, density: number,
    vignetteStrength: number, fullH: number, yOffset: number): Promise<void> {
    if (w <= 0 || h <= 0) {
      return;
    }
    GrainVignette.init();
    if (fullH <= 0) {
      fullH = h;
    }
    const rows = Math.max(1, Math.floor(262144 / w));
    for (let y0 = 0; y0 < h; y0 += rows) {
      const y1 = y0 + rows < h ? y0 + rows : h;
      GrainVignette.applyRows(px, w, y0, y1, density, vignetteStrength, fullH, yOffset);
      await yieldUI();
    }
  }

  private static applyRows(px: Uint8Array, w: number, y0: number, y1: number,
    density: number, vignetteStrength: number, fullH: number, yOffset: number): void {
    const pLut = GrainVignette.pLut;
    const noise = GrainVignette.noise;
    let i4 = y0 * w * 4;
    for (let y = y0; y < y1; y++) {
      const gy = yOffset + y;
      const ny = gy / fullH;
      for (let x = 0; x < w; x++) {
        const r = px[i4] / 255;
        const g = px[i4 + 1] / 255;
        const b = px[i4 + 2] / 255;

        const dx = (x / w - 0.5) * 0.75;
        const dy = ny - 0.5;
        const dist = Math.sqrt(dx * dx + dy * dy);

        const lumIdx = GrainVignette.clamp255(0.2125 * r + 0.7154 * g + 0.0721 * b);
        const lum = pLut[lumIdx];
        const vraw = GrainVignette.smoothstep(1.4, 0.2, dist);
        const vignette = 1 - vignetteStrength * (1 - vraw);
        const m = (1 - lum) * vignette + lum;

        let rr = r * m;
        let gg = g * m;
        let bb = b * m;

        let grainAmt = (1 - (0.299 * rr + 0.114 * gg + 0.587 * bb)) * density;
        if (grainAmt < 0) {
          grainAmt = 0;
        } else if (grainAmt > 1) {
          grainAmt = 1;
        }

        if (grainAmt > 0) {
          const n = noise[((gy & 0xFF) << 8) | (x & 0xFF)] * 2;
          rr = rr + (rr * n - rr) * grainAmt;
          gg = gg + (gg * n - gg) * grainAmt;
          bb = bb + (n * bb - bb) * grainAmt;
        }

        px[i4] = GrainVignette.clamp255(rr);
        px[i4 + 1] = GrainVignette.clamp255(gg);
        px[i4 + 2] = GrainVignette.clamp255(bb);
        i4 += 4;
      }
    }
  }

  private static init(): void {
    if (GrainVignette.inited) {
      return;
    }
    for (let i = 0; i < 256; i++) {
      const x = i / 255;
      GrainVignette.pLut[i] = 1.0 / Math.pow(100.0, 1.0 - x);
    }
    const offs: number[] = [0.07, 0.11, 0.13, 0.17, 0.19, 0.23];
    for (let a = 0; a < 256; a++) {
      for (let b = 0; b < 256; b++) {
        const fx = b / 255;
        const fy = a / 255;
        let sum = 0;
        for (let k = 0; k < 6; k++) {
          sum += GrainVignette.nrand(fx + offs[k], offs[k] + fy);
        }
        GrainVignette.noise[(a << 8) | b] = sum / 6;
      }
    }
    GrainVignette.inited = true;
  }

  private static nrand(a: number, b: number): number {
    const v = Math.sin(a * 12.9898 + b * 78.233) * 43758.5453;
    return v - Math.floor(v);
  }

  private static smoothstep(edge0: number, edge1: number, x: number): number {
    let t = (x - edge0) / (edge1 - edge0);
    if (t < 0) {
      t = 0;
    }
    if (t > 1) {
      t = 1;
    }
    return t * t * (3 - 2 * t);
  }

  private static clamp255(v: number): number {
    const i = Math.floor(v * 255 + 0.5);
    if (i < 0) {
      return 0;
    }
    if (i > 255) {
      return 255;
    }
    return i;
  }
}
