/**
 * 自定义色彩分享码（移植自 ColorShareCode.kt）。
 *
 * 文本形态：`LMC1.` 前缀 + Base64Url(gzip(body))，无 padding。
 * 二进制布局（头部与 steps 大端；LUT 载荷原始字节）：
 *   0..3 "LMC1" int32 BE | 4 format | 5 mode(1=LUT) | 6 dim | 7 flags(bit1 差分)
 *   8..11 crc32 int32 BE | 12..13 thumbLen | 14..15 nameLen | 16..17 seedCount
 *   18 stepCount | 19 reserved | name UTF-8 | thumb | seeds | steps | lut
 * 与 Android 端生成的码完全互通。
 */

import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';

export class CodePayload {
  mode: number = 0;
  dim: number = 0;
  crc: number = 0;
  name: string = '';
  lut: Uint8Array | undefined = undefined;
}

export class ColorCode {
  static readonly PREFIX: string = 'LMC1.';
  static readonly LUT_DIM: number = 17;
  private static readonly MAGIC: number = 0x4C4D4331;
  private static readonly FORMAT: number = 2;
  private static readonly MAX_SEEDS: number = 64;
  private static readonly MAX_STEPS: number = 12;
  private static readonly MAX_NAME_LEN: number = 48;
  private static readonly SEED_BYTES: number = 8 + 200 * 4;
  private static crcTable: Int32Array | undefined = undefined;

  /** 标准 CRC32（IEEE 802.3），返回无符号 32 位。 */
  static crc32(bytes: Uint8Array): number {
    let table = ColorCode.crcTable;
    if (table === undefined) {
      table = new Int32Array(256);
      for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) {
          c = (c & 1) !== 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        }
        table[n] = c;
      }
      ColorCode.crcTable = table;
    }
    let crc = -1;
    for (let i = 0; i < bytes.byteLength; i++) {
      crc = (crc >>> 8) ^ table[(crc ^ bytes[i]) & 0xFF];
    }
    return (crc ^ -1) >>> 0;
  }

  /** 轻量码：17³ 量化 LUT（R 轴差分 + gzip），稳定约 6.3 KB 字符。 */
  static async encodeCompact(name: string, bin: Uint8Array): Promise<string | undefined> {
    const lut = ColorCode.toLut17(bin);
    if (lut === undefined) {
      return undefined;
    }
    const inflate = ColorCode.inflateLut(lut, ColorCode.LUT_DIM);
    if (inflate === undefined) {
      return undefined;
    }
    const safeName = name.length > ColorCode.MAX_NAME_LEN
      ? name.substring(0, ColorCode.MAX_NAME_LEN) : name;
    const nameBytes = new util.TextEncoder().encodeInto(safeName);
    if (nameBytes.byteLength > 0xFFFF) {
      return undefined;
    }
    const delta = ColorCode.deltaEncode(lut, ColorCode.LUT_DIM);
    const bodyLen = 20 + nameBytes.byteLength + 5 + delta.byteLength;
    const body = new Uint8Array(bodyLen);
    const dv = new DataView(body.buffer);
    dv.setInt32(0, ColorCode.MAGIC);
    dv.setUint8(4, ColorCode.FORMAT);
    dv.setUint8(5, 1);
    dv.setUint8(6, ColorCode.LUT_DIM);
    dv.setUint8(7, 2);
    dv.setInt32(8, ColorCode.crc32(inflate) | 0);
    dv.setUint16(12, 0);
    dv.setUint16(14, nameBytes.byteLength);
    dv.setUint16(16, 0);
    dv.setUint8(18, 1);
    dv.setUint8(19, 0);
    body.set(nameBytes, 20);
    const stepOff = 20 + nameBytes.byteLength;
    dv.setUint8(stepOff, 0);
    dv.setFloat32(stepOff + 1, 1.0);
    body.set(delta, stepOff + 5);
    const gz = await ColorCode.gzip(body);
    if (gz === undefined) {
      return undefined;
    }
    let code = new util.Base64Helper().encodeToStringSync(gz, util.Type.BASIC_URL_SAFE);
    while (code.endsWith('=')) {
      code = code.substring(0, code.length - 1);
    }
    return ColorCode.PREFIX + code;
  }

  /** 从任意文本里抽出指令（容错引导语/中文混排）。 */
  static extractPayload(text: string): string | undefined {
    const start = text.indexOf(ColorCode.PREFIX);
    if (start < 0) {
      return undefined;
    }
    let end = start + ColorCode.PREFIX.length;
    while (end < text.length) {
      const c = text.charAt(end);
      const ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
        || (c >= '0' && c <= '9') || c === '-' || c === '_';
      if (ok) {
        end++;
      } else {
        break;
      }
    }
    if (end - start - ColorCode.PREFIX.length < 24) {
      return undefined;
    }
    return text.substring(start + ColorCode.PREFIX.length, end);
  }

  /** 解码指令。仅支持 LUT 模式（配方码需参考图指纹，返回 undefined 由上层提示）。 */
  static async decode(text: string): Promise<CodePayload | undefined> {
    const code = ColorCode.extractPayload(text);
    if (code === undefined) {
      return undefined;
    }
    const rem = code.length % 4;
    if (rem === 1) {
      return undefined;
    }
    let padded = code;
    if (rem === 2) {
      padded = code + '==';
    } else if (rem === 3) {
      padded = code + '=';
    }
    let gz: Uint8Array;
    try {
      gz = new util.Base64Helper().decodeSync(padded, util.Type.BASIC_URL_SAFE);
    } catch (e) {
      return undefined;
    }
    const body = await ColorCode.gunzip(gz, 524288);
    if (body === undefined) {
      return undefined;
    }
    if (body.byteLength < 20) {
      return undefined;
    }
    const dv = new DataView(body.buffer, body.byteOffset, body.byteLength);
    if (dv.getInt32(0) !== ColorCode.MAGIC) {
      return undefined;
    }
    const format = dv.getUint8(4);
    if (format !== ColorCode.FORMAT && format !== 1) {
      return undefined;
    }
    const mode = dv.getUint8(5);
    const dim = dv.getUint8(6);
    const flags = dv.getUint8(7);
    const crc = dv.getUint32(8);
    const thumbLen = dv.getUint16(12);
    const nameLen = dv.getUint16(14);
    const seedCount = dv.getUint16(16);
    const stepCount = dv.getUint8(18);
    if (mode !== 1) {
      return undefined;
    }
    if (dim < 2 || dim > 64) {
      return undefined;
    }
    if (seedCount > ColorCode.MAX_SEEDS || stepCount > ColorCode.MAX_STEPS) {
      return undefined;
    }
    let o = 20;
    if (o + nameLen > body.byteLength) {
      return undefined;
    }
    const nameBytes = body.subarray(o, o + nameLen);
    o += nameLen;
    if ((flags & 1) !== 0) {
      if (o + thumbLen > body.byteLength) {
        return undefined;
      }
      o += thumbLen;
    }
    o += seedCount * ColorCode.SEED_BYTES;
    o += stepCount * 5;
    if (o > body.byteLength) {
      return undefined;
    }
    const expect = dim * dim * dim * 3;
    if (o + expect > body.byteLength) {
      return undefined;
    }
    let lut = body.subarray(o, o + expect);
    if ((flags & 2) !== 0) {
      lut = ColorCode.deltaDecode(lut, dim);
    }
    let name = '';
    try {
      name = new util.TextDecoder().decodeWithStream(nameBytes);
    } catch (e) {
      name = '';
    }
    if (name.length === 0) {
      name = '分享的色彩';
    }
    const payload = new CodePayload();
    payload.mode = mode;
    payload.dim = dim;
    payload.crc = crc;
    payload.name = name;
    payload.lut = lut;
    return payload;
  }

  /** bin → 17³ uint8（等步长采样，两端对齐；步长必须整除）。 */
  static downsample(bin: Uint8Array): Uint8Array | undefined {
    const dst = ColorCode.LUT_DIM;
    const pts = Math.floor(bin.byteLength / 12);
    if (pts <= 0 || pts * 12 !== bin.byteLength) {
      return undefined;
    }
    const src = Math.round(Math.pow(pts, 1.0 / 3.0));
    if (src * src * src !== pts) {
      return undefined;
    }
    if (src <= dst || (src - 1) % (dst - 1) !== 0) {
      return undefined;
    }
    const fb = new DataView(bin.buffer, bin.byteOffset, bin.byteLength);
    const step = (src - 1) / (dst - 1);
    const out = new Uint8Array(dst * dst * dst * 3);
    const planeSrc = src * src * src;
    let o = 0;
    for (let ch = 0; ch < 3; ch++) {
      for (let bi = 0; bi < dst; bi++) {
        const sb = bi * step;
        for (let gi = 0; gi < dst; gi++) {
          const sg = gi * step;
          for (let ri = 0; ri < dst; ri++) {
            const sr = ri * step;
            const v = fb.getFloat32((ch * planeSrc + sb * src * src + sg * src + sr) * 4, true);
            let q = Math.round(ColorCode.clamp01(v) * 255);
            if (q > 255) {
              q = 255;
            }
            out[o++] = q;
          }
        }
      }
    }
    return out;
  }

  /** 任意支持的 bin → 17³ uint8；已是 17³ 直接量化。 */
  static toLut17(bin: Uint8Array): Uint8Array | undefined {
    const pts = Math.floor(bin.byteLength / 12);
    if (pts <= 0 || pts * 12 !== bin.byteLength) {
      return undefined;
    }
    const src = Math.round(Math.pow(pts, 1.0 / 3.0));
    if (src * src * src !== pts) {
      return undefined;
    }
    if (src !== ColorCode.LUT_DIM) {
      return ColorCode.downsample(bin);
    }
    const fb = new DataView(bin.buffer, bin.byteOffset, bin.byteLength);
    const out = new Uint8Array(ColorCode.LUT_DIM * ColorCode.LUT_DIM * ColorCode.LUT_DIM * 3);
    for (let i = 0; i < out.length; i++) {
      const v = fb.getFloat32(i * 4, true);
      let q = Math.round(ColorCode.clamp01(v) * 255);
      if (q > 255) {
        q = 255;
      }
      out[i] = q;
    }
    return out;
  }

  /** 17³ uint8 → float32 LE bin（可直接喂 Lut3D.decode）。 */
  static inflateLut(lut: Uint8Array, dim: number): Uint8Array | undefined {
    const expect = dim * dim * dim * 3;
    if (lut.byteLength !== expect) {
      return undefined;
    }
    const out = new Uint8Array(expect * 4);
    const dv = new DataView(out.buffer);
    for (let i = 0; i < expect; i++) {
      dv.setFloat32(i * 4, lut[i] / 255, true);
    }
    return out;
  }

  /** 沿 R 轴（布局里最快变化的维）差分。 */
  static deltaEncode(lut: Uint8Array, dim: number): Uint8Array {
    const out = new Uint8Array(lut.byteLength);
    out.set(lut);
    for (let i = 0; i < lut.byteLength; i++) {
      if (i % dim !== 0) {
        out[i] = (lut[i] - lut[i - 1]) & 0xFF;
      }
    }
    return out;
  }

  static deltaDecode(enc: Uint8Array, dim: number): Uint8Array {
    const out = new Uint8Array(enc.byteLength);
    out.set(enc);
    for (let i = 1; i < out.byteLength; i++) {
      if (i % dim !== 0) {
        out[i] = (out[i - 1] + enc[i]) & 0xFF;
      }
    }
    return out;
  }

  private static clamp01(v: number): number {
    return v < 0 ? 0 : (v > 1 ? 1 : v);
  }

  private static statusOk(rs: zlib.ReturnStatus): boolean {
    return rs === zlib.ReturnStatus.OK || rs === zlib.ReturnStatus.STREAM_END;
  }

  /** 产出字节数：优先 totalOut，缺失时按 availableOut 差值推断。 */
  private static produced(strm: zlib.ZStream, bufLen: number): number {
    let total = strm.totalOut !== undefined ? strm.totalOut : 0;
    if (total <= 0) {
      const rem = strm.availableOut !== undefined ? strm.availableOut : bufLen;
      total = bufLen - rem;
    }
    return total;
  }

  /** 操作后从 native 侧取回真实流状态（strm 对象本身不回写）。失败时保持原样。 */
  private static async syncState(zip: zlib.Zip, strm: zlib.ZStream): Promise<void> {
    try {
      const inner = await zip.getZStream();
      strm.availableIn = inner.availableIn;
      strm.availableOut = inner.availableOut;
      strm.totalIn = inner.totalIn;
      strm.totalOut = inner.totalOut;
    } catch (e) {
    }
  }

  /** gzip 压缩（windowBits=31）。 */
  private static async gzip(data: Uint8Array): Promise<Uint8Array | undefined> {
    try {
      const input = data.byteOffset === 0 ? data : data.slice();
      const zip = await zlib.createZip();
      const outBuf = new ArrayBuffer(data.byteLength + 1024);
      const strm: zlib.ZStream = {
        nextIn: input.buffer,
        availableIn: input.byteLength,
        nextOut: outBuf,
        availableOut: outBuf.byteLength
      };
      const rs1 = await zip.deflateInit2(strm, zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
        zlib.CompressMethod.DEFLATED, 31, zlib.MemLevel.MEM_LEVEL_DEFAULT,
        zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY);
      if (!ColorCode.statusOk(rs1)) {
        return undefined;
      }
      const rs2 = await zip.deflate(strm, zlib.CompressFlushMode.FINISH);
      if (!ColorCode.statusOk(rs2)) {
        await zip.deflateEnd(strm);
        return undefined;
      }
      await ColorCode.syncState(zip, strm);
      await zip.deflateEnd(strm);
      const total = ColorCode.produced(strm, outBuf.byteLength);
      if (total <= 0 || total > outBuf.byteLength) {
        return undefined;
      }
      return new Uint8Array(outBuf, 0, total);
    } catch (e) {
      return undefined;
    }
  }

  /** gunzip 解压（windowBits=31），输出上限 maxOut。 */
  private static async gunzip(data: Uint8Array, maxOut: number): Promise<Uint8Array | undefined> {
    try {
      const input = data.byteOffset === 0 ? data : data.slice();
      const zip = await zlib.createZip();
      const outBuf = new ArrayBuffer(maxOut);
      const strm: zlib.ZStream = {
        nextIn: input.buffer,
        availableIn: input.byteLength,
        nextOut: outBuf,
        availableOut: maxOut
      };
      const rs1 = await zip.inflateInit2(strm, 31);
      if (!ColorCode.statusOk(rs1)) {
        return undefined;
      }
      const rs2 = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
      if (!ColorCode.statusOk(rs2)) {
        await zip.inflateEnd(strm);
        return undefined;
      }
      await ColorCode.syncState(zip, strm);
      await zip.inflateEnd(strm);
      const total = ColorCode.produced(strm, maxOut);
      if (total <= 0 || total > maxOut) {
        return undefined;
      }
      return new Uint8Array(outBuf, 0, total);
    } catch (e) {
      return undefined;
    }
  }
}
