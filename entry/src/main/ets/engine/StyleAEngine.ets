/**
 * A 路线引擎（移植自 StyleA.java）：Lab 仿射 + 逐通道节点 LUT。
 *
 * 数学：lin = sRGB→linear 查表 → grayWorldGain(clamp 0.5..2) →
 * 0.5/99.5 百分位曝光归一(clamp 0.25..4) → Lab(D65+OpenCV 白点) →
 * knotLut(lab @ A + b) 二分插值 → Lab→sRGB 4096 表。
 * 统计量三遍扫描（均值→直方图→应用）。LUMA 常量按 BGR 排布口径书写
 * （0.2126 乘 B），与 PC 台拟合同源，不得"修正"。
 */

export class StyleAModel {
  private static readonly EPS = 1e-6;
  private static readonly WB_LO = 0.5;
  private static readonly WB_HI = 2.0;
  private static readonly EXPO_LO = 0.005;
  private static readonly EXPO_HI = 0.98;
  private static readonly SCALE_LO = 0.25;
  private static readonly SCALE_HI = 4.0;
  private static readonly HIST = 65536;
  private static readonly WX = 0.950456;
  private static readonly WZ = 1.088754;
  private static readonly T_THRESH = 0.008856;
  private static readonly T_INV_THRESH = 0.206893;
  private static readonly M00 = 0.412453;
  private static readonly M01 = 0.357580;
  private static readonly M02 = 0.180423;
  private static readonly M10 = 0.212671;
  private static readonly M11 = 0.715160;
  private static readonly M12 = 0.072169;
  private static readonly M20 = 0.019334;
  private static readonly M21 = 0.119193;
  private static readonly M22 = 0.950227;
  private static readonly N00 = 3.240479;
  private static readonly N01 = -1.537150;
  private static readonly N02 = -0.498535;
  private static readonly N10 = -0.969256;
  private static readonly N11 = 1.875992;
  private static readonly N12 = 0.041556;
  private static readonly N20 = 0.055648;
  private static readonly N21 = -0.204043;
  private static readonly N22 = 1.057311;
  private static readonly LUMA_B = 0.2126;
  private static readonly LUMA_G = 0.7152;
  private static readonly LUMA_R = 0.0722;
  private static lin: Float64Array = new Float64Array(256);
  private static l2sTab: Float64Array = new Float64Array(4096);
  private static built: boolean = false;

  private readonly a9: Float64Array;
  private readonly b3: Float64Array;
  private readonly xs: Float64Array;
  private readonly tab: Float64Array;
  readonly nodes: number;

  private constructor(nodes: number) {
    this.nodes = nodes;
    this.a9 = new Float64Array(9);
    this.b3 = new Float64Array(3);
    this.xs = new Float64Array(3 * nodes);
    this.tab = new Float64Array(3 * nodes);
  }

  static decode(s: Uint8Array): StyleAModel | undefined {
    if (s.byteLength < 12) {
      return undefined;
    }
    if (s[0] !== 76 || s[1] !== 77 || s[2] !== 65 || s[3] !== 54) {
      return undefined;
    }
    const dv = new DataView(s.buffer, s.byteOffset, s.byteLength);
    const ver = dv.getInt32(4, true);
    const nodes = dv.getInt32(8, true);
    if (ver !== 2 || nodes < 2 || nodes > 4096) {
      return undefined;
    }
    const need = 12 + 36 + 12 + 12 * nodes * 2;
    if (s.byteLength !== need) {
      return undefined;
    }
    const p = new StyleAModel(nodes);
    let o = 12;
    for (let k = 0; k < 3; k++) {
      for (let c = 0; c < 3; c++) {
        p.a9[c * 3 + k] = dv.getFloat32(o + (k * 3 + c) * 4, true);
      }
    }
    o += 36;
    for (let i = 0; i < 3; i++) {
      p.b3[i] = dv.getFloat32(o + i * 4, true);
    }
    o += 12;
    for (let c = 0; c < 3; c++) {
      for (let k = 0; k < nodes; k++) {
        p.xs[c * nodes + k] = dv.getFloat32(o + (c * nodes + k) * 4, true);
      }
    }
    o += 12 * nodes;
    for (let c = 0; c < 3; c++) {
      for (let k = 0; k < nodes; k++) {
        p.tab[c * nodes + k] = dv.getFloat32(o + (c * nodes + k) * 4, true);
      }
    }
    return p;
  }

  /** 三遍扫描，原地改写 RGBA 字节流。 */
  applyPx(px: Uint8Array): void {
    StyleAModel.ensureTables();
    const n4 = px.length;
    const n = n4 >> 2;
    const LIN = StyleAModel.lin;

    let sr = 0;
    let sg = 0;
    let sb = 0;
    for (let i4 = 0; i4 < n4; i4 += 4) {
      sr += LIN[px[i4]];
      sg += LIN[px[i4 + 1]];
      sb += LIN[px[i4 + 2]];
    }
    const mr = sr / n;
    const mg = sg / n;
    const mb = sb / n;
    const m = (mb + mg + mr) / 3.0;
    const gr = StyleAModel.clamp(m / (mr + StyleAModel.EPS), StyleAModel.WB_LO, StyleAModel.WB_HI);
    const gg = StyleAModel.clamp(m / (mg + StyleAModel.EPS), StyleAModel.WB_LO, StyleAModel.WB_HI);
    const gb = StyleAModel.clamp(m / (mb + StyleAModel.EPS), StyleAModel.WB_LO, StyleAModel.WB_HI);

    const hist = new Int32Array(StyleAModel.HIST);
    for (let i4 = 0; i4 < n4; i4 += 4) {
      const y = StyleAModel.LUMA_B * LIN[px[i4 + 2]] * gb
        + StyleAModel.LUMA_G * LIN[px[i4 + 1]] * gg
        + StyleAModel.LUMA_R * LIN[px[i4]] * gr;
      let k = Math.floor(y * StyleAModel.HIST);
      if (k < 0) {
        k = 0;
      }
      if (k >= StyleAModel.HIST) {
        k = StyleAModel.HIST - 1;
      }
      hist[k]++;
    }
    const pLo = StyleAModel.percentile(hist, 0.005, n);
    const pHi = StyleAModel.percentile(hist, 0.995, n);
    const span = Math.max(pHi - pLo, 1e-4);
    const scale = StyleAModel.clamp((StyleAModel.EXPO_HI - StyleAModel.EXPO_LO) / span,
      StyleAModel.SCALE_LO, StyleAModel.SCALE_HI);
    const off = StyleAModel.EXPO_LO - pLo * scale;

    const a9 = this.a9;
    const b3 = this.b3;
    for (let i4 = 0; i4 < n4; i4 += 4) {
      const rl = StyleAModel.clamp(LIN[px[i4]] * gr * scale + off, 0.0, 1.0);
      const gl = StyleAModel.clamp(LIN[px[i4 + 1]] * gg * scale + off, 0.0, 1.0);
      const bl = StyleAModel.clamp(LIN[px[i4 + 2]] * gb * scale + off, 0.0, 1.0);

      const x = (StyleAModel.M00 * rl + StyleAModel.M01 * gl + StyleAModel.M02 * bl) / StyleAModel.WX;
      const y = StyleAModel.M10 * rl + StyleAModel.M11 * gl + StyleAModel.M12 * bl;
      const z = (StyleAModel.M20 * rl + StyleAModel.M21 * gl + StyleAModel.M22 * bl) / StyleAModel.WZ;
      const fx = x > StyleAModel.T_THRESH ? Math.cbrt(x) : 7.787 * x + 16.0 / 116.0;
      const fy = y > StyleAModel.T_THRESH ? Math.cbrt(y) : 7.787 * y + 16.0 / 116.0;
      const fz = z > StyleAModel.T_THRESH ? Math.cbrt(z) : 7.787 * z + 16.0 / 116.0;
      const labL = 116.0 * fy - 16.0;
      const labA = 500.0 * (fx - fy);
      const labB = 200.0 * (fy - fz);

      const v0 = a9[0] * labL + a9[1] * labA + a9[2] * labB + b3[0];
      const v1 = a9[3] * labL + a9[4] * labA + a9[5] * labB + b3[1];
      const v2 = a9[6] * labL + a9[7] * labA + a9[8] * labB + b3[2];

      const kL = this.knot(0, v0);
      const kA = this.knot(1, v1);
      const kB = this.knot(2, v2);

      const fy2 = (kL + 16.0) / 116.0;
      const fx2 = fy2 + kA / 500.0;
      const fz2 = fy2 - kB / 200.0;
      const x2 = (fx2 > StyleAModel.T_INV_THRESH ? fx2 * fx2 * fx2 : (fx2 - 16.0 / 116.0) / 7.787) * StyleAModel.WX;
      const y2 = fy2 > StyleAModel.T_INV_THRESH ? fy2 * fy2 * fy2 : (fy2 - 16.0 / 116.0) / 7.787;
      const z2 = (fz2 > StyleAModel.T_INV_THRESH ? fz2 * fz2 * fz2 : (fz2 - 16.0 / 116.0) / 7.787) * StyleAModel.WZ;
      const lr = StyleAModel.N00 * x2 + StyleAModel.N01 * y2 + StyleAModel.N02 * z2;
      const lg = StyleAModel.N10 * x2 + StyleAModel.N11 * y2 + StyleAModel.N12 * z2;
      const lb = StyleAModel.N20 * x2 + StyleAModel.N21 * y2 + StyleAModel.N22 * z2;

      px[i4] = Math.round(StyleAModel.l2s(lr) * 255.0);
      px[i4 + 1] = Math.round(StyleAModel.l2s(lg) * 255.0);
      px[i4 + 2] = Math.round(StyleAModel.l2s(lb) * 255.0);
    }
  }

  private knot(c: number, v: number): number {
    const xs = this.xs;
    const tab = this.tab;
    const nodes = this.nodes;
    const base = c * nodes;
    if (v <= xs[base]) {
      return tab[base];
    }
    if (v >= xs[base + nodes - 1]) {
      return tab[base + nodes - 1];
    }
    let lo = 0;
    let hi = nodes - 1;
    while (hi - lo > 1) {
      const mid = (lo + hi) >>> 1;
      if (xs[base + mid] <= v) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    const dx = xs[base + hi] - xs[base + lo];
    const f = dx > 1e-9 ? (v - xs[base + lo]) / dx : 0.0;
    return tab[base + lo] * (1.0 - f) + tab[base + hi] * f;
  }

  private static percentile(hist: Int32Array, p: number, total: number): number {
    const want = p * (total - 1) + 0.5;
    let c = 0;
    for (let i = 0; i < hist.length; i++) {
      c += hist[i];
      if (c >= want) {
        return i / StyleAModel.HIST;
      }
    }
    return (StyleAModel.HIST - 1) / StyleAModel.HIST;
  }

  private static l2s(v: number): number {
    if (v <= 0.0) {
      return 0.0;
    }
    if (v >= 1.0) {
      return 1.0;
    }
    const len = StyleAModel.l2sTab.length;
    const pos = v * (len - 1);
    let i = Math.floor(pos);
    if (i >= len - 1) {
      i = len - 2;
    }
    const f = pos - i;
    return StyleAModel.l2sTab[i] * (1.0 - f) + StyleAModel.l2sTab[i + 1] * f;
  }

  private static clamp(v: number, lo: number, hi: number): number {
    return v < lo ? lo : (v > hi ? hi : v);
  }

  private static ensureTables(): void {
    if (StyleAModel.built) {
      return;
    }
    for (let i = 0; i < 256; i++) {
      const s = i / 255.0;
      StyleAModel.lin[i] = s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    }
    for (let i = 0; i < 4096; i++) {
      const x = i / 4095.0;
      StyleAModel.l2sTab[i] = x <= 0.0031308 ? x * 12.92 : 1.055 * Math.pow(x, 1.0 / 2.4) - 0.055;
    }
    StyleAModel.built = true;
  }
}
