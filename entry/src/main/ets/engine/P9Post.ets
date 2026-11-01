/**
 * L-P9 专用前后处理（移植自 P9Post.java + Lm9Post.java 色度算子）。
 *
 * pre：色度中频衰减（云斑治理）——Y 不动，Cb/Cr 取 DS=2 网格低频 + detail×0.3 回加；
 *      天空掩码内 40~121px 中频带衰减 65%（blur15-blur60 校正场双线性减除）。
 * post：高光安全钳——最大通道永不越 250。
 */

export class P9Post {
  private static readonly CH_DS = 2;
  private static readonly CH_R = 9;
  private static readonly CH_KEEP = 0.3;
  private static readonly SKY_BAND_KEEP = 0.35;

  static pre(px: Uint8Array, w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    P9Post.chromaDenoise(px, w, h);
    P9Post.skyChromaMidbandClean(px, w, h);
  }

  static post(px: Uint8Array, w: number, h: number): void {
    const n = px.length;
    for (let i4 = 0; i4 + 3 < n; i4 += 4) {
      const r = px[i4];
      const g = px[i4 + 1];
      const b = px[i4 + 2];
      const mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      if (mx > 250) {
        const k = 250 / mx;
        px[i4] = P9Post.clamp255(r * k);
        px[i4 + 1] = P9Post.clamp255(g * k);
        px[i4 + 2] = P9Post.clamp255(b * k);
      }
    }
  }

  /** 色度中频衰减：Y 不动，Cb/Cr 取网格低频 + detail×CH_KEEP 回加。 */
  private static chromaDenoise(px: Uint8Array, w: number, h: number): void {
    const CH_DS = P9Post.CH_DS;
    const CH_R = P9Post.CH_R;
    const CH_KEEP = P9Post.CH_KEEP;
    const sw = Math.ceil(w / CH_DS);
    const sh = Math.ceil(h / CH_DS);
    const size = sw * sh;
    const crS = new Float64Array(size);
    const cbS = new Float64Array(size);
    const cnt = new Int32Array(size);
    for (let y = 0; y < h; y++) {
      const sy = Math.floor(y / CH_DS);
      for (let x = 0; x < w; x++) {
        const i4 = (y * w + x) * 4;
        const r = px[i4];
        const g = px[i4 + 1];
        const b = px[i4 + 2];
        const Y = 0.299 * r + 0.587 * g + 0.114 * b;
        const si = sy * sw + Math.floor(x / CH_DS);
        crS[si] += (r - Y) / 1.402;
        cbS[si] += (b - Y) / 1.772;
        cnt[si]++;
      }
    }
    for (let i = 0; i < size; i++) {
      if (cnt[i] > 0) {
        crS[i] /= cnt[i];
        cbS[i] /= cnt[i];
      }
    }
    const crL0 = P9Post.boxBlur(crS, sw, sh, CH_R);
    const crL = P9Post.boxBlur(crL0, sw, sh, CH_R);
    const cbL0 = P9Post.boxBlur(cbS, sw, sh, CH_R);
    const cbL = P9Post.boxBlur(cbL0, sw, sh, CH_R);
    const invDs = 1 / CH_DS;
    for (let y = 0; y < h; y++) {
      const fy = (y + 0.5) * invDs - 0.5;
      const y0 = P9Post.floorInt(fy, sh - 1);
      const y1 = Math.min(y0 + 1, sh - 1);
      const wy = Math.max(fy - y0, 0);
      const row0 = y0 * sw;
      const row1 = y1 * sw;
      for (let x = 0; x < w; x++) {
        const fx = (x + 0.5) * invDs - 0.5;
        const x0 = P9Post.floorInt(fx, sw - 1);
        const x1 = Math.min(x0 + 1, sw - 1);
        const wx = Math.max(fx - x0, 0);
        const crLow = (1 - wx) * (1 - wy) * crL[row0 + x0] + wx * (1 - wy) * crL[row0 + x1]
          + (1 - wx) * wy * crL[row1 + x0] + wx * wy * crL[row1 + x1];
        const cbLow = (1 - wx) * (1 - wy) * cbL[row0 + x0] + wx * (1 - wy) * cbL[row0 + x1]
          + (1 - wx) * wy * cbL[row1 + x0] + wx * wy * cbL[row1 + x1];

        const i4 = (y * w + x) * 4;
        const r = px[i4];
        const g = px[i4 + 1];
        const b = px[i4 + 2];
        const Y = 0.299 * r + 0.587 * g + 0.114 * b;
        const Cr = (r - Y) / 1.402;
        const Cb = (b - Y) / 1.772;
        const cr2 = crLow + (Cr - crLow) * CH_KEEP;
        const cb2 = cbLow + (Cb - cbLow) * CH_KEEP;
        px[i4] = P9Post.clamp255(Y + 1.402 * cr2);
        px[i4 + 1] = P9Post.clamp255(Y - 0.7141 * cr2 - 0.3441 * cb2);
        px[i4 + 2] = P9Post.clamp255(Y + 1.772 * cb2);
      }
    }
  }

  /** 天空色度中频清理：掩码内 blur15-blur60 带衰减 65%。 */
  private static skyChromaMidbandClean(px: Uint8Array, w: number, h: number): void {
    const ds = 2;
    const sw = Math.ceil(w / ds);
    const sh = Math.ceil(h / ds);
    const size = sw * sh;
    const cbS = new Float64Array(size);
    const crS = new Float64Array(size);
    const vS = new Float64Array(size);
    const cnt = new Int32Array(size);
    for (let y = 0; y < h; y++) {
      const sy = Math.floor(y / ds);
      for (let x = 0; x < w; x++) {
        const i4 = (y * w + x) * 4;
        const r = px[i4] / 255;
        const g = px[i4 + 1] / 255;
        const b = px[i4 + 2] / 255;
        const Y = 0.299 * r + 0.587 * g + 0.114 * b;
        const si = sy * sw + Math.floor(x / ds);
        crS[si] += (r - Y) / 1.402;
        cbS[si] += (b - Y) / 1.772;
        vS[si] += Math.max(r, Math.max(g, b));
        cnt[si]++;
      }
    }
    for (let i = 0; i < size; i++) {
      if (cnt[i] > 0) {
        crS[i] /= cnt[i];
        cbS[i] /= cnt[i];
        vS[i] /= cnt[i];
      }
    }
    const cb31 = P9Post.boxBlur(cbS, sw, sh, 15);
    const cr31 = P9Post.boxBlur(crS, sw, sh, 15);
    const cb121 = P9Post.boxBlur(cbS, sw, sh, 60);
    const cr121 = P9Post.boxBlur(crS, sw, sh, 60);
    let msk = new Float64Array(size);
    for (let i = 0; i < size; i++) {
      msk[i] = cbS[i] > 0.02 && vS[i] >= 0.55 ? 1 : 0;
    }
    msk = P9Post.boxBlur(msk, sw, sh, 6);
    const invDs = 1 / ds;
    const attnBase = 1 - P9Post.SKY_BAND_KEEP;
    for (let y = 0; y < h; y++) {
      const fy = (y + 0.5) * invDs - 0.5;
      const y0 = P9Post.floorInt(fy, sh - 1);
      const y1 = Math.min(y0 + 1, sh - 1);
      const wy = Math.max(fy - y0, 0);
      const row0 = y0 * sw;
      const row1 = y1 * sw;
      for (let x = 0; x < w; x++) {
        const fx = (x + 0.5) * invDs - 0.5;
        const x0 = P9Post.floorInt(fx, sw - 1);
        const x1 = Math.min(x0 + 1, sw - 1);
        const wx = Math.max(fx - x0, 0);
        const m = (1 - wx) * (1 - wy) * msk[row0 + x0] + wx * (1 - wy) * msk[row0 + x1]
          + (1 - wx) * wy * msk[row1 + x0] + wx * wy * msk[row1 + x1];
        if (m < 0.02) {
          continue;
        }
        const i4 = (y * w + x) * 4;
        const r = px[i4] / 255;
        const g = px[i4 + 1] / 255;
        const b = px[i4 + 2] / 255;
        const Y = 0.299 * r + 0.587 * g + 0.114 * b;
        const Cr = (r - Y) / 1.402;
        const Cb = (b - Y) / 1.772;
        const bandCb = (1 - wx) * (1 - wy) * (cb31[row0 + x0] - cb121[row0 + x0])
          + wx * (1 - wy) * (cb31[row0 + x1] - cb121[row0 + x1])
          + (1 - wx) * wy * (cb31[row1 + x0] - cb121[row1 + x0])
          + wx * wy * (cb31[row1 + x1] - cb121[row1 + x1]);
        const bandCr = (1 - wx) * (1 - wy) * (cr31[row0 + x0] - cr121[row0 + x0])
          + wx * (1 - wy) * (cr31[row0 + x1] - cr121[row0 + x1])
          + (1 - wx) * wy * (cr31[row1 + x0] - cr121[row1 + x0])
          + wx * wy * (cr31[row1 + x1] - cr121[row1 + x1]);
        const attn = attnBase * m;
        const cr2 = Cr - bandCr * attn;
        const cb2 = Cb - bandCb * attn;
        px[i4] = P9Post.clamp255((Y + 1.402 * cr2) * 255);
        px[i4 + 1] = P9Post.clamp255((Y - 0.7141 * cr2 - 0.3441 * cb2) * 255);
        px[i4 + 2] = P9Post.clamp255((Y + 1.772 * cb2) * 255);
      }
    }
  }

  private static boxBlur(src: Float64Array, w: number, h: number, r: number): Float64Array {
    const tmp = new Float64Array(src.length);
    const out = new Float64Array(src.length);
    const inv = 1 / (2 * r + 1);
    for (let y = 0; y < h; y++) {
      const row = y * w;
      let acc = 0;
      for (let k = -r; k <= r; k++) {
        acc += src[row + P9Post.clampi(k, 0, w - 1)];
      }
      for (let x = 0; x < w; x++) {
        tmp[row + x] = acc * inv;
        acc -= src[row + P9Post.clampi(x - r, 0, w - 1)];
        acc += src[row + P9Post.clampi(x + r + 1, 0, w - 1)];
      }
    }
    for (let x = 0; x < w; x++) {
      let acc = 0;
      for (let k = -r; k <= r; k++) {
        acc += tmp[P9Post.clampi(k, 0, h - 1) * w + x];
      }
      for (let y = 0; y < h; y++) {
        out[y * w + x] = acc * inv;
        acc -= tmp[P9Post.clampi(y - r, 0, h - 1) * w + x];
        acc += tmp[P9Post.clampi(y + r + 1, 0, h - 1) * w + x];
      }
    }
    return out;
  }

  private static floorInt(v: number, max: number): number {
    const i = Math.floor(v);
    if (i < 0) {
      return 0;
    }
    if (i > max) {
      return max;
    }
    return i;
  }

  private static clampi(v: number, lo: number, hi: number): number {
    return v < lo ? lo : (v > hi ? hi : v);
  }

  private static clamp255(v: number): number {
    const i = Math.floor(v + 0.5);
    if (i < 0) {
      return 0;
    }
    if (i > 255) {
      return 255;
    }
    return i;
  }
}
