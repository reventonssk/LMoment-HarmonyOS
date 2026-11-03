import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * DNG/RAW（TIFF 结构）EXIF → JPEG APP1（FFE1 + "Exif\0\0" + TIFF）迁移。
 * 从 DNG 的 IFD0 / ExifIFD / GPS IFD 摘取拍摄信息 tag（Make/Model/拍摄参数/GPS），
 * 重建为标准 TIFF/EP APP1 段，供 LeicaMark.mark 以「源图 APP1」口径移植。
 * 注意：
 * - 不迁移 Orientation（0x0112）——LibRaw 解码已按方向摆正像素，保留会二次旋转。
 * - ExifIFD 永远合成（即使源无）：LeicaMark.writeTags 依 0x8769 指针写徽章 tag，
 *   缺指针会返回 undefined 导致整个 APP1 被 minimal 模板替换（机型丢失）。
 * - 输出 TIFF 沿用源 DNG 字节序，值字节原样拷贝。
 */

class RawTag {
  readonly tag: number;
  readonly type: number;
  readonly count: number;
  readonly value: Uint8Array;

  constructor(tag: number, type: number, count: number, value: Uint8Array) {
    this.tag = tag;
    this.type = type;
    this.count = count;
    this.value = value;
  }
}

/** XMP 解析出的 GPS（华为 DNG 的 TIFF GPS IFD 为全零骨架，真值在 XMP）。 */
class XmpGps {
  latDeg: number = 0;
  latMin: number = 0;
  latSec: number = 0;
  latSouth: boolean = false;
  lonDeg: number = 0;
  lonMin: number = 0;
  lonSec: number = 0;
  lonWest: boolean = false;
  altitude: number = -1;
  date: string = '';
  hour: number = -1;
  minute: number = -1;
  second: number = -1;
}

class CoordParts {
  deg: number = 0;
  min: number = 0;
  sec: number = 0;
  neg: boolean = false;
}

export class RawExif {
  /** IFD0 需迁移的 tag（跳过 Orientation/条带偏移等结构性 tag）。 */
  private static readonly IFD0_TAGS: number[] = [
    0x010F, // Make
    0x0110, // Model
    0x0131, // Software
    0x0132, // DateTime
    0x013B, // Artist
    0x8298 // Copyright
  ];

  /** ExifIFD 需迁移的 tag。 */
  private static readonly EXIF_TAGS: number[] = [
    0x829A, // ExposureTime
    0x829D, // FNumber
    0x8822, // ExposureProgram
    0x8827, // ISOSpeedRatings
    0x9000, // ExifVersion
    0x9003, // DateTimeOriginal
    0x9004, // DateTimeDigitized
    0x9201, // ShutterSpeedValue
    0x9202, // ApertureValue
    0x9204, // ExposureBiasValue
    0x9207, // MeteringMode
    0x9209, // Flash
    0x920A, // FocalLength
    0xA001, // ColorSpace
    0xA433, // LensMake
    0xA434 // LensModel
  ];

  private static readonly TAG_EXIF_IFD: number = 0x8769;
  private static readonly TAG_GPS_IFD: number = 0x8825;

  private static typeSize(type: number): number {
    if (type === 1 || type === 2 || type === 6 || type === 7) {
      return 1;
    }
    if (type === 3 || type === 8) {
      return 2;
    }
    if (type === 4 || type === 9 || type === 11 || type === 13) {
      return 4; // 13=IFD 按 LONG 口径
    }
    if (type === 5 || type === 10 || type === 12) {
      return 8;
    }
    return 0;
  }

  private static u16(b: Uint8Array, at: number, le: boolean): number {
    return le ? b[at] | (b[at + 1] << 8) : (b[at] << 8) | b[at + 1];
  }

  private static u32(b: Uint8Array, at: number, le: boolean): number {
    return le ? (b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)) >>> 0 :
      ((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]) >>> 0;
  }

  private static u32Value(v: Uint8Array, le: boolean): number {
    if (v.length < 4) {
      return -1;
    }
    return le ? (v[0] | (v[1] << 8) | (v[2] << 16) | (v[3] << 24)) >>> 0 :
      ((v[0] << 24) | (v[1] << 16) | (v[2] << 8) | v[3]) >>> 0;
  }

  private static put16(b: Uint8Array, at: number, v: number, le: boolean): void {
    if (le) {
      b[at] = v & 0xFF;
      b[at + 1] = (v >> 8) & 0xFF;
    } else {
      b[at] = (v >> 8) & 0xFF;
      b[at + 1] = v & 0xFF;
    }
  }

  private static put32(b: Uint8Array, at: number, v: number, le: boolean): void {
    if (le) {
      b[at] = v & 0xFF;
      b[at + 1] = (v >> 8) & 0xFF;
      b[at + 2] = (v >> 16) & 0xFF;
      b[at + 3] = (v >>> 24) & 0xFF;
    } else {
      b[at] = (v >>> 24) & 0xFF;
      b[at + 1] = (v >> 16) & 0xFF;
      b[at + 2] = (v >> 8) & 0xFF;
      b[at + 3] = v & 0xFF;
    }
  }

  /** 解析 TIFF IFD：返回所有可读条目（值字节已解析；越界值/未知类型条目跳过）。 */
  private static parseIfd(b: Uint8Array, ifdAt: number, le: boolean): RawTag[] {
    const out: RawTag[] = [];
    if (ifdAt < 0 || ifdAt + 2 > b.length) {
      return out;
    }
    const n: number = RawExif.u16(b, ifdAt, le);
    if (n > 512) {
      return out;
    }
    for (let i = 0; i < n; i++) {
      const at: number = ifdAt + 2 + i * 12;
      if (at + 12 > b.length) {
        break;
      }
      const tag: number = RawExif.u16(b, at, le);
      const type: number = RawExif.u16(b, at + 2, le);
      const count: number = RawExif.u32(b, at + 4, le);
      const size: number = RawExif.typeSize(type) * count;
      if (size <= 0 || count > 1024 * 1024) {
        continue;
      }
      let value: Uint8Array;
      if (size <= 4) {
        value = b.slice(at + 8, at + 8 + size);
      } else {
        const off: number = RawExif.u32(b, at + 8, le);
        if (off + size > b.length) {
          continue;
        }
        value = b.slice(off, off + size);
      }
      out.push(new RawTag(tag, type, count, value));
    }
    return out;
  }

  private static wanted(tags: RawTag[], list: number[]): RawTag[] {
    const out: RawTag[] = [];
    for (let i = 0; i < tags.length; i++) {
      if (list.indexOf(tags[i].tag) >= 0) {
        out.push(tags[i]);
      }
    }
    out.sort((a: RawTag, b: RawTag): number => a.tag - b.tag);
    return out;
  }

  private static sortAll(tags: RawTag[]): RawTag[] {
    const out: RawTag[] = tags.slice();
    out.sort((a: RawTag, b: RawTag): number => a.tag - b.tag);
    return out;
  }

  /**
   * 序列化一段 IFD（count + 条目 + next=0 + 数据区写入）；返回数据区写入字节数，溢出返回 -1。
   */
  private static writeIfd(out: Uint8Array, at: number, tags: RawTag[], dataAt: number, le: boolean): number {
    RawExif.put16(out, at, tags.length, le);
    let data: number = dataAt;
    for (let i = 0; i < tags.length; i++) {
      const t: RawTag = tags[i];
      const eAt: number = at + 2 + i * 12;
      RawExif.put16(out, eAt, t.tag, le);
      RawExif.put16(out, eAt + 2, t.type, le);
      RawExif.put32(out, eAt + 4, t.count, le);
      if (t.value.length <= 4) {
        for (let k = 0; k < 4; k++) {
          out[eAt + 8 + k] = k < t.value.length ? t.value[k] : 0;
        }
      } else {
        RawExif.put32(out, eAt + 8, data, le);
        if (data + t.value.length > out.length) {
          return -1;
        }
        out.set(t.value, data);
        data += t.value.length;
        if (data % 2 === 1) {
          out[data] = 0;
          data += 1;
        }
      }
    }
    RawExif.put32(out, at + 2 + tags.length * 12, 0, le);
    return data - dataAt;
  }

  private static dataBytesOf(tags: RawTag[]): number {
    let n: number = 0;
    for (let i = 0; i < tags.length; i++) {
      if (tags[i].value.length > 4) {
        n += tags[i].value.length + (tags[i].value.length % 2);
      }
    }
    return n;
  }

  private static ptrTag(tag: number, offset: number, le: boolean): RawTag {
    const pv: Uint8Array = new Uint8Array(4);
    RawExif.put32(pv, 0, offset, le);
    return new RawTag(tag, 4, 1, pv);
  }

  /** 把 tags 中 tag==want 的条目的 4 字节值按字节序读为偏移；未找到返回 -1。 */
  private static findIfdOffset(tags: RawTag[], want: number, le: boolean): number {
    for (let i = 0; i < tags.length; i++) {
      if (tags[i].tag === want && tags[i].value.length >= 4) {
        return RawExif.u32Value(tags[i].value, le);
      }
    }
    return -1;
  }

  private static tagIds(tags: RawTag[]): string {
    let s: string = '';
    for (let i = 0; i < tags.length; i++) {
      s += tags[i].tag.toString(16) + ',';
    }
    return s;
  }

  private static ascii(s: string): Uint8Array {
    const b: Uint8Array = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      b[i] = s.charCodeAt(i) & 0xFF;
    }
    return b;
  }

  private static findBytes(b: Uint8Array, needle: string, from: number, to: number): number {
    const n: number = needle.length;
    for (let i = from; i + n <= to; i++) {
      let ok: boolean = true;
      for (let k = 0; k < n; k++) {
        if (b[i + k] !== (needle.charCodeAt(k) & 0xFF)) {
          ok = false;
          break;
        }
      }
      if (ok) {
        return i;
      }
    }
    return -1;
  }

  /** 手工十进制解析（避免依赖全局 parseFloat），失败返回 NaN。 */
  private static toNum(s: string): number {
    let i: number = 0;
    while (i < s.length && (s.charCodeAt(i) === 32 || s.charCodeAt(i) === 9)) {
      i++;
    }
    let sign: number = 1;
    if (i < s.length && (s.charAt(i) === '-' || s.charAt(i) === '+')) {
      if (s.charAt(i) === '-') {
        sign = -1;
      }
      i++;
    }
    let val: number = 0;
    let any: boolean = false;
    while (i < s.length && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) {
      val = val * 10 + (s.charCodeAt(i) - 48);
      i++;
      any = true;
    }
    if (i < s.length && s.charAt(i) === '.') {
      i++;
      let scale: number = 0.1;
      while (i < s.length && s.charCodeAt(i) >= 48 && s.charCodeAt(i) <= 57) {
        val += (s.charCodeAt(i) - 48) * scale;
        scale *= 0.1;
        i++;
        any = true;
      }
    }
    if (!any) {
      return NaN;
    }
    return sign * val;
  }

  /** 读取 XMP tag 值：兼容元素形式 <exif:X>val</exif:X> 与属性形式 exif:X="val"。 */
  private static xmpValue(b: Uint8Array, tagAt: number): string {
    const limit: number = b.length;
    let eq: number = -1;
    let gt: number = -1;
    for (let k = tagAt; k < Math.min(tagAt + 300, limit); k++) {
      if (b[k] === 0x3D) { // '='
        eq = k;
        break;
      }
      if (b[k] === 0x3E) { // '>'
        gt = k;
        break;
      }
    }
    if (eq >= 0) {
      let q: number = -1;
      for (let k = eq + 1; k < Math.min(eq + 10, limit); k++) {
        if (b[k] === 0x22) {
          q = k;
          break;
        }
      }
      if (q < 0) {
        return '';
      }
      let end: number = -1;
      for (let k = q + 1; k < limit; k++) {
        if (b[k] === 0x22) {
          end = k;
          break;
        }
      }
      if (end <= q + 1) {
        return '';
      }
      return RawExif.asciiSlice(b, q + 1, end);
    }
    if (gt < 0) {
      return '';
    }
    const nested: number = RawExif.findBytes(b, 'rdf:value', gt + 1, Math.min(gt + 80, limit));
    if (nested >= 0) {
      for (let k = nested; k < limit - 1; k++) {
        if (b[k] === 0x3E) {
          gt = k;
          break;
        }
      }
    }
    let end: number = -1;
    for (let k = gt + 1; k < limit; k++) {
      if (b[k] === 0x3C) {
        end = k;
        break;
      }
    }
    if (end === gt + 1) {
      // 嵌套结构（rdf:Seq/rdf:Bag）：收集 rdf:li 文本，逗号连接
      let vals: string = '';
      let p: number = gt + 1;
      const stop: number = Math.min(gt + 2000, limit);
      while (p < stop) {
        const liAt: number = RawExif.findBytes(b, '<rdf:li', p, stop);
        if (liAt < 0) {
          break;
        }
        let liGt: number = -1;
        for (let k = liAt; k < stop; k++) {
          if (b[k] === 0x3E) {
            liGt = k;
            break;
          }
        }
        if (liGt < 0) {
          break;
        }
        const liEnd: number = RawExif.findBytes(b, '</rdf:li', liGt, stop);
        if (liEnd > liGt + 1) {
          vals += (vals.length > 0 ? ',' : '') + RawExif.asciiSlice(b, liGt + 1, liEnd);
        }
        p = liEnd > liGt ? liEnd + 9 : stop;
      }
      if (vals.length > 0) {
        return vals;
      }
      return '';
    }
    if (end <= gt + 1) {
      return '';
    }
    return RawExif.asciiSlice(b, gt + 1, end);
  }

  private static asciiSlice(b: Uint8Array, from: number, to: number): string {
    let s: string = '';
    for (let i = from; i < to; i++) {
      s += String.fromCharCode(b[i]);
    }
    return s.trim();
  }

  /** XMP 坐标值是否自带半球字母（N/S/E/W 结尾）。 */
  private static hasHemi(v: string): boolean {
    if (v.length === 0) {
      return false;
    }
    const c: string = v.trim().charAt(v.trim().length - 1).toUpperCase();
    return c === 'N' || c === 'S' || c === 'E' || c === 'W';
  }

  /** 解析 XMP 坐标："22,46.2038N" / "22,46,12.23N" / "22,46.2 N" 等。 */
  private static parseCoord(v: string): CoordParts | undefined {
    if (v.length < 3) {
      return undefined;
    }
    const t: string = v.trim();
    const hemi: string = t.charAt(t.length - 1).toUpperCase();
    let body: string = t;
    let neg: boolean = false;
    if (hemi === 'N' || hemi === 'S' || hemi === 'E' || hemi === 'W') {
      body = t.substring(0, t.length - 1);
      neg = hemi === 'S' || hemi === 'W';
    }
    const parts: string[] = body.split(',');
    const cp: CoordParts = new CoordParts();
    if (parts.length >= 3) {
      cp.deg = RawExif.toNum(parts[0]);
      cp.min = RawExif.toNum(parts[1]);
      cp.sec = RawExif.toNum(parts[2]);
    } else if (parts.length === 2) {
      cp.deg = RawExif.toNum(parts[0]);
      const mf: number = RawExif.toNum(parts[1]);
      cp.min = Math.floor(mf);
      cp.sec = (mf - cp.min) * 60;
    } else {
      // 十进制度数（无逗号）
      const v: number = RawExif.toNum(body);
      if (v !== v || v < 0 || v > 180) {
        return undefined;
      }
      cp.deg = Math.floor(v);
      const mf: number = (v - cp.deg) * 60;
      cp.min = Math.floor(mf);
      cp.sec = (mf - cp.min) * 60;
    }
    if (cp.deg !== cp.deg || cp.min !== cp.min || cp.sec !== cp.sec) {
      return undefined;
    }
    if (cp.deg < 0 || cp.deg > 180 || cp.min < 0 || cp.min >= 60 || cp.sec < 0 || cp.sec >= 60) {
      return undefined;
    }
    cp.neg = neg;
    return cp;
  }

  private static parseAltitude(v: string): number {
    const sp: string[] = v.trim().split(' ');
    const f: string = sp.length > 0 ? sp[0] : v;
    const fr: string[] = f.split('/');
    const num: number = RawExif.toNum(fr[0]);
    if (num !== num) {
      return -1;
    }
    if (fr.length > 1) {
      const den: number = RawExif.toNum(fr[1]);
      if (den !== den || den === 0) {
        return -1;
      }
      return num / den;
    }
    return num;
  }

  /** 在文件头（256KB）中扫描 XMP GPS；解析失败返回 undefined。 */
  private static parseXmpGps(head: Uint8Array): XmpGps | undefined {
    const limit: number = head.length;
    let latAt: number = RawExif.findTagNotRef(head, 'exif:GPSLatitude', limit);
    let lonAt: number = RawExif.findTagNotRef(head, 'exif:GPSLongitude', limit);
    if (latAt < 0 || lonAt < 0) {
      latAt = RawExif.findTagNotRef(head, 'GPSLatitude', limit);
      lonAt = RawExif.findTagNotRef(head, 'GPSLongitude', limit);
    }
    if (latAt < 0 || lonAt < 0) {
      return undefined;
    }
    const latV: string = RawExif.xmpValue(head, latAt);
    const lonV: string = RawExif.xmpValue(head, lonAt);
    hilog.info(0x0000, 'RawExif', `xmp raw lat=[${latV}] lon=[${lonV}]`);
    const lat: CoordParts | undefined = RawExif.parseCoord(latV);
    const lon: CoordParts | undefined = RawExif.parseCoord(lonV);
    if (lat === undefined || lon === undefined) {
      hilog.info(0x0000, 'RawExif',
        `xmp parse fail latOk=${lat !== undefined} lonOk=${lon !== undefined}`);
      return undefined;
    }
    if (lat.deg + lat.min + lat.sec <= 0 && lon.deg + lon.min + lon.sec <= 0) {
      return undefined;
    }
    // 值无半球字母时从 Ref tag 补方向
    if (!RawExif.hasHemi(latV)) {
      const rAt: number = RawExif.findBytes(head, 'exif:GPSLatitudeRef', 0, limit);
      if (rAt >= 0) {
        const rv: string = RawExif.xmpValue(head, rAt);
        if (rv.length > 0) {
          lat.neg = rv.charAt(0).toUpperCase() === 'S';
        }
      }
    }
    if (!RawExif.hasHemi(lonV)) {
      const rAt: number = RawExif.findBytes(head, 'exif:GPSLongitudeRef', 0, limit);
      if (rAt >= 0) {
        const rv: string = RawExif.xmpValue(head, rAt);
        if (rv.length > 0) {
          lon.neg = rv.charAt(0).toUpperCase() === 'W';
        }
      }
    }
    const x: XmpGps = new XmpGps();
    x.latDeg = lat.deg;
    x.latMin = lat.min;
    x.latSec = lat.sec;
    x.latSouth = lat.neg;
    x.lonDeg = lon.deg;
    x.lonMin = lon.min;
    x.lonSec = lon.sec;
    x.lonWest = lon.neg;
    const altAt: number = RawExif.findTagNotRef(head, 'exif:GPSAltitude', limit);
    if (altAt >= 0) {
      x.altitude = RawExif.parseAltitude(RawExif.xmpValue(head, altAt));
    }
    const dateAt: number = RawExif.findTagNotRef(head, 'exif:GPSDateStamp', limit);
    if (dateAt >= 0) {
      const dv: string = RawExif.xmpValue(head, dateAt);
      if (dv.length >= 10) {
        x.date = dv.substring(0, 4) + ':' + dv.substring(5, 7) + ':' + dv.substring(8, 10);
      }
    }
    const timeAt: number = RawExif.findTagNotRef(head, 'exif:GPSTimeStamp', limit);
    if (timeAt >= 0) {
      const tv: string = RawExif.xmpValue(head, timeAt);
      const parts: string[] = tv.split(',');
      if (parts.length >= 3) {
        const h: number = RawExif.toNum(parts[0]);
        const m: number = RawExif.toNum(parts[1]);
        const s: number = RawExif.toNum(parts[2]);
        if (h === h && m === m && s === s) {
          x.hour = h;
          x.minute = m;
          x.second = s;
        }
      }
    }
    return x;
  }

  /** 找 XMP tag 名，跳过同名 Ref 后缀 tag（GPSLatitudeRef 等）。 */
  private static findTagNotRef(b: Uint8Array, name: string, limit: number): number {
    let at: number = RawExif.findBytes(b, name, 0, limit);
    while (at >= 0 && at + name.length < limit && b[at + name.length] === 0x52) { // 'R'
      at = RawExif.findBytes(b, name, at + 1, limit);
    }
    return at;
  }

  /** IFD0 原始条目里找 0x02BC XMLPacket（parseIfd 越界跳过，须直查）；返回 [off, cnt] 或空。 */
  private static findXmlPacketEntry(head: Uint8Array, ifd0At: number, le: boolean): number[] {
    if (ifd0At < 0 || ifd0At + 2 > head.length) {
      return [];
    }
    const n: number = RawExif.u16(head, ifd0At, le);
    for (let i = 0; i < n; i++) {
      const eAt: number = ifd0At + 2 + i * 12;
      if (eAt + 12 > head.length) {
        break;
      }
      if (RawExif.u16(head, eAt, le) === 0x02BC) {
        return [RawExif.u32(head, eAt + 8, le), RawExif.u32(head, eAt + 4, le)];
      }
    }
    return [];
  }

  /** XMP 未命中时输出诊断：0x02BC 位置、关键串扫描、GPSLatitude 周边 ASCII dump。 */
  private static logXmpDiag(head: Uint8Array, ifd0At: number, le: boolean): void {
    const limit: number = head.length;
    const xp: number[] = RawExif.findXmlPacketEntry(head, ifd0At, le);
    const bc: string = xp.length === 2 ?
      `cnt=${xp[1]} off=${xp[0]} inHead=${xp[0] + xp[1] <= limit}` : 'none';
    const latAt: number = RawExif.findBytes(head, 'GPSLatitude', 0, limit);
    hilog.info(0x0000, 'RawExif',
      `xmp scan 2bc:${bc} GPSLatitude@${latAt} ` +
      `adobe@${RawExif.findBytes(head, 'ns.adobe.com', 0, limit)} ` +
      `xmpmeta@${RawExif.findBytes(head, 'x:xmpmeta', 0, limit)} head=${limit}`);
    if (latAt >= 0) {
      hilog.info(0x0000, 'RawExif', `xmp dump ${RawExif.asciiSlice(head,
        Math.max(0, latAt - 100), Math.min(limit, latAt + 300))}`);
    }
  }

  /** TIFF GPS IFD 是否含非零经纬度（查度/分分子；华为 DNG 写 0/1 全零骨架，据此切换 XMP 兜底）。 */
  private static gpsHasCoords(tags: RawTag[]): boolean {
    let hasLat: boolean = false;
    let hasLon: boolean = false;
    for (let i = 0; i < tags.length; i++) {
      const t: RawTag = tags[i];
      if ((t.tag === 0x0002 || t.tag === 0x0004) && t.value.length >= 12) {
        // RATIONAL×3：度分子 [0..3]、分分子 [8..11]，全零 = 华为零骨架
        let degNz: boolean = false;
        for (let k = 0; k < 4; k++) {
          if (t.value[k] !== 0) {
            degNz = true;
            break;
          }
        }
        if (!degNz) {
          for (let k = 8; k < 12; k++) {
            if (t.value[k] !== 0) {
              degNz = true;
              break;
            }
          }
        }
        if (t.tag === 0x0002) {
          hasLat = degNz;
        } else {
          hasLon = degNz;
        }
      }
    }
    return hasLat && hasLon;
  }

  private static rationalBytes(num: number, den: number, le: boolean): Uint8Array {
    const b: Uint8Array = new Uint8Array(8);
    RawExif.put32(b, 0, num, le);
    RawExif.put32(b, 4, den, le);
    return b;
  }

  /** 由 XMP GPS 构建标准 EXIF GPS IFD 条目（tag 升序）。 */
  private static buildGpsFromXmp(x: XmpGps, le: boolean): RawTag[] {
    const out: RawTag[] = [];
    const ver: Uint8Array = new Uint8Array(4);
    ver[0] = 2;
    ver[1] = 3;
    ver[2] = 0;
    ver[3] = 0;
    out.push(new RawTag(0x0000, 1, 4, ver));
    out.push(new RawTag(0x0001, 2, 2,
      RawExif.ascii((x.latSouth ? 'S' : 'N') + String.fromCharCode(0))));
    const lat: Uint8Array = new Uint8Array(24);
    lat.set(RawExif.rationalBytes(Math.round(x.latDeg), 1, le), 0);
    lat.set(RawExif.rationalBytes(Math.round(x.latMin), 1, le), 8);
    lat.set(RawExif.rationalBytes(Math.round(x.latSec * 1000000), 1000000, le), 16);
    out.push(new RawTag(0x0002, 5, 3, lat));
    out.push(new RawTag(0x0003, 2, 2,
      RawExif.ascii((x.lonWest ? 'W' : 'E') + String.fromCharCode(0))));
    const lon: Uint8Array = new Uint8Array(24);
    lon.set(RawExif.rationalBytes(Math.round(x.lonDeg), 1, le), 0);
    lon.set(RawExif.rationalBytes(Math.round(x.lonMin), 1, le), 8);
    lon.set(RawExif.rationalBytes(Math.round(x.lonSec * 1000000), 1000000, le), 16);
    out.push(new RawTag(0x0004, 5, 3, lon));
    const altRef: Uint8Array = new Uint8Array(1);
    out.push(new RawTag(0x0005, 1, 1, altRef));
    if (x.altitude > 0) {
      out.push(new RawTag(0x0006, 5, 1, RawExif.rationalBytes(Math.round(x.altitude), 1, le)));
    }
    if (x.hour >= 0 && x.minute >= 0 && x.second >= 0) {
      const ts: Uint8Array = new Uint8Array(24);
      ts.set(RawExif.rationalBytes(x.hour, 1, le), 0);
      ts.set(RawExif.rationalBytes(x.minute, 1, le), 8);
      ts.set(RawExif.rationalBytes(Math.round(x.second), 1, le), 16);
      out.push(new RawTag(0x0007, 5, 3, ts));
    }
    if (x.date.length === 10) {
      out.push(new RawTag(0x001D, 2, 11, RawExif.ascii(x.date + String.fromCharCode(0))));
    }
    return out;
  }

  /**
   * 从 DNG 头部字节提取 EXIF APP1 完整段（FFE1 + 长度 + "Exif\0\0" + TIFF）。
   * 输入建议为文件头 256KB（IFD 与字符串值通常紧随 TIFF 头）。失败返回 undefined。
   */
  static extractApp1(head: Uint8Array,
    readRange?: (off: number, len: number) => Uint8Array): Uint8Array | undefined {
    if (head.length < 16) {
      hilog.info(0x0000, 'RawExif', `extract fail: head too small ${head.length}`);
      return undefined;
    }
    let le: boolean;
    if (head[0] === 0x49 && head[1] === 0x49) {
      le = true;
    } else if (head[0] === 0x4D && head[1] === 0x4D) {
      le = false;
    } else {
      hilog.info(0x0000, 'RawExif', `extract fail: not TIFF head=${head[0]},${head[1]}`);
      return undefined;
    }
    if (RawExif.u16(head, 2, le) !== 42) {
      hilog.info(0x0000, 'RawExif', 'extract fail: magic != 42');
      return undefined;
    }
    const ifd0At: number = RawExif.u32(head, 4, le);
    const ifd0All: RawTag[] = RawExif.parseIfd(head, ifd0At, le);
    const ifd0: RawTag[] = RawExif.wanted(ifd0All, RawExif.IFD0_TAGS);
    if (ifd0.length === 0) {
      hilog.info(0x0000, 'RawExif',
        `extract fail: ifd0 wanted empty (all=${ifd0All.length} tags=${RawExif.tagIds(ifd0All)})`);
      return undefined;
    }
    // ExifIFD（0x8769）
    let exif: RawTag[] = [];
    const exifSrcAt: number = RawExif.findIfdOffset(ifd0All, RawExif.TAG_EXIF_IFD, le);
    if (exifSrcAt >= 0) {
      exif = RawExif.wanted(RawExif.parseIfd(head, exifSrcAt, le), RawExif.EXIF_TAGS);
    }
    // GPS：TIFF GPS IFD 全量迁移；华为 DNG 常写全零骨架（真值在 XMP），XMP 兜底
    let gps: RawTag[] = [];
    let gpsFrom: string = 'none';
    const gpsSrcAt: number = RawExif.findIfdOffset(ifd0All, RawExif.TAG_GPS_IFD, le);
    if (gpsSrcAt >= 0) {
      gps = RawExif.sortAll(RawExif.parseIfd(head, gpsSrcAt, le));
      if (RawExif.gpsHasCoords(gps)) {
        gpsFrom = 'tiff';
      } else {
        gps = [];
      }
    }
    // XMP 兜底：优先 0x02BC XMLPacket（可借 readRange 读 head 外），
    // 其次扫 head；仍无则分块扫全文件（XMP 可能在内嵌 JPEG 预览里）
    let xmp: XmpGps | undefined = undefined;
    if (gpsFrom !== 'tiff') {
      const xp: number[] = RawExif.findXmlPacketEntry(head, ifd0At, le);
      if (xp.length === 2 && readRange !== undefined && xp[1] > 0 && xp[1] <= 8388608) {
        const pkt: Uint8Array = readRange(xp[0], Math.min(xp[1] + 256, 1048576));
        if (pkt.length > 0) {
          xmp = RawExif.parseXmpGps(pkt);
          if (xmp !== undefined) {
            gpsFrom = 'pkt';
          }
        }
      }
      if (xmp === undefined) {
        xmp = RawExif.parseXmpGps(head);
        if (xmp !== undefined) {
          gpsFrom = 'head';
        }
      }
      if (xmp === undefined && readRange !== undefined) {
        let pos: number = Math.max(0, head.length - 512);
        while (pos < 33554432) {
          const chunk: Uint8Array = readRange(pos, 1048576);
          if (chunk.length <= 512) {
            break;
          }
          xmp = RawExif.parseXmpGps(chunk);
          if (xmp !== undefined) {
            gpsFrom = 'chunk';
            break;
          }
          pos += chunk.length - 512;
        }
      }
      if (xmp === undefined) {
        RawExif.logXmpDiag(head, ifd0At, le);
      }
      if (xmp !== undefined) {
        gps = RawExif.buildGpsFromXmp(xmp, le);
      }
    }
    const hasGps: boolean = gps.length > 0;
    if (gpsFrom === 'tiff' && gpsSrcAt >= 0) {
      hilog.info(0x0000, 'RawExif',
        `gps src ifd@${gpsSrcAt} ${RawExif.hexOf(head, gpsSrcAt, gpsSrcAt + 150)}`);
      let vals: string = '';
      for (let i = 0; i < gps.length; i++) {
        vals += gps[i].tag.toString(16) + '=[' +
          RawExif.hexOf(gps[i].value, 0, Math.min(gps[i].value.length, 26)) + '] ';
      }
      hilog.info(0x0000, 'RawExif', `gps parsed ${vals}`);
    } else if (xmp !== undefined) {
      hilog.info(0x0000, 'RawExif',
        `gps xmp ${gpsFrom} lat=${xmp.latDeg},${xmp.latMin},${xmp.latSec.toFixed(4)}${xmp.latSouth ? 'S' : 'N'} ` +
        `lon=${xmp.lonDeg},${xmp.lonMin},${xmp.lonSec.toFixed(4)}${xmp.lonWest ? 'W' : 'E'} ` +
        `alt=${xmp.altitude} date=${xmp.date} time=${xmp.hour}:${xmp.minute}:${xmp.second}`);
    }
    // 布局：TIFF 头 @0，IFD0 @8（wanted + 0x8769 + [0x8825]，升序），
    // ExifIFD @next（永远合成，即使空——writeTags 徽章链依赖），GPS IFD @next，数据区随后
    const ifd0Final: RawTag[] = [];
    for (let i = 0; i < ifd0.length; i++) {
      ifd0Final.push(ifd0[i]);
    }
    const ifd0Count: number = ifd0Final.length + (hasGps ? 2 : 1); // ExifIFD 指针 + [GPS 指针]
    const ifd0Off: number = 8;
    const exifOff: number = ifd0Off + 2 + ifd0Count * 12 + 4;
    const gpsOff: number = exifOff + 2 + exif.length * 12 + 4;
    const dataOff: number = gpsOff + (hasGps ? 2 + gps.length * 12 + 4 : 0);
    const dataLen: number = RawExif.dataBytesOf(ifd0) + RawExif.dataBytesOf(exif) +
      RawExif.dataBytesOf(gps);
    const tiffLen: number = dataOff + dataLen;
    if (tiffLen > 65528) {
      hilog.info(0x0000, 'RawExif', `extract fail: tiffLen=${tiffLen} overflow`);
      return undefined;
    }
    const tiff: Uint8Array = new Uint8Array(tiffLen);
    tiff[0] = le ? 0x49 : 0x4D;
    tiff[1] = le ? 0x49 : 0x4D;
    RawExif.put16(tiff, 2, 42, le);
    RawExif.put32(tiff, 4, ifd0Off, le);
    // IFD0 末尾两指针条目（0x8769 < 0x8825，均大于 IFD0 业务 tag，升序成立）
    ifd0Final.push(RawExif.ptrTag(RawExif.TAG_EXIF_IFD, exifOff, le));
    if (hasGps) {
      ifd0Final.push(RawExif.ptrTag(RawExif.TAG_GPS_IFD, gpsOff, le));
    }
    const w0: number = RawExif.writeIfd(tiff, ifd0Off, ifd0Final, dataOff, le);
    if (w0 < 0) {
      hilog.info(0x0000, 'RawExif', 'extract fail: ifd0 write overflow');
      return undefined;
    }
    // ExifIFD：即使空也写 count=0 骨架，供徽章链在其上重建 theme/legend/mode
    const w1: number = RawExif.writeIfd(tiff, exifOff, exif, dataOff + w0, le);
    if (w1 < 0) {
      hilog.info(0x0000, 'RawExif', 'extract fail: exif write overflow');
      return undefined;
    }
    if (hasGps) {
      const w2: number = RawExif.writeIfd(tiff, gpsOff, gps, dataOff + w0 + w1, le);
      if (w2 < 0) {
        hilog.info(0x0000, 'RawExif', 'extract fail: gps write overflow');
        return undefined;
      }
    }
    const payloadLen: number = 6 + tiffLen;
    const seg: Uint8Array = new Uint8Array(4 + payloadLen);
    seg[0] = 0xFF;
    seg[1] = 0xE1;
    seg[2] = ((payloadLen + 2) >> 8) & 0xFF;
    seg[3] = (payloadLen + 2) & 0xFF;
    seg[4] = 0x45; // E
    seg[5] = 0x78; // x
    seg[6] = 0x69; // i
    seg[7] = 0x66; // f
    seg[8] = 0;
    seg[9] = 0;
    seg.set(tiff, 10);
    hilog.info(0x0000, 'RawExif', `extract ok seg=${seg.length} ifd0=${ifd0.length} ` +
      `exif=${exif.length} gps=${gps.length} gpsFrom=${gpsFrom} exifSrc=${exifSrcAt} ` +
      `le=${le} ifd0Tags=${RawExif.tagIds(ifd0)} exifTags=${RawExif.tagIds(exif)} ` +
      `gpsTags=${RawExif.tagIds(gps)}`);
    return seg;
  }

  /** 诊断：解析 APP1 完整段（FFE1...），返回 IFD0/ExifIFD/GPS 结构摘要（仅供日志定位）。 */
  static diagnose(seg: Uint8Array): string {
    if (seg.length < 18 || seg[0] !== 0xFF || seg[1] !== 0xE1
      || seg[4] !== 0x45 || seg[5] !== 0x78 || seg[6] !== 0x69 || seg[7] !== 0x66) {
      return 'no-app1';
    }
    const base: number = 10;
    const le: boolean = seg[base] === 0x49 && seg[base + 1] === 0x49;
    const tiffLen: number = seg.length - base;
    let ifd0At: number = RawExif.u32(seg, base + 4, le);
    if (ifd0At < 8 || ifd0At + 2 > tiffLen) {
      return `ifd0-oob ${ifd0At}`;
    }
    ifd0At += base;
    const n: number = RawExif.u16(seg, ifd0At, le);
    let ids: string = '';
    let exifP: number = -1;
    let gpsP: number = -1;
    for (let i = 0; i < n && ifd0At + 2 + i * 12 + 12 <= seg.length; i++) {
      const at: number = ifd0At + 2 + i * 12;
      const tag: number = RawExif.u16(seg, at, le);
      ids += tag.toString(16) + ',';
      if (tag === RawExif.TAG_EXIF_IFD) {
        exifP = RawExif.u32(seg, at + 8, le);
      } else if (tag === RawExif.TAG_GPS_IFD) {
        gpsP = RawExif.u32(seg, at + 8, le);
      }
    }
    let exifInfo: string = `exifP=${exifP}`;
    if (exifP >= 0) {
      if (exifP + 2 > tiffLen) {
        exifInfo += ' OOB';
      } else {
        exifInfo += ` n=${RawExif.u16(seg, base + exifP, le)}`;
      }
    }
    let gpsInfo: string = `gpsP=${gpsP}`;
    if (gpsP >= 0) {
      if (gpsP + 2 > tiffLen) {
        gpsInfo += ' OOB';
      } else {
        const gAt: number = base + gpsP;
        const gn: number = RawExif.u16(seg, gAt, le);
        let gids: string = '';
        for (let i = 0; i < gn && gAt + 2 + i * 12 + 12 <= seg.length; i++) {
          gids += RawExif.u16(seg, gAt + 2 + i * 12, le).toString(16) + ',';
        }
        gpsInfo += ` n=${gn} ids=${gids}`;
      }
    }
    return `seg=${seg.length} ifd0=${ids} ${exifInfo} ${gpsInfo}`;
  }

  /** 字节区间转十六进制串（诊断日志用）。 */
  static hexOf(b: Uint8Array, from: number, to: number): string {
    let s: string = '';
    for (let i = from; i < to; i++) {
      s += (b[i] < 16 ? '0' : '') + b[i].toString(16);
    }
    return s;
  }
}
