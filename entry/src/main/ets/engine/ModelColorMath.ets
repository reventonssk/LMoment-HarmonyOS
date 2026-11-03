/**
 * 模型色彩纯数学核心（Batch H，移植自 AdaptiveColorNet.kt 的 Kotlin 回退路径）。
 *
 * aff/knots 语义（23_export_net.py 训练契约）：
 *   in  refs (1,R,6,128,128)  → stage1 → e (R,36) → aggregate → r (108)
 *   r → stage2 → aff (12, 3x4 逐通道仿射) + knots (27, L/a/b 各 9 结点折线)
 *
 * apply 链（与 native/Kotlin 同口径）：N(x) 灰世界白平衡 + 0.5/99.5 分位曝光 → Lab →
 * aff → knots 折线 → Lab → sRGB；protect 为连续天空/肤色权重交叉淡化，
 * guard 限幅 250，smooth 为 3x3 条件平滑。本文件不含 MindSpore / UI 依赖，可入 taskpool。
 * 像素布局：紧密 RGBA 字节流（与全工程口径一致）。
 */

export class ModelColorMath {
  /** 参考集均值色度阈值（Lab √(a²+b²)）：低于判黑白参考。 */
  static readonly MONO_MEAN_CHROMA: number = 6;

  /** 单色判定：a/b 通路全零（aff[4..11] 且 knots[9..26]）。 */
  static isMono(aff: Float32Array, knots: Float32Array): boolean {
    if (aff.length < 12 || knots.length < 27) {
      return false;
    }
    for (let i = 4; i < 12; i++) {
      if (Math.abs(aff[i]) > 1e-4) {
        return false;
      }
    }
    for (let i = 9; i < 27; i++) {
      if (Math.abs(knots[i]) > 1e-4) {
        return false;
      }
    }
    return true;
  }

  /** a/b 通路清零 = 纯黑白（保留 L 影调曲线，显式化单色性质）。 */
  static toMono(aff: Float32Array, knots: Float32Array): void {
    for (let i = 4; i < 12 && i < aff.length; i++) {
      aff[i] = 0;
    }
    for (let i = 9; i < 27 && i < knots.length; i++) {
      knots[i] = 0;
    }
  }

  /**
   * 对整幅 RGBA 原地套用 aff/knots（对齐 AdaptiveColorNet.apply 的 Kotlin 路径）。
   * protect 依单色风格自动关闭（黑白画面不回锚彩色）。
   */
  static apply(px: Uint8Array, w: number, h: number,
    aff: Float32Array, knots: Float32Array,
    protect: boolean, guard: boolean, strength: number, smooth: boolean): void {
    const n = w * h;
    if (n <= 0 || px.length < n * 4 || aff.length < 12 || knots.length < 27) {
      return;
    }
    const st = Math.min(Math.max(strength, 0), 2);
    const mono = ModelColorMath.isMono(aff, knots);
    const prot = protect && !mono;
    const src = px.slice();
    const lab = ModelColorMath.neutralizedLab(src, n);
    let mask: Float32Array | undefined = undefined;
    if (prot) {
      mask = ModelColorMath.protectWeight(src, w, h);
    }
    const rgb: number[] = [0, 0, 0];
    const kn = knots;
    for (let i = 0; i < n; i++) {
      const l = lab[i];
      const a = lab[n + i];
      const b = lab[2 * n + i];
      const o = i * 4;
      let vl = aff[0] * l + aff[1] * a + aff[2] * b + aff[3];
      let va = aff[4] * l + aff[5] * a + aff[6] * b + aff[7];
      let vb = aff[8] * l + aff[9] * a + aff[10] * b + aff[11];
      vl = ModelColorMath.curve(vl, kn, 0, 0, 1);
      va = ModelColorMath.curve(va, kn, 9, -1, 1);
      vb = ModelColorMath.curve(vb, kn, 18, -1, 1);
      let L = vl * 100;
      let A = va * 128;
      let B = vb * 128;
      const m = mask !== undefined ? mask[i] : 0;
      if (st !== 1 || m > 0) {
        ModelColorMath.rgbToLab(src[o] / 255, src[o + 1] / 255, src[o + 2] / 255, rgb);
        const lo = rgb[0];
        const la = rgb[1];
        const lb = rgb[2];
        if (st !== 1) {
          L = lo + st * (L - lo);
          A = la + st * (A - la);
          B = lb + st * (B - lb);
        }
        if (m > 0) {
          // 保护锚点 = 原图像素（PROTECT_SOFT = 0：风格偏移全压回原值）
          L = (1 - m) * L + m * lo;
          A = (1 - m) * A + m * la;
          B = (1 - m) * B + m * lb;
        }
      }
      ModelColorMath.labToRgb(L, A, B, rgb);
      let r8 = ModelColorMath.clamp255(Math.round(rgb[0] * 255));
      let g8 = ModelColorMath.clamp255(Math.round(rgb[1] * 255));
      let b8 = ModelColorMath.clamp255(Math.round(rgb[2] * 255));
      if (guard) {
        r8 = Math.min(r8, 250);
        g8 = Math.min(g8, 250);
        b8 = Math.min(b8, 250);
      }
      px[o] = r8;
      px[o + 1] = g8;
      px[o + 2] = b8;
      px[o + 3] = 255;
    }
    if (smooth) {
      ModelColorMath.smoothPass(px, w, h, guard);
    }
  }

  /** 3x3 邻域同亮度条件平均（|Δlum|<0.04）后按比值回乘，量化回 8bit。 */
  private static smoothPass(px: Uint8Array, w: number, h: number, guard: boolean): void {
    const n = w * h;
    const lum = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const o = i * 4;
      lum[i] = (0.2126 * px[o] + 0.7152 * px[o + 1] + 0.0722 * px[o + 2]) / 255;
    }
    const sm = new Float32Array(n);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const i = y * w + x;
        const c = lum[i];
        let acc = 0;
        let cnt = 0;
        for (let dy = -1; dy <= 1; dy++) {
          const yy = Math.min(h - 1, Math.max(0, y + dy));
          for (let dx = -1; dx <= 1; dx++) {
            const xx = Math.min(w - 1, Math.max(0, x + dx));
            const v = lum[yy * w + xx];
            if (Math.abs(v - c) < 0.04) {
              acc += v;
              cnt++;
            }
          }
        }
        sm[i] = cnt > 0 ? acc / cnt : c;
      }
    }
    for (let i = 0; i < n; i++) {
      const ratio = sm[i] / Math.max(lum[i], 1e-4);
      const o = i * 4;
      let r8 = ModelColorMath.clamp255(Math.round(px[o] * ratio));
      let g8 = ModelColorMath.clamp255(Math.round(px[o + 1] * ratio));
      let b8 = ModelColorMath.clamp255(Math.round(px[o + 2] * ratio));
      if (guard) {
        r8 = Math.min(r8, 250);
        g8 = Math.min(g8, 250);
        b8 = Math.min(b8, 250);
      }
      px[o] = r8;
      px[o + 1] = g8;
      px[o + 2] = b8;
    }
  }

  /** 9 结点折线插值（knots 在 [lo,hi] 上均匀分布）。 */
  static curve(v: number, k: Float32Array, off: number, lo: number, hi: number): number {
    let pos = (v - lo) / (hi - lo);
    pos = pos < 0 ? 0 : (pos > 1 ? 1 : pos);
    pos *= 8;
    let i0 = Math.floor(pos);
    if (i0 > 7) {
      i0 = 7;
    }
    if (i0 < 0) {
      i0 = 0;
    }
    const f = pos - i0;
    return k[off + i0] + (k[off + i0 + 1] - k[off + i0]) * f;
  }

  /**
   * neutralize 输出为 8-bit sRGB 字节流（对齐 Kotlin neutralizePixels 的量化口径；
   * 参考缓冲第 3-5 通道取的是量化后字节的 Lab，训练数据同口径）。
   */
  static neutralizeBytes(px: Uint8Array): Uint8Array {
    const n = Math.floor(px.length / 4);
    if (n <= 0) {
      return px.slice();
    }
    const lin = new Float32Array(n * 3);
    let mr = 0;
    let mg = 0;
    let mb = 0;
    for (let i = 0; i < n; i++) {
      const o = i * 4;
      const r = ModelColorMath.srgbToLinear(px[o] / 255);
      const g = ModelColorMath.srgbToLinear(px[o + 1] / 255);
      const b = ModelColorMath.srgbToLinear(px[o + 2] / 255);
      lin[i * 3] = r;
      lin[i * 3 + 1] = g;
      lin[i * 3 + 2] = b;
      mr += r;
      mg += g;
      mb += b;
    }
    mr = mr / n + 1e-6;
    mg = mg / n + 1e-6;
    mb = mb / n + 1e-6;
    const mean = (mr + mg + mb) / 3;
    const gr = Math.min(Math.max(mean / mr, 0.5), 2);
    const gg = Math.min(Math.max(mean / mg, 0.5), 2);
    const gb = Math.min(Math.max(mean / mb, 0.5), 2);
    const m = Math.max(1, Math.floor((n + 15) / 16));
    const ys = new Float32Array(m);
    for (let k = 0; k < m; k++) {
      const i = k * 16;
      if (i >= n) {
        ys[k] = ys[k - 1];
        continue;
      }
      ys[k] = 0.2126 * lin[i * 3] * gr + 0.7152 * lin[i * 3 + 1] * gg + 0.0722 * lin[i * 3 + 2] * gb;
    }
    ys.sort();
    const lo = ys[Math.min(ys.length - 1, Math.floor(ys.length * 0.005))];
    const hi = ys[Math.min(ys.length - 1, Math.floor(ys.length * 0.995))];
    const span = Math.max(hi - lo, 1e-4);
    const s = Math.min(Math.max((0.98 - 0.005) / span, 0.25), 4);
    const off = 0.005 - lo * s;
    const out = new Uint8Array(n * 4);
    for (let i = 0; i < n; i++) {
      const r = Math.min(Math.max(lin[i * 3] * gr * s + off, 0), 1);
      const g = Math.min(Math.max(lin[i * 3 + 1] * gg * s + off, 0), 1);
      const b = Math.min(Math.max(lin[i * 3 + 2] * gb * s + off, 0), 1);
      const o = i * 4;
      out[o] = ModelColorMath.clamp255(Math.round(ModelColorMath.linearToSrgb(r) * 255));
      out[o + 1] = ModelColorMath.clamp255(Math.round(ModelColorMath.linearToSrgb(g) * 255));
      out[o + 2] = ModelColorMath.clamp255(Math.round(ModelColorMath.linearToSrgb(b) * 255));
      out[o + 3] = 255;
    }
    return out;
  }

  /**
   * N(x) 的 Lab（平面布局 L[0..n)/a[n..2n)/b[2n..3n)，L/100、a/128、b/128）。
   * 灰世界白平衡 + 0.5/99.5 分位曝光，与 common.neutralize 同口径。
   */
  static neutralizedLab(px: Uint8Array, n: number): Float32Array {
    const lin = new Float32Array(n * 3);
    let mr = 0;
    let mg = 0;
    let mb = 0;
    for (let i = 0; i < n; i++) {
      const o = i * 4;
      const r = ModelColorMath.srgbToLinear(px[o] / 255);
      const g = ModelColorMath.srgbToLinear(px[o + 1] / 255);
      const b = ModelColorMath.srgbToLinear(px[o + 2] / 255);
      lin[i * 3] = r;
      lin[i * 3 + 1] = g;
      lin[i * 3 + 2] = b;
      mr += r;
      mg += g;
      mb += b;
    }
    mr = mr / n + 1e-6;
    mg = mg / n + 1e-6;
    mb = mb / n + 1e-6;
    const mean = (mr + mg + mb) / 3;
    let gr = mean / mr;
    let gg = mean / mg;
    let gb = mean / mb;
    gr = Math.min(Math.max(gr, 0.5), 2);
    gg = Math.min(Math.max(gg, 0.5), 2);
    gb = Math.min(Math.max(gb, 0.5), 2);
    const m = Math.max(1, Math.floor((n + 15) / 16));
    const ys = new Float32Array(m);
    for (let k = 0; k < m; k++) {
      const i = k * 16;
      if (i >= n) {
        ys[k] = ys[k - 1];
        continue;
      }
      ys[k] = 0.2126 * lin[i * 3] * gr + 0.7152 * lin[i * 3 + 1] * gg + 0.0722 * lin[i * 3 + 2] * gb;
    }
    ys.sort();
    const lo = ys[Math.min(ys.length - 1, Math.floor(ys.length * 0.005))];
    const hi = ys[Math.min(ys.length - 1, Math.floor(ys.length * 0.995))];
    const span = Math.max(hi - lo, 1e-4);
    let s = (0.98 - 0.005) / span;
    s = Math.min(Math.max(s, 0.25), 4);
    const off = 0.005 - lo * s;
    const out = new Float32Array(n * 3);
    const rgb: number[] = [0, 0, 0];
    for (let i = 0; i < n; i++) {
      const r = Math.min(Math.max(lin[i * 3] * gr * s + off, 0), 1);
      const g = Math.min(Math.max(lin[i * 3 + 1] * gg * s + off, 0), 1);
      const b = Math.min(Math.max(lin[i * 3 + 2] * gb * s + off, 0), 1);
      ModelColorMath.rgbToRgbLab(ModelColorMath.linearToSrgb(r), ModelColorMath.linearToSrgb(g),
        ModelColorMath.linearToSrgb(b), rgb);
      out[i] = rgb[0] / 100;
      out[n + i] = rgb[1] / 128;
      out[2 * n + i] = rgb[2] / 128;
    }
    return out;
  }

  /**
   * 连续 0..1 天空/肤色保护权重（1 = 全保护）：1/8 网格打分 + 高斯模糊 + 双线性回采样。
   */
  static protectWeight(px: Uint8Array, w: number, h: number): Float32Array {
    const div = 8;
    const sw = Math.max(1, Math.floor((w + div - 1) / div));
    const sh = Math.max(1, Math.floor((h + div - 1) / div));
    const small = new Float32Array(sw * sh);
    const lab: number[] = [0, 0, 0];
    for (let sy = 0; sy < sh; sy++) {
      const y0 = sy * div;
      const y1 = Math.min(h, y0 + div);
      for (let sx = 0; sx < sw; sx++) {
        const x0 = sx * div;
        const x1 = Math.min(w, x0 + div);
        let sr = 0;
        let sg = 0;
        let sb = 0;
        let cnt = 0;
        for (let y = y0; y < y1; y++) {
          let idx = y * w + x0;
          for (let x = x0; x < x1; x++) {
            const o = idx * 4;
            sr += px[o];
            sg += px[o + 1];
            sb += px[o + 2];
            cnt++;
            idx++;
          }
        }
        if (cnt <= 0) {
          continue;
        }
        ModelColorMath.rgbToLab(((sr + Math.floor(cnt / 2)) / cnt) / 255,
          ((sg + Math.floor(cnt / 2)) / cnt) / 255,
          ((sb + Math.floor(cnt / 2)) / cnt) / 255, lab);
        small[sy * sw + sx] = ModelColorMath.protectScore(lab[0], lab[1], lab[2]);
      }
    }
    // 可分高斯（σ=2，BORDER_REFLECT_101）
    const sigma = 2;
    const rad = Math.ceil(3 * sigma);
    const kern = new Float32Array(2 * rad + 1);
    let ksum = 0;
    for (let i = -rad; i <= rad; i++) {
      const wgt = Math.exp(-(i * i) / (2 * sigma * sigma));
      kern[i + rad] = wgt;
      ksum += wgt;
    }
    for (let i = 0; i < kern.length; i++) {
      kern[i] /= ksum;
    }
    const tmp = new Float32Array(sw * sh);
    for (let y = 0; y < sh; y++) {
      for (let x = 0; x < sw; x++) {
        let acc = 0;
        for (let i = -rad; i <= rad; i++) {
          acc += kern[i + rad] * small[y * sw + ModelColorMath.reflect101(x + i, sw)];
        }
        tmp[y * sw + x] = acc;
      }
    }
    for (let y = 0; y < sh; y++) {
      for (let x = 0; x < sw; x++) {
        let acc = 0;
        for (let i = -rad; i <= rad; i++) {
          acc += kern[i + rad] * tmp[ModelColorMath.reflect101(y + i, sh) * sw + x];
        }
        small[y * sw + x] = acc;
      }
    }
    const out = new Float32Array(w * h);
    const scaleX = sw / w;
    const scaleY = sh / h;
    for (let y = 0; y < h; y++) {
      const spy = (y + 0.5) * scaleY - 0.5;
      let gy0 = Math.floor(spy);
      const fy = spy - gy0;
      const gy1 = Math.min(sh - 1, Math.max(0, gy0 + 1));
      gy0 = Math.min(sh - 1, Math.max(0, gy0));
      const r0 = gy0 * sw;
      const r1 = gy1 * sw;
      for (let x = 0; x < w; x++) {
        const spx = (x + 0.5) * scaleX - 0.5;
        let gx0 = Math.floor(spx);
        const fx = spx - gx0;
        const gx1 = Math.min(sw - 1, Math.max(0, gx0 + 1));
        gx0 = Math.min(sw - 1, Math.max(0, gx0));
        out[y * w + x] = (small[r0 + gx0] * (1 - fx) + small[r0 + gx1] * fx) * (1 - fy) +
          (small[r1 + gx0] * (1 - fx) + small[r1 + gx1] * fx) * fy;
      }
    }
    return out;
  }

  /** 三套天空/肤色软盒（白云、蓝天、肤色），色度与 |a| 上限排除彩色物体。 */
  private static protectScore(L: number, a: number, b: number): number {
    const chroma = Math.sqrt(a * a + b * b);
    const white = ModelColorMath.smoothstep(66, 79, L) * ModelColorMath.smoothstep(25, 12, chroma) *
      ModelColorMath.smoothstep(-1, -4, b) * (1 - ModelColorMath.smoothstep(4, 9, Math.abs(a)));
    const blue = ModelColorMath.smoothstep(42, 60, L) * ModelColorMath.smoothstep(42, 25, chroma) *
      ModelColorMath.smoothstep(-2, -7, b) * (1 - ModelColorMath.smoothstep(12, 20, Math.abs(a)));
    const skin = ModelColorMath.smoothstep(26, 36, L) * ModelColorMath.smoothstep(92, 80, L) *
      ModelColorMath.smoothstep(5, 11, a) * ModelColorMath.smoothstep(38, 30, a) *
      ModelColorMath.smoothstep(4, 10, b) * ModelColorMath.smoothstep(40, 32, b);
    return Math.max(Math.max(white, blue), skin);
  }

  private static smoothstep(e0: number, e1: number, x: number): number {
    let t = (x - e0) / (e1 - e0);
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return t * t * (3 - 2 * t);
  }

  private static reflect101(i: number, size: number): number {
    if (size <= 1) {
      return 0;
    }
    let v = i;
    while (v < 0 || v >= size) {
      if (v < 0) {
        v = -v;
      }
      if (v >= size) {
        v = 2 * (size - 1) - v;
      }
    }
    return v;
  }

  /** Lab 平面化（L/100、a/128、b/128），n = w*h。 */
  static labPlanes(px: Uint8Array, n: number): Float32Array {
    const out = new Float32Array(n * 3);
    const lab: number[] = [0, 0, 0];
    for (let i = 0; i < n; i++) {
      const o = i * 4;
      ModelColorMath.rgbToLab(px[o] / 255, px[o + 1] / 255, px[o + 2] / 255, lab);
      out[i] = lab[0] / 100;
      out[n + i] = lab[1] / 128;
      out[2 * n + i] = lab[2] / 128;
    }
    return out;
  }

  /** sRGB [0,1] → Lab [L, a, b]（D65）。 */
  static rgbToLab(r: number, g: number, b: number, out: number[]): void {
    const rl = ModelColorMath.srgbToLinear(r);
    const gl = ModelColorMath.srgbToLinear(g);
    const bl = ModelColorMath.srgbToLinear(b);
    const x = (0.412453 * rl + 0.357580 * gl + 0.180423 * bl) / 0.950456;
    const y = 0.212671 * rl + 0.715160 * gl + 0.072169 * bl;
    const z = (0.019334 * rl + 0.119193 * gl + 0.950227 * bl) / 1.088754;
    const fx = x > 0.008856 ? Math.cbrt(x) : 7.787 * x + 16 / 116;
    const fy = y > 0.008856 ? Math.cbrt(y) : 7.787 * y + 16 / 116;
    const fz = z > 0.008856 ? Math.cbrt(z) : 7.787 * z + 16 / 116;
    out[0] = 116 * fy - 16;
    out[1] = 500 * (fx - fy);
    out[2] = 200 * (fy - fz);
  }

  /** 线性 RGB（经 gamma 展开后的 sRGB 值）→ Lab（neutralize 输出复用）。 */
  private static rgbToRgbLab(r: number, g: number, b: number, out: number[]): void {
    ModelColorMath.rgbToLab(r, g, b, out);
  }

  /** Lab → sRGB [0,1]。 */
  static labToRgb(L: number, A: number, B: number, out: number[]): void {
    const fy = (L + 16) / 116;
    const fx = fy + A / 500;
    const fz = fy - B / 200;
    const x = ModelColorMath.finv(fx) * 0.950456;
    const y = ModelColorMath.finv(fy);
    const z = ModelColorMath.finv(fz) * 1.088754;
    const rl = Math.min(Math.max(3.240479 * x - 1.537150 * y - 0.498535 * z, 0), 1);
    const gl = Math.min(Math.max(-0.969256 * x + 1.875992 * y + 0.041556 * z, 0), 1);
    const bl = Math.min(Math.max(0.055648 * x - 0.204043 * y + 1.057311 * z, 0), 1);
    out[0] = ModelColorMath.linearToSrgb(rl);
    out[1] = ModelColorMath.linearToSrgb(gl);
    out[2] = ModelColorMath.linearToSrgb(bl);
  }

  private static finv(t: number): number {
    return t > 0.206893 ? t * t * t : (t - 16 / 116) / 7.787;
  }

  static srgbToLinear(v: number): number {
    return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  }

  static linearToSrgb(v: number): number {
    return v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
  }

  static clamp255(v: number): number {
    return v < 0 ? 0 : (v > 255 ? 255 : v);
  }

  /** 紧密 RGBA 双线性缩放。 */
  static scaleRgba(src: Uint8Array, sw: number, sh: number, dw: number, dh: number): Uint8Array {
    const out = new Uint8Array(dw * dh * 4);
    const xr = sw / dw;
    const yr = sh / dh;
    for (let y = 0; y < dh; y++) {
      let sy = (y + 0.5) * yr - 0.5;
      if (sy < 0) {
        sy = 0;
      }
      const y0 = Math.floor(sy);
      const y1 = Math.min(y0 + 1, sh - 1);
      const fy = sy - y0;
      for (let x = 0; x < dw; x++) {
        let sx = (x + 0.5) * xr - 0.5;
        if (sx < 0) {
          sx = 0;
        }
        const x0 = Math.floor(sx);
        const x1 = Math.min(x0 + 1, sw - 1);
        const fx = sx - x0;
        const i00 = (y0 * sw + x0) * 4;
        const i01 = (y0 * sw + x1) * 4;
        const i10 = (y1 * sw + x0) * 4;
        const i11 = (y1 * sw + x1) * 4;
        const o = (y * dw + x) * 4;
        for (let c = 0; c < 3; c++) {
          const top = src[i00 + c] * (1 - fx) + src[i01 + c] * fx;
          const bot = src[i10 + c] * (1 - fx) + src[i11 + c] * fx;
          out[o + c] = Math.round(top * (1 - fy) + bot * fy);
        }
        out[o + 3] = 255;
      }
    }
    return out;
  }
}
