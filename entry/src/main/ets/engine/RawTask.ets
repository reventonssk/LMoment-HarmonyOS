/**
 * RAW/DNG 解码 taskpool 任务（修复 RAW 导入主线程阻塞冻屏 AppFreeze/THREAD_BLOCK_6S）。
 * 文件读取 + 内嵌预览提取 + LibRaw 解码 + ARGB→RGBA + 降采样全部在工作线程完成；
 * 主线程仅做最后的 RGBA→PixelMap 包装。
 */

import { taskpool } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RawDecoder } from './RawDecoder';
import { PixelScale } from './PixelScale';
import { RawTaskResult } from './RawTypes';

@Concurrent
async function decodeRawTask(path: string, threshold: number, maxEdge: number): Promise<RawTaskResult | undefined> {
  // 1) 读文件字节（大 DNG 可达几十 MB，移出主线程）
  let bytes: Uint8Array;
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const size = fs.statSync(file.fd).size;
    if (size <= 0) {
      return undefined;
    }
    const ab = new ArrayBuffer(size);
    fs.readSync(file.fd, ab);
    bytes = new Uint8Array(ab);
  } finally {
    fs.closeSync(file);
  }
  // 2) 厂商内嵌 JPEG 预览（色彩最准）：image kit 解码 + 紧密化
  try {
    const preview = RawDecoder.extractPreview(bytes);
    if (preview !== undefined && preview.byteLength > 0) {
      const buf = new ArrayBuffer(preview.byteLength);
      new Uint8Array(buf).set(preview);
      const source = image.createImageSource(buf);
      const info = await source.getImageInfo();
      const scale = Math.min(1, maxEdge / Math.max(info.size.width, info.size.height));
      const tw = Math.max(1, Math.round(info.size.width * scale));
      const th = Math.max(1, Math.round(info.size.height * scale));
      const pm = await source.createPixelMap({
        desiredSize: { width: tw, height: th },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      });
      await source.release();
      const num = pm.getPixelBytesNumber();
      const raw = new ArrayBuffer(num);
      await pm.readPixelsToBuffer(raw);
      const src = new Uint8Array(raw);
      const rowBytes = tw * 4;
      const stride = pm.getBytesNumberPerRow();
      let tight: ArrayBuffer;
      if (stride === rowBytes && num >= rowBytes * th) {
        tight = raw;
      } else {
        const tb = new ArrayBuffer(rowBytes * th);
        const t = new Uint8Array(tb);
        for (let y = 0; y < th; y++) {
          t.set(src.subarray(y * stride, y * stride + rowBytes), y * rowBytes);
        }
        tight = tb;
      }
      pm.release().catch(() => {
      });
      return new RawTaskResult(tight, tw, th);
    }
  } catch (e) {
  }
  // 3) LibRaw 全量解码回退：ARGB 数组 → RGBA → 盒式降采样
  const decoded = RawDecoder.decode(bytes, threshold);
  if (decoded === undefined || decoded.length < 3) {
    return undefined;
  }
  const sw = decoded[0];
  const sh = decoded[1];
  if (sw < 1 || sh < 1 || decoded.length < sw * sh + 2) {
    return undefined;
  }
  const fullBuf = new ArrayBuffer(sw * sh * 4);
  const full = new Uint8Array(fullBuf);
  for (let i = 0; i < sw * sh; i++) {
    const argb = decoded[i + 2];
    full[i * 4] = (argb >>> 16) & 0xFF;
    full[i * 4 + 1] = (argb >>> 8) & 0xFF;
    full[i * 4 + 2] = argb & 0xFF;
    full[i * 4 + 3] = 255;
  }
  const scale = Math.min(1, maxEdge / Math.max(sw, sh));
  if (scale < 1) {
    const dw = Math.max(1, Math.round(sw * scale));
    const dh = Math.max(1, Math.round(sh * scale));
    const rgba = PixelScale.downscaleRgba(full, sw, sh, dw, dh);
    const outBuf = new ArrayBuffer(dw * dh * 4);
    new Uint8Array(outBuf).set(rgba);
    return new RawTaskResult(outBuf, dw, dh);
  }
  return new RawTaskResult(fullBuf, sw, sh);
}

/** UI 线程侧封装：派发任务并规整返回类型。 */
export class RawTaskRunner {
  static async run(path: string, threshold: number, maxEdge: number): Promise<RawTaskResult | undefined> {
    const out = await taskpool.execute(decodeRawTask, path, threshold, maxEdge);
    if (out instanceof RawTaskResult) {
      return out;
    }
    return undefined;
  }
}
