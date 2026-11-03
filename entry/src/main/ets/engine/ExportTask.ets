/**
 * taskpool 工作任务：风格链 + 色调曲线 + 柔光的纯数学处理（无 UI / image / zlib 依赖）。
 *
 * 参数全部为可序列化对象（ArrayBuffer/number/boolean/number[]）；
 * LUT / SA 二进制用空 ArrayBuffer 表示「无」。失败抛 Error，由调用方 toast。
 * levels[7]（柔光）为空间算子，在 ToneCurves 之后按 8-bit 域叠加（与 Android 同口径）。
 */

import { taskpool } from '@kit.ArkTS';
import { Lut3D } from './Lut3D';
import { StyleEngine } from './StyleEngine';
import { StyleAModel } from './StyleAEngine';
import { ToneCurves } from './ToneCurves';
import { SoftGlow } from './SoftGlow';
import { StyleMode } from './StyleDefs';
import { ModelColorMath } from './ModelColorMath';

@Concurrent
export function runStyleTask(rgba: ArrayBuffer, w: number, h: number, mode: StyleMode,
  grain: number, vignette: number, p9: boolean,
  lutBin: ArrayBuffer, saNodes: ArrayBuffer, levels: number[]): ArrayBuffer {
  const px = new Uint8Array(rgba);
  let lut: Lut3D | undefined = undefined;
  if (lutBin.byteLength > 0) {
    lut = Lut3D.decode(new Uint8Array(lutBin));
    if (lut === undefined) {
      throw new Error('LUT 数据无效');
    }
  }
  let sa: StyleAModel | undefined = undefined;
  if (saNodes.byteLength > 0) {
    sa = StyleAModel.decode(new Uint8Array(saNodes));
    if (sa === undefined) {
      throw new Error('Style A 参数无效');
    }
  }
  StyleEngine.applyPx(px, w, h, mode, grain, vignette, p9, lut, sa);
  ToneCurves.apply(px, levels);
  if (levels.length > ToneCurves.TONE_COUNT) {
    SoftGlow.apply(px, w, h, levels[ToneCurves.TONE_COUNT]);
  }
  return rgba;
}

/**
 * taskpool 工作任务：模型色彩（aff/knots）+ 色调曲线 + 柔光（Batch H）。
 * 参数全部为可序列化对象；aff[12]/knots[27] 用 number[] 传（Float32Array 不可跨 taskpool）。
 * 失败抛 Error，由调用方 toast。
 */
@Concurrent
export function runModelColorTask(rgba: ArrayBuffer, w: number, h: number,
  aff: number[], knots: number[], protect: boolean, guard: boolean, smooth: boolean,
  strength: number, levels: number[]): ArrayBuffer {
  const px = new Uint8Array(rgba);
  const fAff = new Float32Array(12);
  const fKnots = new Float32Array(27);
  for (let i = 0; i < 12 && i < aff.length; i++) {
    fAff[i] = aff[i];
  }
  for (let i = 0; i < 27 && i < knots.length; i++) {
    fKnots[i] = knots[i];
  }
  ModelColorMath.apply(px, w, h, fAff, fKnots, protect, guard, strength, smooth);
  ToneCurves.apply(px, levels);
  if (levels.length > ToneCurves.TONE_COUNT) {
    SoftGlow.apply(px, w, h, levels[ToneCurves.TONE_COUNT]);
  }
  return rgba;
}

/** UI 线程侧封装：拷贝入参、派发任务、返回处理后的 RGBA。 */
export class ModelColorRunner {
  static async run(src: Uint8Array, w: number, h: number,
    aff: Float32Array, knots: Float32Array,
    protect: boolean, guard: boolean, smooth: boolean, strength: number,
    levels: number[]): Promise<Uint8Array> {
    const srcCopy = new ArrayBuffer(src.byteLength);
    new Uint8Array(srcCopy).set(src);
    const a: number[] = [];
    for (let i = 0; i < aff.length; i++) {
      a.push(aff[i]);
    }
    const k: number[] = [];
    for (let i = 0; i < knots.length; i++) {
      k.push(knots[i]);
    }
    const lv: number[] = [];
    for (let i = 0; i < levels.length; i++) {
      lv.push(levels[i]);
    }
    const out = await taskpool.execute(runModelColorTask, srcCopy, w, h,
      a, k, protect, guard, smooth, strength, lv);
    if (out instanceof ArrayBuffer) {
      return new Uint8Array(out);
    }
    return new Uint8Array(0);
  }
}

/** UI 线程侧封装：拷贝入参、派发任务、返回处理后的 RGBA。 */
export class StyleRunner {
  static async run(src: Uint8Array, w: number, h: number, mode: StyleMode,
    grain: number, vignette: number, p9: boolean,
    lutBin: Uint8Array | undefined, saNodes: Uint8Array | undefined,
    levels: number[]): Promise<Uint8Array> {
    const srcCopy = new ArrayBuffer(src.byteLength);
    new Uint8Array(srcCopy).set(src);
    const empty = new ArrayBuffer(0);
    const lutBuf = StyleRunner.toBuffer(lutBin, empty);
    const saBuf = StyleRunner.toBuffer(saNodes, empty);
    const lv: number[] = [];
    for (let i = 0; i < levels.length; i++) {
      lv.push(levels[i]);
    }
    const out = await taskpool.execute(runStyleTask, srcCopy, w, h, mode,
      grain, vignette, p9, lutBuf, saBuf, lv);
    if (out instanceof ArrayBuffer) {
      return new Uint8Array(out);
    }
    return new Uint8Array(0);
  }

  private static toBuffer(u8: Uint8Array | undefined, fallback: ArrayBuffer): ArrayBuffer {
    if (u8 === undefined || u8.byteLength === 0) {
      return fallback;
    }
    const ab = new ArrayBuffer(u8.byteLength);
    new Uint8Array(ab).set(u8);
    return ab;
  }
}
