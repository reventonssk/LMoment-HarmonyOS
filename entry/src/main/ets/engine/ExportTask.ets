/**
 * taskpool 工作任务：风格链 + 色调曲线的纯数学处理（无 UI / image / zlib 依赖）。
 *
 * 参数全部为可序列化对象（ArrayBuffer/number/boolean/number[]）；
 * LUT / SA 二进制用空 ArrayBuffer 表示「无」。失败抛 Error，由调用方 toast。
 */

import { taskpool } from '@kit.ArkTS';
import { Lut3D } from './Lut3D';
import { StyleEngine } from './StyleEngine';
import { StyleAModel } from './StyleAEngine';
import { ToneCurves } from './ToneCurves';
import { StyleMode } from './StyleDefs';

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
  return rgba;
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
