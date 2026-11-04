/**
 * RAW 解码 taskpool 结果载体（仅可序列化普通字段）。
 * 独立成文件：@Concurrent 函数只能引用 import 变量或局部变量。
 */

export class RawTaskResult {
  readonly rgba: ArrayBuffer;
  readonly width: number;
  readonly height: number;
  /** 由 TIFF EXIF 重建的 APP1（含 GPS/XMP 兜底迁移结果）；null 表示无。 */
  readonly app1: ArrayBuffer | null;

  constructor(rgba: ArrayBuffer, width: number, height: number, app1: ArrayBuffer | null) {
    this.rgba = rgba;
    this.width = width;
    this.height = height;
    this.app1 = app1;
  }
}