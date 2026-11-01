/**
 * 图片管线：URI 解码（降采样+EXIF 旋转）、RGBA ↔ PixelMap、JPEG 打包、
 * 系统相册保存（SaveButton 授权口径）、图库选图与合成测试图。
 * 像素口径统一为紧密排布 RGBA（无行尾 padding）。
 */

import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { common } from '@kit.AbilityKit';

export class DecodedImage {
  readonly pixelMap: image.PixelMap;
  readonly width: number;
  readonly height: number;
  /** 紧密排布 RGBA（w*h*4）。 */
  readonly data: Uint8Array;

  constructor(pixelMap: image.PixelMap, width: number, height: number, data: Uint8Array) {
    this.pixelMap = pixelMap;
    this.width = width;
    this.height = height;
    this.data = data;
  }
}

export class ImagePipeline {
  /** 预览最长边（对齐 Android scaleBitmap(base, 1600)）。 */
  static readonly PREVIEW_EDGE = 1600;
  /** 缩略图最长边。 */
  static readonly THUMB_EDGE = 128;
  /** 导出工作上限：长边 ≤ 4096、短边 ≤ 3072（对齐 Android MAX_WORK_*）。 */
  static readonly WORK_LONG = 4096;
  static readonly WORK_SHORT = 3072;

  /**
   * URI（file:// 或图库 photo://）→ 降采样 + EXIF 旋转的 RGBA。
   * capShort > 0 时附加短边上限（导出口径：长 4096 / 短 3072）。
   */
  static async decodeUri(uri: string, maxEdge: number, capShort: number = 0): Promise<DecodedImage | undefined> {
    let file: fs.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      const info = await source.getImageInfo();
      const sw = info.size.width;
      const sh = info.size.height;
      if (sw < 1 || sh < 1) {
        return undefined;
      }
      let ori = 0;
      try {
        ori = ImagePipeline.parseOrientation(source.getImagePropertySync(image.PropertyKey.ORIENTATION));
      } catch (e) {
        ori = 0;
      }
      const rotate = ImagePipeline.orientationRotate(ori);
      const swap = ori === 5 || ori === 6 || ori === 7 || ori === 8;
      // 目标尺寸（旋转后口径）
      let dw = sw;
      let dh = sh;
      if (swap) {
        dw = sh;
        dh = sw;
      }
      const long = Math.max(dw, dh);
      const short = Math.min(dw, dh);
      let scale = Math.min(1, maxEdge / long);
      if (capShort > 0) {
        scale = Math.min(scale, capShort / short);
      }
      let tw = Math.max(1, Math.round(dw * scale));
      let th = Math.max(1, Math.round(dh * scale));
      if (swap) {
        const t = tw;
        tw = th;
        th = t;
      }
      const pm = await source.createPixelMap({
        desiredSize: { width: tw, height: th },
        rotate: rotate,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      });
      const out = await ImagePipeline.extract(pm);
      return out;
    } catch (e) {
      return undefined;
    } finally {
      if (source !== undefined) {
        try {
          await source.release();
        } catch (e) {
        }
      }
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
  }

  /** 解析 EXIF Orientation（数字串 1-8 或名称），失败返回 0。 */
  static parseOrientation(v: string): number {
    const s = v.trim();
    if (s.length === 1 && s >= '1' && s <= '8') {
      return parseInt(s);
    }
    const names: string[] = ['top-left', 'top-right', 'bottom-right', 'bottom-left',
      'left-top', 'right-top', 'right-bottom', 'left-bottom'];
    const low = s.toLowerCase();
    for (let i = 0; i < names.length; i++) {
      if (low === names[i]) {
        return i + 1;
      }
    }
    return 0;
  }

  /** EXIF → 顺时针旋转角（镜像 2/4 忽略，5/7 按主旋转近似）。 */
  static orientationRotate(ori: number): number {
    if (ori === 3 || ori === 4) {
      return 180;
    }
    if (ori === 5 || ori === 6) {
      return 90;
    }
    if (ori === 7 || ori === 8) {
      return 270;
    }
    return 0;
  }

  /** PixelMap → 紧密 RGBA（处理 stride padding 与临时 buffer 复用）。 */
  static async extract(pm: image.PixelMap): Promise<DecodedImage> {
    const info = await pm.getImageInfo();
    const w = info.size.width;
    const h = info.size.height;
    const num = pm.getPixelBytesNumber();
    const raw = new ArrayBuffer(num);
    await pm.readPixelsToBuffer(raw);
    const src = new Uint8Array(raw);
    const tight = new Uint8Array(w * h * 4);
    const stride = info.stride;
    if (stride === w * 4) {
      tight.set(src);
    } else {
      const rowBytes = w * 4;
      for (let y = 0; y < h; y++) {
        tight.set(src.subarray(y * stride, y * stride + rowBytes), y * rowBytes);
      }
    }
    return new DecodedImage(pm, w, h, tight);
  }

  /** 紧密 RGBA → PixelMap（预览渲染用）。 */
  static rgbaToPixelMap(data: Uint8Array, w: number, h: number): Promise<image.PixelMap> {
    const buf = new ArrayBuffer(w * h * 4);
    new Uint8Array(buf).set(data);
    const opts: image.InitializationOptions = {
      size: { width: w, height: h },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false
    };
    return image.createPixelMap(buf, opts);
  }

  /** PixelMap → JPEG 字节。 */
  static async packJpeg(pm: image.PixelMap, quality: number): Promise<Uint8Array> {
    const packer = image.createImagePacker();
    try {
      const out = await packer.packing(pm, { format: 'image/jpeg', quality: quality });
      return new Uint8Array(out);
    } finally {
      packer.release();
    }
  }

  /**
   * JPEG 字节 → RGBA（用于「分享码导入的 JPEG 结果」或测试图回路）。
   */
  static async decodeJpegBytes(jpeg: Uint8Array, maxEdge: number): Promise<DecodedImage | undefined> {
    try {
      const buf = new ArrayBuffer(jpeg.byteLength);
      new Uint8Array(buf).set(jpeg);
      const source = image.createImageSource(buf);
      const info = await source.getImageInfo();
      const scale = Math.min(1, maxEdge / Math.max(info.size.width, info.size.height));
      const pm = await source.createPixelMap({
        desiredSize: {
          width: Math.max(1, Math.round(info.size.width * scale)),
          height: Math.max(1, Math.round(info.size.height * scale))
        },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      });
      await source.release();
      return await ImagePipeline.extract(pm);
    } catch (e) {
      return undefined;
    }
  }

  /** 在 SaveButton 授权窗口内立即创建相册资产，返回可写 URI。 */
  static async createAssetTarget(context: common.Context, ext: string): Promise<string> {
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    return helper.createAsset(photoAccessHelper.PhotoType.IMAGE, ext);
  }

  /** 向已创建的相册 URI 写入数据（不受授权时限约束）。 */
  static async writeToGallery(uri: string, data: Uint8Array): Promise<void> {
    const file = await fs.open(uri, fs.OpenMode.READ_WRITE);
    try {
      const buf = new ArrayBuffer(data.byteLength);
      new Uint8Array(buf).set(data);
      await fs.write(file.fd, buf);
    } finally {
      await fs.close(file);
    }
  }

  /** 系统图库选图（单选），返回 URI；取消返回 ''。 */
  static async pickImage(): Promise<string> {
    const picker = new photoAccessHelper.PhotoViewPicker();
    const res = await picker.select({
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: 1
    });
    if (res.photoUris !== undefined && res.photoUris.length > 0) {
      return res.photoUris[0];
    }
    return '';
  }

  /** 合成测试图（渐变 + 色块 + 灰阶，供模拟器无图库内容时闭环验证）。 */
  static async makeTestImage(w: number, h: number): Promise<DecodedImage> {
    const data = new Uint8Array(w * h * 4);
    const patches: number[][] = [
      [230, 60, 60], [60, 200, 80], [60, 110, 230], [240, 210, 60],
      [220, 120, 200], [60, 220, 220], [130, 80, 50], [20, 20, 25],
      [235, 180, 150], [190, 140, 110], [245, 150, 90], [70, 160, 170],
      [200, 200, 210], [150, 160, 140], [110, 90, 130], [40, 80, 60]
    ];
    const patchW = Math.floor(w / 4);
    const patchH = Math.floor(h / 8);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const i = (y * w + x) * 4;
        let r = 0;
        let g = 0;
        let b = 0;
        const band = Math.floor(y / patchH);
        if (band === 0) {
          // 顶部：横向灰阶渐变
          const v = Math.round(255 * x / (w - 1));
          r = v;
          g = v;
          b = v;
        } else if (band === 1) {
          // 天空蓝 → 橙色黄昏渐变（检验风格链色彩倾向）
          const t = x / (w - 1);
          r = Math.round(90 + t * 160);
          g = Math.round(140 + t * 40);
          b = Math.round(220 - t * 160);
        } else if (band >= 2 && band <= 5) {
          // 4×4 色块
          const col = Math.min(3, Math.floor(x / patchW));
          const c = patches[(band - 2) * 4 + col];
          r = c[0];
          g = c[1];
          b = c[2];
        } else if (band === 6) {
          // 细灰阶条（检验色调曲线量化与抖动）
          const step = Math.min(31, Math.floor(x / (w / 32)));
          const v = Math.round(step * 255 / 31);
          r = v;
          g = v;
          b = v;
        } else {
          // 底部：暗角敏感区（径向渐变）
          const dx = (x / w - 0.5) * 2;
          const dy = (y / h - 0.5) * 2;
          const d = Math.min(1, Math.sqrt(dx * dx + dy * dy));
          const v = Math.round(200 * (1 - d * 0.6));
          r = v;
          g = v;
          b = Math.round(v * 1.05);
        }
        data[i] = r;
        data[i + 1] = g;
        data[i + 2] = b;
        data[i + 3] = 255;
      }
    }
    const pm = await ImagePipeline.rgbaToPixelMap(data, w, h);
    return new DecodedImage(pm, w, h, data);
  }

  /** 导出工作上限缩放（长 4096 / 短 3072）。 */
  static workScale(w: number, h: number): number {
    if (w < 1 || h < 1) {
      return 1;
    }
    const long = Math.max(w, h);
    const short = Math.min(w, h);
    return Math.min(1, ImagePipeline.WORK_LONG / long, ImagePipeline.WORK_SHORT / short);
  }

  /** 紧密 RGBA 盒式降采样（生成缩略图源）。 */
  static downscaleRgba(src: Uint8Array, sw: number, sh: number, dw: number, dh: number): Uint8Array {
    const out = new Uint8Array(dw * dh * 4);
    const xRatio = sw / dw;
    const yRatio = sh / dh;
    for (let dy = 0; dy < dh; dy++) {
      const y0 = Math.floor(dy * yRatio);
      const y1 = Math.min(sh, Math.max(y0 + 1, Math.floor((dy + 1) * yRatio)));
      for (let dx = 0; dx < dw; dx++) {
        const x0 = Math.floor(dx * xRatio);
        const x1 = Math.min(sw, Math.max(x0 + 1, Math.floor((dx + 1) * xRatio)));
        let r = 0;
        let g = 0;
        let b = 0;
        let n = 0;
        for (let y = y0; y < y1; y++) {
          const row = y * sw * 4;
          for (let x = x0; x < x1; x++) {
            const i = row + x * 4;
            r += src[i];
            g += src[i + 1];
            b += src[i + 2];
            n++;
          }
        }
        const o = (dy * dw + dx) * 4;
        out[o] = Math.round(r / n);
        out[o + 1] = Math.round(g / n);
        out[o + 2] = Math.round(b / n);
        out[o + 3] = 255;
      }
    }
    return out;
  }
}
