/**
 * 复合色调引擎（移植自 ToneCurve.kt）。
 *
 * 七档参数（-10..10）：亮度/曝光/高光/阴影/黑色阶/饱和度/对比度，
 * 参数域合成一条 4096 级亮度曲线，色相保护（Y'/Y 缩放）+ 保亮度软限 + TPDF 抖动。
 * levels 数组顺序：[brightness, exposure, highlights, shadows, black, saturation, contrast]。
 */

export class ToneCurves {
  static readonly MIN_LEVEL: number = -10;
  static readonly MAX_LEVEL: number = 10;
  private static readonly LUT_N: number = 4096;
  private static s2l: Float64Array = new Float64Array(256);
  private static l2sTab: Float64Array = new Float64Array(1025);
  private static built: boolean = false;

  static isNeutral(levels: number[]): boolean {
    for (let i = 0; i < levels.length; i++) {
      if (levels[i] !== 0) {
        return false;
      }
    }
    return true;
  }

  private static clamp01(v: number): number {
    return v < 0 ? 0 : (v > 1 ? 1 : v);
  }

  private static smoothstep(a: number, b: number, x: number): number {
    const t = ToneCurves.clamp01((x - a) / (b - a));
    return t * t * (3 - 2 * t);
  }

  private static sToL(v: number): number {
    return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  }

  private static lToS(v: number): number {
    return v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1.0 / 2.4) - 0.055;
  }

  private static ensureTables(): void {
    if (ToneCurves.built) {
      return;
    }
    for (let v = 0; v < 256; v++) {
      const d = v / 255.0;
      ToneCurves.s2l[v] = d <= 0.04045 ? d / 12.92 : Math.pow((d + 0.055) / 1.055, 2.4);
    }
    for (let i = 0; i <= 1024; i++) {
      const d = i / 1024.0;
      ToneCurves.l2sTab[i] = d <= 0.0031308 ? d * 12.92 : 1.055 * Math.pow(d, 1.0 / 2.4) - 0.055;
    }
    ToneCurves.built = true;
  }

  /** 参数域合成线性亮度曲线（4096 级，强制单调）。 */
  static buildLumaLut(levels: number[]): Float64Array {
    ToneCurves.ensureTables();
    const LUT_N = ToneCurves.LUT_N;
    const lut = new Float64Array(LUT_N);
    const br = levels[0] * 0.035;
    const ev = Math.pow(2, levels[1] * 0.15);
    const hl = levels[2] * 0.04;
    const sh = levels[3] * 0.04;
    const bl = levels[4] * 0.025;
    const con = levels[6] * 0.03;
    for (let i = 0; i < LUT_N; i++) {
      let v = ToneCurves.lToS(i / (LUT_N - 1));
      if (br !== 0) {
        v = Math.pow(v, Math.pow(2, -br));
      }
      if (ev !== 1) {
        v = ToneCurves.lToS(ToneCurves.sToL(v) * ev);
      }
      if (hl !== 0) {
        const vc = ToneCurves.clamp01(v);
        const w = ToneCurves.smoothstep(0.40, 0.90, vc);
        const a = Math.abs(hl);
        let t = a * w;
        if (t > 0.85) {
          t = 0.85;
        }
        if (t > 0) {
          const tgt = hl > 0 ? Math.pow(vc, 1 + 2 * a) : 1 - Math.pow(1 - vc, 1 + 2 * a);
          v += t * (tgt - v);
        }
      }
      if (sh !== 0) {
        const vc = ToneCurves.clamp01(v);
        const w = 1 - ToneCurves.smoothstep(0.10, 0.60, vc);
        const a = Math.abs(sh);
        let t = a * w;
        if (t > 0.85) {
          t = 0.85;
        }
        if (t > 0) {
          const tgt = sh > 0 ? Math.sqrt(vc) : vc * vc;
          v += t * (tgt - v);
        }
      }
      if (bl !== 0) {
        const vc = ToneCurves.clamp01(v);
        v -= bl * (1 - vc) * (1 - vc);
      }
      if (con !== 0) {
        const vc = ToneCurves.clamp01(v);
        const s = vc * vc * (3 - 2 * vc);
        v += con * (s - vc);
      }
      lut[i] = ToneCurves.sToL(v);
    }
    for (let i = 1; i < LUT_N; i++) {
      if (lut[i] < lut[i - 1]) {
        lut[i] = lut[i - 1];
      }
    }
    return lut;
  }

  /** 原地改写 RGBA 字节流。七档全 0 时直接返回。 */
  static apply(px: Uint8Array, levels: number[]): void {
    if (ToneCurves.isNeutral(levels)) {
      return;
    }
    ToneCurves.ensureTables();
    const lut = ToneCurves.buildLumaLut(levels);
    const LUT_N = ToneCurves.LUT_N;
    const s2l = ToneCurves.s2l;
    const sg = 1 + levels[5] * 0.045;
    let st = (0x9E3779B9 ^ Date.now()) | 0;
    const n = px.length;
    for (let i4 = 0; i4 + 3 < n; i4 += 4) {
      const r = s2l[px[i4]];
      const g = s2l[px[i4 + 1]];
      const b = s2l[px[i4 + 2]];
      const y = 0.2126 * r + 0.7152 * g + 0.0722 * b;

      const fi = y * (LUT_N - 1);
      let idx = Math.floor(fi);
      if (idx > LUT_N - 2) {
        idx = LUT_N - 2;
      }
      if (idx < 0) {
        idx = 0;
      }
      const y2 = lut[idx] + (lut[idx + 1] - lut[idx]) * (fi - idx);

      let r2: number;
      let g2: number;
      let b2: number;
      if (y < 1e-5) {
        r2 = y2;
        g2 = y2;
        b2 = y2;
      } else {
        const s = y2 / y;
        r2 = r * s;
        g2 = g * s;
        b2 = b * s;
        let m = r2 > g2 ? (r2 > b2 ? r2 : b2) : (g2 > b2 ? g2 : b2);
        if (m > 1) {
          const k = 1 - ToneCurves.smoothstep(1, 1.25, m);
          r2 = y2 + (r2 - y2) * k;
          g2 = y2 + (g2 - y2) * k;
          b2 = y2 + (b2 - y2) * k;
        }
      }
      if (sg !== 1) {
        r2 = y2 + (r2 - y2) * sg;
        g2 = y2 + (g2 - y2) * sg;
        b2 = y2 + (b2 - y2) * sg;
        const m = r2 > g2 ? (r2 > b2 ? r2 : b2) : (g2 > b2 ? g2 : b2);
        if (m > 1) {
          const k = 1 - ToneCurves.smoothstep(1, 1.25, m);
          r2 = y2 + (r2 - y2) * k;
          g2 = y2 + (g2 - y2) * k;
          b2 = y2 + (b2 - y2) * k;
        }
      }

      st = (st ^ (st << 13)) | 0;
      st = (st ^ (st >>> 17)) | 0;
      st = (st ^ (st << 5)) | 0;
      const u1 = (st & 0xFFFFFF) / 16777216;
      st = (st ^ (st << 13)) | 0;
      st = (st ^ (st >>> 17)) | 0;
      st = (st ^ (st << 5)) | 0;
      const u2 = (st & 0xFFFFFF) / 16777216;
      const dth = (u1 + u2 - 1) * 0.5;

      px[i4] = ToneCurves.enc8(r2, dth);
      px[i4 + 1] = ToneCurves.enc8(g2, dth);
      px[i4 + 2] = ToneCurves.enc8(b2, dth);
    }
  }

  /** 线性→8bit：1024 格表插值 + TPDF 抖动，>1 裁 255。 */
  private static enc8(x: number, dither: number): number {
    if (x >= 1) {
      return 255;
    }
    if (x <= 0) {
      return 0;
    }
    const fi = x * 1024;
    const idx = Math.floor(fi);
    const l2s = ToneCurves.l2sTab;
    const f = l2s[idx] + (l2s[idx + 1] - l2s[idx]) * (fi - idx);
    const v8 = Math.floor(f * 255 + 0.5 + dither);
    if (v8 > 255) {
      return 255;
    }
    if (v8 < 0) {
      return 0;
    }
    return v8;
  }
}
