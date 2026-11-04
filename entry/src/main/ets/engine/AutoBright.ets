/**
 * LibRaw auto_bright 预览路径复刻（copy_mem_image 同语义）。
 * 独立模块：@Concurrent 任务只能引用 import，不能引用文件级函数。
 *
 * 原版语义：perc = w*h*thr 为允许裁剪的像素数；逐通道线性直方图自顶向下
 * 累计，超过 perc 即停得 t_white（下限对应原版 val>32），三通道取最大；
 * 白点提升至 t_white 即线性放大 f = 1024/t_white，上限 4x 防近黑图爆噪。
 * f≤1.02 视为图像已足够亮，跳过不改。
 */
export class AutoBright {
  /** sRGB→线性 LUT（256 档，worker 内惰性构建复用）。 */
  private static srgbLin: Float32Array | null = null;
  /** 三通道线性直方图（1024 桶/通道，任务间复用）。 */
  private static linHist: Uint32Array | null = null;

  private static lut(): Float32Array {
    let lut = AutoBright.srgbLin;
    if (lut === null) {
      lut = new Float32Array(256);
      for (let v = 0; v < 256; v++) {
        const c = v / 255;
        lut[v] = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
      }
      AutoBright.srgbLin = lut;
    }
    return lut;
  }

  private static linToSrgbByte(lin: number): number {
    if (lin >= 1) {
      return 255;
    }
    const c = lin <= 0.0031308 ? lin * 12.92 : 1.055 * Math.pow(lin, 1 / 2.4) - 0.055;
    const v = Math.round(c * 255);
    return v < 0 ? 0 : (v > 255 ? 255 : v);
  }

  /** 对内嵌预览 RGBA 像素按 thr（auto_bright_thr）执行提亮，返回是否实际调整。 */
  static preview(rgba: Uint8Array, width: number, height: number, thr: number): boolean {
    const n = width * height;
    if (n <= 0 || rgba.length < n * 4 || thr <= 0) {
      return false;
    }
    const BINS = 1024;
    let hist = AutoBright.linHist;
    if (hist === null) {
      hist = new Uint32Array(3 * BINS);
      AutoBright.linHist = hist;
    }
    hist.fill(0);
    const lut = AutoBright.lut();
    const scale = BINS - 1;
    for (let i = 0; i < n; i++) {
      hist[(lut[rgba[i * 4]] * scale) | 0]++;
      hist[BINS + ((lut[rgba[i * 4 + 1]] * scale) | 0)]++;
      hist[BINS * 2 + ((lut[rgba[i * 4 + 2]] * scale) | 0)]++;
    }
    const perc = Math.floor(n * thr);
    let tWhite = 0;
    for (let c = 0; c < 3; c++) {
      const base = c * BINS;
      let total = 0;
      let b = BINS;
      while (b > 4) {
        b--;
        total += hist[base + b];
        if (total > perc) {
          break;
        }
      }
      if (tWhite < b) {
        tWhite = b;
      }
    }
    if (tWhite >= BINS - 21) {
      return false;
    }
    let f = BINS / tWhite;
    if (f > 4) {
      f = 4;
    }
    const out = new Uint8Array(256);
    for (let v = 0; v < 256; v++) {
      out[v] = AutoBright.linToSrgbByte(lut[v] * f);
    }
    for (let i = 0; i < n; i++) {
      rgba[i * 4] = out[rgba[i * 4]];
      rgba[i * 4 + 1] = out[rgba[i * 4 + 1]];
      rgba[i * 4 + 2] = out[rgba[i * 4 + 2]];
    }
    return true;
  }
}
