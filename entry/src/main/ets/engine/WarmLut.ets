/**
 * 暖调参数 bin（leica_filter_param_*_snapshot.bin）解析与触发应用。
 *
 * bin 布局（对齐 leicafilter.py 权威参考）：
 * 0x000 u16 n_scene、u16 scene_size[n]（字节）、u16 param_off、u16 lut_off、
 *        u16 lut_size(17)、u16 n_zoom、u16 zoom_size[n]（字节）；
 * 0x020 char trigger[256]；0x120 char param_type[256]；0x220 char param_range[256]；
 * 0x320 char version[64]；0x360 u16×4 使能位；
 * param_off 起每 scene{char name[64]; u16 n_lux; lux×{lo,hi,n_cct; cct×{lo,hi,idx}}}；
 * 之后每 zoom{f32 zoom; 同构树}；
 * lut_off 起 n_lut×u8[17][17][17][3]（索引 [r][g][b]，texel=(B,G,R)）；
 * 尾部 n_shading×f32[8]（start,end,coordScale,valueScale,k,b,v,t）。
 *
 * 应用链 = 17³ LUT 三线性 + CvStyle 暗角（单遍 float，最终一次量化，≤1LSB 偏差）。
 */

import { yieldUI } from './PixAsync';

class CctBin {
  lo: number = 0;
  hi: number = 0;
  idx: number = 0;
}

class LuxBin {
  lo: number = 0;
  hi: number = 0;
  ccts: CctBin[] = [];
}

class ZoomTree {
  z: number = 0;
  tree: LuxBin[] = [];
}

export class WarmBin {
  readonly lutN: number;
  readonly nLut: number;
  readonly nSh: number;
  readonly lutOff: number;
  readonly data: Uint8Array;
  readonly shading: Float32Array;
  readonly scenes: Map<string, LuxBin[]> = new Map();
  readonly zooms: ZoomTree[] = [];

  constructor(data: Uint8Array) {
    if (data.length < 0x368) {
      throw new Error('warm bin too small');
    }
    const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const nScene = dv.getUint16(0, true);
    if (nScene < 1 || nScene > 64) {
      throw new Error('warm bin bad scene count');
    }
    const sceneSizes: number[] = [];
    for (let i = 0; i < nScene; i++) {
      sceneSizes.push(dv.getUint16(2 + 2 * i, true));
    }
    let p = 2 + 2 * nScene;
    const paramOff = dv.getUint16(p, true);
    const lutOff = dv.getUint16(p + 2, true);
    const lutN = dv.getUint16(p + 4, true);
    const nZoom = dv.getUint16(p + 6, true);
    if (lutN < 2 || lutN > 65) {
      throw new Error('warm bin bad lut size');
    }
    const zoomSizes: number[] = [];
    for (let i = 0; i < nZoom; i++) {
      zoomSizes.push(dv.getUint16(p + 8 + 2 * i, true));
    }
    let off = paramOff;
    let nLut = 0;
    for (let s = 0; s < nScene; s++) {
      const sz = sceneSizes[s];
      if (sz < 66 || off + sz > data.length) {
        throw new Error('warm bin scene overflow');
      }
      const name = WarmBin.readName(data, off);
      const tree = WarmBin.readTree(dv, off + 64, off + sz);
      this.scenes.set(name, tree);
      for (let i = 0; i < tree.length; i++) {
        const ccts = tree[i].ccts;
        for (let j = 0; j < ccts.length; j++) {
          if (ccts[j].idx >= nLut) {
            nLut = ccts[j].idx + 1;
          }
        }
      }
      off += sz;
    }
    let nSh = 0;
    for (let z = 0; z < nZoom; z++) {
      const sz = zoomSizes[z];
      if (sz < 6 || off + sz > data.length) {
        throw new Error('warm bin zoom overflow');
      }
      const zt = new ZoomTree();
      zt.z = dv.getFloat32(off, true);
      zt.tree = WarmBin.readTree(dv, off + 4, off + sz);
      this.zooms.push(zt);
      for (let i = 0; i < zt.tree.length; i++) {
        const ccts = zt.tree[i].ccts;
        for (let j = 0; j < ccts.length; j++) {
          if (ccts[j].idx >= nSh) {
            nSh = ccts[j].idx + 1;
          }
        }
      }
      off += sz;
    }
    this.zooms.sort((a: ZoomTree, b: ZoomTree): number => a.z - b.z);
    const lutBytes = lutN * lutN * lutN * 3;
    const shadingOff = lutOff + nLut * lutBytes;
    if (nLut < 1 || nSh < 1 || shadingOff + nSh * 32 !== data.length) {
      throw new Error('warm bin size mismatch');
    }
    this.lutN = lutN;
    this.nLut = nLut;
    this.nSh = nSh;
    this.lutOff = lutOff;
    this.data = data;
    this.shading = new Float32Array(nSh * 8);
    for (let i = 0; i < nSh * 8; i++) {
      this.shading[i] = dv.getFloat32(shadingOff + 4 * i, true);
    }
  }

  private static readName(data: Uint8Array, off: number): string {
    let end = off;
    const lim = off + 64 < data.length ? off + 64 : data.length;
    while (end < lim && data[end] !== 0) {
      end++;
    }
    let s = '';
    for (let i = off; i < end; i++) {
      s += String.fromCharCode(data[i]);
    }
    return s.trim();
  }

  private static readTree(dv: DataView, pos: number, end: number): LuxBin[] {
    const out: LuxBin[] = [];
    if (pos + 2 > end) {
      throw new Error('warm bin tree overflow');
    }
    const nLux = dv.getUint16(pos, true);
    pos += 2;
    for (let i = 0; i < nLux; i++) {
      if (pos + 6 > end) {
        throw new Error('warm bin tree overflow');
      }
      const lb = new LuxBin();
      lb.lo = dv.getUint16(pos, true);
      lb.hi = dv.getUint16(pos + 2, true);
      const nCct = dv.getUint16(pos + 4, true);
      pos += 6;
      if (pos + 6 * nCct > end) {
        throw new Error('warm bin tree overflow');
      }
      for (let j = 0; j < nCct; j++) {
        const cb = new CctBin();
        cb.lo = dv.getUint16(pos, true);
        cb.hi = dv.getUint16(pos + 2, true);
        cb.idx = dv.getUint16(pos + 4, true);
        pos += 6;
        lb.ccts.push(cb);
      }
      out.push(lb);
    }
    return out;
  }
}

class Corner {
  idx: number = 0;
  w: number = 0;
}

export class WarmApplier {
  readonly lutN: number;
  private lutF: Float32Array;
  private sh: Float32Array;

  constructor(bin: WarmBin, scene: string, lux: number, cct: number, zoom: number) {
    this.lutN = bin.lutN;
    let tree = bin.scenes.get(scene);
    if (tree === undefined) {
      tree = bin.scenes.get('common');
    }
    if (tree === undefined) {
      throw new Error('warm bin has no scene tree');
    }
    const lutCorners = WarmApplier.corners(tree, lux, cct);
    const order: number[] = [];
    const acc: number[] = [];
    for (let i = 0; i < lutCorners.length; i++) {
      const idx = lutCorners[i].idx;
      const w = lutCorners[i].w;
      let k = -1;
      for (let j = 0; j < order.length; j++) {
        if (order[j] === idx) {
          k = j;
          break;
        }
      }
      if (k < 0) {
        order.push(idx);
        acc.push(w);
      } else {
        acc[k] += w;
      }
    }
    const lb = bin.lutN * bin.lutN * bin.lutN * 3;
    const src = bin.data;
    const lut = new Uint8Array(lb);
    if (order.length === 1) {
      const base = bin.lutOff + order[0] * lb;
      if (base + lb > src.length) {
        throw new Error('warm lut out of range');
      }
      for (let j = 0; j < lb; j++) {
        lut[j] = src[base + j];
      }
    } else {
      for (let i = 0; i < order.length; i++) {
        if (bin.lutOff + order[i] * lb + lb > src.length) {
          throw new Error('warm lut out of range');
        }
      }
      for (let j = 0; j < lb; j++) {
        let s = 0;
        for (let i = 0; i < order.length; i++) {
          s += acc[i] * src[bin.lutOff + order[i] * lb + j];
        }
        lut[j] = s < 0 ? 0 : (s > 255 ? 255 : Math.floor(s));
      }
    }
    this.lutF = new Float32Array(lb);
    for (let j = 0; j < lb; j += 3) {
      this.lutF[j] = lut[j + 2] / 255;
      this.lutF[j + 1] = lut[j + 1] / 255;
      this.lutF[j + 2] = lut[j] / 255;
    }
    let zt: ZoomTree | undefined = undefined;
    for (let i = 0; i < bin.zooms.length; i++) {
      if (zoom >= bin.zooms[i].z) {
        zt = bin.zooms[i];
      }
    }
    if (zt === undefined) {
      zt = bin.zooms[0];
    }
    const shCorners = WarmApplier.corners(zt.tree, lux, cct);
    this.sh = new Float32Array(8);
    for (let i = 0; i < shCorners.length; i++) {
      const idx = shCorners[i].idx;
      if (idx < 0 || idx >= bin.nSh) {
        continue;
      }
      const w = shCorners[i].w;
      for (let k = 0; k < 8; k++) {
        this.sh[k] += w * bin.shading[idx * 8 + k];
      }
    }
  }

  /** 原地暖调（LUT 三线性 + CvStyle），RGBA 字节流。 */
  async apply(px: Uint8Array, w: number, h: number, timeMs: number): Promise<void> {
    const n = this.lutN;
    const nm1 = n - 1;
    const nm2 = n - 2;
    const lutF = this.lutF;
    const start = this.sh[0];
    const end = this.sh[1];
    const cs = this.sh[2];
    const vs = this.sh[3];
    const kPar = this.sh[4];
    const bPar = this.sh[5];
    const vPar = this.sh[6];
    const tPar = this.sh[7];
    const invRange = 1 / (end - start);
    const tt = timeMs / 200;
    const cvals: number[] = [0.07, 0.11, 0.13, 0.17, 0.19, 0.23];
    const cArr = new Float64Array(6);
    for (let i = 0; i < 6; i++) {
      cArr[i] = cvals[i] * tt * (12.9898 + 78.233);
    }
    const ratio = w / h;
    const uxArr = new Float64Array(w);
    const aArr = new Float64Array(w);
    for (let x = 0; x < w; x++) {
      const uvx = ((x + 0.5) / w - 0.5) * ratio + 0.5;
      const ux = uvx - 0.5;
      uxArr[x] = ux;
      aArr[x] = (ux - 0.5) * 12.9898;
    }
    const uyArr = new Float64Array(h);
    const bArr = new Float64Array(h);
    for (let y = 0; y < h; y++) {
      const uy = (y + 0.5) / h - 0.5;
      uyArr[y] = uy;
      bArr[y] = (uy - 0.5) * 78.233;
    }
    const stepR = n * n * 3;
    const stepG = n * 3;
    const scale = nm1 / 255;
    const rowsPerChunk = 262144 / w > 1 ? Math.floor(262144 / w) : 1;
    for (let y0 = 0; y0 < h; y0 += rowsPerChunk) {
      const y1 = y0 + rowsPerChunk < h ? y0 + rowsPerChunk : h;
      for (let y = y0; y < y1; y++) {
        const uy = uyArr[y];
        const by = bArr[y];
        let i = y * w * 4;
        for (let x = 0; x < w; x++, i += 4) {
          const fx = px[i] * scale;
          const fy = px[i + 1] * scale;
          const fz = px[i + 2] * scale;
          const ir = fx | 0;
          const ig = fy | 0;
          const ib = fz | 0;
          const r0i = ir > nm2 ? nm2 : ir;
          const g0i = ig > nm2 ? nm2 : ig;
          const b0i = ib > nm2 ? nm2 : ib;
          const fr = fx - ir;
          const fg = fy - ig;
          const fb = fz - ib;
          const fbase = ((r0i * n + g0i) * n + b0i) * 3;
          const wfr = 1 - fr;
          const wfg = 1 - fg;
          const wfb = 1 - fb;
          const w000 = wfr * wfg * wfb;
          const w001 = wfr * wfg * fb;
          const w010 = wfr * fg * wfb;
          const w011 = wfr * fg * fb;
          const w100 = fr * wfg * wfb;
          const w101 = fr * wfg * fb;
          const w110 = fr * fg * wfb;
          const w111 = fr * fg * fb;
          const o000 = fbase;
          const o001 = fbase + 3;
          const o010 = fbase + stepG;
          const o011 = fbase + stepG + 3;
          const o100 = fbase + stepR;
          const o101 = fbase + stepR + 3;
          const o110 = fbase + stepR + stepG;
          const o111 = fbase + stepR + stepG + 3;
          let R = w000 * lutF[o000] + w001 * lutF[o001] + w010 * lutF[o010] + w011 * lutF[o011] +
            w100 * lutF[o100] + w101 * lutF[o101] + w110 * lutF[o110] + w111 * lutF[o111];
          let G = w000 * lutF[o000 + 1] + w001 * lutF[o001 + 1] + w010 * lutF[o010 + 1] + w011 * lutF[o011 + 1] +
            w100 * lutF[o100 + 1] + w101 * lutF[o101 + 1] + w110 * lutF[o110 + 1] + w111 * lutF[o111 + 1];
          let B = w000 * lutF[o000 + 2] + w001 * lutF[o001 + 2] + w010 * lutF[o010 + 2] + w011 * lutF[o011 + 2] +
            w100 * lutF[o100 + 2] + w101 * lutF[o101 + 2] + w110 * lutF[o110 + 2] + w111 * lutF[o111 + 2];
          const ux = uxArr[x];
          let dist = Math.sqrt(ux * ux + uy * uy);
          const axv = aArr[x];
          let rnd = 0;
          for (let ci = 0; ci < 6; ci++) {
            const sv = Math.sin(axv + by + cArr[ci]) * 43758.5453;
            rnd += sv - Math.floor(sv);
          }
          dist += 0.04 * (rnd / 6) * cs;
          let sS = (dist - start) * invRange;
          sS = sS < 0 ? 0 : (sS > 1 ? 1 : sS);
          const vig0 = sS * sS * (3 - 2 * sS);
          const L = 0.499 * R + 0.387 * G + 0.114 * B;
          const Y = 0.299 * R + 0.587 * G + 0.114 * B;
          const pf = vPar / (1 + Math.exp(kPar * (bPar - L))) + tPar;
          let vig = (1 - pf) * vig0 + pf;
          vig *= vs;
          const delta = Y * (vig - 1);
          R += delta;
          G += delta;
          B += delta;
          px[i] = R <= 0 ? 0 : (R >= 1 ? 255 : (R * 255 + 0.5) | 0);
          px[i + 1] = G <= 0 ? 0 : (G >= 1 ? 255 : (G * 255 + 0.5) | 0);
          px[i + 2] = B <= 0 ? 0 : (B >= 1 ? 255 : (B * 255 + 0.5) | 0);
        }
      }
      await yieldUI();
    }
  }

  private static corners(tree: LuxBin[], lux: number, cct: number): Corner[] {
    const le = WarmApplier.findLux(tree, lux);
    const a = WarmApplier.frac(lux, le[0].hi, le[1].lo);
    const ce = WarmApplier.findCct(le[0].ccts, cct);
    const b = WarmApplier.frac(cct, ce[0].hi, ce[1].lo);
    const de = WarmApplier.findCct(le[1].ccts, cct);
    const c = WarmApplier.frac(cct, de[0].hi, de[1].lo);
    const out: Corner[] = [];
    WarmApplier.pushCorner(out, ce[0].idx, (1 - a) * (1 - b));
    WarmApplier.pushCorner(out, ce[1].idx, (1 - a) * b);
    WarmApplier.pushCorner(out, de[0].idx, a * (1 - c));
    WarmApplier.pushCorner(out, de[1].idx, a * c);
    return out;
  }

  private static pushCorner(out: Corner[], idx: number, w: number): void {
    const cc = new Corner();
    cc.idx = idx;
    cc.w = w;
    out.push(cc);
  }

  private static frac(v: number, eHi: number, pLo: number): number {
    const den = pLo - eHi;
    return den !== 0 ? (v - eHi) / den : 0;
  }

  private static findLux(bins: LuxBin[], v: number): LuxBin[] {
    const out: LuxBin[] = [];
    if (bins.length === 0) {
      throw new Error('warm bin empty lux bins');
    }
    for (let i = 0; i < bins.length; i++) {
      const bb = bins[i];
      if (v <= bb.hi) {
        if (v >= bb.lo || i === 0) {
          out.push(bb);
          out.push(bb);
        } else {
          out.push(bins[i - 1]);
          out.push(bb);
        }
        return out;
      }
    }
    const last = bins[bins.length - 1];
    out.push(last);
    out.push(last);
    return out;
  }

  private static findCct(bins: CctBin[], v: number): CctBin[] {
    const out: CctBin[] = [];
    if (bins.length === 0) {
      throw new Error('warm bin empty cct bins');
    }
    for (let i = 0; i < bins.length; i++) {
      const bb = bins[i];
      if (v <= bb.hi) {
        if (v >= bb.lo || i === 0) {
          out.push(bb);
          out.push(bb);
        } else {
          out.push(bins[i - 1]);
          out.push(bb);
        }
        return out;
      }
    }
    const last = bins[bins.length - 1];
    out.push(last);
    out.push(last);
    return out;
  }
}
