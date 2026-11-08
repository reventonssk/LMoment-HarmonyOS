/**
 * 导出时间的 EXIF 重写（移植自 v1.5.0 ExifTimes.kt「按当下时间」模式）。
 *
 * 「保留原图时间」（默认）：EXIF 时间 tag 原样移植，行为与移植前完全一致。
 * 「按当下时间」：把 IFD0 DateTime(0x0132)、ExifIFD DateTimeOriginal(0x9003)、
 * DateTimeDigitized(0x9004) 三个 ASCII tag 的值原地重写为导出时刻——
 * 只动这三个时间 tag，机型/拍摄参数/GPS 等其余 EXIF 不受影响。
 *
 * 边界：三 tag 为相机 JPEG 标配（count=20 的 ASCII），缺失或结构异常时跳过
 * 该 tag（安全兜底，不阻塞导出主链）；不新增 tag（注入会牵动 IFD 重排）。
 * 文件属性时间（入库时间）由系统强制写入，应用不可改，与原版行为一致。
 */

export class ExifTimes {
  /** EXIF 时间字段格式（冒号分隔日期是 EXIF 规范写法）：yyyy:MM:dd HH:mm:ss。 */
  static formatNow(): string {
    const d = new Date();
    return d.getFullYear() + ':' + ExifTimes.pad2(d.getMonth() + 1) + ':' + ExifTimes.pad2(d.getDate())
      + ' ' + ExifTimes.pad2(d.getHours()) + ':' + ExifTimes.pad2(d.getMinutes()) + ':'
      + ExifTimes.pad2(d.getSeconds());
  }

  /**
   * 对完整 APP1 段（FFE1 + 长度 + "Exif\0\0" + TIFF）原地重写三个时间 tag。
   * 内部先复制，不改动调用方持有的原段；结构异常时返回原段。
   */
  static rewriteSegmentTimes(seg: Uint8Array, timeStr: string): Uint8Array {
    // 完整 APP1 段：FFE1(2) + len(2) + "Exif\0\0"(6) + TIFF
    if (seg.length < 18 || seg[0] !== 0xFF || seg[1] !== 0xE1) {
      return seg;
    }
    if (seg[4] !== 0x45 || seg[5] !== 0x78 || seg[6] !== 0x69 || seg[7] !== 0x66
      || seg[8] !== 0 || seg[9] !== 0) {
      return seg;
    }
    const le = seg[10] === 0x49 && seg[11] === 0x49;
    if (!le && !(seg[10] === 0x4D && seg[11] === 0x4D)) {
      return seg;
    }
    const tiff = 10;
    const ifd0 = tiff + ExifTimes.u32(seg, 14, le);
    if (ifd0 < tiff + 8 || ifd0 + 2 > seg.length) {
      return seg;
    }
    const out = seg.slice();
    let exifIfd = -1;
    const count0 = ExifTimes.u16(out, ifd0, le);
    for (let i = 0; i < count0; i++) {
      const e = ifd0 + 2 + i * 12;
      if (e + 12 > out.length) {
        break;
      }
      const tag = ExifTimes.u16(out, e, le);
      if (tag === 0x0132) {
        ExifTimes.replaceAsciiValue(out, le, e, timeStr);
      } else if (tag === 0x8769 && ExifTimes.u16(out, e + 2, le) === 4
        && ExifTimes.u32(out, e + 4, le) === 1) {
        exifIfd = tiff + ExifTimes.u32(out, e + 8, le);
      }
    }
    if (exifIfd < tiff + 8 || exifIfd + 2 > out.length) {
      return out;
    }
    const countExif = ExifTimes.u16(out, exifIfd, le);
    for (let i = 0; i < countExif; i++) {
      const e = exifIfd + 2 + i * 12;
      if (e + 12 > out.length) {
        break;
      }
      const tag = ExifTimes.u16(out, e, le);
      if (tag === 0x9003 || tag === 0x9004) {
        ExifTimes.replaceAsciiValue(out, le, e, timeStr);
      }
    }
    return out;
  }

  /** 原地替换一个 ASCII entry 的值区：仅当类型 ASCII 且 count 足够容纳 19+\0。 */
  private static replaceAsciiValue(b: Uint8Array, le: boolean, entry: number, value: string): void {
    if (ExifTimes.u16(b, entry + 2, le) !== 2) {
      return;
    }
    const cnt = ExifTimes.u32(b, entry + 4, le);
    if (cnt < value.length + 1) {
      return;
    }
    // TIFF 偏移基准（"Exif\0\0" 之后）
    const valOff = 10 + ExifTimes.u32(b, entry + 8, le);
    if (valOff < 10 || valOff + value.length + 1 > b.length) {
      return;
    }
    for (let i = 0; i < value.length; i++) {
      b[valOff + i] = value.charCodeAt(i);
    }
    b[valOff + value.length] = 0;
  }

  private static pad2(n: number): string {
    return n < 10 ? '0' + n : '' + n;
  }

  private static u16(b: Uint8Array, off: number, le: boolean): number {
    if (off < 0 || off + 2 > b.length) {
      return 0;
    }
    return le ? (b[off] | (b[off + 1] << 8)) : ((b[off] << 8) | b[off + 1]);
  }

  private static u32(b: Uint8Array, off: number, le: boolean): number {
    if (off < 0 || off + 4 > b.length) {
      return 0;
    }
    if (le) {
      return (b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)) >>> 0;
    }
    return ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) >>> 0;
  }
}
