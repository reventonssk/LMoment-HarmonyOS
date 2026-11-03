/**
 * 「完美档」引擎（Batch F5）：M9 系高保真导出链（JPEG 后段）。
 *
 * 管线与几何协议逐行对齐原版 M9Perfect.kt（非 RAW 路径 `run`）：
 *   竖图转横 → fit 4096x3072（只缩）→ 最小 4:3 画布 → 居中镜像 pad
 *   → 缩 1024x768 → pad48(镜像) 进 StyleTrans(rgb 1x3x864x1120 + mask 全 0)
 *   → 裁 1024x768 → 放回画布 → ColorFix 544 分块(step 512 / 中心 512 / margin 16 /
 *   6 通道 [styled(3), orig(3)]) → 裁回窗口 → 缩回原尺寸 → 转回竖图。
 *
 * 模型：m9fb_styletrans_high.ms（rgb+mask，batch 固化 1）、m9fb_colorfix.ms（x，batch 固化 2）。
 * 注意：两模型输入形状为静态烘焙——喂入形状必须与声明完全一致，避免 model.resize
 * （MS 2.3.1 对本图 resize 会触发 InferShape 失败）；尾批 tile 不足时补零凑满。
 * 说明：原版末段另接暖调 LUT（LegendaryPostProcessor）；本引擎只产出「已摆正、已配色」的 RGBA，
 * 暖调/徽章/HDR 由导出链统一处理（避免二次套色）。
 */

import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { resourceManager } from '@kit.LocalizationKit';
import { yieldUI } from './PixAsync';

const W4K = 4096;
const H4K = 3072;
const NW = 1024;
const NH = 768;
const PAD = 48;
const TILE = 544;
const STEP = 512;
const MARGIN = 16;
const BATCH = 2;

/** 已处理 RGBA 图（紧密排布 w*h*4）。 */
export class RgbaImg {
  readonly px: Uint8Array;
  readonly w: number;
  readonly h: number;

  constructor(px: Uint8Array, w: number, h: number) {
    this.px = px;
    this.w = w;
    this.h = h;
  }
}

/** 模型输入喂数项（与 NeuralEngine.Feed 同构）。 */
class Feed {
  readonly name: string;
  readonly data: Float32Array;

  constructor(name: string, data: Float32Array) {
    this.name = name;
    this.data = data;
  }
}

export class M9PerfectEngine {
  private static models: Map<string, mindSporeLite.Model> = new Map();

  private static async rawOf(rm: resourceManager.ResourceManager, name: string): Promise<Uint8Array> {
    return rm.getRawFileContent(name);
  }

  private static async ensureModel(rm: resourceManager.ResourceManager,
    name: string): Promise<mindSporeLite.Model> {
    const hit = M9PerfectEngine.models.get(name);
    if (hit !== undefined) {
      return hit;
    }
    const d = await M9PerfectEngine.rawOf(rm, name);
    const ab = new ArrayBuffer(d.byteLength);
    new Uint8Array(ab).set(d);
    const cpu: mindSporeLite.CpuDevice = {
      threadNum: 4,
      threadAffinityMode: mindSporeLite.ThreadAffinityMode.NO_AFFINITIES
    };
    const context: mindSporeLite.Context = { target: ['cpu'], cpu: cpu };
    const model = await mindSporeLite.loadModelFromBuffer(ab, context);
    M9PerfectEngine.models.set(name, model);
    return model;
  }

  /** 是否已加载（供内存紧张时 release）。 */
  static release(): void {
    M9PerfectEngine.models.clear();
  }

  /**
   * 完美档处理：输入任意尺寸 RGBA，返回同尺寸「已摆正、已配色」RGBA。
   * 任何失败返回 undefined（调用方回落普通导出）。
   * 重几何全部行分块 + yieldUI（对齐 NeuralEngine 口径）：同步大循环会冻住主线程，
   * 表现为「完美档处理卡住」；模型预测本身异步不阻塞。
   */
  static async process(rgba: Uint8Array, w: number, h: number,
    rm: resourceManager.ResourceManager, onProgress: (v: number) => void): Promise<RgbaImg | undefined> {
    if (w < 1 || h < 1) {
      return undefined;
    }
    const t0 = Date.now();
    try {
      onProgress(3);
      const st = await M9PerfectEngine.ensureModel(rm, 'm9fb_styletrans_high.ms');
      const cf = await M9PerfectEngine.ensureModel(rm, 'm9fb_colorfix.ms');
      onProgress(10);
      console.info(`PERFECT models ready ${Date.now() - t0}ms`);

      // ---- 竖图转横 ----
      const portrait = h > w;
      let lpx = rgba;
      let lw = w;
      let lh = h;
      if (portrait) {
        lpx = await M9PerfectEngine.rotCCW(rgba, w, h);
        lw = h;
        lh = w;
      }

      // ---- fit 4096x3072（只缩不放大）----
      let fpx = lpx;
      let fw = lw;
      let fh = lh;
      if (lw > W4K || lh > H4K) {
        const s = Math.min(W4K / lw, H4K / lh);
        const nw = Math.max(1, Math.round(lw * s));
        const nh = Math.max(1, Math.round(lh * s));
        fpx = await M9PerfectEngine.scaleBilinear(lpx, lw, lh, nw, nh);
        fw = nw;
        fh = nh;
      }
      await yieldUI();

      // ---- 最小 4:3 画布 + 居中镜像 pad ----
      const cvs = M9PerfectEngine.canvasOf(fw, fh);
      const cw = cvs[0];
      const ch = cvs[1];
      const left = Math.floor((cw - fw) / 2);
      const top = Math.floor((ch - fh) / 2);
      const big = await M9PerfectEngine.padMirror(fpx, fw, fh, cw, ch, left, top);
      await yieldUI();
      console.info(`PERFECT canvas ${cw}x${ch} ${Date.now() - t0}ms`);
      onProgress(16);

      // ---- StyleTrans（1024x768 + pad48）----
      const small = await M9PerfectEngine.scaleBilinear(big, cw, ch, NW, NH);
      const inW = NW + PAD * 2;
      const inH = NH + PAD * 2;
      const rgbp = await M9PerfectEngine.padMirror(small, NW, NH, inW, inH, PAD, PAD);
      onProgress(22);
      const plane = inW * inH;
      const rgb = new Float32Array(plane * 3);
      const stNhwc = M9PerfectEngine.isNhwc(M9PerfectEngine.inputShapeByName(st, 'rgb'));
      if (stNhwc) {
        // 转换器布局优化后接口为 NHWC [1,H,W,3]，按像素交错写入
        for (let i = 0; i < plane; i++) {
          const o = i * 4;
          const d = i * 3;
          rgb[d] = (rgbp[o] - 128) / 127.5;
          rgb[d + 1] = (rgbp[o + 1] - 128) / 127.5;
          rgb[d + 2] = (rgbp[o + 2] - 128) / 127.5;
        }
      } else {
        for (let i = 0; i < plane; i++) {
          const o = i * 4;
          rgb[i] = (rgbp[o] - 128) / 127.5;
          rgb[plane + i] = (rgbp[o + 1] - 128) / 127.5;
          rgb[plane * 2 + i] = (rgbp[o + 2] - 128) / 127.5;
        }
      }
      const mask = new Float32Array(plane);
      const stFeeds: Feed[] = [new Feed('rgb', rgb), new Feed('mask', mask)];
      const stWants: number[][] = stNhwc
        ? [[1, inH, inW, 3], [1, inH, inW, 1]]
        : [[1, 3, inH, inW], [1, 1, inH, inW]];
      const stOut = await M9PerfectEngine.runByShape(st, stFeeds, stWants);
      onProgress(60);
      await yieldUI();
      console.info(`PERFECT styletrans done ${Date.now() - t0}ms`);

      const styled = M9PerfectEngine.deNormToRgba(stOut[0], NW, NH, PAD, inW);
      onProgress(64);

      // ---- 放回画布 → 取像素数组 ----
      const styledBig = await M9PerfectEngine.scaleBilinear(styled, NW, NH, cw, ch);
      await yieldUI();

      // ---- 真 ColorFix（544 分块）----
      const fixed = await M9PerfectEngine.colorfix(cf, big, styledBig, cw, ch, onProgress, 66, 94);
      console.info(`PERFECT colorfix done ${Date.now() - t0}ms`);

      // ---- 裁回 fitted 窗口 ----
      const win = new Uint8Array(fw * fh * 4);
      for (let y = 0; y < fh; y++) {
        const src = ((top + y) * cw + left) * 4;
        win.set(fixed.subarray(src, src + fw * 4), y * fw * 4);
        if ((y & 255) === 0) {
          await yieldUI();
        }
      }

      // ---- 缩回原横向尺寸 → 转回竖图 ----
      let outPx: Uint8Array;
      let ow: number;
      let oh: number;
      if (fw !== lw || fh !== lh) {
        outPx = await M9PerfectEngine.scaleBilinear(win, fw, fh, lw, lh);
        ow = lw;
        oh = lh;
      } else {
        outPx = win;
        ow = fw;
        oh = fh;
      }
      if (portrait) {
        const newW = oh;
        const newH = ow;
        outPx = await M9PerfectEngine.rotCW(outPx, ow, oh);
        ow = newW;
        oh = newH;
      }
      onProgress(100);
      console.info(`PERFECT done ${ow}x${oh} ${Date.now() - t0}ms`);
      return new RgbaImg(outPx, ow, oh);
    } catch (e) {
      console.info(`PERFECT fail: ${e instanceof Error ? e.message : 'unknown'} ${Date.now() - t0}ms`);
      return undefined;
    }
  }

  // ---- 推理 ----

  /** 按 name 对齐 feed/want（模型输入顺序可能与 feed 顺序不同）→ 校验 shape →
   *  setData → predict。静态批量模型契约：wants 必须恒等于声明形状，永不 resize。 */
  private static async runByShape(model: mindSporeLite.Model, feeds: Feed[],
    wants: number[][]): Promise<mindSporeLite.MSTensor[]> {
    // wants[i] 与 feeds[i] 一一对应；模型输入按 name 映射到对应 want
    let inputs = model.getInputs();
    const desc: string = inputs.map((t: mindSporeLite.MSTensor): string =>
      t.name + ':' + t.shape.join('x')).join(',');
    const aligned: number[][] = [];
    for (let i = 0; i < inputs.length; i++) {
      let wi = -1;
      for (let k = 0; k < feeds.length; k++) {
        if (feeds[k].name === inputs[i].name) {
          wi = k;
          break;
        }
      }
      if (wi < 0) {
        console.info(`PERFECT runByShape in[${desc}] no feed for ${inputs[i].name}`);
        throw new Error(`no feed for input ${inputs[i].name}`);
      }
      aligned.push(wants[wi]);
    }
    let need = false;
    for (let i = 0; i < inputs.length; i++) {
      const shape = inputs[i].shape;
      const want = aligned[i];
      if (shape.length !== want.length) {
        need = true;
        break;
      }
      for (let d = 0; d < want.length; d++) {
        if (shape[d] !== want[d]) {
          need = true;
          break;
        }
      }
      if (need) {
        break;
      }
    }
    console.info(`PERFECT runByShape in[${desc}] need=${need}`);
    if (need) {
      if (!model.resize(inputs, aligned)) {
        throw new Error('resize failed');
      }
      inputs = model.getInputs();
    }
    for (let i = 0; i < inputs.length; i++) {
      const f = M9PerfectEngine.findFeed(feeds, inputs[i].name, i);
      if (inputs[i].dataSize !== f.data.byteLength) {
        throw new Error(`tensor ${inputs[i].name} size mismatch`);
      }
      inputs[i].setData(f.data.buffer);
    }
    return model.predict(inputs);
  }

  private static findFeed(feeds: Feed[], name: string, index: number): Feed {
    for (let i = 0; i < feeds.length; i++) {
      if (feeds[i].name === name) {
        return feeds[i];
      }
    }
    return index < feeds.length ? feeds[index] : feeds[0];
  }

  /** 按名称取模型输入 shape（输入顺序与 feed 顺序不保证一致）。 */
  private static inputShapeByName(model: mindSporeLite.Model, name: string): number[] {
    const ins = model.getInputs();
    for (let i = 0; i < ins.length; i++) {
      if (ins[i].name === name) {
        return ins[i].shape;
      }
    }
    return ins.length > 0 ? ins[0].shape : [];
  }

  /** 4D shape 的通道维在末位（NHWC [N,H,W,C]）还是第 2 位（NCHW [N,C,H,W]）。 */
  private static isNhwc(shape: number[]): boolean {
    return shape.length === 4 && shape[3] < shape[1];
  }

  /** StyleTrans 输出 → 裁 PAD 后反归一化为 NW×NH RGBA。 */
  private static deNormToRgba(t: mindSporeLite.MSTensor, nw: number, nh: number,
    pad: number, inW: number): Uint8Array {
    const fb = new Float32Array(t.getData());
    const out = new Uint8Array(nw * nh * 4);
    const nhwc = M9PerfectEngine.isNhwc(t.shape);
    const plane = inW * (nh + pad * 2);
    for (let y = 0; y < nh; y++) {
      const base = (pad + y) * inW + pad;
      for (let x = 0; x < nw; x++) {
        const o = (y * nw + x) * 4;
        if (nhwc) {
          const si = (base + x) * 3;
          out[o] = M9PerfectEngine.clamp255(fb[si] * 127.5 + 128);
          out[o + 1] = M9PerfectEngine.clamp255(fb[si + 1] * 127.5 + 128);
          out[o + 2] = M9PerfectEngine.clamp255(fb[si + 2] * 127.5 + 128);
        } else {
          out[o] = M9PerfectEngine.clamp255(fb[base + x] * 127.5 + 128);
          out[o + 1] = M9PerfectEngine.clamp255(fb[plane + base + x] * 127.5 + 128);
          out[o + 2] = M9PerfectEngine.clamp255(fb[plane * 2 + base + x] * 127.5 + 128);
        }
        out[o + 3] = 255;
      }
    }
    return out;
  }

  /** ColorFix：544 分块 U-Net，6 通道 [styled(3), orig(3)]。 */
  private static async colorfix(model: mindSporeLite.Model, orig: Uint8Array,
    styled: Uint8Array, w: number, h: number, onProgress: (v: number) => void,
    pFrom: number, pTo: number): Promise<Uint8Array> {
    let batch = BATCH;
    const shape0 = model.getInputs()[0].shape;
    if (shape0.length === 4 && shape0[0] > 0 && shape0[0] !== BATCH) {
      batch = shape0[0];
    }
    const out = new Uint8Array(w * h * 4);
    let ny = 0;
    let yy = 0;
    while (yy < h) {
      ny++;
      yy += STEP;
    }
    let nx = 0;
    let xx = 0;
    while (xx < w) {
      nx++;
      xx += STEP;
    }
    const count = nx * ny;
    const ty = new Int32Array(count);
    const tx = new Int32Array(count);
    const tys = new Int32Array(count);
    const txs = new Int32Array(count);
    const tth = new Int32Array(count);
    const ttw = new Int32Array(count);
    const tkh = new Int32Array(count);
    const tkw = new Int32Array(count);
    let k = 0;
    for (let y = 0; y < h; y += STEP) {
      for (let x = 0; x < w; x += STEP) {
        ty[k] = y;
        tx[k] = x;
        tys[k] = Math.max(y - MARGIN, 0);
        txs[k] = Math.max(x - MARGIN, 0);
        tth[k] = Math.min(y + STEP + MARGIN, h) - tys[k];
        ttw[k] = Math.min(x + STEP + MARGIN, w) - txs[k];
        tkh[k] = Math.min(STEP, h - y);
        tkw[k] = Math.min(STEP, w - x);
        k++;
      }
    }

    const tilePlane = TILE * TILE;
    const cfNhwc = M9PerfectEngine.isNhwc(model.getInputs()[0].shape);
    const span = Math.max(1, pTo - pFrom);
    let start = 0;
    let done = 0;
    while (start < count) {
      const n = Math.min(batch, count - start);
      // 模型 batch 已固化为静态（b2），尾批不足时补零凑满 batch，
      // 保证 wants 恒等于声明形状、永不触发 model.resize（动态 resize 会挂坏图）。
      const buf = new Float32Array(batch * 6 * tilePlane);
      for (let i = 0; i < n; i++) {
        const j = start + i;
        const oy = MARGIN - (ty[j] - tys[j]);
        const ox = MARGIN - (tx[j] - txs[j]);
        const th = tth[j];
        const tw = ttw[j];
        const sy = tys[j];
        const sx = txs[j];
        const base = i * 6 * tilePlane;
        if (cfNhwc) {
          // NHWC [B,TILE,TILE,6]，通道交错
          for (let row = 0; row < th; row++) {
            const srow = ((sy + row) * w + sx) * 4;
            const drow = base + ((oy + row) * TILE + ox) * 6;
            for (let col = 0; col < tw; col++) {
              const so = srow + col * 4;
              const d = drow + col * 6;
              buf[d] = (styled[so] - 128) / 127.5;
              buf[d + 1] = (styled[so + 1] - 128) / 127.5;
              buf[d + 2] = (styled[so + 2] - 128) / 127.5;
              buf[d + 3] = (orig[so] - 128) / 127.5;
              buf[d + 4] = (orig[so + 1] - 128) / 127.5;
              buf[d + 5] = (orig[so + 2] - 128) / 127.5;
            }
          }
        } else {
          // NCHW [B,6,TILE,TILE]，通道平面
          for (let row = 0; row < th; row++) {
            const srow = ((sy + row) * w + sx) * 4;
            const drow = base + (oy + row) * TILE + ox;
            for (let col = 0; col < tw; col++) {
              const so = srow + col * 4;
              const d = drow + col;
              buf[d] = (styled[so] - 128) / 127.5;
              buf[d + tilePlane] = (styled[so + 1] - 128) / 127.5;
              buf[d + 2 * tilePlane] = (styled[so + 2] - 128) / 127.5;
              buf[d + 3 * tilePlane] = (orig[so] - 128) / 127.5;
              buf[d + 4 * tilePlane] = (orig[so + 1] - 128) / 127.5;
              buf[d + 5 * tilePlane] = (orig[so + 2] - 128) / 127.5;
            }
          }
        }
      }
      const feeds: Feed[] = [new Feed('x', buf)];
      const wants: number[][] = [cfNhwc ? [batch, TILE, TILE, 6] : [batch, 6, TILE, TILE]];
      const res = await M9PerfectEngine.runByShape(model, feeds, wants);
      const ob = new Float32Array(res[0].getData());
      const obNhwc = M9PerfectEngine.isNhwc(res[0].shape);
      for (let i = 0; i < n; i++) {
        const j = start + i;
        const th = tkh[j];
        const tw = tkw[j];
        const base = i * 3 * tilePlane;
        for (let row = 0; row < th; row++) {
          const drow = ((ty[j] + row) * w + tx[j]) * 4;
          if (obNhwc) {
            const srow = base + ((MARGIN + row) * TILE + MARGIN) * 3;
            for (let col = 0; col < tw; col++) {
              const si = srow + col * 3;
              const o = drow + col * 4;
              out[o] = M9PerfectEngine.clamp255(ob[si] * 127.5 + 128);
              out[o + 1] = M9PerfectEngine.clamp255(ob[si + 1] * 127.5 + 128);
              out[o + 2] = M9PerfectEngine.clamp255(ob[si + 2] * 127.5 + 128);
              out[o + 3] = 255;
            }
          } else {
            const srow = base + (MARGIN + row) * TILE + MARGIN;
            for (let col = 0; col < tw; col++) {
              const si = srow + col;
              const o = drow + col * 4;
              out[o] = M9PerfectEngine.clamp255(ob[si] * 127.5 + 128);
              out[o + 1] = M9PerfectEngine.clamp255(ob[si + tilePlane] * 127.5 + 128);
              out[o + 2] = M9PerfectEngine.clamp255(ob[si + 2 * tilePlane] * 127.5 + 128);
              out[o + 3] = 255;
            }
          }
        }
      }
      start += n;
      done += n;
      onProgress(pFrom + Math.floor(done * span / count));
      await yieldUI();
    }
    return out;
  }

  // ---- 几何 ----

  private static clamp255(v: number): number {
    const i = Math.round(v);
    return i < 0 ? 0 : (i > 255 ? 255 : i);
  }

  /** 最小 4:3 画布（与 M9OrtFallback.canvasOf 一致）。 */
  private static canvasOf(fw: number, fh: number): number[] {
    if (fw * 3 >= fh * 4) {
      const w = Math.min(fw, W4K);
      const h = Math.min(Math.max(fh, Math.round(w * 3 / 4)), H4K);
      return [w, h];
    }
    const h = Math.min(fh, H4K);
    const w = Math.min(Math.max(fw, Math.round(h * 4 / 3)), W4K);
    return [w, h];
  }

  /** 顺时针 90°（行分块 + yield，避免冻住主线程）。 */
  private static async rotCW(px: Uint8Array, w: number, h: number): Promise<Uint8Array> {
    const out = new Uint8Array(px.length);
    const dw = h;
    for (let y = 0; y < w; y++) {
      for (let x = 0; x < h; x++) {
        const src = ((h - 1 - x) * w + y) * 4;
        const dst = (y * dw + x) * 4;
        out[dst] = px[src];
        out[dst + 1] = px[src + 1];
        out[dst + 2] = px[src + 2];
        out[dst + 3] = px[src + 3];
      }
      if ((y & 255) === 0) {
        await yieldUI();
      }
    }
    return out;
  }

  /** 逆时针 90°（行分块 + yield）。 */
  private static async rotCCW(px: Uint8Array, w: number, h: number): Promise<Uint8Array> {
    const out = new Uint8Array(px.length);
    const dw = h;
    for (let y = 0; y < w; y++) {
      for (let x = 0; x < h; x++) {
        const src = (x * w + (w - 1 - y)) * 4;
        const dst = (y * dw + x) * 4;
        out[dst] = px[src];
        out[dst + 1] = px[src + 1];
        out[dst + 2] = px[src + 2];
        out[dst + 3] = px[src + 3];
      }
      if ((y & 255) === 0) {
        await yieldUI();
      }
    }
    return out;
  }

  /** 双线性缩放（行分块 + yield）。 */
  private static async scaleBilinear(src: Uint8Array, sw: number, sh: number,
    dw: number, dh: number): Promise<Uint8Array> {
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
        for (let c = 0; c < 4; c++) {
          const top = src[i00 + c] * (1 - fx) + src[i01 + c] * fx;
          const bot = src[i10 + c] * (1 - fx) + src[i11 + c] * fx;
          out[o + c] = Math.round(top * (1 - fy) + bot * fy);
        }
      }
      if ((y & 63) === 0) {
        await yieldUI();
      }
    }
    return out;
  }

  private static mirrorIdx(sz: number, v: number): number {
    const period = sz * 2;
    let m = v % period;
    if (m < 0) {
      m += period;
    }
    return m < sz ? m : period - 1 - m;
  }

  /** 居中镜像 pad 到 dw×dh（offset 指定原图左上角落点；行分块 + yield）。 */
  private static async padMirror(src: Uint8Array, sw: number, sh: number,
    dw: number, dh: number, offX: number, offY: number): Promise<Uint8Array> {
    const out = new Uint8Array(dw * dh * 4);
    for (let y = 0; y < dh; y++) {
      const sy = M9PerfectEngine.mirrorIdx(sh, y - offY);
      for (let x = 0; x < dw; x++) {
        const sx = M9PerfectEngine.mirrorIdx(sw, x - offX);
        const s = (sy * sw + sx) * 4;
        const o = (y * dw + x) * 4;
        out[o] = src[s];
        out[o + 1] = src[s + 1];
        out[o + 2] = src[s + 2];
        out[o + 3] = src[s + 3];
      }
      if ((y & 63) === 0) {
        await yieldUI();
      }
    }
    return out;
  }
}