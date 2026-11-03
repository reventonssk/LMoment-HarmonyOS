/**
 * 徕卡徽章 / EXIF 处理（忠实移植原版 LeicaMark.java，2026-11 重构）。
 *
 * 徽章 = 纯元数据（与原版一致，不绘制任何像素水印）：
 * - EXIF APP1 私有 tag（ExifIFD）：themeCustomize(0x889D)="Madrid"、
 *   legendmode(0x88B0)=1、mode(0xA661)="256"；IFD0 同步一份 theme。
 * - FFE4 "XIAOMI_CUSTOMIZE" 段：魔数 + 14 字段 JSON（相册主要读这里）。
 * - 附带：删动态照片标记 tag(0x8897)；把 XiaomiComment(0x9999) 与
 *   XiaomiAuxiliaryInfo(0x889E) 替换为徕卡模式约定值。
 *
 * badge=false：不写徽章并剥离徽章元数据（FFE4 段 + 三 tag，含源图原生携带的）。
 *
 * EXIF 主体 = 移植源图 APP1（srcApp1 为 extractApp1 提取的完整 FFE1 段，
 * 保留真实拍摄设备/时间/参数，对齐原版 ExifTransplant）；无源 EXIF 时：
 * badge=true 注入小米徕卡模板（原版 minimalExifPayload 口径），
 * badge=false 注入仅 Software="L-Moment" 的极简 EXIF。
 *
 * 无论开关状态：剥离 XMP('http')/MPF/ISO 复合容器段与多余 APP1 Exif 段
 * （HDR 回嵌依赖「复合容器已移除」这一前提）。
 *
 * 导出顺序契约不变：packJpeg → mark → HDR 增益图回嵌 → 保存。
 */

/** 小米徽章私有 tag。 */
const TAG_EXIF_IFD_POINTER: number = 34665; // 0x8769
const TAG_THEME: number = 0x889D;           // 34973
const TAG_LEGENDMODE: number = 34992;       // 0x88B0
const TAG_MODE: number = 0xA661;            // 42593

/** FFE4 段魔数："XIAOMI_CUSTOMIZE" + 0x00 0x01 0x01（19 字节）。 */
const CUSTOMIZE_MAGIC: Uint8Array = asciiBytes('XIAOMI_CUSTOMIZE\u0000\u0001\u0001');

// 0x9999 XiaomiComment 的格式约定值——filterId=66048 是该模式的标识
const XIAOMI_COMMENT_LEICA: string = '{"mirror":false,"sensorType":"rear","Hdr":"off","OpMode":0,' +
  '"smallPicture":false,"AIScene":0,"filterId":66048,' +
  '"zoomMultiple":4.300000190734863}';
// 0x889E XiaomiAuxiliaryInfo 的格式约定值
const XIAOMI_AUX_LEICA: string = '{"buildDevice":"xuanyuan","customize":"","cvLensName":"",' +
  '"deviceType":1,"filterName":"??","livephotoInfo":"",' +
  '"series":"","variant":"","version":4,' +
  '"waterLogo":"XIAOMI","waterName":"15 Ultra"}';
// XIAOMI_CUSTOMIZE JSON（14 字段，含设备标识）× 格式约定值
const CUSTOMIZE_JSON: string = '{"8895":"0","10f":"Xiaomi","88a3":"{}","version":"32",' +
  '"110":"Xiaomi 15 Ultra","889d":"Madrid","889a":"0",' +
  '"9a00":"Xiaomi 15 Ultra","9aaa":"","88b0":"1",' +
  '"889e":"{\\"buildDevice\\":\\"xuanyuan\\",\\"customize\\":\\"\\",' +
  '\\"cvLensName\\":\\"\\",\\"deviceType\\":1,\\"filterName\\":\\"??\\",' +
  '\\"livephotoInfo\\":\\"\\",\\"series\\":\\"\\",\\"variant\\":\\"\\",' +
  '\\"version\\":4,\\"waterLogo\\":\\"XIAOMI\\",\\"waterName\\":\\"15 Ultra\\"}",' +
  '"889f":"???",' +
  '"9999":"{\\"mirror\\":false,\\"sensorType\\":\\"rear\\",\\"Hdr\\":\\"off\\",' +
  '\\"OpMode\\":0,\\"smallPicture\\":false,\\"AIScene\\":0,' +
  '\\"filterId\\":66048,\\"zoomMultiple\\":1}",' +
  '"a661":"256"}';

/** ASCII/Latin-1 字节化（不含结尾 0）。 */
function asciiBytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0xFF;
  }
  return out;
}

/** ASCII 字节化并补结尾 0（EXIF ASCII 值口径）。 */
function asciiZ(s: string): Uint8Array {
  const out = new Uint8Array(s.length + 1);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0xFF;
  }
  return out;
}

/** 可增长字节缓冲。 */
class ByteSink {
  private buf: Uint8Array;
  private len: number = 0;

  constructor(cap: number) {
    this.buf = new Uint8Array(cap > 32 ? cap : 32);
  }

  writeBytes(src: Uint8Array, from: number, count: number): void {
    if (count <= 0) {
      return;
    }
    this.ensure(count);
    this.buf.set(src.subarray(from, from + count), this.len);
    this.len += count;
  }

  toBytes(): Uint8Array {
    return this.buf.slice(0, this.len);
  }

  private ensure(n: number): void {
    if (this.len + n <= this.buf.length) {
      return;
    }
    let cap = this.buf.length * 2;
    while (cap < this.len + n) {
      cap *= 2;
    }
    const nb = new Uint8Array(cap);
    nb.set(this.buf.subarray(0, this.len));
    this.buf = nb;
  }
}

export class LeicaMark {
  /**
   * 导出 JPEG 收口。
   * badge=true：移植/注入源图 EXIF 后写入徕卡相机标记（EXIF 三 tag + FFE4）。
   * badge=false：剥离复合容器/多余 APP1/徽章元数据，移植源图 EXIF，
   *   无源时注入 Software="L-Moment" 极简 EXIF。异常返回原字节。
   */
  static mark(jpeg: Uint8Array, srcApp1?: Uint8Array, badge: boolean = true): Uint8Array {
    if (jpeg.length < 4 || jpeg[0] !== 0xFF || jpeg[1] !== 0xD8) {
      return jpeg;
    }
    try {
      let out = LeicaMark.stripExtraExif(LeicaMark.stripCompositeMeta(jpeg));
      if (badge) {
        if (srcApp1 !== undefined && LeicaMark.validApp1(srcApp1)) {
          out = LeicaMark.insertAfterSoi(out, srcApp1);
        }
        out = LeicaMark.markExifOnJpeg(out);
        return LeicaMark.markCustomize(out);
      }
      out = LeicaMark.stripBadgeMeta(out);
      let app1: Uint8Array;
      if (srcApp1 !== undefined && LeicaMark.validApp1(srcApp1)) {
        app1 = srcApp1;
      } else {
        app1 = LeicaMark.softwareExifSegment();
      }
      return LeicaMark.insertAfterSoi(out, app1);
    } catch (e) {
      return jpeg;
    }
  }

  /**
   * 从 JPEG 字节流提取首个 APP1 "Exif\0\0" 完整段（含 FFE1 与 2 字节长度头）。
   * 输入可以是文件头部若干字节；段超出读取窗口时返回 undefined。
   */
  static extractApp1(bytes: Uint8Array): Uint8Array | undefined {
    if (bytes.length < 4 || bytes[0] !== 0xFF || bytes[1] !== 0xD8) {
      return undefined;
    }
    let pos = 2;
    while (pos + 4 <= bytes.length && bytes[pos] === 0xFF) {
      const marker = bytes[pos + 1];
      if (marker === 0xDA || marker === 0xD9) {
        return undefined;
      }
      if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) {
        pos += 2;
        continue;
      }
      const len = (bytes[pos + 2] << 8) | bytes[pos + 3];
      if (len < 2 || pos + 2 + len > bytes.length) {
        return undefined;
      }
      if (marker === 0xE1 && len >= 10
        && bytes[pos + 4] === 0x45 && bytes[pos + 5] === 0x78
        && bytes[pos + 6] === 0x69 && bytes[pos + 7] === 0x66
        && bytes[pos + 8] === 0 && bytes[pos + 9] === 0) {
        return bytes.slice(pos, pos + 2 + len);
      }
      pos += 2 + len;
    }
    return undefined;
  }

  // ---- EXIF 徽章写入（badge=true 路径，对齐原版 markExif）----

  /** 对 JPEG 的 APP1 Exif 段写入徕卡标记：无 APP1 时注入完整模板。 */
  private static markExifOnJpeg(jpeg: Uint8Array): Uint8Array {
    let pos = 2;
    let app1DataStart = -1;
    let app1DataLen = 0;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker = jpeg[pos + 1];
      if (marker === 0xDA || marker === 0xD9) {
        break;
      }
      if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) {
        pos += 2;
        continue;
      }
      const segLen = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
      if (segLen < 2 || pos + 2 + segLen > jpeg.length) {
        break;
      }
      if (marker === 0xE1 && segLen >= 8
        && jpeg[pos + 4] === 0x45 && jpeg[pos + 5] === 0x78
        && jpeg[pos + 6] === 0x69 && jpeg[pos + 7] === 0x66
        && jpeg[pos + 8] === 0 && jpeg[pos + 9] === 0) {
        app1DataStart = pos + 4;
        app1DataLen = segLen - 2;
        break;
      }
      pos += 2 + segLen;
    }
    if (app1DataStart < 0) {
      const minimal = LeicaMark.minimalBadgePayload();
      const segLen = minimal.length + 2;
      const seg = new Uint8Array(4 + minimal.length);
      seg[0] = 0xFF;
      seg[1] = 0xE1;
      seg[2] = (segLen >> 8) & 0xFF;
      seg[3] = segLen & 0xFF;
      seg.set(minimal, 4);
      return LeicaMark.insertAfterSoi(jpeg, seg);
    }
    const payload = jpeg.slice(app1DataStart, app1DataStart + app1DataLen);
    let marked: Uint8Array | undefined = LeicaMark.writeTags(payload);
    if (marked === undefined || !LeicaMark.verifyTags(marked)) {
      marked = LeicaMark.minimalBadgePayload();
    }
    const len = marked.length + 2;
    if (len > 0xFFFF) {
      return jpeg;
    }
    const hdr = new Uint8Array(4);
    hdr[0] = 0xFF;
    hdr[1] = 0xE1;
    hdr[2] = (len >> 8) & 0xFF;
    hdr[3] = len & 0xFF;
    const bos = new ByteSink(jpeg.length + 64);
    bos.writeBytes(jpeg, 0, app1DataStart - 4);
    bos.writeBytes(hdr, 0, 4);
    bos.writeBytes(marked, 0, marked.length);
    bos.writeBytes(jpeg, app1DataStart + app1DataLen, jpeg.length - app1DataStart - app1DataLen);
    return bos.toBytes();
  }

  /**
   * 对 APP1 payload（"Exif\0\0" 起）写入徕卡 tag：
   * 找 IFD0 的 ExifIFD 指针 → 删 0x8897 动态标记 → ExifIFD 补/改三 tag →
   * 替换 0x9999/0x889E → IFD0 确保 theme → IFD0 替换 0x9999。
   * 无 ExifIFD 指针或结构异常返回 undefined（由调用方回退模板）。
   */
  private static writeTags(data: Uint8Array): Uint8Array | undefined {
    if (data.length < 14) {
      return data;
    }
    const le = data[6] === 0x49 && data[7] === 0x49;
    if (!le && !(data[6] === 0x4D && data[7] === 0x4D)) {
      return data;
    }
    const ifd0 = LeicaMark.integer(data, 10, 4, le) + 6;
    if (ifd0 < 14 || ifd0 > data.length - 2) {
      return data;
    }
    const count = LeicaMark.integer(data, ifd0, 2, le);
    for (let i = 0; i < count; i++) {
      const p = ifd0 + 2 + i * 12;
      if (p > data.length - 12) {
        break;
      }
      if (LeicaMark.integer(data, p, 2, le) === TAG_EXIF_IFD_POINTER
        && LeicaMark.integer(data, p + 2, 2, le) === 4
        && LeicaMark.integer(data, p + 4, 4, le) === 1) {
        const exifIfd = LeicaMark.integer(data, p + 8, 4, le) + 6;
        if (exifIfd < 14 || exifIfd > data.length - 4) {
          return undefined;
        }
        // 删除动态照片标记 tag（0x8897=1）：残留会让相册按复合照片路径判定
        LeicaMark.removeEntryInPlace(data, le, exifIfd, 0x8897);
        LeicaMark.removeEntryInPlace(data, le, ifd0, 0x8897);
        let afterExif = LeicaMark.writeInExifIfd(data, le, p, exifIfd);
        // 设备拍摄模式记录替换为徕卡约定值（相册徽章判定读 EXIF 本体的 filterId）
        afterExif = LeicaMark.writeReplaceAscii(afterExif, le, exifIfd, 0x9999, XIAOMI_COMMENT_LEICA);
        afterExif = LeicaMark.writeReplaceAscii(afterExif, le, exifIfd, 0x889E, XIAOMI_AUX_LEICA);
        const afterIfd0 = LeicaMark.writeInIfd0(afterExif, le);
        const ifd0b = LeicaMark.integer(afterIfd0, 10, 4, le) + 6;
        return LeicaMark.writeReplaceAscii(afterIfd0, le, ifd0b, 0x9999, XIAOMI_COMMENT_LEICA);
      }
    }
    return undefined;
  }

  /** ExifIFD：确保 theme/legendmode/mode 三 tag 存在且值正确（缺失则重建该 IFD）。 */
  private static writeInExifIfd(data: Uint8Array, le: boolean, ifd0Entry: number,
    exifIfd: number): Uint8Array {
    const count = LeicaMark.integer(data, exifIfd, 2, le);
    if (count < 0 || exifIfd + 6 + count * 12 > data.length) {
      return data;
    }
    let hasTheme = false;
    let hasLegend = false;
    let hasMode = false;
    for (let i = 0; i < count; i++) {
      const e = exifIfd + 2 + i * 12;
      const tag = LeicaMark.integer(data, e, 2, le);
      const type = LeicaMark.integer(data, e + 2, 2, le);
      if (tag === TAG_THEME) {
        hasTheme = true;
        if (type === 2 && LeicaMark.integer(data, e + 4, 4, le) >= 7) {
          const off = LeicaMark.integer(data, e + 8, 4, le) + 6;
          if (off >= 6 && off + 7 <= data.length) {
            LeicaMark.putMadrid(data, off);
          }
        }
      } else if (tag === TAG_LEGENDMODE) {
        hasLegend = true;
        if (type === 1 && LeicaMark.integer(data, e + 4, 4, le) === 1) {
          data[e + 8] = 1;
        }
      } else if (tag === TAG_MODE) {
        hasMode = true;
        if (type === 2) {
          LeicaMark.writeInt(data, e + 4, 4, 4, le);
          LeicaMark.putMode256(data, e + 8);
        }
      }
    }
    if (hasTheme && hasLegend && hasMode) {
      return data;
    }
    const missing = (hasTheme ? 0 : 1) + (hasLegend ? 0 : 1) + (hasMode ? 0 : 1);
    const base = (data.length + 1) & ~1;
    const newCount = count + missing;
    const dataSize = hasTheme ? 0 : 8;
    const total = base + 6 + newCount * 12 + dataSize;
    if (total > 65533) {
      return data;
    }
    const out = new Uint8Array(total);
    out.set(data);
    LeicaMark.writeInt(out, ifd0Entry + 8, base - 6, 4, le);
    LeicaMark.writeInt(out, base, newCount, 2, le);
    const dataOff = base + 6 + newCount * 12;
    let w = base + 2;
    let themeWritten = hasTheme;
    let legendWritten = hasLegend;
    let modeWritten = hasMode;
    for (let i = 0; i < count; i++) {
      const e = exifIfd + 2 + i * 12;
      const tag = LeicaMark.integer(data, e, 2, le);
      if (!themeWritten && TAG_THEME < tag) {
        w = LeicaMark.writeThemeEntry(out, w, le, dataOff);
        themeWritten = true;
      }
      if (!legendWritten && TAG_LEGENDMODE < tag) {
        w = LeicaMark.writeLegendEntry(out, w, le);
        legendWritten = true;
      }
      if (!modeWritten && TAG_MODE < tag) {
        w = LeicaMark.writeModeEntry(out, w, le);
        modeWritten = true;
      }
      out.set(data.subarray(e, e + 12), w);
      w += 12;
    }
    if (!themeWritten) {
      w = LeicaMark.writeThemeEntry(out, w, le, dataOff);
    }
    if (!legendWritten) {
      w = LeicaMark.writeLegendEntry(out, w, le);
    }
    if (!modeWritten) {
      w = LeicaMark.writeModeEntry(out, w, le);
    }
    out.set(data.subarray(exifIfd + 2 + count * 12, exifIfd + 6 + count * 12), w);
    return out;
  }

  /** IFD0 确保 themeCustomize="Madrid"（样张在 IFD0 与 ExifIFD 各有一处，相册可能读 IFD0 的）。 */
  private static writeInIfd0(data: Uint8Array, le: boolean): Uint8Array {
    if (data.length < 14) {
      return data;
    }
    const ifd0 = LeicaMark.integer(data, 10, 4, le) + 6;
    if (ifd0 < 14 || ifd0 > data.length - 2) {
      return data;
    }
    const count = LeicaMark.integer(data, ifd0, 2, le);
    if (count < 0 || ifd0 + 6 + count * 12 > data.length) {
      return data;
    }
    for (let i = 0; i < count; i++) {
      const e = ifd0 + 2 + i * 12;
      if (LeicaMark.integer(data, e, 2, le) === TAG_THEME) {
        const type = LeicaMark.integer(data, e + 2, 2, le);
        if (type === 2 && LeicaMark.integer(data, e + 4, 4, le) >= 7) {
          const off = LeicaMark.integer(data, e + 8, 4, le) + 6;
          if (off >= 6 && off + 7 <= data.length) {
            LeicaMark.putMadrid(data, off);
          }
        }
        return data;
      }
    }
    // 缺失：重建 IFD0 到 payload 末尾（TIFF header 的 IFD0 offset 同步更新）
    const base = (data.length + 1) & ~1;
    const newCount = count + 1;
    const total = base + 6 + newCount * 12 + 8;
    if (total > 65533) {
      return data;
    }
    const out = new Uint8Array(total);
    out.set(data);
    const dataOff = base + 6 + newCount * 12;
    LeicaMark.writeInt(out, 10, base - 6, 4, le);
    LeicaMark.writeInt(out, base, newCount, 2, le);
    let w = base + 2;
    let themeWritten = false;
    for (let i = 0; i < count; i++) {
      const e = ifd0 + 2 + i * 12;
      const tag = LeicaMark.integer(data, e, 2, le);
      if (!themeWritten && TAG_THEME < tag) {
        w = LeicaMark.writeThemeEntry(out, w, le, dataOff);
        themeWritten = true;
      }
      out.set(data.subarray(e, e + 12), w);
      w += 12;
    }
    if (!themeWritten) {
      w = LeicaMark.writeThemeEntry(out, w, le, dataOff);
    }
    out.set(data.subarray(ifd0 + 2 + count * 12, ifd0 + 6 + count * 12), w);
    return out;
  }

  /** 写入 theme entry（ASCII "Madrid\0" 数据在 dataOff），返回写入后的偏移。 */
  private static writeThemeEntry(b: Uint8Array, off: number, le: boolean, dataOff: number): number {
    LeicaMark.writeInt(b, off, TAG_THEME, 2, le);
    LeicaMark.writeInt(b, off + 2, 2, 2, le);
    LeicaMark.writeInt(b, off + 4, 7, 4, le);
    LeicaMark.writeInt(b, off + 8, dataOff - 6, 4, le);
    LeicaMark.putMadrid(b, dataOff);
    return off + 12;
  }

  /** 写入 legendmode entry（BYTE=1 inline），返回写入后的偏移。 */
  private static writeLegendEntry(b: Uint8Array, off: number, le: boolean): number {
    LeicaMark.writeInt(b, off, TAG_LEGENDMODE, 2, le);
    LeicaMark.writeInt(b, off + 2, 1, 2, le);
    LeicaMark.writeInt(b, off + 4, 1, 4, le);
    b[off + 8] = 1;
    return off + 12;
  }

  /** 写入 mode entry（ASCII "256\0" inline），返回写入后的偏移。 */
  private static writeModeEntry(b: Uint8Array, off: number, le: boolean): number {
    LeicaMark.writeInt(b, off, TAG_MODE, 2, le);
    LeicaMark.writeInt(b, off + 2, 2, 2, le);
    LeicaMark.writeInt(b, off + 4, 4, 4, le);
    LeicaMark.putMode256(b, off + 8);
    return off + 12;
  }

  /** 校验 payload 的徕卡标记是否可解析（IFD0 有 theme + ExifIFD 三 tag 齐）。 */
  private static verifyTags(payload: Uint8Array): boolean {
    if (payload.length < 14) {
      return false;
    }
    const le = payload[6] === 0x49 && payload[7] === 0x49;
    if (!le && !(payload[6] === 0x4D && payload[7] === 0x4D)) {
      return false;
    }
    const ifd0 = LeicaMark.integer(payload, 10, 4, le) + 6;
    if (ifd0 < 14 || ifd0 > payload.length - 2) {
      return false;
    }
    const count = LeicaMark.integer(payload, ifd0, 2, le);
    let theme0 = false;
    let exif = -1;
    for (let i = 0; i < count; i++) {
      const e = ifd0 + 2 + i * 12;
      if (e + 12 > payload.length) {
        return false;
      }
      const tag = LeicaMark.integer(payload, e, 2, le);
      if (tag === TAG_THEME) {
        theme0 = true;
      }
      if (tag === TAG_EXIF_IFD_POINTER
        && LeicaMark.integer(payload, e + 2, 2, le) === 4
        && LeicaMark.integer(payload, e + 4, 4, le) === 1) {
        exif = LeicaMark.integer(payload, e + 8, 4, le) + 6;
      }
    }
    if (!theme0 || exif < 14 || exif > payload.length - 4) {
      return false;
    }
    const n = LeicaMark.integer(payload, exif, 2, le);
    let t = false;
    let l = false;
    let m = false;
    for (let i = 0; i < n; i++) {
      const e = exif + 2 + i * 12;
      if (e + 12 > payload.length) {
        return false;
      }
      const tag = LeicaMark.integer(payload, e, 2, le);
      if (tag === TAG_THEME) {
        t = true;
      }
      if (tag === TAG_LEGENDMODE) {
        l = true;
      }
      if (tag === TAG_MODE) {
        m = true;
      }
    }
    return t && l && m;
  }

  // ---- FFE4 XIAOMI_CUSTOMIZE（对齐原版 markCustomize）----

  /** 写入/替换 FFE4 XIAOMI_CUSTOMIZE 段（魔数 + 14 字段 JSON）。 */
  private static markCustomize(jpeg: Uint8Array): Uint8Array {
    const jsonBytes = asciiBytes(CUSTOMIZE_JSON);
    const segLen = CUSTOMIZE_MAGIC.length + jsonBytes.length + 2;
    const seg = new Uint8Array(segLen + 2);
    seg[0] = 0xFF;
    seg[1] = 0xE4;
    seg[2] = (segLen >> 8) & 0xFF;
    seg[3] = segLen & 0xFF;
    seg.set(CUSTOMIZE_MAGIC, 4);
    seg.set(jsonBytes, 4 + CUSTOMIZE_MAGIC.length);
    // 扫描：若已存在 FFE4 XIAOMI_CUSTOMIZE，替换；否则在 SOI 后插入
    let pos = 2;
    let found = -1;
    let foundLen = 0;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker = jpeg[pos + 1];
      if (marker === 0xDA || marker === 0xD9) {
        break;
      }
      if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) {
        pos += 2;
        continue;
      }
      const len = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
      if (len < 2 || pos + 2 + len > jpeg.length) {
        break;
      }
      if (marker === 0xE4 && len >= CUSTOMIZE_MAGIC.length
        && LeicaMark.matchAt(jpeg, pos + 4, CUSTOMIZE_MAGIC)) {
        found = pos;
        foundLen = len + 2;
        break;
      }
      pos += 2 + len;
    }
    if (found >= 0) {
      const out = new Uint8Array(jpeg.length - foundLen + seg.length);
      out.set(jpeg.subarray(0, found), 0);
      out.set(seg, found);
      out.set(jpeg.subarray(found + foundLen), found + seg.length);
      return out;
    }
    return LeicaMark.insertAfterSoi(jpeg, seg);
  }

  // ---- 自建徕卡 EXIF 模板（对齐原版 minimalExifPayload）----

  /**
   * 自建完整徕卡 EXIF payload（动态计算偏移）："Exif\0\0" + TIFF(LE) +
   * IFD0{Make, Model, themeCustomize="Madrid", →ExifIFD}
   * ExifIFD{themeCustomize="Madrid", legendmode=1, mode="256"}。
   */
  private static minimalBadgePayload(): Uint8Array {
    const make = asciiZ('Xiaomi');
    const model = asciiZ('Xiaomi 15 Ultra');
    const madrid = asciiZ('Madrid');
    const ifd0Off = 8;
    const ifd0N = 4;
    const exifOff = ifd0Off + 2 + ifd0N * 12 + 4;
    const exifN = 3;
    const dataOff = exifOff + 2 + exifN * 12 + 4;
    const offMake = dataOff;
    const offModel = offMake + make.length;
    const offM0 = offModel + model.length;
    const offM1 = offM0 + madrid.length;
    const p = new Uint8Array(6 + offM1 + madrid.length);
    p[0] = 0x45;
    p[1] = 0x78;
    p[2] = 0x69;
    p[3] = 0x66;
    p[6] = 0x49;
    p[7] = 0x49;
    p[8] = 0x2A;
    LeicaMark.writeInt(p, 10, ifd0Off, 4, true);
    let w = 6 + ifd0Off;
    p[w] = ifd0N & 0xFF;
    w += 1;
    w = LeicaMark.putEntry(p, w, 0x010F, 2, make.length, offMake);
    w = LeicaMark.putEntry(p, w, 0x0110, 2, model.length, offModel);
    w = LeicaMark.putEntry(p, w, 0x889D, 2, madrid.length, offM0);
    w = LeicaMark.putEntry(p, w, 0x8769, 4, 1, exifOff);
    w += 4;
    const e = 6 + exifOff;
    p[e] = exifN & 0xFF;
    w = e + 2;
    w = LeicaMark.putEntry(p, w, 0x889D, 2, madrid.length, offM1);
    w = LeicaMark.putEntry(p, w, 0x88B0, 1, 1, 1);
    w = LeicaMark.putEntry(p, w, 0xA661, 2, 4, -1);
    LeicaMark.putMode256(p, w - 4);
    p.set(make, 6 + offMake);
    p.set(model, 6 + offModel);
    p.set(madrid, 6 + offM0);
    p.set(madrid, 6 + offM1);
    return p;
  }

  /** 小端 EXIF entry 写入（minimal 模板专用），value<0 表示不写 value 区。 */
  private static putEntry(p: Uint8Array, w: number, tag: number, type: number,
    count: number, value: number): number {
    p[w] = tag & 0xFF;
    p[w + 1] = (tag >> 8) & 0xFF;
    p[w + 2] = type & 0xFF;
    p[w + 3] = (type >> 8) & 0xFF;
    LeicaMark.writeInt(p, w + 4, count, 4, true);
    if (value >= 0) {
      LeicaMark.writeInt(p, w + 8, value, 4, true);
    }
    return w + 12;
  }

  /** 将 IFD 内指定 ASCII tag 的值整体替换为新字符串（新数据区追加到 payload 末尾）。 */
  private static writeReplaceAscii(data: Uint8Array, le: boolean, ifdOff: number,
    tag: number, newValue: string): Uint8Array {
    if (ifdOff < 14 || ifdOff > data.length - 2) {
      return data;
    }
    const count = LeicaMark.integer(data, ifdOff, 2, le);
    if (count <= 0) {
      return data;
    }
    for (let i = 0; i < count; i++) {
      const e = ifdOff + 2 + i * 12;
      if (e + 12 > data.length) {
        return data;
      }
      if (LeicaMark.integer(data, e, 2, le) !== tag) {
        continue;
      }
      if (LeicaMark.integer(data, e + 2, 2, le) !== 2) {
        return data;
      }
      const nv = asciiZ(newValue);
      const base = (data.length + 1) & ~1;
      const total = base + 6 + nv.length;
      if (total > 65533) {
        return data;
      }
      const out = new Uint8Array(total);
      out.set(data);
      out.set(nv, base + 6);
      LeicaMark.writeInt(out, e + 4, nv.length, 4, le);
      LeicaMark.writeInt(out, e + 8, base - 6, 4, le);
      return out;
    }
    return data;
  }

  // ---- 段插入 ----

  /** SOI 之后插入完整段（FFE1/FFE4 …）。 */
  private static insertAfterSoi(jpeg: Uint8Array, seg: Uint8Array): Uint8Array {
    const bos = new ByteSink(jpeg.length + seg.length);
    bos.writeBytes(jpeg, 0, 2);
    bos.writeBytes(seg, 0, seg.length);
    bos.writeBytes(jpeg, 2, jpeg.length - 2);
    return bos.toBytes();
  }

  private static validApp1(seg?: Uint8Array): boolean {
    return seg !== undefined && seg.length >= 18
      && seg[0] === 0xFF && seg[1] === 0xE1
      && seg[4] === 0x45 && seg[5] === 0x78 && seg[6] === 0x69 && seg[7] === 0x66
      && seg[8] === 0 && seg[9] === 0;
  }

  /**
   * 仅 Software="L-Moment" 的极简 EXIF APP1 段（完整段：FFE1 + 长度 + payload）。
   * 结构："Exif\0\0" + TIFF(II 0x2A, IFD0@8) + IFD0{Software} + "L-Moment\0"。
   */
  private static softwareExifSegment(): Uint8Array {
    const sw = asciiBytes('L-Moment');
    const ifd0 = 8;
    const dataOff = ifd0 + 2 + 12 + 4;
    const tiffLen = dataOff + sw.length + 1;
    const payloadLen = 6 + tiffLen;
    const seg = new Uint8Array(4 + payloadLen);
    seg[0] = 0xFF;
    seg[1] = 0xE1;
    seg[2] = ((payloadLen + 2) >> 8) & 0xFF;
    seg[3] = (payloadLen + 2) & 0xFF;
    seg[4] = 0x45; // E
    seg[5] = 0x78; // x
    seg[6] = 0x69; // i
    seg[7] = 0x66; // f
    let w = 10;
    seg[w] = 0x49;
    seg[w + 1] = 0x49; // II
    w += 2;
    LeicaMark.writeInt(seg, w, 0x2A, 2, true);
    w += 2;
    LeicaMark.writeInt(seg, w, ifd0, 4, true);
    w += 4;
    LeicaMark.writeInt(seg, w, 1, 2, true); // IFD0 entry-count
    w += 2;
    LeicaMark.writeInt(seg, w, 0x0131, 2, true); // Software
    w += 2;
    LeicaMark.writeInt(seg, w, 2, 2, true); // ASCII
    w += 2;
    LeicaMark.writeInt(seg, w, sw.length + 1, 4, true);
    w += 4;
    LeicaMark.writeInt(seg, w, dataOff, 4, true);
    w += 4;
    LeicaMark.writeInt(seg, w, 0, 4, true); // next IFD = 0
    w += 4;
    seg.set(sw, w);
    return seg;
  }

  // ---- 复合照片容器元数据移除 ----

  private static stripCompositeMeta(jpeg: Uint8Array): Uint8Array {
    let cur = jpeg;
    while (true) {
      const out = LeicaMark.removeOneComposite(cur);
      if (out === cur) {
        return cur;
      }
      cur = out;
    }
  }

  private static removeOneComposite(jpeg: Uint8Array): Uint8Array {
    let pos = 2;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker = jpeg[pos + 1];
      if (marker === 0xDA || marker === 0xD9) {
        break;
      }
      if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) {
        pos += 2;
        continue;
      }
      const len = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
      if (len < 2 || pos + 2 + len > jpeg.length) {
        break;
      }
      let del = false;
      if (marker === 0xE1 && len >= 16
        && jpeg[pos + 4] === 0x68 && jpeg[pos + 5] === 0x74
        && jpeg[pos + 6] === 0x74 && jpeg[pos + 7] === 0x70) {
        del = true; // XMP（含 Container:Directory 复合照片标记）
      } else if (marker === 0xE2 && len >= 5
        && jpeg[pos + 4] === 0x4D && jpeg[pos + 5] === 0x50 && jpeg[pos + 6] === 0x46) {
        del = true; // MPF 多图格式
      } else if (marker === 0xE2 && len >= 6
        && jpeg[pos + 4] === 0x75 && jpeg[pos + 5] === 0x72 && jpeg[pos + 6] === 0x6E) {
        del = true; // urn:iso:std:iso:ts:21496 增益图标识
      }
      if (del) {
        return LeicaMark.cutSegment(jpeg, pos, len);
      }
      pos += 2 + len;
    }
    return jpeg;
  }

  // ---- 多余 Exif 段移除 ----

  private static stripExtraExif(jpeg: Uint8Array): Uint8Array {
    let cur = jpeg;
    while (true) {
      const out = LeicaMark.stripOneExtraExif(cur);
      if (out === cur) {
        return cur;
      }
      cur = out;
    }
  }

  private static stripOneExtraExif(jpeg: Uint8Array): Uint8Array {
    let pos = 2;
    let seen = false;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker = jpeg[pos + 1];
      if (marker === 0xDA || marker === 0xD9) {
        break;
      }
      if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) {
        pos += 2;
        continue;
      }
      const len = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
      if (len < 2 || pos + 2 + len > jpeg.length) {
        break;
      }
      if (marker === 0xE1 && len >= 10
        && jpeg[pos + 4] === 0x45 && jpeg[pos + 5] === 0x78
        && jpeg[pos + 6] === 0x69 && jpeg[pos + 7] === 0x66
        && jpeg[pos + 8] === 0 && jpeg[pos + 9] === 0) {
        if (seen) {
          return LeicaMark.cutSegment(jpeg, pos, len);
        }
        seen = true;
      }
      pos += 2 + len;
    }
    return jpeg;
  }

  // ---- 段工具 ----

  /** 删除 [pos, pos+2+len) 的段。 */
  private static cutSegment(jpeg: Uint8Array, pos: number, len: number): Uint8Array {
    const out = new Uint8Array(jpeg.length - len - 2);
    out.set(jpeg.subarray(0, pos), 0);
    out.set(jpeg.subarray(pos + 2 + len), pos);
    return out;
  }

  private static matchAt(src: Uint8Array, at: number, prefix: Uint8Array): boolean {
    for (let i = 0; i < prefix.length; i++) {
      if (src[at + i] !== prefix[i]) {
        return false;
      }
    }
    return true;
  }

  private static removeSegment(jpeg: Uint8Array, marker: number, magic: Uint8Array): Uint8Array {
    let pos = 2;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const m = jpeg[pos + 1];
      if (m === 0xDA || m === 0xD9) {
        break;
      }
      if (m === 0xD8 || (m >= 0xD0 && m <= 0xD7) || m === 0x01) {
        pos += 2;
        continue;
      }
      const len = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
      if (len < 2 || pos + 2 + len > jpeg.length) {
        break;
      }
      if (m === marker && len - 2 >= magic.length && LeicaMark.matchAt(jpeg, pos + 4, magic)) {
        return LeicaMark.cutSegment(jpeg, pos, len);
      }
      pos += 2 + len;
    }
    return jpeg;
  }

  /** 就地从 IFD 表删除一个 entry（count 减 1、后续前移、next IFD 指针前移）。 */
  private static removeEntryInPlace(d: Uint8Array, le: boolean, ifdOff: number, tag: number): void {
    if (ifdOff < 6 || ifdOff + 2 > d.length) {
      return;
    }
    const count = LeicaMark.integer(d, ifdOff, 2, le);
    if (count <= 0) {
      return;
    }
    let idx = -1;
    for (let i = 0; i < count; i++) {
      const e = ifdOff + 2 + i * 12;
      if (e + 12 > d.length) {
        return;
      }
      if (LeicaMark.integer(d, e, 2, le) === tag) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return;
    }
    for (let i = idx; i < count - 1; i++) {
      const src = ifdOff + 2 + (i + 1) * 12;
      d.set(d.subarray(src, src + 12), ifdOff + 2 + i * 12);
    }
    const nextOld = ifdOff + 2 + count * 12;
    const nextNew = ifdOff + 2 + (count - 1) * 12;
    if (nextOld + 4 <= d.length) {
      d.set(d.subarray(nextOld, nextOld + 4), nextNew);
    }
    LeicaMark.writeInt(d, ifdOff, count - 1, 2, le);
  }

  // ---- 徽章元数据剥离（badge=false 导出路径）----

  private static stripBadgeMeta(jpeg: Uint8Array): Uint8Array {
    let cur = jpeg;
    try {
      while (true) {
        const out = LeicaMark.removeSegment(cur, 0xE4, CUSTOMIZE_MAGIC);
        if (out === cur) {
          break;
        }
        cur = out;
      }
      LeicaMark.stripBadgeTagsInPlace(cur);
    } catch (e) {
    }
    return cur;
  }

  /** 定位第一个 APP1 "Exif\0\0" 段，就地删除 IFD0 与 ExifIFD 里的徽章三 tag。 */
  private static stripBadgeTagsInPlace(jpeg: Uint8Array): void {
    let pos = 2;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker = jpeg[pos + 1];
      if (marker === 0xDA || marker === 0xD9) {
        return;
      }
      if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) {
        pos += 2;
        continue;
      }
      const len = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
      if (len < 2 || pos + 2 + len > jpeg.length) {
        return;
      }
      if (marker === 0xE1 && len >= 10
        && jpeg[pos + 4] === 0x45 && jpeg[pos + 5] === 0x78
        && jpeg[pos + 6] === 0x69 && jpeg[pos + 7] === 0x66
        && jpeg[pos + 8] === 0 && jpeg[pos + 9] === 0) {
        const dOff = pos + 10; // TIFF 头起点
        if (dOff + 8 > jpeg.length) {
          return;
        }
        const le = jpeg[dOff] === 0x49 && jpeg[dOff + 1] === 0x49;
        if (!le && !(jpeg[dOff] === 0x4D && jpeg[dOff + 1] === 0x4D)) {
          return;
        }
        const ifd0 = dOff + LeicaMark.integer(jpeg, dOff + 4, 4, le);
        LeicaMark.removeEntryInPlace(jpeg, le, ifd0, TAG_THEME);
        LeicaMark.removeEntryInPlace(jpeg, le, ifd0, TAG_LEGENDMODE);
        LeicaMark.removeEntryInPlace(jpeg, le, ifd0, TAG_MODE);
        const count = LeicaMark.integer(jpeg, ifd0, 2, le);
        for (let i = 0; i < count; i++) {
          const e = ifd0 + 2 + i * 12;
          if (e + 12 > jpeg.length) {
            break;
          }
          if (LeicaMark.integer(jpeg, e, 2, le) === TAG_EXIF_IFD_POINTER
            && LeicaMark.integer(jpeg, e + 2, 2, le) === 4
            && LeicaMark.integer(jpeg, e + 4, 4, le) === 1) {
            const exifIfd = dOff + LeicaMark.integer(jpeg, e + 8, 4, le);
            LeicaMark.removeEntryInPlace(jpeg, le, exifIfd, TAG_THEME);
            LeicaMark.removeEntryInPlace(jpeg, le, exifIfd, TAG_LEGENDMODE);
            LeicaMark.removeEntryInPlace(jpeg, le, exifIfd, TAG_MODE);
            break;
          }
        }
        return;
      }
      pos += 2 + len;
    }
  }

  // ---- 基础整数读写 ----

  private static integer(b: Uint8Array, off: number, len: number, le: boolean): number {
    let v = 0;
    for (let i = 0; i < len; i++) {
      const k = le ? len - i - 1 : i;
      v = (v << 8) | b[k + off];
    }
    return v;
  }

  private static writeInt(b: Uint8Array, off: number, v: number, len: number, le: boolean): void {
    for (let i = 0; i < len; i++) {
      const k = le ? i : len - 1 - i;
      b[k + off] = (v >>> (i * 8)) & 0xFF;
    }
  }

  /** 在 off 处写 "Madrid\0"（7 字节）。 */
  private static putMadrid(b: Uint8Array, off: number): void {
    b[off] = 0x4D; // M
    b[off + 1] = 0x61; // a
    b[off + 2] = 0x64; // d
    b[off + 3] = 0x72; // r
    b[off + 4] = 0x69; // i
    b[off + 5] = 0x64; // d
    b[off + 6] = 0;
  }

  /** 在 off 处写 inline "256\0"（4 字节）。 */
  private static putMode256(b: Uint8Array, off: number): void {
    b[off] = 0x32; // 2
    b[off + 1] = 0x35; // 5
    b[off + 2] = 0x36; // 6
    b[off + 3] = 0;
  }
}
