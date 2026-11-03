/**
 * 纯像素缩放工具（无 UI / image / so 依赖，可在 taskpool 工作线程使用）。
 */

export class PixelScale {
  /** 紧密 RGBA 盒式降采样。 */
  static downscaleRgba(src: Uint8Array, sw: number, sh: number, dw: number, dh: number): Uint8Array {
    const out = new Uint8Array(dw * dh * 4);
    const xRatio = sw / dw;
    const yRatio = sh / dh;
    for (let dy = 0; dy < dh; dy++) {
      const y0 = Math.floor(dy * yRatio);
      const y1 = Math.min(sh, Math.max(y0 + 1, Math.floor((dy + 1) * yRatio)));
      for (let dx = 0; dx < dw; dx++) {
        const x0 = Math.floor(dx * xRatio);
        const x1 = Math.min(sw, Math.max(x0 + 1, Math.floor((dx + 1) * xRatio)));
        let r = 0;
        let g = 0;
        let b = 0;
        let n = 0;
        for (let y = y0; y < y1; y++) {
          const row = y * sw * 4;
          for (let x = x0; x < x1; x++) {
            const i = row + x * 4;
            r += src[i];
            g += src[i + 1];
            b += src[i + 2];
            n++;
          }
        }
        const o = (dy * dw + dx) * 4;
        out[o] = Math.round(r / n);
        out[o + 1] = Math.round(g / n);
        out[o + 2] = Math.round(b / n);
        out[o + 3] = 255;
      }
    }
    return out;
  }
}
