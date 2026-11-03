import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { yieldUI } from './PixAsync';

export enum SuperResMode {
  FAST = 0,
  QUALITY = 1
}

export class SuperResImage {
  readonly data: Uint8Array;
  readonly width: number;
  readonly height: number;

  constructor(data: Uint8Array, width: number, height: number) {
    this.data = data;
    this.width = width;
    this.height = height;
  }
}

class SuperResFeed {
  readonly name: string;
  readonly dims: number[];
  readonly data: Float32Array;

  constructor(name: string, dims: number[], data: Float32Array) {
    this.name = name;
    this.dims = dims;
    this.data = data;
  }
}

export class SuperResEngine {
  static readonly TILE: number = 256;
  static readonly OVERLAP: number = 16;
  static readonly SCALE: number = 2;
  /** ×2 后输出须落在 12MP 安全帽内（SAFE_EXPORT_PIXELS/4）；分块+块间 yield 架构下大图安全。 */
  static readonly MAX_SAFE_INPUT_PIXELS: number = 3 * 1024 * 1024;
  private static readonly models: Map<string, mindSporeLite.Model> = new Map();
  private static rm: resourceManager.ResourceManager | undefined = undefined;

  static init(rm: resourceManager.ResourceManager): void {
    SuperResEngine.rm = rm;
  }

  static async upscale(src: Uint8Array, width: number, height: number,
    mode: SuperResMode): Promise<SuperResImage | undefined> {
    if (width < 1 || height < 1 || src.length < width * height * 4) {
      return undefined;
    }
    if (width * height > SuperResEngine.MAX_SAFE_INPUT_PIXELS) {
      return undefined;
    }
    const name: string = mode === SuperResMode.QUALITY ? 'swinir_s_x2' : 'fast_span_x2';
    const model: mindSporeLite.Model = await SuperResEngine.ensureModel(name);
    const ow: number = width * SuperResEngine.SCALE;
    const oh: number = height * SuperResEngine.SCALE;
    const result: Uint8Array = new Uint8Array(ow * oh * 4);
    const xs: number[] = SuperResEngine.offsets(width);
    const ys: number[] = SuperResEngine.offsets(height);
    for (let yi = 0; yi < ys.length; yi++) {
      for (let xi = 0; xi < xs.length; xi++) {
        await yieldUI();
        const tile: Float32Array = SuperResEngine.readTile(src, width, height, xs[xi], ys[yi]);
        const feeds: SuperResFeed[] = [];
        const input = model.getInputs();
        const inputDims: number[] = input[0].shape.length === 4 && input[0].shape[3] === 3 ?
          [1, SuperResEngine.TILE, SuperResEngine.TILE, 3] : [1, 3, SuperResEngine.TILE, SuperResEngine.TILE];
        feeds.push(new SuperResFeed(input[0].name, inputDims,
          SuperResEngine.toTensor(tile, inputDims[1] === SuperResEngine.TILE)));
        if (input.length > 1) {
          const mask: Float32Array = new Float32Array(1024 * 64 * 64);
          feeds.push(new SuperResFeed(input[1].name, [1024, 64, 64], mask));
        }
        const outputs = await SuperResEngine.predict(model, feeds);
        await yieldUI();
        if (outputs.length < 1) {
          return undefined;
        }
        const out = new Float32Array(outputs[0].getData());
        const outHwc: boolean = outputs[0].shape.length === 4 && outputs[0].shape[3] === 3;
        const nextX: number = xi + 1 < xs.length ? xs[xi + 1] : -1;
        const nextY: number = yi + 1 < ys.length ? ys[yi + 1] : -1;
        SuperResEngine.writeCenter(out, outHwc, xs[xi], ys[yi], nextX, nextY, width, height, ow, oh, result);
      }
    }
    return new SuperResImage(result, ow, oh);
  }

  private static async ensureModel(name: string): Promise<mindSporeLite.Model> {
    const hit = SuperResEngine.models.get(name);
    if (hit !== undefined) {
      return hit;
    }
    const rm = SuperResEngine.rm;
    if (rm === undefined) {
      throw new Error('super resolution resource manager unavailable');
    }
    const raw: Uint8Array = await rm.getRawFileContent(name + '.ms');
    const buffer: ArrayBuffer = new ArrayBuffer(raw.length);
    new Uint8Array(buffer).set(raw);
    const cpu: mindSporeLite.CpuDevice = {
      threadNum: 4,
      threadAffinityMode: mindSporeLite.ThreadAffinityMode.NO_AFFINITIES
    };
    const context: mindSporeLite.Context = { target: ['cpu'], cpu: cpu };
    const model: mindSporeLite.Model = await mindSporeLite.loadModelFromBuffer(buffer, context);
    SuperResEngine.models.set(name, model);
    return model;
  }

  private static async predict(model: mindSporeLite.Model,
    feeds: SuperResFeed[]): Promise<mindSporeLite.MSTensor[]> {
    const inputs = model.getInputs();
    const dims: number[][] = [];
    for (let i = 0; i < inputs.length; i++) {
      const feed: SuperResFeed = feeds[i];
      dims.push(feed.dims);
    }
    let resize: boolean = false;
    for (let i = 0; i < inputs.length; i++) {
      const shape: number[] = inputs[i].shape;
      const target: number[] = dims[i];
      if (shape.length !== target.length) {
        resize = true;
      } else {
        for (let j = 0; j < shape.length; j++) {
          if (shape[j] !== target[j]) {
            resize = true;
          }
        }
      }
    }
    if (resize && !model.resize(inputs, dims)) {
      throw new Error('super resolution model resize failed');
    }
    const current = model.getInputs();
    for (let i = 0; i < current.length; i++) {
      const feed: SuperResFeed = feeds[i];
      current[i].setData(feed.data.buffer);
    }
    return model.predict(current);
  }

  private static offsets(size: number): number[] {
    const step: number = SuperResEngine.TILE - SuperResEngine.OVERLAP;
    const result: number[] = [];
    let at: number = 0;
    while (true) {
      result.push(at);
      if (at + SuperResEngine.TILE >= size) {
        break;
      }
      at += step;
      if (at + SuperResEngine.TILE > size) {
        at = Math.max(0, size - SuperResEngine.TILE);
      }
    }
    return result;
  }

  private static readTile(src: Uint8Array, width: number, height: number,
    x0: number, y0: number): Float32Array {
    const out: Float32Array = new Float32Array(SuperResEngine.TILE * SuperResEngine.TILE * 3);
    for (let y = 0; y < SuperResEngine.TILE; y++) {
      const sy: number = Math.min(height - 1, y0 + y);
      for (let x = 0; x < SuperResEngine.TILE; x++) {
        const sx: number = Math.min(width - 1, x0 + x);
        const si: number = (sy * width + sx) * 4;
        const oi: number = (y * SuperResEngine.TILE + x) * 3;
        out[oi] = src[si] / 255;
        out[oi + 1] = src[si + 1] / 255;
        out[oi + 2] = src[si + 2] / 255;
      }
    }
    return out;
  }

  private static toTensor(tile: Float32Array, hwc: boolean): Float32Array {
    if (hwc) {
      return tile;
    }
    const out: Float32Array = new Float32Array(tile.length);
    const plane: number = SuperResEngine.TILE * SuperResEngine.TILE;
    for (let i = 0; i < plane; i++) {
      out[i] = tile[i * 3];
      out[plane + i] = tile[i * 3 + 1];
      out[plane * 2 + i] = tile[i * 3 + 2];
    }
    return out;
  }

  private static writeCenter(out: Float32Array, hwc: boolean, inputX: number, inputY: number,
    nextX: number, nextY: number,
    inputWidth: number, inputHeight: number, width: number, height: number, result: Uint8Array): void {
    const tileOut: number = SuperResEngine.TILE * 2;
    const half: number = SuperResEngine.OVERLAP; // 重叠区对半分：各弃 8 输入像素/侧，接缝落在重叠区中部
    // 修复黑色接缝：原实现块两侧各裁 crop=32，但块步长仅 480，块间留下 32px 未写黑缝
    // （1600x1200 → 7x5 块 → 竖 5 条 / 横 3-4 条实测）。正确所有权：
    // 非首块从半重叠后写起，非末块写到下一块半重叠起点，块间严格连续。
    const startX: number = inputX > 0 ? half : 0;
    const startY: number = inputY > 0 ? half : 0;
    const endX: number = nextX >= 0 ? Math.min(tileOut, (nextX - inputX) * 2 + half) : tileOut;
    const endY: number = nextY >= 0 ? Math.min(tileOut, (nextY - inputY) * 2 + half) : tileOut;
    const outputX: number = inputX * 2;
    const outputY: number = inputY * 2;
    for (let y = startY; y < endY; y++) {
      const oy: number = outputY + y;
      if (oy >= height) {
        continue;
      }
      for (let x = startX; x < endX; x++) {
        const ox: number = outputX + x;
        if (ox >= width) {
          continue;
        }
        const srcPixel: number = y * tileOut + x;
        const di: number = oy * width + ox;
        const plane: number = tileOut * tileOut;
        const r: number = hwc ? out[srcPixel * 3] : out[srcPixel];
        const g: number = hwc ? out[srcPixel * 3 + 1] : out[plane + srcPixel];
        const b: number = hwc ? out[srcPixel * 3 + 2] : out[plane * 2 + srcPixel];
        result[di * 4] = SuperResEngine.byte(r);
        result[di * 4 + 1] = SuperResEngine.byte(g);
        result[di * 4 + 2] = SuperResEngine.byte(b);
        result[di * 4 + 3] = 255;
      }
    }
  }

  private static byte(value: number): number {
    return Math.max(0, Math.min(255, Math.round(value * 255)));
  }

  /** 导出诊断：未写像素计数（黑缝决定性信号，未写处 alpha 恒为 0）+ 块接缝行/列均值跳变对比。 */
  static scanSeam(data: Uint8Array, w: number, h: number): void {
    let unwritten: number = 0;
    const rowMean: Float64Array = new Float64Array(h);
    const colMean: Float64Array = new Float64Array(w);
    for (let y = 0; y < h; y++) {
      const rowBase: number = y * w * 4;
      let sum: number = 0;
      for (let x = 0; x < w; x++) {
        const i: number = rowBase + x * 4;
        if (data[i + 3] !== 255) {
          unwritten++;
        }
        const lum: number = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
        sum += lum;
        colMean[x] += lum;
      }
      rowMean[y] = sum / w;
    }
    for (let x = 0; x < w; x++) {
      colMean[x] /= h;
    }
    const seamsY: number[] = SuperResEngine.seamPositions(h);
    const seamsX: number[] = SuperResEngine.seamPositions(w);
    let seamY: number = 0;
    let otherY: number = 0;
    for (let y = 1; y < h; y++) {
      const d: number = Math.abs(rowMean[y] - rowMean[y - 1]);
      if (seamsY.indexOf(y) >= 0) {
        if (d > seamY) {
          seamY = d;
        }
      } else if (d > otherY) {
        otherY = d;
      }
    }
    let seamX: number = 0;
    let otherX: number = 0;
    for (let x = 1; x < w; x++) {
      const d: number = Math.abs(colMean[x] - colMean[x - 1]);
      if (seamsX.indexOf(x) >= 0) {
        if (d > seamX) {
          seamX = d;
        }
      } else if (d > otherX) {
        otherX = d;
      }
    }
    hilog.info(0xD002, 'SRScan',
      'scan %{public}dx%{public}d unwritten=%{public}d seams=%{public}d+%{public}d seamY=%{public}s otherY=%{public}s seamX=%{public}s otherX=%{public}s',
      w, h, unwritten, seamsY.length, seamsX.length,
      seamY.toFixed(2), otherY.toFixed(2), seamX.toFixed(2), otherX.toFixed(2));
  }

  /** 由 offsets() 精确推算输出坐标系中的接缝位置（末块钳位后不再是整齐的 k*480）。 */
  private static seamPositions(outSize: number): number[] {
    const inputSize: number = Math.floor(outSize / 2);
    if (inputSize <= SuperResEngine.TILE) {
      return [];
    }
    const offs: number[] = SuperResEngine.offsets(inputSize);
    const result: number[] = [];
    for (let i = 1; i < offs.length; i++) {
      result.push(offs[i] * 2 + SuperResEngine.OVERLAP);
    }
    return result;
  }
}
