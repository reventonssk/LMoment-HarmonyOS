/**
 * 模型色彩持久化（Batch H）：filesDir/model_colors.txt。
 *
 * v2 行（制表符分隔，首列标记 MC2）：
 *   MC2 \t name \t currentIdx \t versionCount \t refCount
 *   每版本 6 列：id \t label \t createdAt \t seedCount \t affCSV(12) \t knotsCSV(27)
 *   再 3 列：embCSV(refCount*36) \t fpCSV(refCount*2) \t chromaCSV(refCount)
 *
 * emb = stage1 逐参考 36 维指纹，供增强时与新增参考重新聚合；
 * fp = dHash [hi,lo]（查重/淘汰），chroma = 逐参考平均色度（黑白门限）。
 * v1 行（name\taffCSV\tknotsCSV）读取时升级为单版本、空参考池：
 * 此时增强退化为仅用新参考拟合（旧统计量不可复现），行为可预期。
 * 模型链要求图像相关的 neutralize，不能烘焙进静态 LUT，故直接存网络输出的
 * aff/knots，预览/导出时经 ModelColorMath.apply 施加。全同步 IO，量小。
 */

import { fileIo as fs } from '@kit.CoreFileKit';

/** 一个模型色彩版本：aff/knots 快照 + 产生它时的参考前缀张数。 */
export class McVersion {
  readonly id: string;
  readonly label: string;
  readonly createdAt: number;
  readonly aff: Float32Array;
  readonly knots: Float32Array;
  readonly seedCount: number;

  constructor(id: string, label: string, createdAt: number,
    aff: Float32Array, knots: Float32Array, seedCount: number) {
    this.id = id;
    this.label = label;
    this.createdAt = createdAt;
    this.aff = aff;
    this.knots = knots;
    this.seedCount = seedCount;
  }
}

/** 一条已保存的模型色彩：版本链 + 增强用参考指纹池。 */
export class ModelColorEntry {
  name: string;
  versions: McVersion[];
  currentIdx: number;
  /** stage1 逐参考指纹（refCount*36，row-major）。 */
  embs: Float32Array;
  /** dHash [hi,lo] 平铺（refCount*2，无符号 32 位存 number）。 */
  fps: number[];
  /** 逐参考平均色度（refCount）。 */
  chroma: number[];

  constructor(name: string, versions: McVersion[], currentIdx: number,
    embs: Float32Array, fps: number[], chroma: number[]) {
    this.name = name;
    this.versions = versions;
    this.currentIdx = currentIdx;
    this.embs = embs;
    this.fps = fps;
    this.chroma = chroma;
  }

  /** 参考池张数。 */
  refCount(): number {
    return Math.floor(this.embs.length / 36);
  }

  /** 当前版本（currentIdx 越界时钳制；构造保证至少一个版本）。 */
  current(): McVersion {
    const i = Math.min(Math.max(this.currentIdx, 0), this.versions.length - 1);
    return this.versions[i];
  }
}

export class ModelColorStore {
  private static readonly FILE: string = 'model_colors.txt';
  private static readonly MARK: string = 'MC2';

  /** 读取全部条目；文件不存在或损坏返回空表（逐行容错跳过）。 */
  static load(dir: string): ModelColorEntry[] {
    const path = `${dir}/${ModelColorStore.FILE}`;
    const out: ModelColorEntry[] = [];
    try {
      if (!fs.accessSync(path)) {
        return out;
      }
      const txt = fs.readTextSync(path);
      const lines = txt.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (line.length === 0) {
          continue;
        }
        const entry = ModelColorStore.parseLine(line);
        if (entry !== undefined) {
          out.push(entry);
        }
      }
    } catch (e) {
      // 读取失败视为空库
    }
    return out;
  }

  /** 全量覆写保存（v1 行同步升级为 v2）；返回是否成功。 */
  static save(dir: string, entries: ModelColorEntry[]): boolean {
    try {
      const lines: string[] = [];
      for (let i = 0; i < entries.length; i++) {
        lines.push(ModelColorStore.serialize(entries[i]));
      }
      const path = `${dir}/${ModelColorStore.FILE}`;
      const file = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, lines.join('\n'));
      } finally {
        fs.closeSync(file);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  private static serialize(e: ModelColorEntry): string {
    const fields: string[] = [];
    fields.push(ModelColorStore.MARK);
    fields.push(e.name.replace(/\t/g, ' '));
    fields.push(`${e.currentIdx}`);
    fields.push(`${e.versions.length}`);
    fields.push(`${e.refCount()}`);
    for (let i = 0; i < e.versions.length; i++) {
      const v = e.versions[i];
      fields.push(v.id.replace(/\t/g, ' '));
      fields.push(v.label.replace(/\t/g, ' '));
      fields.push(`${v.createdAt}`);
      fields.push(`${v.seedCount}`);
      fields.push(ModelColorStore.floatCsv(v.aff));
      fields.push(ModelColorStore.floatCsv(v.knots));
    }
    fields.push(ModelColorStore.floatCsv(e.embs));
    fields.push(ModelColorStore.intCsv(e.fps));
    fields.push(ModelColorStore.chromaCsv(e.chroma));
    return fields.join('\t');
  }

  private static parseLine(line: string): ModelColorEntry | undefined {
    const parts = line.split('\t');
    if (parts.length >= 5 && parts[0] === ModelColorStore.MARK) {
      return ModelColorStore.parseV2(parts);
    }
    if (parts.length >= 3 && parts[0] !== ModelColorStore.MARK) {
      // v1 兼容：单版本、空参考池
      const aff = ModelColorStore.parseFloatCsv(parts[1]);
      const knots = ModelColorStore.parseFloatCsv(parts[2]);
      if (aff === undefined || knots === undefined || aff.length !== 12 || knots.length !== 27) {
        return undefined;
      }
      const v = new McVersion('v1', '初始', 0, aff, knots, 0);
      return new ModelColorEntry(parts[0], [v], 0, new Float32Array(0), [], []);
    }
    return undefined;
  }

  /** v2 解析：逐版本/逐池字段容错，版本全坏才丢条目；池坏退空池（增强降级）。 */
  private static parseV2(parts: string[]): ModelColorEntry | undefined {
    const name = parts[1].trim();
    const currentIdx = Number(parts[2]);
    const vcount = Number(parts[3]);
    const refCount = Number(parts[4]);
    if (name.length === 0 || !ModelColorStore.isCount(vcount) ||
      !ModelColorStore.isCount(refCount)) {
      return undefined;
    }
    let p = 5;
    const versions: McVersion[] = [];
    for (let i = 0; i < vcount; i++) {
      if (p + 6 > parts.length) {
        break;
      }
      const id = parts[p].trim();
      const label = parts[p + 1].trim();
      const createdAt = Number(parts[p + 2]);
      const seedCount = Number(parts[p + 3]);
      const aff = ModelColorStore.parseFloatCsv(parts[p + 4]);
      const knots = ModelColorStore.parseFloatCsv(parts[p + 5]);
      p += 6;
      if (id.length === 0 || !isFinite(createdAt) || !isFinite(seedCount) ||
        aff === undefined || knots === undefined || aff.length !== 12 || knots.length !== 27) {
        continue;
      }
      versions.push(new McVersion(id, label, createdAt, aff, knots,
        seedCount > 0 ? Math.floor(seedCount) : 0));
    }
    if (versions.length === 0) {
      return undefined;
    }
    let embs = new Float32Array(0);
    if (p < parts.length) {
      const e = ModelColorStore.parseFloatCsv(parts[p]);
      if (e !== undefined && e.length === refCount * 36) {
        embs = e;
      }
    }
    p++;
    const fps: number[] = [];
    if (p < parts.length) {
      const f = ModelColorStore.parseIntCsv(parts[p], refCount * 2);
      if (f !== undefined) {
        for (let i = 0; i < f.length; i++) {
          fps.push(f[i]);
        }
      }
    }
    p++;
    const chroma: number[] = [];
    if (p < parts.length) {
      const cc = ModelColorStore.parseFloatCsv(parts[p]);
      if (cc !== undefined && cc.length === refCount) {
        for (let i = 0; i < cc.length; i++) {
          chroma.push(cc[i]);
        }
      }
    }
    const ci = Math.min(Math.max(ModelColorStore.isCount(currentIdx) ? currentIdx : 0, 0),
      versions.length - 1);
    return new ModelColorEntry(name, versions, ci, embs, fps, chroma);
  }

  /** 非负整数（vcount/refCount/currentIdx 校验）。 */
  private static isCount(v: number): boolean {
    return isFinite(v) && v >= 0 && Math.floor(v) === v;
  }

  private static floatCsv(a: Float32Array): string {
    const out: string[] = [];
    for (let i = 0; i < a.length; i++) {
      out.push(a[i].toFixed(6));
    }
    return out.join(',');
  }

  private static intCsv(a: number[]): string {
    const out: string[] = [];
    for (let i = 0; i < a.length; i++) {
      out.push(`${Math.round(a[i])}`);
    }
    return out.join(',');
  }

  private static chromaCsv(a: number[]): string {
    const out: string[] = [];
    for (let i = 0; i < a.length; i++) {
      out.push(a[i].toFixed(4));
    }
    return out.join(',');
  }

  private static parseFloatCsv(csv: string): Float32Array | undefined {
    if (csv.length === 0) {
      return undefined;
    }
    const parts = csv.split(',');
    const out = new Float32Array(parts.length);
    for (let i = 0; i < parts.length; i++) {
      const v = parseFloat(parts[i]);
      if (isNaN(v)) {
        return undefined;
      }
      out[i] = v;
    }
    return out;
  }

  /** 整数 CSV（dHash 半字，值域 0..2^32-1，Float32 存不下须走 number[]）。 */
  private static parseIntCsv(csv: string, expect: number): number[] | undefined {
    if (csv.length === 0 || expect <= 0) {
      return undefined;
    }
    const parts = csv.split(',');
    if (parts.length !== expect) {
      return undefined;
    }
    const out: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const v = Number(parts[i]);
      if (isNaN(v)) {
        return undefined;
      }
      out.push(v);
    }
    return out;
  }
}
