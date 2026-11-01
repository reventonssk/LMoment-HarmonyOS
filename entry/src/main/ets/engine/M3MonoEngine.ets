/**
 * M3 手工黑白滤镜（移植自 M3Mono.kt convert()）。
 *
 * 五层结构：通道混合黑白（黄滤权重）→ 胶片 S 曲线 → 底灰/白位 →
 * 亮度相关颗粒（低频噪声场双线性采样）→ 输出恒为灰度。
 */

export class M3MonoEngine {
  static apply(px: Uint8Array, w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    const W_R = 0.54;
    const W_G = 0.40;
    const W_B = 0.06;
    const FADE_BLACK = 10;
    const FADE_WHITE = 246;
    const CONTRAST_S = 0.42;
    const GRAIN_MAX = 13;
    const GRAIN_SIZE_DIV = 1400;

    const range = FADE_WHITE - FADE_BLACK;
    const curve = new Float64Array(256);
    for (let v = 0; v < 256; v++) {
      const u0 = (v - FADE_BLACK) / range;
      const u = u0 < 0 ? 0 : (u0 > 1 ? 1 : u0);
      const s = u * u * (3 - 2 * u);
      const mixed = u + (s - u) * CONTRAST_S;
      curve[v] = FADE_BLACK + mixed * range;
    }

    const gs = Math.max(1, w / GRAIN_SIZE_DIV);
    const nw = Math.floor(w / gs) + 2;
    const nh = Math.floor(h / gs) + 2;
    const noise = new Float64Array(nw * nh);
    let seed = -1640531527; // 0x9E3779B9
    for (let i = 0; i < noise.length; i++) {
      seed = (seed ^ (seed << 13)) | 0;
      seed = (seed ^ (seed >>> 17)) | 0;
      seed = (seed ^ (seed << 5)) | 0;
      noise[i] = (seed & 0xFFFF) / 32768 - 1;
    }

    for (let y = 0; y < h; y++) {
      const gy = y / gs;
      let y0 = Math.floor(gy);
      if (y0 > nh - 2) {
        y0 = nh - 2;
      }
      if (y0 < 0) {
        y0 = 0;
      }
      const fy = gy - y0;
      const row0 = y0 * nw;
      const row1 = row0 + nw;

      const rowBase = y * w;
      for (let x = 0; x < w; x++) {
        const i4 = (rowBase + x) * 4;
        const r = px[i4];
        const g = px[i4 + 1];
        const b = px[i4 + 2];

        const mix = W_R * r + W_G * g + W_B * b;
        let mi = Math.floor(mix);
        if (mi > 255) {
          mi = 255;
        }
        if (mi < 0) {
          mi = 0;
        }
        let v = curve[mi];

        const t = v / 255;
        const shape0 = t * (1 - t) * 4;
        const shape = shape0 < 0 ? 0 : (shape0 > 1 ? 1 : shape0);
        const amp = GRAIN_MAX * (0.3 + 0.7 * shape);

        const gx = x / gs;
        let x0 = Math.floor(gx);
        if (x0 > nw - 2) {
          x0 = nw - 2;
        }
        if (x0 < 0) {
          x0 = 0;
        }
        const fx = gx - x0;
        const n00 = noise[row0 + x0];
        const n10 = noise[row0 + x0 + 1];
        const n01 = noise[row1 + x0];
        const n11 = noise[row1 + x0 + 1];
        const nTop = n00 + (n10 - n00) * fx;
        const nBot = n01 + (n11 - n01) * fx;
        v += (nTop + (nBot - nTop) * fy) * amp;

        let vi = Math.trunc(v);
        if (vi > 255) {
          vi = 255;
        }
        if (vi < 0) {
          vi = 0;
        }
        px[i4] = vi;
        px[i4 + 1] = vi;
        px[i4 + 2] = vi;
      }
    }
  }
}
