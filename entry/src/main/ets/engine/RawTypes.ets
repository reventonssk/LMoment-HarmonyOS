/**
 * RAW 解码 taskpool 结果载体（仅可序列化普通字段）。
 * 独立成文件：@Concurrent 函数只能引用 import 变量或局部变量。
 */

export class RawTaskResult {
  readonly rgba: ArrayBuffer;
  readonly width: number;
  readonly height: number;

  constructor(rgba: ArrayBuffer, width: number, height: number) {
    this.rgba = rgba;
    this.width = width;
    this.height = height;
  }
}
