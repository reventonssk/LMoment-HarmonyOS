/**
 * M13「Portra」人像胶片（对齐 Android PortraitFilm.kt）：
 * SepLUT（ECCV 2022，FiveK 预训练）整图级 LUT 打底 + 固定 Portra 曲线。
 *
 * 链路：整图缩 256 喂模型 → 1D LUT(3×17) + 3D LUT(17³，轴序 (B,G,R))
 *   → 全分辨率逐像素：1D 精确查表 → 17³ 三线性 → Portra 矩阵 → 中间调冷暖偏
 *   → 肤色定向（去饱和+提亮+B 微升）→ 亮度域 gamma → 阴影偏移 → 通道曲线 → 量化。
 */

import { yieldUI } from './PixAsync';

const SKIN_SAT_LO = 0.05;
const SKIN_SAT_SPAN = 0.10;
const SKIN_LUM_LO = 0.10;
const SKIN_LUM_SPAN = 0.15;
const SKIN_R_DROP = 0.004;
const SHADOW_SKIN_CUT = 0.8;

export class CcdCurve {
  readonly ys: Float32Array;

  constructor(y0: number, y1: number, y2: number, y3: number, y4: number) {
    this.ys = new Float32Array([y0, y1, y2, y3, y4]);
  }
}

export class CcdProfile {
  readonly idx: number;
  readonly label: string;
  readonly sat: number;
  readonly gain: Float32Array;
  readonly warmMid: number;
  readonly gamma: number;
  readonly shadowTint: Float32Array;
  readonly skinSat: number;
  readonly skinLumLift: number;
  readonly skinBLift: number;
  readonly skinHueC: number;
  readonly skinHueHalf: number;
  readonly curveR: CcdCurve;
  readonly curveG: CcdCurve;
  readonly curveB: CcdCurve;
  readonly grain: number;
  readonly vignette: number;

  constructor(idx: number, label: string, sat: number, g0: number, g1: number, g2: number,
    warmMid: number, gamma: number, s0: number, s1: number, s2: number,
    skinSat: number, skinLumLift: number, skinBLift: number, skinHueC: number, skinHueHalf: number,
    curveR: CcdCurve, curveG: CcdCurve, curveB: CcdCurve, grain: number, vignette: number) {
    this.idx = idx;
    this.label = label;
    this.sat = sat;
    this.gain = new Float32Array([g0, g1, g2]);
    this.warmMid = warmMid;
    this.gamma = gamma;
    this.shadowTint = new Float32Array([s0, s1, s2]);
    this.skinSat = skinSat;
    this.skinLumLift = skinLumLift;
    this.skinBLift = skinBLift;
    this.skinHueC = skinHueC;
    this.skinHueHalf = skinHueHalf;
    this.curveR = curveR;
    this.curveG = curveG;
    this.curveB = curveB;
    this.grain = grain;
    this.vignette = vignette;
  }
}

export class CcdProfiles {
  static readonly COOL: CcdProfile = new CcdProfile(0, 'CCD·冷白', 0.88, 0.980, 1.000, 1.026,
    -0.016, 0.05, -0.015, 0.00525, 0.0165,
    0.62, 0.05, 0.012, 32, 18,
    new CcdCurve(0, 0.249, 0.500, 0.756, 1),
    new CcdCurve(0, 0.250, 0.500, 0.752, 1),
    new CcdCurve(0, 0.251, 0.501, 0.753, 1),
    0.18, 1);

  static readonly PINK: CcdProfile = new CcdProfile(1, 'CCD·粉', 0.92, 1.012, 0.994, 1.014,
    0.010, 0.06, 0.008, -0.004, 0.010,
    0.70, 0.06, 0.016, 32, 18,
    new CcdCurve(0, 0.252, 0.505, 0.760, 1),
    new CcdCurve(0, 0.250, 0.500, 0.752, 1),
    new CcdCurve(0, 0.254, 0.508, 0.758, 1),
    0.14, 0.35);

  static readonly WARM: CcdProfile = new CcdProfile(2, 'CCD·暖', 0.98, 1.030, 1.000, 0.964,
    0.022, 0.04, 0, 0, 0,
    0.80, 0.03, 0, 26, 22,
    new CcdCurve(0, 0.250, 0.502, 0.771, 1),
    new CcdCurve(0, 0.250, 0.500, 0.752, 1),
    new CcdCurve(0, 0.246, 0.497, 0.750, 1),
    0.20, 0.55);
}

/** 档位无关的预计算结果：3×3 混合矩阵 / 三通道 256 级曲线 / 513 级 gamma 表。 */
export class CcdParams {
  readonly matrix: Float32Array;
  readonly curveR: Float32Array;
  readonly curveG: Float32Array;
  readonly curveB: Float32Array;
  readonly gammaLut: Float32Array;

  constructor(profile: CcdProfile) {
    const lum: number[] = [0.299, 0.587, 0.114];
    const m = new Float32Array(9);
    for (let r = 0; r < 3; r++) {
      for (let c = 0; c < 3; c++) {
        m[r * 3 + c] = profile.sat * (r === c ? 1 : 0) + (1 - profile.sat) * lum[c];
      }
    }
    for (let r = 0; r < 3; r++) {
      for (let c = 0; c < 3; c++) {
        m[r * 3 + c] *= profile.gain[r];
      }
    }
    for (let r = 0; r < 3; r++) {
      let s = 0;
      for (let c = 0; c < 3; c++) {
        s += m[r * 3 + c];
      }
      for (let c = 0; c < 3; c++) {
        m[r * 3 + c] /= s;
      }
    }
    this.matrix = m;
    const gl = new Float32Array(513);
    if (profile.gamma > 0) {
      for (let i = 0; i <= 512; i++) {
        gl[i] = Math.pow(i / 512, profile.gamma);
      }
    }
    this.gammaLut = gl;
    this.curveR = CcdParams.buildCurve(profile.curveR);
    this.curveG = CcdParams.buildCurve(profile.curveG);
    this.curveB = CcdParams.buildCurve(profile.curveB);
  }

  private static buildCurve(c: CcdCurve): Float32Array {
    const xs: number[] = [0, 0.25, 0.5, 0.75, 1];
    const ys = c.ys;
    const t = new Float32Array(256);
    let seg = 0;
    for (let i = 0; i < 256; i++) {
      const x = i / 255;
      while (seg < xs.length - 2 && x > xs[seg + 1]) {
        seg++;
      }
      const x0 = xs[seg];
      const x1 = xs[seg + 1];
      const y0 = ys[seg];
      const y1 = ys[seg + 1];
      let f = x1 > x0 ? (x - x0) / (x1 - x0) : 0;
      f = f < 0 ? 0 : (f > 1 ? 1 : f);
      t[i] = y0 + (y1 - y0) * f;
    }
    return t;
  }
}

class CcdParamsCache {
  private static cache: Array<CcdParams | undefined> = [];

  static of(profile: CcdProfile): CcdParams {
    let v = CcdParamsCache.cache[profile.idx];
    if (v === undefined) {
      v = new CcdParams(profile);
      CcdParamsCache.cache[profile.idx] = v;
    }
    return v;
  }
}

/** 全图共享 LUT 包（SepLUT 输出整图级，先算一次再逐像素应用）。 */
export class CcdBundle {
  readonly t1d: Float32Array;
  readonly lut3d: Float32Array;

  constructor(lut1dFlat: Float32Array, lut3dFlat: Float32Array) {
    if (lut1dFlat.length !== 51 || lut3dFlat.length !== 14739) {
      throw new Error('seplut output shape mismatch');
    }
    this.lut3d = lut3dFlat;
    this.t1d = new Float32Array(3 * 256);
    for (let c = 0; c < 3; c++) {
      const off = c * 17;
      for (let i = 0; i < 256; i++) {
        const x = i / 255 * 16;
        let i0 = x | 0;
        if (i0 > 15) {
          i0 = 15;
        }
        if (i0 < 0) {
          i0 = 0;
        }
        let f = x - i0;
        f = f < 0 ? 0 : (f > 1 ? 1 : f);
        this.t1d[c * 256 + i] = lut1dFlat[off + i0] + (lut1dFlat[off + i0 + 1] - lut1dFlat[off + i0]) * f;
      }
    }
  }
}

export class CcdFilm {
  /** 原地应用 CCD 色彩（RGBA 字节流，全分辨率逐像素）。 */
  static async applyPx(px: Uint8Array, w: number, h: number,
    profile: CcdProfile, bundle: CcdBundle): Promise<void> {
    const prm = CcdParamsCache.of(profile);
    const t1d = bundle.t1d;
    const lut3d = bundle.lut3d;
    const m = prm.matrix;
    const cR = prm.curveR;
    const cG = prm.curveG;
    const cB = prm.curveB;
    const gl = prm.gammaLut;
    const useGamma = profile.gamma > 0;
    const warmMid = profile.warmMid;
    const skinSat = profile.skinSat;
    const skinLumLift = profile.skinLumLift;
    const skinBLift = profile.skinBLift;
    const skinHueC = profile.skinHueC;
    const skinHueHalf = profile.skinHueHalf;
    const sR = profile.shadowTint[0];
    const sG = profile.shadowTint[1];
    const sB = profile.shadowTint[2];
    const useShadow = sR !== 0 || sG !== 0 || sB !== 0;
    const rowsPerChunk = 262144 / w > 1 ? Math.floor(262144 / w) : 1;
    for (let cy0 = 0; cy0 < h; cy0 += rowsPerChunk) {
      const cy1 = cy0 + rowsPerChunk < h ? cy0 + rowsPerChunk : h;
      for (let y = cy0; y < cy1; y++) {
        let i = y * w * 4;
        for (let x = 0; x < w; x++, i += 4) {
          let r = t1d[px[i]];
          let g = t1d[256 + px[i + 1]];
          let b = t1d[512 + px[i + 2]];
          const fx = r * 16;
          const fy = g * 16;
          const fz = b * 16;
          let x0 = fx | 0;
          let yq = fy | 0;
          let z0 = fz | 0;
          if (x0 > 15) {
            x0 = 15;
          }
          if (x0 < 0) {
            x0 = 0;
          }
          if (yq > 15) {
            yq = 15;
          }
          if (yq < 0) {
            yq = 0;
          }
          if (z0 > 15) {
            z0 = 15;
          }
          if (z0 < 0) {
            z0 = 0;
          }
          const dx = fx - x0;
          const dy = fy - yq;
          const dz = fz - z0;
          const x1 = dx > 0 ? x0 + 1 : x0;
          const y1 = dy > 0 ? yq + 1 : yq;
          const z1 = dz > 0 ? z0 + 1 : z0;
          const wdx = 1 - dx;
          const wdy = 1 - dy;
          const wdz = 1 - dz;
          const w000 = wdx * wdy * wdz;
          const w100 = dx * wdy * wdz;
          const w010 = wdx * dy * wdz;
          const w110 = dx * dy * wdz;
          const w001 = wdx * wdy * dz;
          const w101 = dx * wdy * dz;
          const w011 = wdx * dy * dz;
          const w111 = dx * dy * dz;
          const b000 = z0 * 289 + yq * 17 + x0;
          const b100 = z0 * 289 + yq * 17 + x1;
          const b010 = z0 * 289 + y1 * 17 + x0;
          const b110 = z0 * 289 + y1 * 17 + x1;
          const b001 = z1 * 289 + yq * 17 + x0;
          const b101 = z1 * 289 + yq * 17 + x1;
          const b011 = z1 * 289 + y1 * 17 + x0;
          const b111 = z1 * 289 + y1 * 17 + x1;
          r = lut3d[b000] * w000 + lut3d[b100] * w100 + lut3d[b010] * w010 + lut3d[b110] * w110 +
            lut3d[b001] * w001 + lut3d[b101] * w101 + lut3d[b011] * w011 + lut3d[b111] * w111;
          g = lut3d[4913 + b000] * w000 + lut3d[4913 + b100] * w100 + lut3d[4913 + b010] * w010 +
            lut3d[4913 + b110] * w110 + lut3d[4913 + b001] * w001 + lut3d[4913 + b101] * w101 +
            lut3d[4913 + b011] * w011 + lut3d[4913 + b111] * w111;
          b = lut3d[9826 + b000] * w000 + lut3d[9826 + b100] * w100 + lut3d[9826 + b010] * w010 +
            lut3d[9826 + b110] * w110 + lut3d[9826 + b001] * w001 + lut3d[9826 + b101] * w101 +
            lut3d[9826 + b011] * w011 + lut3d[9826 + b111] * w111;
          const mr = m[0] * r + m[1] * g + m[2] * b;
          const mg = m[3] * r + m[4] * g + m[5] * b;
          const mb = m[6] * r + m[7] * g + m[8] * b;
          r = mr;
          g = mg;
          b = mb;
          const lum2 = 0.299 * r + 0.587 * g + 0.114 * b;
          const wt = 4 * lum2 * (1 - lum2);
          r += warmMid * wt;
          b -= warmMid * wt;
          r = r < 0 ? 0 : (r > 1 ? 1 : r);
          b = b < 0 ? 0 : (b > 1 ? 1 : b);
          let skinW = 0;
          const mx0 = r > g ? (r > b ? r : b) : (g > b ? g : b);
          const mn0 = r < g ? (r < b ? r : b) : (g < b ? g : b);
          const delta = mx0 - mn0;
          let wgt = 0;
          if (delta > 1e-5) {
            let hue: number;
            if (mx0 === r) {
              const hh = 60 * (g - b) / delta;
              hue = hh < 0 ? hh + 360 : hh;
            } else if (mx0 === g) {
              hue = 60 * (b - r) / delta + 120;
            } else {
              hue = 60 * (r - g) / delta + 240;
            }
            let dh = Math.abs(hue - skinHueC);
            if (dh > 180) {
              dh = 360 - dh;
            }
            let hw = 1 - dh / skinHueHalf;
            if (hw > 0) {
              hw = hw * hw * (3 - 2 * hw);
              const sat = delta / (mx0 > 1e-6 ? mx0 : 1e-6);
              let sw = (sat - SKIN_SAT_LO) / SKIN_SAT_SPAN;
              sw = sw < 0 ? 0 : (sw > 1 ? 1 : sw);
              let lw = (mx0 - SKIN_LUM_LO) / SKIN_LUM_SPAN;
              lw = lw < 0 ? 0 : (lw > 1 ? 1 : lw);
              wgt = hw * sw * lw;
            }
          }
          if (wgt > 0) {
            const keep = 1 - wgt * (1 - skinSat);
            const ls = 0.299 * r + 0.587 * g + 0.114 * b;
            r = ls + (r - ls) * keep;
            g = ls + (g - ls) * keep;
            b = ls + (b - ls) * keep;
            r = r < 0 ? 0 : (r > 1 ? 1 : r);
            g = g < 0 ? 0 : (g > 1 ? 1 : g);
            b = b < 0 ? 0 : (b > 1 ? 1 : b);
            const lift = 1 + skinLumLift * wgt;
            r = r * lift - SKIN_R_DROP * wgt;
            g = g * lift;
            b = b * lift + skinBLift * wgt;
            r = r < 0 ? 0 : (r > 1 ? 1 : r);
            g = g < 0 ? 0 : (g > 1 ? 1 : g);
            b = b < 0 ? 0 : (b > 1 ? 1 : b);
            skinW = wgt;
          }
          if (useGamma) {
            const li = lum2 * 512;
            let gi = li | 0;
            gi = gi < 0 ? 0 : (gi > 511 ? 511 : gi);
            let gf = li - gi;
            gf = gf < 0 ? 0 : (gf > 1 ? 1 : gf);
            const factor = gl[gi] + (gl[gi + 1] - gl[gi]) * gf;
            r *= factor;
            g *= factor;
            b *= factor;
            r = r < 0 ? 0 : (r > 1 ? 1 : r);
            g = g < 0 ? 0 : (g > 1 ? 1 : g);
            b = b < 0 ? 0 : (b > 1 ? 1 : b);
          }
          if (useShadow) {
            const l3 = 0.299 * r + 0.587 * g + 0.114 * b;
            const ws = (1 - l3) * (1 - l3) * (1 - skinW * SHADOW_SKIN_CUT);
            r += sR * ws;
            g += sG * ws;
            b += sB * ws;
            r = r < 0 ? 0 : (r > 1 ? 1 : r);
            g = g < 0 ? 0 : (g > 1 ? 1 : g);
            b = b < 0 ? 0 : (b > 1 ? 1 : b);
          }
          let ciR = (r * 255 + 0.5) | 0;
          let ciG = (g * 255 + 0.5) | 0;
          let ciB = (b * 255 + 0.5) | 0;
          ciR = ciR < 0 ? 0 : (ciR > 255 ? 255 : ciR);
          ciG = ciG < 0 ? 0 : (ciG > 255 ? 255 : ciG);
          ciB = ciB < 0 ? 0 : (ciB > 255 ? 255 : ciB);
          r = cR[ciR];
          g = cG[ciG];
          b = cB[ciB];
          let qR = (r * 255 + 0.5) | 0;
          let qG = (g * 255 + 0.5) | 0;
          let qB = (b * 255 + 0.5) | 0;
          qR = qR < 0 ? 0 : (qR > 255 ? 255 : qR);
          qG = qG < 0 ? 0 : (qG > 255 ? 255 : qG);
          qB = qB < 0 ? 0 : (qB > 255 ? 255 : qB);
          px[i] = qR;
          px[i + 1] = qG;
          px[i + 2] = qB;
        }
      }
      await yieldUI();
    }
  }
}
