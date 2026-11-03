/**
 * 模型色彩网络推理（Batch H，移植自 AdaptiveColorNet.kt 的 ONNX 路径）：
 *   refs → m7_stage1 → e (r,36) → aggregate(mean/amax/std → 108) → m7_stage2 → aff/knots。
 *
 * 模型契约（23_export_net.py，style_only checkpoint）：
 *   stage1 in  refs (1,R,6,128,128)  [参考 Lab, N(ref) Lab]，L/100、a/b/128
 *   stage1 out e    (1,R,36)
 *   stage2 in  r    (1,108)
 *   stage2 out aff  (1,12,1,1)  3x4 逐通道仿射 [c0 rgb+bias, c1, c2]
 *             knots(1,3,9)     L 曲线在 [0,1] 均匀取 9 点，a/b 在 [-1,1]
 *
 * 单色补救（§mono）：stage2 在彩色成片上训练，黑白参考属于分布外——
 * 参考集均值色度 < MONO_MEAN_CHROMA 时清零 a/b 通路（保留 L 影调）。
 * 本类只做推理与数据整形；逐像素应用见 ModelColorMath.apply（taskpool）。
 */

import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { resourceManager } from '@kit.LocalizationKit';
import { yieldUI } from './PixAsync';
import { ModelColorMath } from './ModelColorMath';

const REF: number = 128;
const REF_SIDE: number = 256;

/** 风格参数：aff(12) + knots(27)，可直接序列化存储。 */
export class McStyle {
  readonly aff: Float32Array;
  readonly knots: Float32Array;

  constructor(aff: Float32Array, knots: Float32Array) {
    this.aff = aff;
    this.knots = knots;
  }
}

/** 已解码参考图（紧密 RGBA 字节流）。 */
export class McRef {
  readonly px: Uint8Array;
  readonly w: number;
  readonly h: number;

  constructor(px: Uint8Array, w: number, h: number) {
    this.px = px;
    this.w = w;
    this.h = h;
  }
}

/** monoIfGray 输出：风格 + 是否单色。 */
export class McMonoOut {
  readonly style: McStyle;
  readonly mono: boolean;

  constructor(style: McStyle, mono: boolean) {
    this.style = style;
    this.mono = mono;
  }
}

/** 模型输入喂数项（与 M9PerfectEngine.Feed 同构）。 */
class Feed {
  readonly name: string;
  readonly data: Float32Array;

  constructor(name: string, data: Float32Array) {
    this.name = name;
    this.data = data;
  }
}

export class ModelColorNet {
  private static models: Map<string, mindSporeLite.Model> = new Map();

  private static async ensureModel(rm: resourceManager.ResourceManager,
    name: string): Promise<mindSporeLite.Model> {
    const hit = ModelColorNet.models.get(name);
    if (hit !== undefined) {
      return hit;
    }
    const d = await rm.getRawFileContent(name);
    const ab = new ArrayBuffer(d.byteLength);
    new Uint8Array(ab).set(d);
    const cpu: mindSporeLite.CpuDevice = {
      threadNum: 4,
      threadAffinityMode: mindSporeLite.ThreadAffinityMode.NO_AFFINITIES
    };
    const context: mindSporeLite.Context = { target: ['cpu'], cpu: cpu };
    const model = await mindSporeLite.loadModelFromBuffer(ab, context);
    ModelColorNet.models.set(name, model);
    return model;
  }

  /** 释放已加载模型（内存紧张时）。 */
  static release(): void {
    ModelColorNet.models.clear();
  }

  /**
   * 逐图指纹 e_i（r*36），直接来自 stage1。失败返回 undefined。
   * 每张参考的 Lab/neutralize 像素级计算间 yield，避免主线程卡顿。
   */
  static async encodeStats(rm: resourceManager.ResourceManager,
    refs: McRef[]): Promise<Float32Array | undefined> {
    const r = refs.length;
    if (r <= 0) {
      return undefined;
    }
    try {
      const s1 = await ModelColorNet.ensureModel(rm, 'm7_stage1.ms');
      const buf = new Float32Array(r * 6 * REF * REF);
      for (let i = 0; i < r; i++) {
        ModelColorNet.fillRefBuf(refs[i], buf, i);
        await yieldUI();
      }
      const feeds: Feed[] = [new Feed('refs', buf)];
      const out = await ModelColorNet.runByShape(s1, feeds, [[1, r, 6, REF, REF]]);
      return new Float32Array(out[0].getData());
    } catch (e) {
      return undefined;
    }
  }

  /** 参考缓冲填充：ch0-2 = 128² 中心 patch 的 Lab；ch3-5 = N(patch) 的 Lab。 */
  private static fillRefBuf(ref: McRef, buf: Float32Array, idx: number): void {
    const patch = ModelColorNet.refPatch(ref);
    const n = REF * REF;
    const lab = ModelColorMath.labPlanes(patch, n);
    const neu = ModelColorMath.labPlanes(ModelColorMath.neutralizeBytes(patch), n);
    let o = idx * 6 * n;
    for (let c = 0; c < 3; c++) {
      for (let k = 0; k < n; k++) {
        buf[o++] = lab[c * n + k];
      }
    }
    for (let c = 0; c < 3; c++) {
      for (let k = 0; k < n; k++) {
        buf[o++] = neu[c * n + k];
      }
    }
  }

  /** 短边 → 256（中心裁 256²）→ 缩 128²，对齐 refPatch（含小图放大）。 */
  private static refPatch(ref: McRef): Uint8Array {
    const shortSide = Math.min(ref.w, ref.h);
    const s = REF_SIDE / Math.max(shortSide, 1);
    const nw = Math.max(REF_SIDE, Math.round(ref.w * s));
    const nh = Math.max(REF_SIDE, Math.round(ref.h * s));
    const scaled = ModelColorMath.scaleRgba(ref.px, ref.w, ref.h, nw, nh);
    const x = Math.floor((nw - REF_SIDE) / 2);
    const y = Math.floor((nh - REF_SIDE) / 2);
    const crop = new Uint8Array(REF_SIDE * REF_SIDE * 4);
    for (let row = 0; row < REF_SIDE; row++) {
      const src = ((y + row) * nw + x) * 4;
      crop.set(scaled.subarray(src, src + REF_SIDE * 4), row * REF_SIDE * 4);
    }
    return ModelColorMath.scaleRgba(crop, REF_SIDE, REF_SIDE, REF, REF);
  }

  /** mean/amax/std over R → stage2 消费的 108 维 r。 */
  static aggregate(e: Float32Array, r: number): Float32Array {
    const d = 36;
    const mu = new Float32Array(d);
    const amx = new Float32Array(d);
    const sd = new Float32Array(d);
    for (let k = 0; k < d; k++) {
      let m = 0;
      let mx = -Number.MAX_VALUE;
      for (let i = 0; i < r; i++) {
        const v = e[i * d + k];
        m += v;
        if (v > mx) {
          mx = v;
        }
      }
      m /= r;
      mu[k] = m;
      amx[k] = mx;
      let s2 = 0;
      for (let i = 0; i < r; i++) {
        const dd = e[i * d + k] - m;
        s2 += dd * dd;
      }
      sd[k] = Math.sqrt(s2 / r);
    }
    const out = new Float32Array(d * 3);
    out.set(mu, 0);
    out.set(amx, d);
    out.set(sd, 2 * d);
    return out;
  }

  /** stage2：聚合 r → aff/knots。失败返回 undefined。 */
  static async fuse(rm: resourceManager.ResourceManager,
    r: Float32Array): Promise<McStyle | undefined> {
    try {
      const s2 = await ModelColorNet.ensureModel(rm, 'm7_stage2.ms');
      const feeds: Feed[] = [new Feed('r', r)];
      const out = await ModelColorNet.runByShape(s2, feeds, [[1, r.length]]);
      const aff = new Float32Array(12);
      const knots = new Float32Array(27);
      let affT = ModelColorNet.findTensor(out, 'aff', 0);
      let knotsT = ModelColorNet.findTensor(out, 'knots', 1);
      const ab = new Float32Array(affT.getData());
      const kb = new Float32Array(knotsT.getData());
      for (let i = 0; i < 12 && i < ab.length; i++) {
        aff[i] = ab[i];
      }
      for (let i = 0; i < 27 && i < kb.length; i++) {
        knots[i] = kb[i];
      }
      return new McStyle(aff, knots);
    } catch (e) {
      return undefined;
    }
  }

  /** 编码参考集 → aff/knots。失败返回 undefined（调用方回退 LUT 链）。 */
  static async encodeStyle(rm: resourceManager.ResourceManager,
    refs: McRef[]): Promise<McStyle | undefined> {
    const e = await ModelColorNet.encodeStats(rm, refs);
    if (e === undefined) {
      return undefined;
    }
    return ModelColorNet.fuse(rm, ModelColorNet.aggregate(e, refs.length));
  }

  /** 参考集平均色度（Lab √(a²+b²)），与 stage1 同口径（128² 中心裁剪后测）。 */
  static refsMeanChroma(refs: McRef[]): number {
    let acc = 0;
    let cnt = 0;
    for (let i = 0; i < refs.length; i++) {
      const patch = ModelColorNet.refPatch(refs[i]);
      const n = REF * REF;
      const lab = ModelColorMath.labPlanes(patch, n);
      for (let k = 0; k < n; k++) {
        const a = lab[n + k] * 128;
        const b = lab[2 * n + k] * 128;
        acc += Math.sqrt(a * a + b * b);
        cnt++;
      }
    }
    return cnt > 0 ? acc / cnt : 0;
  }

  /** 编码后调用：黑白参考 → 单色风格。 */
  static monoIfGray(refs: McRef[], s: McStyle): McMonoOut {
    const mc = ModelColorNet.refsMeanChroma(refs);
    if (mc < ModelColorMath.MONO_MEAN_CHROMA) {
      const aff = s.aff.slice();
      const knots = s.knots.slice();
      ModelColorMath.toMono(aff, knots);
      return new McMonoOut(new McStyle(aff, knots), true);
    }
    return new McMonoOut(s, false);
  }

  // ---- 推理 ----

  /** 按 dims 就位（必要时 resize）→ setData → predict。 */
  private static async runByShape(model: mindSporeLite.Model, feeds: Feed[],
    wants: number[][]): Promise<mindSporeLite.MSTensor[]> {
    let inputs = model.getInputs();
    let need = false;
    for (let i = 0; i < inputs.length; i++) {
      const shape = inputs[i].shape;
      const want = wants[i];
      if (shape.length !== want.length) {
        need = true;
        break;
      }
      for (let dd = 0; dd < want.length; dd++) {
        if (shape[dd] !== want[dd]) {
          need = true;
          break;
        }
      }
      if (need) {
        break;
      }
    }
    if (need) {
      if (!model.resize(inputs, wants)) {
        throw new Error('resize failed');
      }
      inputs = model.getInputs();
    }
    for (let i = 0; i < inputs.length; i++) {
      const f = ModelColorNet.findFeed(feeds, inputs[i].name, i);
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

  private static findTensor(ts: mindSporeLite.MSTensor[], name: string,
    index: number): mindSporeLite.MSTensor {
    for (let i = 0; i < ts.length; i++) {
      if (ts[i].name === name) {
        return ts[i];
      }
    }
    return index < ts.length ? ts[index] : ts[0];
  }
}
