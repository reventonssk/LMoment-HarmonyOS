/**
 * 3D LUT 查表引擎（移植自 AlexaLut.java）。
 *
 * bin 布局：float32 LE，data[ch][b][g][r]，ch = 输出通道 R/G/B 各占 dim³ 平面。
 * dim 由文件长度反推（len/12 的立方根），33³ / 65³ / 17³ 混用。
 * binsize = 1.0001/(dim-1)，与烘焙脚本口径一致。
 */

export class Lut3D {
  readonly data: Float32Array;
  readonly dim: number;
  private readonly dim2: number;
  private readonly shift: number;
  private readonly binsize: number;
  private static leCache: number = -1;

  constructor(data: Float32Array, dim: number) {
    this.data = data;
    this.dim = dim;
    this.dim2 = dim * dim;
    this.shift = this.dim2 * dim;
    this.binsize = 1.0001 / (dim - 1);
  }

  static decode(bytes: Uint8Array): Lut3D | undefined {
    const len = bytes.byteLength;
    if (len < 24 || len % 12 !== 0) {
      return undefined;
    }
    const points = len / 12;
    const dim = Math.round(Math.pow(points, 1.0 / 3.0));
    if (dim < 2 || dim > 256 || dim * dim * dim !== points) {
      return undefined;
    }
    const src = new Uint8Array(points * 12);
    src.set(bytes);
    let floats: Float32Array;
    if (Lut3D.isLittleEndian()) {
      floats = new Float32Array(src.buffer);
    } else {
      const dv = new DataView(src.buffer);
      floats = new Float32Array(points * 3);
      let o = 0;
      for (let i = 0; i < floats.length; i++) {
        floats[i] = dv.getFloat32(o, true);
        o += 4;
      }
    }
    for (let i = 0; i < floats.length; i++) {
      const v = floats[i];
      if (!(v >= -0.1 && v <= 1.1)) {
        return undefined;
      }
    }
    return new Lut3D(floats, dim);
  }

  /** 三线性插值查表，原地改写 RGBA 字节流（px.length 必须是 4 的倍数）。 */
  applyPx(px: Uint8Array): void {
    const d = this.data;
    const dim = this.dim;
    const dim2 = this.dim2;
    const shift = this.shift;
    const last = dim - 2;
    const bs = this.binsize;
    const n = px.length;
    for (let i4 = 0; i4 + 3 < n; i4 += 4) {
      const r = px[i4] / 255;
      const g = px[i4 + 1] / 255;
      const b = px[i4 + 2] / 255;

      let ri = Math.floor(r / bs);
      let gi = Math.floor(g / bs);
      let bi = Math.floor(b / bs);
      if (ri > last) {
        ri = last;
      }
      if (gi > last) {
        gi = last;
      }
      if (bi > last) {
        bi = last;
      }

      let rd = (r % bs) / bs;
      let gd = (g % bs) / bs;
      let bd = (b % bs) / bs;
      if (rd < 0) {
        rd = 0;
      } else if (rd > 1) {
        rd = 1;
      }
      if (gd < 0) {
        gd = 0;
      } else if (gd > 1) {
        gd = 1;
      }
      if (bd < 0) {
        bd = 0;
      } else if (bd > 1) {
        bd = 1;
      }

      const w000 = (1 - rd) * (1 - gd) * (1 - bd);
      const w100 = rd * (1 - gd) * (1 - bd);
      const w010 = (1 - rd) * gd * (1 - bd);
      const w110 = rd * gd * (1 - bd);
      const w001 = (1 - rd) * (1 - gd) * bd;
      const w101 = rd * (1 - gd) * bd;
      const w011 = (1 - rd) * gd * bd;
      const w111 = rd * gd * bd;

      const b00 = bi * dim2 + gi * dim + ri;

      let idx = b00;
      const orv = w000 * d[idx] + w100 * d[idx + 1]
        + w010 * d[idx + dim] + w110 * d[idx + dim + 1]
        + w001 * d[idx + dim2] + w101 * d[idx + dim2 + 1]
        + w011 * d[idx + dim2 + dim] + w111 * d[idx + dim2 + dim + 1];

      idx = shift + b00;
      const og = w000 * d[idx] + w100 * d[idx + 1]
        + w010 * d[idx + dim] + w110 * d[idx + dim + 1]
        + w001 * d[idx + dim2] + w101 * d[idx + dim2 + 1]
        + w011 * d[idx + dim2 + dim] + w111 * d[idx + dim2 + dim + 1];

      idx = shift * 2 + b00;
      const ob = w000 * d[idx] + w100 * d[idx + 1]
        + w010 * d[idx + dim] + w110 * d[idx + dim + 1]
        + w001 * d[idx + dim2] + w101 * d[idx + dim2 + 1]
        + w011 * d[idx + dim2 + dim] + w111 * d[idx + dim2 + dim + 1];

      px[i4] = Lut3D.clamp255(orv);
      px[i4 + 1] = Lut3D.clamp255(og);
      px[i4 + 2] = Lut3D.clamp255(ob);
    }
  }

  static clamp255(v: number): number {
    const i = Math.floor(v * 255 + 0.5);
    if (i < 0) {
      return 0;
    }
    if (i > 255) {
      return 255;
    }
    return i;
  }

  private static isLittleEndian(): boolean {
    if (Lut3D.leCache < 0) {
      const buf = new ArrayBuffer(4);
      const u8 = new Uint8Array(buf);
      u8[0] = 0;
      u8[1] = 0;
      u8[2] = 0x80;
      u8[3] = 0x3f;
      Lut3D.leCache = new Float32Array(buf)[0] === 1.0 ? 1 : 0;
    }
    return Lut3D.leCache === 1;
  }
}
