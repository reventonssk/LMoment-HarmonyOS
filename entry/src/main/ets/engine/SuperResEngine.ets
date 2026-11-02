import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { resourceManager } from '@kit.LocalizationKit';

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
  static readonly MAX_UI_PIXELS: number = 512 * 512;
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
    if (width * height > SuperResEngine.MAX_UI_PIXELS) {
      return undefined;
    }
    const name: string = mode === SuperResMode.QUALITY ? 'swinir_s_x2' : 'fast_span_x2';
    const model: mindSporeLite.Model = await SuperResEngine.ensureModel(name);
    const ow: number = width * SuperResEngine.SCALE;
    const oh: number = height * SuperResEngine.SCALE;
    const sum: Float32Array = new Float32Array(ow * oh * 3);
    const weight: Float32Array = new Float32Array(ow * oh);
    const xs: number[] = SuperResEngine.offsets(width);
    const ys: number[] = SuperResEngine.offsets(height);
    for (let yi = 0; yi < ys.length; yi++) {
      for (let xi = 0; xi < xs.length; xi++) {
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
        if (outputs.length < 1) {
          return undefined;
        }
        const out = new Float32Array(outputs[0].getData());
        const outHwc: boolean = outputs[0].shape.length === 4 && outputs[0].shape[3] === 3;
        SuperResEngine.accumulate(out, outHwc, xs[xi] * 2, ys[yi] * 2, ow, oh, sum, weight);
      }
    }
    const result: Uint8Array = new Uint8Array(ow * oh * 4);
    for (let i = 0; i < ow * oh; i++) {
      const w: number = weight[i] > 0 ? weight[i] : 1;
      result[i * 4] = SuperResEngine.byte(sum[i * 3] / w);
      result[i * 4 + 1] = SuperResEngine.byte(sum[i * 3 + 1] / w);
      result[i * 4 + 2] = SuperResEngine.byte(sum[i * 3 + 2] / w);
      result[i * 4 + 3] = 255;
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

  private static accumulate(out: Float32Array, hwc: boolean, x0: number, y0: number,
    width: number, height: number, sum: Float32Array, weight: Float32Array): void {
    const tileOut: number = SuperResEngine.TILE * 2;
    for (let y = 0; y < tileOut; y++) {
      const oy: number = y0 + y;
      if (oy >= height) {
        continue;
      }
      for (let x = 0; x < tileOut; x++) {
        const ox: number = x0 + x;
        if (ox >= width) {
          continue;
        }
        const srcPixel: number = y * tileOut + x;
        const di: number = oy * width + ox;
        const plane: number = tileOut * tileOut;
        const r: number = hwc ? out[srcPixel * 3] : out[srcPixel];
        const g: number = hwc ? out[srcPixel * 3 + 1] : out[plane + srcPixel];
        const b: number = hwc ? out[srcPixel * 3 + 2] : out[plane * 2 + srcPixel];
        sum[di * 3] += r;
        sum[di * 3 + 1] += g;
        sum[di * 3 + 2] += b;
        weight[di] += 1;
      }
    }
  }

  private static byte(value: number): number {
    return Math.max(0, Math.min(255, Math.round(value * 255)));
  }
}
