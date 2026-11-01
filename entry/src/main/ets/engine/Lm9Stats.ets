/**
 * L-M9 v0「统计同源」链（对齐 Android Lm9Stats.java，纯 ArkTS 无模型）。
 *
 * 区域化相对变换：out = (x - m_区域) * RS + m_区域 * RL，
 * 行 = 天空 / 植被 / 其他（连续软权重 + 高光保护）；
 * 天空域（顶行连通 + 高斯羽化）内换单一等效曲线（一阶矩守恒解 wMix）；
 * 全图 1-D 误差扩散量化（每行重置）。
 * 失败抛异常，调用方（NeuralEngine）降级到下一级链。
 */

import { yieldUI } from './PixAsync';

const LM9_KEYS: string[] = ['A-plain', 'A-sky', 'A-skyveg', 'B-plain', 'B-sky', 'B-skyveg',
  'B-veg', 'C-plain', 'C-veg'];

/** 行 0/1/2 = 天空/植被/其他；rL = 池区域均值 / 语料区域均值（选择性压暗）。 */
const LM9_RL: Float32Array = new Float32Array([
  0.919, 0.953, 0.959,
  0.700, 0.740, 0.700,
  0.720, 0.740, 0.760]);

/** rS = 池区域标准差 / 语料区域标准差（轻微压对比）。 */
const LM9_RS: Float32Array = new Float32Array([
  1.062, 1.028, 1.000,
  0.870, 0.953, 0.858,
  0.892, 0.859, 0.864]);

const LM9_PROBE = 320;

/** skyWeight 三元组复用（单线程逐像素使用，无重入）。 */
const LM9_W3: Float32Array = new Float32Array(3);

export class Lm9Stats {
  /** 原地改写 RGBA 字节流（全分辨率）。 */
  static async apply(px: Uint8Array, w: number, h: number): Promise<void> {
    if (w < 1 || h < 1 || px.length < w * h * 4) {
      throw new Error('lm9stats bad input');
    }
    const pw = LM9_PROBE;
    const ph = Math.max(1, Math.round(LM9_PROBE * h / w));
    const probe = Lm9Stats.buildProbe(px, w, h, pw, ph);
    const bucket = Lm9Stats.bucketOf(probe, pw, ph);

    // 探测图上三区域均值（分类阈值与 skyWeight 同口径的硬判版）
    const mR = new Float32Array(9);
    Lm9Stats.regionMeans(probe, pw, ph, mR);

    // 区域 LUT：lut[(region*3+channel)*256 + v]，值域 0..255（float，不预取整避免双重量化）
    const lut = new Float32Array(9 * 256);
    for (let r = 0; r < 3; r++) {
      for (let c = 0; c < 3; c++) {
        const base = (r * 3 + c) * 256;
        const m = mR[r * 3 + c];
        const rs = LM9_RS[r * 3 + c];
        const rl = LM9_RL[r * 3 + c];
        for (let v = 0; v < 256; v++) {
          let o = (v / 255 - m) * rs + m * rl;
          o = o < 0 ? 0 : (o > 1 ? 1 : o);
          lut[base + v] = o * 255;
        }
      }
    }

    // ---- 天空域单等效曲线（320 探测图决策，全图只做双线性采样）----
    const mk = Lm9Stats.skyDomain(probe, pw, ph);
    let eff: Float32Array | undefined = undefined;
    let dMk: Float32Array | undefined = undefined;
    let mx0: Int32Array | undefined = undefined;
    let mx1: Int32Array | undefined = undefined;
    let mfx: Float32Array | undefined = undefined;
    if (mk !== undefined) {
      let area = 0;
      let dn = 0;
      let wsum = 0;
      let ssum = 0;
      let l0 = 0;
      let l2 = 0;
      let lo = 0;
      for (let i = 0; i < pw * ph; i++) {
        if (mk[i] <= 0.5) {
          continue;
        }
        area++;
        const o = i * 4;
        const r0 = probe[o];
        const g0 = probe[o + 1];
        const b0 = probe[o + 2];
        Lm9Stats.skyWeightInto(r0, g0, b0, LM9_W3);
        const y0 = 0.2126 * lut[r0] + 0.7152 * lut[256 + g0] + 0.0722 * lut[512 + b0];
        const y2 = 0.2126 * lut[1536 + r0] + 0.7152 * lut[1792 + g0] + 0.0722 * lut[2048 + b0];
        const sw2 = Math.max(1e-6, LM9_W3[0] + LM9_W3[2]);
        lo += (LM9_W3[0] * y0 + LM9_W3[2] * y2) / sw2;
        l0 += y0;
        l2 += y2;
        wsum += mk[i];
        ssum += LM9_W3[0] * mk[i];
        dn++;
      }
      if (dn > 0 && area >= 0.05 * pw * ph && wsum > 0) {
        const wbar = ssum / wsum;
        if (wbar >= 0.30) {
          const a = l0 / dn;
          const b = l2 / dn;
          const ov = lo / dn;
          let wMix = Math.abs(a - b) < 1e-3 ? wbar : (ov - b) / (a - b);
          wMix = wMix < 0 ? 0 : (wMix > 1 ? 1 : wMix);
          eff = new Float32Array(768);
          for (let c = 0; c < 3; c++) {
            for (let v = 0; v < 256; v++) {
              eff[c * 256 + v] = wMix * lut[c * 256 + v] + (1 - wMix) * lut[(6 + c) * 256 + v];
            }
          }
          dMk = mk;
          mx0 = new Int32Array(w);
          mx1 = new Int32Array(w);
          mfx = new Float32Array(w);
          for (let x = 0; x < w; x++) {
            let sx = (x + 0.5) * pw / w - 0.5;
            sx = sx < 0 ? 0 : (sx > pw - 1 ? pw - 1 : sx);
            const i0 = sx | 0;
            mx0[x] = i0;
            mx1[x] = i0 + 1 < pw ? i0 + 1 : i0;
            mfx[x] = sx - i0;
          }
          console.info(`LM9STAT sky-domain on: area=${(area / (pw * ph)).toFixed(3)}` +
            ` wbar=${wbar.toFixed(3)} wMix=${wMix.toFixed(3)}`);
        }
      }
    }

    // ---- 全图主循环：软权重混合三档曲线 + 1-D 误差扩散（每行重置）----
    let errR = 0;
    let errG = 0;
    let errB = 0;
    const useDomain = dMk !== undefined && eff !== undefined && mx0 !== undefined &&
      mx1 !== undefined && mfx !== undefined;
    const rowsPerChunk = 262144 / w > 1 ? Math.floor(262144 / w) : 1;
    for (let cy0 = 0; cy0 < h; cy0 += rowsPerChunk) {
      const cy1 = cy0 + rowsPerChunk < h ? cy0 + rowsPerChunk : h;
      for (let y = cy0; y < cy1; y++) {
        errR = 0;
        errG = 0;
        errB = 0;
        let my0 = 0;
        let my1 = 0;
        let mfy = 0;
        if (useDomain && dMk !== undefined) {
          let sy = (y + 0.5) * ph / h - 0.5;
          sy = sy < 0 ? 0 : (sy > ph - 1 ? ph - 1 : sy);
          my0 = sy | 0;
          my1 = my0 + 1 < ph ? my0 + 1 : my0;
          mfy = sy - my0;
        }
        let i = y * w * 4;
        for (let x = 0; x < w; x++, i += 4) {
          const r0 = px[i];
          const g0 = px[i + 1];
          const b0 = px[i + 2];
          Lm9Stats.skyWeightInto(r0, g0, b0, LM9_W3);
          let sky = LM9_W3[0];
          const veg = LM9_W3[1];
          let other = LM9_W3[2];
          let cSky = lut;
          if (useDomain && dMk !== undefined && eff !== undefined && mx0 !== undefined &&
            mx1 !== undefined && mfx !== undefined) {
            const a0 = my0 * pw;
            const a1 = my1 * pw;
            const fx0 = mx0[x];
            const fx1 = mx1[x];
            const fx = mfx[x];
            const wfx = 1 - fx;
            const wmfy = 1 - mfy;
            const m = (dMk[a0 + fx0] * wfx + dMk[a0 + fx1] * fx) * wmfy +
              (dMk[a1 + fx0] * wfx + dMk[a1 + fx1] * fx) * mfy;
            const sk = m + (1 - m) * sky;
            other = 1 - sk - veg;
            if (other < 0) {
              other = 0;
            }
            sky = sk;
            cSky = eff;
          }
          const sw = sky + veg + other;
          const wantR = (sky * cSky[r0] + veg * lut[768 + r0] + other * lut[1536 + r0]) / sw + errR;
          const wantG = (sky * cSky[256 + g0] + veg * lut[1024 + g0] + other * lut[1792 + g0]) / sw + errG;
          const wantB = (sky * cSky[512 + b0] + veg * lut[1280 + b0] + other * lut[2048 + b0]) / sw + errB;
          let ri = Math.round(wantR);
          let gi = Math.round(wantG);
          let bi = Math.round(wantB);
          errR = wantR - ri;
          errR = errR < -1 ? -1 : (errR > 1 ? 1 : errR);
          errG = wantG - gi;
          errG = errG < -1 ? -1 : (errG > 1 ? 1 : errG);
          errB = wantB - bi;
          errB = errB < -1 ? -1 : (errB > 1 ? 1 : errB);
          ri = ri < 0 ? 0 : (ri > 255 ? 255 : ri);
          gi = gi < 0 ? 0 : (gi > 255 ? 255 : gi);
          bi = bi < 0 ? 0 : (bi > 255 ? 255 : bi);
          px[i] = ri;
          px[i + 1] = gi;
          px[i + 2] = bi;
        }
      }
      await yieldUI();
    }
    console.info(`LM9STAT 统计同源链完成 bucket=${LM9_KEYS[bucket]}`);
  }

  /** 双线性探测图（RGBA，等价 createScaledBitmap filter=true）。 */
  private static buildProbe(px: Uint8Array, w: number, h: number, pw: number, ph: number): Uint8Array {
    const out = new Uint8Array(pw * ph * 4);
    for (let y = 0; y < ph; y++) {
      let sy = (y + 0.5) * h / ph - 0.5;
      sy = sy < 0 ? 0 : (sy > h - 1 ? h - 1 : sy);
      const y0 = sy | 0;
      const y1 = y0 + 1 < h ? y0 + 1 : y0;
      const fy = sy - y0;
      const wfy = 1 - fy;
      const r0y = y0 * w * 4;
      const r1y = y1 * w * 4;
      for (let x = 0; x < pw; x++) {
        let sx = (x + 0.5) * w / pw - 0.5;
        sx = sx < 0 ? 0 : (sx > w - 1 ? w - 1 : sx);
        const x0 = sx | 0;
        const x1 = x0 + 1 < w ? x0 + 1 : x0;
        const fx = sx - x0;
        const wfx = 1 - fx;
        const c00 = r0y + x0 * 4;
        const c01 = r0y + x1 * 4;
        const c10 = r1y + x0 * 4;
        const c11 = r1y + x1 * 4;
        const o = (y * pw + x) * 4;
        for (let c = 0; c < 3; c++) {
          const v = px[c00 + c] * wfx * wfy + px[c01 + c] * fx * wfy +
            px[c10 + c] * wfx * fy + px[c11 + c] * fx * fy;
          out[o + c] = Math.round(v);
        }
        out[o + 3] = 255;
      }
    }
    return out;
  }

  /** 三区域软权重：out[0]=sky, out[1]=veg, out[2]=other（探测图与全图共用口径）。 */
  private static skyWeightInto(r0: number, g0: number, b0: number, out: Float32Array): void {
    const rf = r0 / 255;
    const gf = g0 / 255;
    const bf = b0 / 255;
    const lum = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
    let blueness = (bf - gf - 0.024) / 0.078;
    blueness = blueness < 0 ? 0 : (blueness > 1 ? 1 : blueness);
    const mx = rf > gf ? (rf > bf ? rf : bf) : (gf > bf ? gf : bf);
    const mn = rf < gf ? (rf < bf ? rf : bf) : (gf < bf ? gf : bf);
    let greenness = (gf - (rf > bf ? rf : bf) - 0.016) / 0.063;
    greenness = greenness < 0 ? 0 : (greenness > 1 ? 1 : greenness);
    const chroma = mx - mn;
    let satGate = (chroma - 0.045) / 0.055;
    satGate = satGate < 0 ? 0 : (satGate > 1 ? 1 : satGate);
    let warmT = (rf - bf - 0.020) / 0.060;
    warmT = warmT < 0 ? 0 : (warmT > 1 ? 1 : warmT);
    let warmL = (lum - 0.45) / 0.15;
    warmL = warmL < 0 ? 0 : (warmL > 1 ? 1 : warmL);
    const warmSky = warmT * warmL * satGate;
    let blueL = (lum - 0.30) / 0.15;
    blueL = blueL < 0 ? 0 : (blueL > 1 ? 1 : blueL);
    const blueSky = blueness * blueL;
    let sky = blueSky > warmSky ? blueSky : warmSky;
    let hi = (lum - 0.80) / 0.15;
    hi = hi < 0 ? 0 : (hi > 1 ? 1 : hi);
    sky = sky * (1 - hi) + hi;
    const veg = greenness * (1 - sky);
    out[0] = sky;
    out[1] = veg;
    const oth = 1 - sky - veg;
    out[2] = oth > 0 ? oth : 0;
  }

  /** 探测图三区域均值（硬判分类）+ 空区域回退（用 other 档）。 */
  private static regionMeans(probe: Uint8Array, pw: number, ph: number, mR: Float32Array): void {
    const rSum = [0, 0, 0];
    const gSum = [0, 0, 0];
    const bSum = [0, 0, 0];
    const rCnt = [0, 0, 0];
    for (let i = 0; i < pw * ph; i++) {
      const o = i * 4;
      const r0 = probe[o];
      const g0 = probe[o + 1];
      const b0 = probe[o + 2];
      const lm = (0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0) / 255;
      let reg = 2;
      if (b0 > g0 + 10 && b0 > r0 + 20 && lm > 0.35) {
        reg = 0;
      } else if (g0 > r0 + 8 && g0 > b0 + 8) {
        reg = 1;
      }
      rSum[reg] += r0;
      gSum[reg] += g0;
      bSum[reg] += b0;
      rCnt[reg]++;
    }
    for (let r = 0; r < 3; r++) {
      const c0 = rCnt[r] > 0 ? rCnt[r] : 1;
      mR[r * 3] = rSum[r] / c0 / 255;
      mR[r * 3 + 1] = gSum[r] / c0 / 255;
      mR[r * 3 + 2] = bSum[r] / c0 / 255;
    }
    const minCnt = Math.max(8, (pw * ph / 100) | 0);
    for (let r = 0; r < 2; r++) {
      if (rCnt[r] < minCnt) {
        mR[r * 3] = mR[6];
        mR[r * 3 + 1] = mR[7];
        mR[r * 3 + 2] = mR[8];
      }
    }
  }

  /** 空间天空域：宽松候选 → 膨胀×2 → 顶行连通 → 高斯羽化；失败返回 undefined。 */
  private static skyDomain(probe: Uint8Array, pw: number, ph: number): Float32Array | undefined {
    const n = pw * ph;
    if (n < 64) {
      return undefined;
    }
    const cand = new Uint8Array(n);
    let cc = 0;
    for (let i = 0; i < n; i++) {
      const o = i * 4;
      const r = probe[o];
      const g = probe[o + 1];
      const b = probe[o + 2];
      const lm = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
      if (b - g > 2 && b > r - 8 && lm > 0.20) {
        cand[i] = 1;
        cc++;
      }
    }
    if (cc < Math.max(16, (n / 100) | 0)) {
      return undefined;
    }
    const dil = Lm9Stats.dilate3(Lm9Stats.dilate3(cand, pw, ph), pw, ph);
    const seed = new Uint8Array(n);
    const stack = new Int32Array(n);
    let sp = 0;
    for (let x = 0; x < pw; x++) {
      const i = x;
      if (dil[i] === 1 && seed[i] === 0) {
        seed[i] = 1;
        stack[sp++] = i;
      }
    }
    if (sp === 0) {
      return undefined;
    }
    while (sp > 0) {
      const i = stack[--sp];
      const x = i % pw;
      const y = (i / pw) | 0;
      for (let dy = -1; dy <= 1; dy++) {
        const ny = y + dy;
        if (ny < 0 || ny >= ph) {
          continue;
        }
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx;
          if (nx < 0 || nx >= pw) {
            continue;
          }
          const j = ny * pw + nx;
          if (dil[j] === 1 && seed[j] === 0) {
            seed[j] = 1;
            stack[sp++] = j;
          }
        }
      }
    }
    const f = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      f[i] = seed[i];
    }
    return Lm9Stats.blur5(f, pw, ph, 1.7);
  }

  /** 3×3 二值膨胀。 */
  private static dilate3(src: Uint8Array, w: number, h: number): Uint8Array {
    const d = new Uint8Array(src.length);
    for (let y = 0; y < h; y++) {
      const row = y * w;
      const y0 = y > 0 ? y - 1 : 0;
      const y1 = y + 1 < h ? y + 1 : h - 1;
      for (let x = 0; x < w; x++) {
        if (src[row + x] === 0) {
          continue;
        }
        const x0 = x > 0 ? x - 1 : 0;
        const x1 = x + 1 < w ? x + 1 : w - 1;
        for (let yy = y0; yy <= y1; yy++) {
          const r2 = yy * w;
          for (let xx = x0; xx <= x1; xx++) {
            d[r2 + xx] = 1;
          }
        }
      }
    }
    return d;
  }

  /** 可分离高斯（边缘钳位），半径 = sigma*3。 */
  private static blur5(src: Float32Array, w: number, h: number, sigma: number): Float32Array {
    const rad = Math.max(1, Math.round(sigma * 3));
    const k = new Float32Array(rad * 2 + 1);
    let sum = 0;
    for (let i = -rad; i <= rad; i++) {
      const v = Math.exp(-(i * i) / (2.0 * sigma * sigma));
      k[i + rad] = v;
      sum += v;
    }
    for (let i = 0; i < k.length; i++) {
      k[i] /= sum;
    }
    const n = src.length;
    const tmp = new Float32Array(n);
    const out = new Float32Array(n);
    for (let y = 0; y < h; y++) {
      const row = y * w;
      for (let x = 0; x < w; x++) {
        let acc = 0;
        for (let i = -rad; i <= rad; i++) {
          let xx = x + i;
          xx = xx < 0 ? 0 : (xx > w - 1 ? w - 1 : xx);
          acc += src[row + xx] * k[i + rad];
        }
        tmp[row + x] = acc;
      }
    }
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let acc = 0;
        for (let i = -rad; i <= rad; i++) {
          let yy = y + i;
          yy = yy < 0 ? 0 : (yy > h - 1 ? h - 1 : yy);
          acc += tmp[yy * w + x] * k[i + rad];
        }
        out[y * w + x] = acc;
      }
    }
    return out;
  }

  /** 选桶（仅日志用）：亮度档 × 场景型。 */
  private static bucketOf(probe: Uint8Array, pw: number, ph: number): number {
    let lumSum = 0;
    let sky = 0;
    let veg = 0;
    for (let i = 0; i < pw * ph; i++) {
      const o = i * 4;
      const r = probe[o];
      const g = probe[o + 1];
      const b = probe[o + 2];
      const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
      lumSum += lum;
      if (b > g + 10 && b > r + 20 && lum > 0.35) {
        sky++;
      }
      if (g > r + 8 && g > b + 8) {
        veg++;
      }
    }
    const n = pw * ph;
    const lm = lumSum / n;
    const skyF = sky / n;
    const vegF = veg / n;
    let type = '';
    if (skyF > 0.12) {
      type += 'sky';
    }
    if (vegF > 0.12) {
      type += 'veg';
    }
    if (type === '') {
      type = 'plain';
    }
    const tier = lm >= 0.50 ? 'A' : (lm >= 0.30 ? 'B' : 'C');
    const key = `${tier}-${type}`;
    for (let i = 0; i < LM9_KEYS.length; i++) {
      if (LM9_KEYS[i] === key) {
        return i;
      }
    }
    return 3;
  }
}
