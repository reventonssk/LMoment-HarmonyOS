/**
 * 第八档「柔光」（移植自 SoftGlow.kt：Orton 扩散 / 反向清晰化）。
 *
 * 正档 = 经典 Orton 柔光：模糊版 ×1.10 提亮 → 与原图 screen 混合 → 高光掩码限域 →
 *        强度混合；雾集中在中高光，阴影不上灰。负档 = 反向清晰化（unsharp，向模糊版
 *        反向拉），两方向共用同一次三趟分离盒模糊（近似高斯）。
 *
 * 半径 = min(w,h)/100：与分辨率无关的视觉口径，预览与全尺寸导出观感一致。
 * 8-bit 紧密 RGBA 域执行（ToneCurves 之后调用，与 Android 曲线后叠加同口径）。
 * 不进条带链：大半径超出条带重叠带，逐带处理必然带边不连续（LM9 v15 教训）。
 * 线程安全：无共享状态，taskpool 中并发调用不同缓冲区安全。
 */

export class SoftGlow {
  static readonly MIN_LEVEL: number = -10;
  static readonly MAX_LEVEL: number = 10;
  /** 正档 +10 的最大混合强度（经典 Orton 观感区间 0.45~0.6）。 */
  private static readonly MAX_STRENGTH: number = 0.55;
  /** 负档 -10 的最大清晰化强度。 */
  private static readonly MAX_CLARITY: number = 0.45;
  /** 高光掩码 smoothstep 端点（亮度 0..255）：柔光集中在中高光。 */
  private static readonly MASK_LO: number = 115;
  private static readonly MASK_HI: number = 235;
  /** 像素防护上限（>26M px 跳过：px+blur 双缓冲瞬时占用过高）。 */
  private static readonly MAX_PIXELS: number = 26000000;

  /** 原地处理紧密 RGBA；level==0 / 尺寸过小 / 超大图原样返回（与 Android 同防护）。 */
  static apply(px: Uint8Array, w: number, h: number, level: number): void {
    if (level === 0 || w < 3 || h < 3 || w * h > SoftGlow.MAX_PIXELS) {
      return;
    }
    if (px.length < w * h * 4) {
      return;
    }
    const blur = px.slice();
    SoftGlow.boxBlur3(blur, w, h, Math.max(2, Math.floor(Math.min(w, h) / 100)));
    const n = w * h * 4;
    if (level > 0) {
      // 0..~140 的混合强度
      const k = Math.trunc(0.55 * level / 10 * 255);
      for (let i = 0; i < n; i += 4) {
        const pr = px[i];
        const pg = px[i + 1];
        const pb = px[i + 2];
        // 亮层：模糊版 ×1.10 提亮（Orton 的 glow 层）
        const gr = Math.min(255, (blur[i] * 282) >> 8);
        const gg = Math.min(255, (blur[i + 1] * 282) >> 8);
        const gb = Math.min(255, (blur[i + 2] * 282) >> 8);
        // screen：255-(255-a)(255-g)/255
        const sr = 255 - Math.floor((255 - pr) * (255 - gr) / 255);
        const sg = 255 - Math.floor((255 - pg) * (255 - gg) / 255);
        const sb = 255 - Math.floor((255 - pb) * (255 - gb) / 255);
        // 高光掩码 smoothstep（亮度域），阴影不上灰
        const lum = (pr * 77 + pg * 150 + pb * 29) >> 8;
        let t = Math.floor((lum - SoftGlow.MASK_LO) * 255 / (SoftGlow.MASK_HI - SoftGlow.MASK_LO));
        if (t < 0) {
          t = 0;
        } else if (t > 255) {
          t = 255;
        }
        const m = Math.floor(t * t * (3 * 255 - 2 * t) / (255 * 255));
        const eff = Math.floor(k * m / 255);
        px[i] = SoftGlow.clamp255(pr + Math.floor((sr - pr) * eff / 255));
        px[i + 1] = SoftGlow.clamp255(pg + Math.floor((sg - pg) * eff / 255));
        px[i + 2] = SoftGlow.clamp255(pb + Math.floor((sb - pb) * eff / 255));
      }
    } else {
      const kf = 0.45 * (-level) / 10;
      for (let i = 0; i < n; i += 4) {
        const pr = px[i];
        const pg = px[i + 1];
        const pb = px[i + 2];
        px[i] = SoftGlow.clamp255(Math.round(pr + (pr - blur[i]) * kf));
        px[i + 1] = SoftGlow.clamp255(Math.round(pg + (pg - blur[i + 1]) * kf));
        px[i + 2] = SoftGlow.clamp255(Math.round(pb + (pb - blur[i + 2]) * kf));
      }
    }
  }

  private static clamp255(v: number): number {
    return v < 0 ? 0 : (v > 255 ? 255 : v);
  }

  /** 三趟分离盒模糊（近似高斯）；原地改写 [px]。窗口半径 [r]，边缘钳位。 */
  private static boxBlur3(px: Uint8Array, w: number, h: number, r: number): void {
    const win = 2 * r + 1;
    const tmp = new Uint8Array(px.length);
    for (let pass = 0; pass < 3; pass++) {
      // 水平：px → tmp
      for (let y = 0; y < h; y++) {
        const row = y * w * 4;
        let sr = 0;
        let sg = 0;
        let sb = 0;
        for (let x = -r; x <= r; x++) {
          const cx = x < 0 ? 0 : (x > w - 1 ? w - 1 : x);
          const p = row + cx * 4;
          sr += px[p];
          sg += px[p + 1];
          sb += px[p + 2];
        }
        for (let x = 0; x < w; x++) {
          const o = row + x * 4;
          tmp[o] = Math.floor(sr / win);
          tmp[o + 1] = Math.floor(sg / win);
          tmp[o + 2] = Math.floor(sb / win);
          tmp[o + 3] = 255;
          const ox = x - r < 0 ? 0 : (x - r > w - 1 ? w - 1 : x - r);
          const ix = x + r + 1 > w - 1 ? w - 1 : x + r + 1;
          const po = row + ox * 4;
          const pi = row + ix * 4;
          sr += px[pi] - px[po];
          sg += px[pi + 1] - px[po + 1];
          sb += px[pi + 2] - px[po + 2];
        }
      }
      // 垂直：tmp → px
      for (let x = 0; x < w; x++) {
        const col = x * 4;
        let sr = 0;
        let sg = 0;
        let sb = 0;
        for (let yv = -r; yv <= r; yv++) {
          const cy = yv < 0 ? 0 : (yv > h - 1 ? h - 1 : yv);
          const p = cy * w * 4 + col;
          sr += tmp[p];
          sg += tmp[p + 1];
          sb += tmp[p + 2];
        }
        for (let yv = 0; yv < h; yv++) {
          const o = yv * w * 4 + col;
          px[o] = Math.floor(sr / win);
          px[o + 1] = Math.floor(sg / win);
          px[o + 2] = Math.floor(sb / win);
          px[o + 3] = 255;
          const oy = yv - r < 0 ? 0 : (yv - r > h - 1 ? h - 1 : yv - r);
          const iy = yv + r + 1 > h - 1 ? h - 1 : yv + r + 1;
          const po = oy * w * 4 + col;
          const pi = iy * w * 4 + col;
          sr += tmp[pi] - tmp[po];
          sg += tmp[pi + 1] - tmp[po + 1];
          sb += tmp[pi + 2] - tmp[po + 2];
        }
      }
    }
  }
}
