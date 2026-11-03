/**
 * 神经风格引擎（MindSpore Lite 主线程推理）：
 *  - M9 / M9 蒸馏 / M9+：m9_distill 微网（keep1024+halo96 分块）+ m9 暖调（+激进后推）
 *  - M10-R：蒸馏 + m10r 暖调 + 暗角颗粒
 *  - L-M9：统计同源（Lm9Stats）→ lm9_net 微网（512 分块 + 64px 羽化）→ M9 链
 *  - CCD 三档：seplut_fivek（SepLUT）+ Portra 曲线 + 颗粒暗角
 *
 * Model 不可跨线程共享：全部公共操作经 Promise 队列在主线程串行；
 * 逐级降级并返回提示文案（'' = 正常）。
 *
 * 布局自适应：MindSpore 转换器会把 ONNX NCHW 图整体转成 NHWC（输入/输出边界随之变化），
 * 故填充与读取均按张量实际 shape 判定（末维=3 → HWC 交错；次维=3 → CHW 平面），两套口径兼容。
 */

import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { resourceManager } from '@kit.LocalizationKit';
import { yieldUI } from './PixAsync';
import { WarmBin, WarmApplier } from './WarmLut';
import { CcdFilm, CcdBundle, CcdProfile, CcdProfiles } from './CcdFilm';
import { Lm9Stats } from './Lm9Stats';
import { StyleEngine } from './StyleEngine';
import { GrainVignette } from './GrainVignette';
import { StyleMode } from './StyleDefs';

const DISTILL_KEEP = 1024;
const DISTILL_HALO = 96;
const DISTILL_MIN_CANVAS = 256;
const LM9_TILE = 512;
const LM9_LOW = 256;
const LM9_OV = 64;
const LM9_STRIDE = 448;
const NEURAL_DITHER = 1.0;
const WARM_M9 = 'leica_filter_param_m9_snapshot.bin';
const WARM_M10R = 'leica_filter_param_m10r_snapshot.bin';

class Feed {
  readonly name: string;
  readonly dims: number[];
  readonly data: Float32Array;

  constructor(name: string, dims: number[], data: Float32Array) {
    this.name = name;
    this.dims = dims;
    this.data = data;
  }
}

class Rgba {
  readonly px: Uint8Array;
  readonly w: number;
  readonly h: number;

  constructor(px: Uint8Array, w: number, h: number) {
    this.px = px;
    this.w = w;
    this.h = h;
  }
}

export class NeuralEngine {
  private static rm: resourceManager.ResourceManager | undefined = undefined;
  private static models: Map<string, mindSporeLite.Model> = new Map();
  private static modelFailed: Set<string> = new Set();
  private static modelDims: Map<mindSporeLite.Model, string> = new Map();
  private static warmBins: Map<string, WarmBin> = new Map();
  private static queue: Promise<void> = Promise.resolve();

  static init(rm: resourceManager.ResourceManager): void {
    NeuralEngine.rm = rm;
  }

  static isNeuralMode(mode: StyleMode): boolean {
    return mode === StyleMode.MODEL_M9 || mode === StyleMode.MODEL_M9P ||
      mode === StyleMode.MODEL_M9D || mode === StyleMode.MODEL_M10R ||
      mode === StyleMode.MODEL_LM9 || mode === StyleMode.MODEL_CCD_COOL ||
      mode === StyleMode.MODEL_CCD_PINK || mode === StyleMode.MODEL_CCD_WARM;
  }

  /** 模型/暖调 bin 后台预载（入队，失败仅记日志）。 */
  static preload(): Promise<void> {
    return NeuralEngine.enqueue(async (): Promise<void> => {
      const names: string[] = ['m9_distill', 'lm9_net', 'seplut_fivek'];
      for (let i = 0; i < names.length; i++) {
        const t0 = Date.now();
        console.info(`NEURAL preload ${names[i]} begin`);
        try {
          await NeuralEngine.ensureModel(names[i]);
          console.info(`NEURAL preload ${names[i]} ok ${Date.now() - t0}ms`);
        } catch (e) {
          console.info(`NEURAL preload ${names[i]} fail: ${NeuralEngine.errMsg(e)}`);
        }
      }
      const bins: string[] = [WARM_M9, WARM_M10R];
      for (let i = 0; i < bins.length; i++) {
        try {
          await NeuralEngine.ensureWarmBin(bins[i]);
        } catch (e) {
          console.info(`NEURAL preload ${bins[i]} fail: ${NeuralEngine.errMsg(e)}`);
        }
      }
      console.info('NEURAL preload done');
    });
  }

  /** 原地改写 RGBA 字节流，返回降级提示文案。 */
  static applyNeural(px: Uint8Array, w: number, h: number, mode: StyleMode): Promise<string> {
    return NeuralEngine.enqueue((): Promise<string> => NeuralEngine.applyNeuralLocked(px, w, h, mode));
  }

  private static async applyNeuralLocked(px: Uint8Array, w: number, h: number,
    mode: StyleMode): Promise<string> {
    const timeMs = Date.now() % 60000;
    switch (mode) {
      case StyleMode.MODEL_M9:
      case StyleMode.MODEL_M9D: {
        try {
          const styled = await NeuralEngine.distillStyled(px, w, h);
          await NeuralEngine.tpdfDither(styled, w, h, NEURAL_DITHER);
          await NeuralEngine.applyWarm(styled, w, h, WARM_M9, timeMs);
          await NeuralEngine.tpdfDither(styled, w, h, NEURAL_DITHER);
          px.set(styled);
          return '';
        } catch (e) {
          console.info(`NEURAL distill fail: ${NeuralEngine.errMsg(e)}`);
        }
        await NeuralEngine.applyWarm(px, w, h, WARM_M9, timeMs);
        return mode === StyleMode.MODEL_M9D ? 'M9 蒸馏模型不可用，已切换为经典暖调' :
          'M9 模型不可用，已切换为经典暖调';
      }
      case StyleMode.MODEL_M9P: {
        let ok = true;
        try {
          const styled = await NeuralEngine.distillStyled(px, w, h);
          await NeuralEngine.tpdfDither(styled, w, h, NEURAL_DITHER);
          await NeuralEngine.applyWarm(styled, w, h, WARM_M9, timeMs);
          await NeuralEngine.tpdfDither(styled, w, h, NEURAL_DITHER);
          px.set(styled);
        } catch (e) {
          ok = false;
          console.info(`NEURAL M9P distill fail: ${NeuralEngine.errMsg(e)}`);
        }
        await StyleEngine.boost(px, w, h, 1.25, 1.10, 0.04);
        return ok ? '' : 'M9+ 模型不可用，已切换为经典暖调（激进后推）';
      }
      case StyleMode.MODEL_M10R: {
        try {
          const styled = await NeuralEngine.distillStyled(px, w, h);
          await NeuralEngine.tpdfDither(styled, w, h, NEURAL_DITHER);
          await NeuralEngine.applyWarm(styled, w, h, WARM_M10R, timeMs);
          await NeuralEngine.tpdfDither(styled, w, h, NEURAL_DITHER);
          await GrainVignette.applyChunked(styled, w, h, 0.3, 1.0, h, 0);
          px.set(styled);
          return '';
        } catch (e) {
          console.info(`NEURAL M10R distill fail: ${NeuralEngine.errMsg(e)}`);
        }
        await NeuralEngine.applyWarm(px, w, h, WARM_M10R, timeMs);
        await GrainVignette.applyChunked(px, w, h, 0.3, 1.0, h, 0);
        return 'M10-R 模型不可用，已切换为暖调+暗角';
      }
      case StyleMode.MODEL_LM9: {
        try {
          await Lm9Stats.apply(px, w, h);
          return '';
        } catch (e) {
          console.info(`NEURAL LM9 stats fail: ${NeuralEngine.errMsg(e)}`);
        }
        try {
          const styled = await NeuralEngine.lm9NetStyled(px, w, h);
          px.set(styled);
          return 'L-M9 统计链异常，已切换为学习式微网';
        } catch (e) {
          console.info(`NEURAL LM9 net fail: ${NeuralEngine.errMsg(e)}`);
        }
        let notice = 'L-M9 链路不可用，已切换为 M9';
        try {
          const styled = await NeuralEngine.distillStyled(px, w, h);
          await NeuralEngine.tpdfDither(styled, w, h, NEURAL_DITHER);
          await NeuralEngine.applyWarm(styled, w, h, WARM_M9, timeMs);
          await NeuralEngine.tpdfDither(styled, w, h, NEURAL_DITHER);
          px.set(styled);
        } catch (e) {
          await NeuralEngine.applyWarm(px, w, h, WARM_M9, timeMs);
          notice = 'L-M9 链路不可用，已切换为 M9（暖调）';
        }
        return notice;
      }
      case StyleMode.MODEL_CCD_COOL:
      case StyleMode.MODEL_CCD_PINK:
      case StyleMode.MODEL_CCD_WARM: {
        const profile: CcdProfile = mode === StyleMode.MODEL_CCD_COOL ? CcdProfiles.COOL :
          (mode === StyleMode.MODEL_CCD_PINK ? CcdProfiles.PINK : CcdProfiles.WARM);
        try {
          const bundle = await NeuralEngine.sepLutBundle(px, w, h);
          await CcdFilm.applyPx(px, w, h, profile, bundle);
          await GrainVignette.applyChunked(px, w, h, profile.grain, profile.vignette, h, 0);
          return '';
        } catch (e) {
          console.info(`NEURAL ccd seplut fail: ${NeuralEngine.errMsg(e)}`);
        }
        await NeuralEngine.applyWarm(px, w, h, WARM_M9, timeMs);
        return 'CCD 模型不可用，已切换为经典暖调';
      }
      default: {
        return '';
      }
    }
  }

  // ---- 资产与模型 ----

  private static errMsg(e: Object): string {
    return e instanceof Error ? e.message : 'unknown';
  }

  private static async rawOf(name: string): Promise<Uint8Array> {
    const rm = NeuralEngine.rm;
    if (rm === undefined) {
      throw new Error('resource manager not ready');
    }
    return rm.getRawFileContent(name);
  }

  private static async ensureModel(name: string): Promise<mindSporeLite.Model> {
    const hit = NeuralEngine.models.get(name);
    if (hit !== undefined) {
      return hit;
    }
    if (NeuralEngine.modelFailed.has(name)) {
      throw new Error(`model ${name} unavailable`);
    }
    const d = await NeuralEngine.rawOf(`${name}.ms`);
    const ab = new ArrayBuffer(d.byteLength);
    new Uint8Array(ab).set(d);
    const tl = Date.now();
    const cpu: mindSporeLite.CpuDevice = {
      threadNum: 4,
      threadAffinityMode: mindSporeLite.ThreadAffinityMode.NO_AFFINITIES
    };
    const context: mindSporeLite.Context = {
      target: ['cpu'],
      cpu: cpu
    };
    const model = await mindSporeLite.loadModelFromBuffer(ab, context);
    console.info(`NEURAL loadModel ${name} ${Date.now() - tl}ms`);
    NeuralEngine.models.set(name, model);
    const inputs = model.getInputs();
    const names: string[] = [];
    for (let i = 0; i < inputs.length; i++) {
      names.push(`${inputs[i].name}[${inputs[i].shape.join('x')}]`);
    }
    console.info(`NEURAL model ${name} ready, inputs: ${names.join(',')}`);
    return model;
  }

  private static async ensureWarmBin(name: string): Promise<WarmBin> {
    const hit = NeuralEngine.warmBins.get(name);
    if (hit !== undefined) {
      return hit;
    }
    const d = await NeuralEngine.rawOf(name);
    const bin = new WarmBin(d);
    NeuralEngine.warmBins.set(name, bin);
    return bin;
  }

  /** 按名匹配输入 → resize（元数据与目标不符且签名变化时）→ 重新获取张量（元数据仅在构造时刷新）→ setData → predict。 */
  private static async runPredict(model: mindSporeLite.Model,
    feeds: Feed[]): Promise<mindSporeLite.MSTensor[]> {
    let inputs = model.getInputs();
    const dims: number[][] = [];
    const sigParts: string[] = [];
    let needResize = false;
    for (let i = 0; i < inputs.length; i++) {
      const f = NeuralEngine.findFeed(feeds, inputs[i].name);
      dims.push(f.dims);
      sigParts.push(f.dims.join(','));
      const cur = inputs[i].shape;
      if (cur.length !== f.dims.length) {
        needResize = true;
      } else {
        for (let d = 0; d < f.dims.length; d++) {
          if (cur[d] !== f.dims[d]) {
            needResize = true;
            break;
          }
        }
      }
    }
    const sig = sigParts.join(';');
    if (needResize && NeuralEngine.modelDims.get(model) !== sig) {
      if (!model.resize(inputs, dims)) {
        throw new Error('model resize failed');
      }
      NeuralEngine.modelDims.set(model, sig);
    }
    inputs = model.getInputs();
    for (let i = 0; i < inputs.length; i++) {
      const f = NeuralEngine.findFeed(feeds, inputs[i].name);
      if (inputs[i].dataSize !== f.data.byteLength) {
        throw new Error(`tensor ${inputs[i].name} size ${inputs[i].dataSize} != ${f.data.byteLength}`);
      }
      inputs[i].setData(f.data.buffer);
    }
    const tp = Date.now();
    const outs = await model.predict(inputs);
    console.info(`NEURAL predict ${feeds[0].dims.join('x')} ${Date.now() - tp}ms`);
    return outs;
  }

  private static findFeed(feeds: Feed[], name: string): Feed {
    for (let i = 0; i < feeds.length; i++) {
      if (feeds[i].name === name) {
        return feeds[i];
      }
    }
    throw new Error(`feed ${name} not found`);
  }

  private static async applyWarm(px: Uint8Array, w: number, h: number,
    binName: string, timeMs: number): Promise<void> {
    const bin = await NeuralEngine.ensureWarmBin(binName);
    const applier = new WarmApplier(bin, 'common', 200, 5500, 1);
    await applier.apply(px, w, h, timeMs);
  }

  // ---- 推理链 ----

  /** M9 蒸馏微网：keep×keep 保留区 + halo 边缘复制，只写回中心区。 */
  private static async distillStyled(px: Uint8Array, w: number, h: number): Promise<Uint8Array> {
    const model = await NeuralEngine.ensureModel('m9_distill');
    let work = new Rgba(px, w, h);
    const portrait = work.h > work.w;
    if (portrait) {
      work = await NeuralEngine.rotCCW(work.px, work.w, work.h);
    }
    let fitted = work;
    if (Math.min(work.w, work.h) < DISTILL_MIN_CANVAS) {
      const s = DISTILL_MIN_CANVAS / Math.min(work.w, work.h);
      fitted = await NeuralEngine.resizeBilinear(work.px, work.w, work.h,
        Math.ceil(work.w * s), Math.ceil(work.h * s));
    }
    const ww = fitted.w;
    const wh = fitted.h;
    let keep = Math.min(DISTILL_KEEP, Math.min(ww, wh));
    keep -= keep & 1;
    if (keep < 16) {
      throw new Error('distill canvas too small');
    }
    const n = keep + 2 * DISTILL_HALO;
    const low = n / 2;
    const xs = NeuralEngine.tileOffsets(ww, keep);
    const ys = NeuralEngine.tileOffsets(wh, keep);
    const outPx = new Uint8Array(ww * wh * 4);
    for (let i = 3; i < outPx.length; i += 4) {
      outPx[i] = 255;
    }
    const tilePx = new Uint8Array(n * n * 4);
    const lowPx = new Uint8Array(low * low * 4);
    const plane = n * n;
    const fullBuf = new Float32Array(plane * 3);
    const lowBuf = new Float32Array(low * low * 3);
    const inHwc = NeuralEngine.modelInputHwc(model);
    let fullDims: number[] = [1, 3, n, n];
    let lowDims: number[] = [1, 3, low, low];
    if (inHwc) {
      fullDims = [1, n, n, 3];
      lowDims = [1, low, low, 3];
    }
    const t0 = Date.now();
    for (let yi = 0; yi < ys.length; yi++) {
      for (let xi = 0; xi < xs.length; xi++) {
        const x0 = xs[xi];
        const y0 = ys[yi];
        NeuralEngine.readBlock(fitted.px, ww, wh, x0, y0, n, DISTILL_HALO, tilePx);
        await yieldUI();
        NeuralEngine.boxDown2(tilePx, n, lowPx);
        if (inHwc) {
          NeuralEngine.fillHWC(tilePx, plane, fullBuf);
          NeuralEngine.fillHWC(lowPx, low * low, lowBuf);
        } else {
          NeuralEngine.fillPlanesCHW(tilePx, plane, fullBuf);
          NeuralEngine.fillPlanesCHW(lowPx, low * low, lowBuf);
        }
        await yieldUI();
        const feeds: Feed[] = [
          new Feed('lowres', lowDims, lowBuf),
          new Feed('full', fullDims, fullBuf)
        ];
        const outs = await NeuralEngine.runPredict(model, feeds);
        const ob = new Float32Array(outs[0].getData());
        if (ob.length !== plane * 3) {
          throw new Error(`distill output ${ob.length} != ${plane * 3}`);
        }
        const outHwc = NeuralEngine.outLayoutHwc(outs[0].shape, inHwc);
        for (let ty = 0; ty < keep; ty++) {
          const y = y0 + ty;
          if (y >= wh) {
            break;
          }
          let o = (y * ww + x0) * 4;
          let i = (ty + DISTILL_HALO) * n + DISTILL_HALO;
          for (let tx = 0; tx < keep; tx++, o += 4, i++) {
            let r: number;
            let g: number;
            let b: number;
            if (outHwc) {
              const j = i * 3;
              r = Math.round(ob[j] * 255);
              g = Math.round(ob[j + 1] * 255);
              b = Math.round(ob[j + 2] * 255);
            } else {
              r = Math.round(ob[i] * 255);
              g = Math.round(ob[plane + i] * 255);
              b = Math.round(ob[plane * 2 + i] * 255);
            }
            r = r < 0 ? 0 : (r > 255 ? 255 : r);
            g = g < 0 ? 0 : (g > 255 ? 255 : g);
            b = b < 0 ? 0 : (b > 255 ? 255 : b);
            outPx[o] = r;
            outPx[o + 1] = g;
            outPx[o + 2] = b;
          }
        }
        await yieldUI();
      }
    }
    console.info(`NEURAL distill ${ww}x${wh} tiles=${xs.length * ys.length} ${Date.now() - t0}ms`);
    let result = new Rgba(outPx, ww, wh);
    if (ww !== work.w || wh !== work.h) {
      result = await NeuralEngine.resizeBilinear(result.px, ww, wh, work.w, work.h);
    }
    if (portrait) {
      result = await NeuralEngine.rotCW(result.px, result.w, result.h);
    }
    return result.px;
  }

  /** L-M9 微网：512 分块 + 64px 重叠线性羽化（行带滑动累加）。 */
  private static async lm9NetStyled(px: Uint8Array, w: number, h: number): Promise<Uint8Array> {
    const model = await NeuralEngine.ensureModel('lm9_net');
    let work = new Rgba(px, w, h);
    const portrait = work.h > work.w;
    if (portrait) {
      work = await NeuralEngine.rotCCW(work.px, work.w, work.h);
    }
    let fitted = work;
    if (work.w < LM9_TILE || work.h < LM9_TILE) {
      const s = LM9_TILE / Math.min(work.w, work.h);
      fitted = await NeuralEngine.resizeBilinear(work.px, work.w, work.h,
        Math.ceil(work.w * s), Math.ceil(work.h * s));
    }
    const ww = fitted.w;
    const wh = fitted.h;
    const outPx = new Uint8Array(ww * wh * 4);
    for (let i = 3; i < outPx.length; i += 4) {
      outPx[i] = 255;
    }
    const xs = NeuralEngine.lm9Offsets(ww);
    const ys = NeuralEngine.lm9Offsets(wh);
    const band = new Float32Array(3 * LM9_TILE * ww);
    const bandW = new Float32Array(LM9_TILE * ww);
    const rowW = new Float32Array(LM9_TILE);
    const wx = new Float32Array(LM9_TILE);
    const tilePx = new Uint8Array(LM9_TILE * LM9_TILE * 4);
    const lowPx = new Uint8Array(LM9_LOW * LM9_LOW * 4);
    const plane = LM9_TILE * LM9_TILE;
    const fullBuf = new Float32Array(plane * 3);
    const lowBuf = new Float32Array(LM9_LOW * LM9_LOW * 3);
    const inHwc = NeuralEngine.modelInputHwc(model);
    let fullDims: number[] = [1, 3, LM9_TILE, LM9_TILE];
    let lowDims: number[] = [1, 3, LM9_LOW, LM9_LOW];
    if (inHwc) {
      fullDims = [1, LM9_TILE, LM9_TILE, 3];
      lowDims = [1, LM9_LOW, LM9_LOW, 3];
    }
    band.fill(0);
    bandW.fill(0);
    const t0 = Date.now();
    let prevY0 = -1;
    for (let yi = 0; yi < ys.length; yi++) {
      const y0 = ys[yi];
      if (prevY0 >= 0) {
        const delta = y0 - prevY0;
        NeuralEngine.finalizeRows(band, bandW, ww, 0, delta, prevY0, outPx);
        const keepRows = LM9_TILE - delta;
        band.copyWithin(0, delta * ww * 3, LM9_TILE * ww * 3);
        band.fill(0, keepRows * ww * 3, LM9_TILE * ww * 3);
        bandW.copyWithin(0, delta * ww, LM9_TILE * ww);
        bandW.fill(0, keepRows * ww, LM9_TILE * ww);
      }
      NeuralEngine.lm9Weights1d(rowW, wh, y0);
      for (let xi = 0; xi < xs.length; xi++) {
        const x0 = xs[xi];
        NeuralEngine.lm9Weights1d(wx, ww, x0);
        for (let ty = 0; ty < LM9_TILE; ty++) {
          const srcRow = ((y0 + ty) * ww + x0) * 4;
          tilePx.set(fitted.px.subarray(srcRow, srcRow + LM9_TILE * 4), ty * LM9_TILE * 4);
        }
        NeuralEngine.boxDown2(tilePx, LM9_TILE, lowPx);
        if (inHwc) {
          NeuralEngine.fillHWC(tilePx, plane, fullBuf);
          NeuralEngine.fillHWC(lowPx, LM9_LOW * LM9_LOW, lowBuf);
        } else {
          NeuralEngine.fillPlanesCHW(tilePx, plane, fullBuf);
          NeuralEngine.fillPlanesCHW(lowPx, LM9_LOW * LM9_LOW, lowBuf);
        }
        const feeds: Feed[] = [
          new Feed('lowres', lowDims, lowBuf),
          new Feed('full', fullDims, fullBuf)
        ];
        const outs = await NeuralEngine.runPredict(model, feeds);
        const ob = new Float32Array(outs[0].getData());
        if (ob.length !== plane * 3) {
          throw new Error(`lm9net output ${ob.length} != ${plane * 3}`);
        }
        const outHwc = NeuralEngine.outLayoutHwc(outs[0].shape, inHwc);
        for (let ty = 0; ty < LM9_TILE; ty++) {
          const wy = rowW[ty];
          const o = ty * ww;
          const i = ty * LM9_TILE;
          for (let tx = 0; tx < LM9_TILE; tx++) {
            const wgt = wy * wx[tx];
            const idx = o + x0 + tx;
            if (outHwc) {
              const j = (i + tx) * 3;
              band[idx * 3] += wgt * ob[j];
              band[idx * 3 + 1] += wgt * ob[j + 1];
              band[idx * 3 + 2] += wgt * ob[j + 2];
            } else {
              band[idx * 3] += wgt * ob[i + tx];
              band[idx * 3 + 1] += wgt * ob[plane + i + tx];
              band[idx * 3 + 2] += wgt * ob[plane * 2 + i + tx];
            }
            bandW[idx] += wgt;
          }
        }
        await yieldUI();
      }
      prevY0 = y0;
    }
    if (prevY0 >= 0) {
      NeuralEngine.finalizeRows(band, bandW, ww, 0, wh - prevY0, prevY0, outPx);
    }
    console.info(`NEURAL lm9net ${ww}x${wh} tiles=${xs.length * ys.length} ${Date.now() - t0}ms`);
    let result = new Rgba(outPx, ww, wh);
    if (ww !== work.w || wh !== work.h) {
      result = await NeuralEngine.resizeBilinear(result.px, ww, wh, work.w, work.h);
    }
    if (portrait) {
      result = await NeuralEngine.rotCW(result.px, result.w, result.h);
    }
    return result.px;
  }

  /** SepLUT：整图缩 256 喂模型 → 1D LUT(3×17) + 3D LUT(17³)，统一为通道优先平面（轴序 B,G,R）。 */
  private static async sepLutBundle(px: Uint8Array, w: number, h: number): Promise<CcdBundle> {
    const model = await NeuralEngine.ensureModel('seplut_fivek');
    const small = await NeuralEngine.resizeBilinear(px, w, h, 256, 256);
    const inHwc = NeuralEngine.modelInputHwc(model);
    const buf = new Float32Array(256 * 256 * 3);
    let dims: number[] = [1, 3, 256, 256];
    if (inHwc) {
      NeuralEngine.fillHWC(small.px, 256 * 256, buf);
      dims = [1, 256, 256, 3];
    } else {
      NeuralEngine.fillPlanesCHW(small.px, 256 * 256, buf);
    }
    const feeds: Feed[] = [new Feed('img', dims, buf)];
    const outs = await NeuralEngine.runPredict(model, feeds);
    let lut1dRaw: Float32Array | undefined = undefined;
    let lut1dShape: number[] | undefined = undefined;
    let lut3dRaw: Float32Array | undefined = undefined;
    let lut3dShape: number[] | undefined = undefined;
    for (let i = 0; i < outs.length; i++) {
      const en = outs[i].elementNum;
      if (en === 51) {
        lut1dRaw = new Float32Array(outs[i].getData());
        lut1dShape = outs[i].shape;
      } else if (en === 14739) {
        lut3dRaw = new Float32Array(outs[i].getData());
        lut3dShape = outs[i].shape;
      }
    }
    if (lut1dRaw === undefined || lut3dRaw === undefined ||
      lut1dShape === undefined || lut3dShape === undefined) {
      throw new Error('seplut output shape mismatch');
    }
    const lut1d = new Float32Array(51);
    if (lut1dShape.length > 0 && lut1dShape[lut1dShape.length - 1] === 3) {
      for (let i = 0; i < 17; i++) {
        for (let c = 0; c < 3; c++) {
          lut1d[c * 17 + i] = lut1dRaw[i * 3 + c];
        }
      }
    } else {
      lut1d.set(lut1dRaw);
    }
    const lut3d = new Float32Array(14739);
    if (lut3dShape.length > 0 && lut3dShape[lut3dShape.length - 1] === 3) {
      for (let b = 0; b < 17; b++) {
        for (let g = 0; g < 17; g++) {
          for (let r = 0; r < 17; r++) {
            const src = (b * 289 + g * 17 + r) * 3;
            const dst = b * 289 + g * 17 + r;
            lut3d[dst] = lut3dRaw[src];
            lut3d[4913 + dst] = lut3dRaw[src + 1];
            lut3d[9826 + dst] = lut3dRaw[src + 2];
          }
        }
      }
    } else {
      lut3d.set(lut3dRaw);
    }
    return new CcdBundle(lut1d, lut3d);
  }

  // ---- 几何与像素辅助 ----

  private static tileOffsets(total: number, keep: number): number[] {
    if (total <= keep) {
      return [0];
    }
    const cnt = (total + keep - 1) / keep | 0;
    const arr: number[] = [];
    for (let i = 0; i < cnt; i++) {
      const v = i * keep < total - keep ? i * keep : total - keep;
      arr.push(v);
    }
    return arr;
  }

  private static lm9Offsets(total: number): number[] {
    const list: number[] = [];
    if (total <= LM9_TILE) {
      list.push(0);
      return list;
    }
    let o = 0;
    while (o <= total - LM9_TILE) {
      list.push(o);
      o += LM9_STRIDE;
    }
    if (list[list.length - 1] !== total - LM9_TILE) {
      list.push(total - LM9_TILE);
    }
    return list;
  }

  private static lm9Weights1d(out: Float32Array, total: number, start: number): void {
    out.fill(1);
    if (total <= LM9_TILE) {
      return;
    }
    for (let k = 0; k < LM9_OV; k++) {
      if (start > 0) {
        out[k] = k / LM9_OV;
      }
      if (start + LM9_TILE < total) {
        out[LM9_TILE - LM9_OV + k] = (LM9_OV - 1 - k) / LM9_OV;
      }
    }
  }

  private static finalizeRows(band: Float32Array, bandW: Float32Array, w: number,
    from: number, to: number, base: number, outPx: Uint8Array): void {
    for (let k = from; k < to; k++) {
      const o = k * w;
      const rowOut = (base + k) * w;
      for (let j = 0; j < w; j++) {
        const wwv = bandW[o + j];
        if (wwv <= 0) {
          continue;
        }
        const idx = o + j;
        let r = Math.round(band[idx * 3] / wwv * 255);
        r = r < 0 ? 0 : (r > 255 ? 255 : r);
        let g = Math.round(band[idx * 3 + 1] / wwv * 255);
        g = g < 0 ? 0 : (g > 255 ? 255 : g);
        let b = Math.round(band[idx * 3 + 2] / wwv * 255);
        b = b < 0 ? 0 : (b > 255 ? 255 : b);
        const di = (rowOut + j) * 4;
        outPx[di] = r;
        outPx[di + 1] = g;
        outPx[di + 2] = b;
        outPx[di + 3] = 255;
      }
    }
  }

  /** 读 n×n 块（含 halo）：越界行列边缘复制。 */
  private static readBlock(px: Uint8Array, w: number, h: number, x0: number, y0: number,
    n: number, halo: number, dst: Uint8Array): void {
    const bx = x0 - halo;
    const by = y0 - halo;
    const cx0 = bx > 0 ? bx : 0;
    const cy0 = by > 0 ? by : 0;
    const cx1 = Math.min(w, bx + n);
    const cy1 = Math.min(h, by + n);
    for (let ry = 0; ry < n; ry++) {
      let sy = by + ry;
      sy = sy < cy0 ? cy0 : (sy > cy1 - 1 ? cy1 - 1 : sy);
      const srcRow = sy * w * 4;
      const dstRow = ry * n * 4;
      for (let rx = 0; rx < n; rx++) {
        let sx = bx + rx;
        sx = sx < cx0 ? cx0 : (sx > cx1 - 1 ? cx1 - 1 : sx);
        const si = srcRow + sx * 4;
        const di = dstRow + rx * 4;
        dst[di] = px[si];
        dst[di + 1] = px[si + 1];
        dst[di + 2] = px[si + 2];
        dst[di + 3] = 255;
      }
    }
  }

  /** 精确 2:1 盒降采样（n 为偶数）。 */
  private static boxDown2(src: Uint8Array, n: number, dst: Uint8Array): void {
    const low = n / 2;
    let d = 0;
    for (let y = 0; y < low; y++) {
      const r0 = (2 * y) * n * 4;
      const r1 = r0 + n * 4;
      for (let x = 0; x < low; x++) {
        const c = 2 * x * 4;
        const p0 = r0 + c;
        const p1 = p0 + 4;
        const p2 = r1 + c;
        const p3 = p2 + 4;
        const r = (src[p0] + src[p1] + src[p2] + src[p3] + 2) >> 2;
        const g = (src[p0 + 1] + src[p1 + 1] + src[p2 + 1] + src[p3 + 1] + 2) >> 2;
        const b = (src[p0 + 2] + src[p1 + 2] + src[p2 + 2] + src[p3 + 2] + 2) >> 2;
        dst[d] = r;
        dst[d + 1] = g;
        dst[d + 2] = b;
        dst[d + 3] = 255;
        d += 4;
      }
    }
  }

  /** RGBA → CHW float 三平面（R/G/B，/255）。 */
  private static fillPlanesCHW(px: Uint8Array, planeN: number, out: Float32Array): void {
    let o = 0;
    for (let i = 0; i < planeN; i++) {
      out[o++] = px[i * 4] / 255;
    }
    for (let i = 0; i < planeN; i++) {
      out[o++] = px[i * 4 + 1] / 255;
    }
    for (let i = 0; i < planeN; i++) {
      out[o++] = px[i * 4 + 2] / 255;
    }
  }

  /** RGBA → HWC 交错 float（逐像素 R/G/B 相邻，/255）。 */
  private static fillHWC(px: Uint8Array, planeN: number, out: Float32Array): void {
    for (let i = 0; i < planeN; i++) {
      const s = i * 4;
      const o = i * 3;
      out[o] = px[s] / 255;
      out[o + 1] = px[s + 1] / 255;
      out[o + 2] = px[s + 2] / 255;
    }
  }

  /** 模型输入是否为 NHWC（任一输入末维=3 即认定）。 */
  private static modelInputHwc(model: mindSporeLite.Model): boolean {
    const inputs = model.getInputs();
    for (let i = 0; i < inputs.length; i++) {
      const s = inputs[i].shape;
      if (s.length === 4 && s[3] === 3) {
        return true;
      }
    }
    return false;
  }

  /** 输出布局判定：末维=3 → HWC 交错；次维=3 → CHW 平面；无法判定时随输入布局。 */
  private static outLayoutHwc(shape: number[], inHwc: boolean): boolean {
    if (shape.length === 4) {
      if (shape[3] === 3) {
        return true;
      }
      if (shape[1] === 3) {
        return false;
      }
    }
    return inHwc;
  }

  /** 逆时针 90°（竖转横，对齐 Android rotate(-90)）。 */
  private static async rotCCW(px: Uint8Array, w: number, h: number): Promise<Rgba> {
    const ow = h;
    const out = new Uint8Array(px.length);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const si = (y * w + x) * 4;
        const di = ((w - 1 - x) * ow + y) * 4;
        out[di] = px[si];
        out[di + 1] = px[si + 1];
        out[di + 2] = px[si + 2];
        out[di + 3] = 255;
      }
      if ((y & 255) === 0) {
        await yieldUI();
      }
    }
    return new Rgba(out, ow, w);
  }

  /** 顺时针 90°（横转回竖，对齐 Android rotate(90)）。 */
  private static async rotCW(px: Uint8Array, w: number, h: number): Promise<Rgba> {
    const ow = h;
    const out = new Uint8Array(px.length);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const si = (y * w + x) * 4;
        const di = (x * ow + (h - 1 - y)) * 4;
        out[di] = px[si];
        out[di + 1] = px[si + 1];
        out[di + 2] = px[si + 2];
        out[di + 3] = 255;
      }
      if ((y & 255) === 0) {
        await yieldUI();
      }
    }
    return new Rgba(out, ow, w);
  }

  /** 中心对齐双线性缩放（边缘钳位）。 */
  private static async resizeBilinear(px: Uint8Array, w: number, h: number, dw: number, dh: number): Promise<Rgba> {
    const out = new Uint8Array(dw * dh * 4);
    for (let y = 0; y < dh; y++) {
      if ((y & 127) === 0) {
        await yieldUI();
      }
      let sy = (y + 0.5) * h / dh - 0.5;
      sy = sy < 0 ? 0 : (sy > h - 1 ? h - 1 : sy);
      const y0 = sy | 0;
      const y1 = y0 + 1 < h ? y0 + 1 : y0;
      const fy = sy - y0;
      const wfy = 1 - fy;
      const r0y = y0 * w * 4;
      const r1y = y1 * w * 4;
      for (let x = 0; x < dw; x++) {
        let sx = (x + 0.5) * w / dw - 0.5;
        sx = sx < 0 ? 0 : (sx > w - 1 ? w - 1 : sx);
        const x0 = sx | 0;
        const x1 = x0 + 1 < w ? x0 + 1 : x0;
        const fx = sx - x0;
        const wfx = 1 - fx;
        const c00 = r0y + x0 * 4;
        const c01 = r0y + x1 * 4;
        const c10 = r1y + x0 * 4;
        const c11 = r1y + x1 * 4;
        const o = (y * dw + x) * 4;
        out[o] = Math.round(px[c00] * wfx * wfy + px[c01] * fx * wfy +
          px[c10] * wfx * fy + px[c11] * fx * fy);
        out[o + 1] = Math.round(px[c00 + 1] * wfx * wfy + px[c01 + 1] * fx * wfy +
          px[c10 + 1] * wfx * fy + px[c11 + 1] * fx * fy);
        out[o + 2] = Math.round(px[c00 + 2] * wfx * wfy + px[c01 + 2] * fx * wfy +
          px[c10 + 2] * wfx * fy + px[c11 + 2] * fx * fy);
        out[o + 3] = 255;
      }
    }
    return new Rgba(out, dw, dh);
  }

  /** ±amp LSB 三角分布抖动（量化台阶打散）。主线程行分块让出。 */
  private static async tpdfDither(px: Uint8Array, w: number, h: number, amp: number): Promise<void> {
    let st = (0x9E3779B9 ^ Date.now()) | 0;
    const rows = Math.max(1, Math.floor(16384 / w));
    for (let y0 = 0; y0 < h; y0 += rows) {
      const end = (y0 + rows < h ? y0 + rows : h) * w * 4;
      for (let i = y0 * w * 4; i < end; i += 4) {
        for (let c = 0; c < 3; c++) {
          st = NeuralEngine.nextSeed(st);
          const u1 = (st & 0xFFFFFF) / 16777216;
          st = NeuralEngine.nextSeed(st);
          const u2 = (st & 0xFFFFFF) / 16777216;
          const dv = (u1 + u2 - 1) * amp;
          const j = i + c;
          let v = px[j];
          if (dv >= 0.5) {
            v += 1;
          } else if (dv <= -0.5) {
            v -= 1;
          }
          px[j] = v < 0 ? 0 : (v > 255 ? 255 : v);
        }
      }
      await yieldUI();
    }
  }

  private static nextSeed(st: number): number {
    let s = (st ^ (st << 13)) | 0;
    s = (s ^ (s >>> 17)) | 0;
    s = (s ^ (s << 5)) | 0;
    return s;
  }

  private static enqueue<T>(op: () => Promise<T>): Promise<T> {
    const run: Promise<T> = NeuralEngine.queue.then(op);
    NeuralEngine.queue = run.then((): void => {}, (): void => {});
    return run;
  }
}
