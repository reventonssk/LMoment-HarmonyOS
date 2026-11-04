/**
 * RAW/DNG 解码 taskpool 任务（修复 RAW 导入主线程阻塞冻屏 AppFreeze/THREAD_BLOCK_6S）。
 * 文件读取 + 内嵌预览提取 + LibRaw 解码 + ARGB→RGBA + 降采样全部在工作线程完成；
 * 主线程仅做最后的 RGBA→PixelMap 包装。
 */

import { taskpool } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RawDecoder } from './RawDecoder';
import { PixelScale } from './PixelScale';
import { RawTaskResult } from './RawTypes';
import { RawExif } from './RawExif';

const RAW_TAG: string = 'RawDebug';

/** taskpool 内诊断日志（解码链各失败点定位）。 */
function rawLog(msg: string): void {
  try {
    hilog.info(0xD00, RAW_TAG, '%{public}s', msg);
  } catch (e) {
  }
}

@Concurrent
async function decodeRawTask(path: string, threshold: number, maxEdge: number): Promise<RawTaskResult | undefined> {
  const t0: number = Date.now();
  // @Concurrent 内只能用局部变量：诊断日志用局部箭头（hilog 为顶层 import）
  const log = (msg: string): void => {
    try {
      hilog.info(0xD00, 'RawDebug', '%{public}s', msg);
    } catch (e) {
    }
  };
  // 1) 读文件字节（大 DNG 可达几十 MB，移出主线程）
  let bytes: Uint8Array;
  let file: fs.File | undefined = undefined;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const size = fs.statSync(file.fd).size;
    if (size <= 0) {
      log(`open ok but size=${size}`);
      return undefined;
    }
    const ab = new ArrayBuffer(size);
    fs.readSync(file.fd, ab);
    bytes = new Uint8Array(ab);
    log(`read ok bytes=${size} in ${Date.now() - t0}ms`);
  } catch (e) {
    log(`open/read FAIL: ${e instanceof Error ? e.message : 'unknown'}`);
    return undefined;
  } finally {
    if (file !== undefined) {
      try {
        fs.closeSync(file);
      } catch (e) {
      }
    }
  }
  // TIFF EXIF → APP1（含 GPS IFD / XMP 兜底迁移）。必须留在 worker 内：
  // 无 XMP 的 DNG 会触发全文件分块扫描，主线程实测阻塞 10s → THREAD_BLOCK_6S 杀进程。
  // 文件字节已在内存，readRange 直接切片，不再二次读盘。
  let app1: ArrayBuffer | null = null;
  try {
    const headLen: number = Math.min(262144, bytes.byteLength);
    const app1Bytes = RawExif.extractApp1(bytes.subarray(0, headLen),
      (off: number, len: number): Uint8Array => {
        const s: number = Math.max(0, Math.min(off, bytes.byteLength));
        const e: number = Math.max(s, Math.min(off + len, bytes.byteLength));
        return bytes.subarray(s, e);
      });
    if (app1Bytes !== undefined && app1Bytes.byteLength > 0) {
      const buf = new ArrayBuffer(app1Bytes.byteLength);
      new Uint8Array(buf).set(app1Bytes);
      app1 = buf;
    }
    log(`app1 ${app1 === null ? 0 : app1.byteLength}B in ${Date.now() - t0}ms`);
  } catch (e) {
    log(`app1 FAIL: ${e instanceof Error ? e.message : 'unknown'}`);
  }
  // 2) 厂商内嵌 JPEG 预览（色彩最准）：image kit 解码 + 紧密化
  try {
    const preview = RawDecoder.extractPreview(bytes);
    log(`extractPreview -> ${preview === undefined ? 'undefined' : preview.byteLength + 'B'}`);
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
      log(`preview path ok ${tw}x${th} in ${Date.now() - t0}ms`);
      return new RawTaskResult(tight, tw, th, app1);
    }
  } catch (e) {
    log(`preview path FAIL: ${e instanceof Error ? e.message : 'unknown'}`);
  }
  // 3) LibRaw 全量解码回退：ARGB 数组 → RGBA → 盒式降采样
  const t1: number = Date.now();
  const decoded = RawDecoder.decode(bytes, threshold);
  if (decoded === undefined || decoded.length < 3) {
    log(`LibRaw decode FAIL (undefined/short) in ${Date.now() - t1}ms`);
    return undefined;
  }
  const sw = decoded[0];
  const sh = decoded[1];
  if (sw < 1 || sh < 1 || decoded.length < sw * sh + 2) {
    log(`LibRaw decode invalid ${sw}x${sh} len=${decoded.length}`);
    return undefined;
  }
  log(`LibRaw decode ok ${sw}x${sh} in ${Date.now() - t1}ms`);
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
    log(`libraw path ok ${dw}x${dh} total ${Date.now() - t0}ms`);
    return new RawTaskResult(outBuf, dw, dh, app1);
  }
  log(`libraw path full ok ${sw}x${sh} total ${Date.now() - t0}ms`);
  return new RawTaskResult(fullBuf, sw, sh, app1);
}

/** taskpool 跨线程反序列化会丢失类标识：仅按字段形状收窄后的原样载体。 */
interface RawTaskOut {
  rgba: ArrayBuffer;
  width: number;
  height: number;
  app1: ArrayBuffer | null;
}

/** UI 线程侧封装：派发任务并规整返回类型。 */
export class RawTaskRunner {
  static async run(path: string, threshold: number, maxEdge: number): Promise<RawTaskResult | undefined> {
    try {
      const out = await taskpool.execute(decodeRawTask, path, threshold, maxEdge);
      if (out === undefined || out === null) {
        rawLog('task returned undefined (decode failed in worker)');
        return undefined;
      }
      // 一次性形状收窄（类标识跨线程丢失，不能 instanceof）
      const res = out as RawTaskOut;
      if (res.rgba instanceof ArrayBuffer && typeof res.width === 'number' && typeof res.height === 'number'
        && res.width > 0 && res.height > 0) {
        rawLog(`task ok ${res.width}x${res.height} ${res.rgba.byteLength}B`);
        return new RawTaskResult(res.rgba, res.width, res.height, res.app1);
      }
      rawLog(`task returned invalid shape: rgba=${typeof res.rgba}`);
      return undefined;
    } catch (e) {
      rawLog(`taskpool execute FAIL: ${e instanceof Error ? e.message : 'unknown'}`);
      return undefined;
    }
  }
}
