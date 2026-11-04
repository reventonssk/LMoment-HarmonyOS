import { image } from '@kit.ImageKit';
import { colorSpaceManager } from '@kit.ArkGraphics2D';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImagePipeline } from './ImagePipeline';
import { yieldUI } from './PixAsync';

export class HdrData {
  readonly gainmapJpeg: Uint8Array;
  readonly minLog2: string;
  readonly maxLog2: string;
  readonly gamma: string;
  readonly offsetSdr: string;
  readonly offsetHdr: string;
  readonly capMinLog2: string;
  readonly capMaxLog2: string;

  constructor(gainmapJpeg: Uint8Array, minLog2: string, maxLog2: string, gamma: string,
    offsetSdr: string, offsetHdr: string, capMinLog2: string, capMaxLog2: string) {
    this.gainmapJpeg = gainmapJpeg;
    this.minLog2 = minLog2;
    this.maxLog2 = maxLog2;
    this.gamma = gamma;
    this.offsetSdr = offsetSdr;
    this.offsetHdr = offsetHdr;
    this.capMinLog2 = capMinLog2;
    this.capMaxLog2 = capMaxLog2;
  }
}

export class HdrCheck {
  readonly ok: boolean;
  readonly brief: string;
  readonly detail: string;

  constructor(ok: boolean, brief: string, detail: string) {
    this.ok = ok;
    this.brief = brief;
    this.detail = detail;
  }
}

class HdrSegment {
  readonly bytes: Uint8Array;
  readonly marker: number;
  readonly dataStart: number;
  readonly dataLength: number;

  constructor(bytes: Uint8Array, marker: number, dataStart: number, dataLength: number) {
    this.bytes = bytes;
    this.marker = marker;
    this.dataStart = dataStart;
    this.dataLength = dataLength;
  }
}

export class HdrGainMap {
  private static readonly XMP_NS: string = 'http://ns.adobe.com/xap/1.0/';
  private static readonly DEFAULT_OFFSET: string = '0.015625';

  static extract(jpeg: Uint8Array): HdrData | undefined {
    if (!HdrGainMap.isJpeg(jpeg)) {
      return undefined;
    }
    let mpfStart: number = -1;
    let xmp: string = '';
    HdrGainMap.forEachSegment(jpeg, (segment: HdrSegment): boolean => {
      if (segment.marker === 0xE1 && HdrGainMap.startsWith(segment, HdrGainMap.ascii(HdrGainMap.XMP_NS))) {
        if (xmp === '') {
          xmp = HdrGainMap.segmentText(segment);
        }
      }
      if (segment.marker === 0xE2 && HdrGainMap.startsWith(segment, HdrGainMap.ascii('MPF\u0000'))) {
        mpfStart = segment.dataStart;
        return true;
      }
      return false;
    });
    if (mpfStart < 0) {
      return undefined;
    }
    const base: number = mpfStart;
    const bigEndian: boolean = jpeg[base] === 0x4D;
    const tiffBase: number = base + 4;
    const ifd: number = tiffBase + HdrGainMap.u32(jpeg, base + 8, bigEndian);
    if (ifd < 0 || ifd + 2 > jpeg.length) {
      return undefined;
    }
    const count: number = HdrGainMap.u16(jpeg, ifd, bigEndian);
    let entry: number = -1;
    let pos: number = ifd + 2;
    for (let i = 0; i < count; i++) {
      if (pos + 12 > jpeg.length) {
        return undefined;
      }
      if (HdrGainMap.u16(jpeg, pos, bigEndian) === 0xB002) {
        entry = tiffBase + HdrGainMap.u32(jpeg, pos + 8, bigEndian);
        break;
      }
      pos += 12;
    }
    if (entry < 0 || entry + 32 > jpeg.length) {
      return undefined;
    }
    const size: number = HdrGainMap.u32(jpeg, entry + 20, bigEndian);
    const offset: number = HdrGainMap.u32(jpeg, entry + 24, bigEndian);
    const start: number = tiffBase + offset;
    if (size < 4 || start < 0 || start + size > jpeg.length) {
      return undefined;
    }
    const gain: Uint8Array = jpeg.slice(start, start + size);
    if (!HdrGainMap.isJpeg(gain)) {
      return undefined;
    }
    const min: string = HdrGainMap.attr(xmp, 'hdrgm:GainMapMin', '0.0');
    const max: string = HdrGainMap.attr(xmp, 'hdrgm:GainMapMax', '1.0');
    const gamma: string = HdrGainMap.attr(xmp, 'hdrgm:Gamma', '1');
    const offSdr: string = HdrGainMap.attr(xmp, 'hdrgm:OffsetSDR', HdrGainMap.DEFAULT_OFFSET);
    const offHdr: string = HdrGainMap.attr(xmp, 'hdrgm:OffsetHDR', HdrGainMap.DEFAULT_OFFSET);
    const capMin: string = HdrGainMap.attr(xmp, 'hdrgm:HDRCapacityMin', '0.0');
    const capMax: string = HdrGainMap.attr(xmp, 'hdrgm:HDRCapacityMax', max);
    return new HdrData(gain, min, max, gamma, offSdr, offHdr, capMin, capMax);
  }

  static embed(primary: Uint8Array, data: HdrData): Uint8Array {
    if (!HdrGainMap.isJpeg(primary) || !HdrGainMap.isJpeg(data.gainmapJpeg)) {
      return primary;
    }
    const base: Uint8Array = HdrGainMap.truncate(HdrGainMap.strip(primary));
    const secondary: Uint8Array = HdrGainMap.ensureSecondaryXmp(data.gainmapJpeg, data);
    const xmp: Uint8Array = HdrGainMap.app1(HdrGainMap.primaryXmp(secondary.length, data));
    let insert: number = 2;
    let pos: number = 2;
    while (pos + 4 <= base.length && base[pos] === 0xFF) {
      const marker: number = base[pos + 1];
      if (marker < 0xE0 || marker > 0xEF) {
        break;
      }
      const length: number = HdrGainMap.u16(base, pos + 2, true);
      if (length < 2 || pos + 2 + length > base.length) {
        return primary;
      }
      pos += 2 + length;
      insert = pos;
    }
    const withXmp: Uint8Array = HdrGainMap.insert(base, insert, xmp);
    const sos: number = HdrGainMap.findSos(withXmp);
    if (sos < 0) {
      return primary;
    }
    const primarySize: number = withXmp.length + 90;
    const secondaryOffset: number = primarySize - sos - 8;
    const mpfPayload: Uint8Array = HdrGainMap.mpfPayload(primarySize, secondary.length, secondaryOffset);
    const mpf: Uint8Array = new Uint8Array(90);
    mpf.set(HdrGainMap.ascii('\u00FF\u00E2'), 0);
    mpf[2] = 0;
    mpf[3] = 0x58;
    mpf.set(mpfPayload, 4);
    const out: Uint8Array = new Uint8Array(primarySize + secondary.length);
    out.set(withXmp.slice(0, sos), 0);
    out.set(mpf, sos);
    out.set(withXmp.slice(sos), sos + mpf.length);
    out.set(secondary, primarySize);
    return out;
  }

  static truncateToPrimary(jpeg: Uint8Array): Uint8Array {
    return HdrGainMap.truncate(jpeg);
  }

  static async synthFromRgba(rgba: Uint8Array, width: number, height: number, level: number): Promise<HdrData | undefined> {
    if (width < 1 || height < 1 || rgba.length < width * height * 4) {
      return undefined;
    }
    const scale: number = Math.min(1, 512 / Math.max(width, height));
    const gw: number = Math.max(1, Math.round(width * scale));
    const gh: number = Math.max(1, Math.round(height * scale));
    const gain: Uint8Array = new Uint8Array(gw * gh * 4);
    const maxEv: number = level === 2 ? 2.5 : (level === 1 ? 2.0 : 1.5);
    for (let y = 0; y < gh; y++) {
      if ((y & 15) === 0) {
        await yieldUI();
      }
      const sy: number = Math.min(height - 1, Math.floor(y / scale));
      for (let x = 0; x < gw; x++) {
        const sx: number = Math.min(width - 1, Math.floor(x / scale));
        const si: number = (sy * width + sx) * 4;
        const lum: number = (0.2126 * rgba[si] + 0.7152 * rgba[si + 1] + 0.0722 * rgba[si + 2]) / 255;
        const t: number = Math.max(0, Math.min(1, (lum - 0.68) / 0.32));
        const shaped: number = t * t * (3 - 2 * t);
        const value: number = Math.round(255 * Math.min(1, shaped * maxEv / (maxEv + 1.0)));
        const gi: number = (y * gw + x) * 4;
        gain[gi] = value;
        gain[gi + 1] = value;
        gain[gi + 2] = value;
        gain[gi + 3] = 255;
      }
    }
    const pm = await ImagePipeline.rgbaToPixelMap(gain, gw, gh);
    try {
      const jpeg: Uint8Array = await ImagePipeline.packJpeg(pm, 90);
      return new HdrData(jpeg, '0.0', maxEv.toFixed(3), '1', HdrGainMap.DEFAULT_OFFSET,
        HdrGainMap.DEFAULT_OFFSET, '0.0', maxEv.toFixed(3));
    } finally {
      pm.release().catch(() => {
      });
    }
  }

  /**
   * 系统编解码 HDR 路径（ISO 21496-1 双层 JPEG）：
   * 主图 PixelMap + GAINMAP 辅助图 + HdrGainmapMetadata → ImagePacker 编码，
   * 再把源 EXIF APP1 插回 SOI 后，并同步修补 MPF 中附属图的绝对偏移。
   * 图库/媒体库按增益图元数据走 HDR 渲染（旧手写 Ultra HDR 容器按 SDR 显示）。
   * 失败返回 undefined，调用方回退手写容器路径。
   */
  static async synthSystemHdr(rgba: Uint8Array, width: number, height: number, level: number,
    srcApp1?: Uint8Array): Promise<Uint8Array | undefined> {
    if (width < 1 || height < 1 || rgba.length < width * height * 4) {
      return undefined;
    }
    const maxEv: number = level === 2 ? 2.5 : (level === 1 ? 2.0 : 1.5);
    const scale: number = Math.min(1, 512 / Math.max(width, height));
    const gw: number = Math.max(1, Math.round(width * scale));
    const gh: number = Math.max(1, Math.round(height * scale));
    // createAuxiliaryPicture 仅收 BGRA 连续像素；灰度增益图 B=G=R=v
    const bgra: Uint8Array = new Uint8Array(gw * gh * 4);
    for (let y = 0; y < gh; y++) {
      if ((y & 15) === 0) {
        await yieldUI();
      }
      const sy: number = Math.min(height - 1, Math.floor(y / scale));
      for (let x = 0; x < gw; x++) {
        const sx: number = Math.min(width - 1, Math.floor(x / scale));
        const si: number = (sy * width + sx) * 4;
        const lum: number = (0.2126 * rgba[si] + 0.7152 * rgba[si + 1] + 0.0722 * rgba[si + 2]) / 255;
        const t: number = Math.max(0, Math.min(1, (lum - 0.68) / 0.32));
        const shaped: number = t * t * (3 - 2 * t);
        const value: number = Math.round(255 * Math.min(1, shaped * maxEv / (maxEv + 1.0)));
        const gi: number = (y * gw + x) * 4;
        bgra[gi] = value;
        bgra[gi + 1] = value;
        bgra[gi + 2] = value;
        bgra[gi + 3] = 255;
      }
    }
    let mainPm: image.PixelMap | undefined = undefined;
    let picture: image.Picture | undefined = undefined;
    let aux: image.AuxiliaryPicture | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    let step: string = 'gainmap-fill';
    try {
      // 主图也必须是 DMA（getHdrComposedPixelmap 的约束同样适用于编码路径：
      // "MainPixelMap's allocator type is not DMA" 会 7600201，且 packer 会静默丢增益图）。
      const mainBuf: ArrayBuffer = new ArrayBuffer(width * height * 4);
      new Uint8Array(mainBuf).set(rgba.subarray(0, width * height * 4));
      const mainOpts: image.InitializationOptions = {
        size: { width: width, height: height },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      };
      step = 'createMainPixelmap(DMA)';
      mainPm = await image.createPixelMapUsingAllocator(mainBuf, mainOpts, image.AllocatorType.DMA);
      step = 'createPicture';
      picture = image.createPicture(mainPm);
      // setMetadata(HDR_GAINMAP_METADATA) 只支持 DMA 内存（62980173），
      // 故必须用 createAuxiliaryPictureUsingAllocator 显式申请 DMA，不能用共享内存的 createAuxiliaryPicture。
      const auxInfo: image.AuxiliaryPictureInfo = {
        auxiliaryPictureType: image.AuxiliaryPictureType.GAINMAP,
        size: { width: gw, height: gh },
        rowStride: gw * 4,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        colorSpace: colorSpaceManager.create(colorSpaceManager.ColorSpace.SRGB)
      };
      step = 'createAuxiliaryPicture(DMA)';
      aux = image.createAuxiliaryPictureUsingAllocator(auxInfo, image.AllocatorType.DMA, bgra.buffer);
      step = 'setAuxiliaryPicture';
      picture.setAuxiliaryPicture(image.AuxiliaryPictureType.GAINMAP, aux);
      const gainPm: image.PixelMap | null = picture.getGainmapPixelmap();
      if (gainPm === null) {
        hilog.warn(0xF100, 'HdrSys', 'gainmap pixelmap null');
        return undefined;
      }
      const chan: image.GainmapChannel = {
        gainmapMax: maxEv,
        gainmapMin: 0.0,
        gamma: 1.0,
        baseOffset: 0.015625,
        alternateOffset: 0.015625
      };
      const meta: image.HdrGainmapMetadata = {
        writerVersion: 0,
        miniVersion: 0,
        gainmapChannelCount: 1,
        useBaseColorFlag: true,
        baseHeadroom: 1.0,
        alternateHeadroom: Math.pow(2, maxEv),
        channels: [chan]
      };
      step = 'setMetadata';
      await gainPm.setMetadata(image.HdrMetadataKey.HDR_GAINMAP_METADATA, meta);
      packer = image.createImagePacker();
      step = 'packing';
      // desiredDynamicRange 默认 SDR 会丢掉增益图；AUTO 按内容编码（含 GAINMAP 辅助图）。
      const packed: ArrayBuffer = await packer.packing(picture, {
        format: 'image/jpeg',
        quality: 95,
        needsPackProperties: true,
        desiredDynamicRange: image.PackingDynamicRange.AUTO
      });
      const sys: Uint8Array = new Uint8Array(packed);
      hilog.info(0xF100, 'HdrSys',
        'sys pack ok %{public}d bytes gainmap=%{public}dx%{public}d maxEv=%{public}s',
        sys.length, gw, gh, maxEv.toFixed(1));
      const out: Uint8Array = HdrGainMap.patchExifMpf(sys, srcApp1);
      HdrGainMap.logStructure(out);
      return out;
    } catch (e) {
      hilog.warn(0xF100, 'HdrSys', 'sys hdr failed at %{public}s: %{public}s', step, `${e}`);
      return undefined;
    } finally {
      if (packer !== undefined) {
        packer.release().catch(() => {
        });
      }
      if (picture !== undefined) {
        picture.release();
      }
      if (aux !== undefined) {
        aux.release();
      }
      if (mainPm !== undefined) {
        mainPm.release().catch(() => {
        });
      }
    }
  }

  /** 扫描最终 JPEG 结构并打日志：SOI 数、第二图像起点、MPF/ISO-21496-1/Exif 段位置。 */
  private static logStructure(j: Uint8Array): void {
    let secondSoi: number = -1;
    let mpfAt: number = -1;
    let isoAt: number = -1;
    let exifAt: number = -1;
    for (let i = 0; i + 8 < j.length; i++) {
      if (secondSoi < 0 && i > 0 && j[i] === 0xFF && j[i + 1] === 0xD8) {
        secondSoi = i;
      }
      if (mpfAt < 0 && j[i] === 0x4D && j[i + 1] === 0x50 && j[i + 2] === 0x46 && j[i + 3] === 0x00) {
        mpfAt = i;
      }
      if (isoAt < 0 && j[i] === 0x75 && j[i + 1] === 0x72 && j[i + 2] === 0x6E && j[i + 3] === 0x3A &&
        j[i + 4] === 0x69 && j[i + 5] === 0x73 && j[i + 6] === 0x6F) {
        isoAt = i;
      }
      if (exifAt < 0 && j[i] === 0x45 && j[i + 1] === 0x78 && j[i + 2] === 0x69 && j[i + 3] === 0x66 &&
        j[i + 4] === 0x00) {
        exifAt = i;
      }
    }
    hilog.info(0xF100, 'HdrSys',
      'jpeg struct len=%{public}d soi2=%{public}d mpf=%{public}d iso=%{public}d exif=%{public}d',
      j.length, secondSoi, mpfAt, isoAt, exifAt);
  }

  /** 系统双层 JPEG：SOI 后插入源 EXIF APP1；插入前先把 MPF 附属图绝对偏移 +delta。 */
  private static patchExifMpf(jpeg: Uint8Array, app1?: Uint8Array): Uint8Array {
    if (app1 === undefined || app1.length < 4 || app1[0] !== 0xFF || app1[1] !== 0xE1) {
      return jpeg;
    }
    const patched: Uint8Array = HdrGainMap.patchMpfOffsets(jpeg, app1.length);
    const out: Uint8Array = new Uint8Array(patched.length + app1.length);
    out.set(patched.subarray(0, 2), 0);
    out.set(app1, 2);
    out.set(patched.subarray(2), 2 + app1.length);
    return out;
  }

  /** 定位主图 APP2 "MPF\0" 段，把 MP Entry 中第 2 张起的图像数据绝对偏移加 delta。 */
  private static patchMpfOffsets(jpeg: Uint8Array, delta: number): Uint8Array {
    let payloadAt: number = -1;
    let pos: number = 2;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker: number = jpeg[pos + 1];
      if (marker === 0xDA || marker === 0xD9) {
        break;
      }
      if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) {
        pos += 2;
        continue;
      }
      const len: number = HdrGainMap.u16(jpeg, pos + 2, true);
      if (len < 2 || pos + 2 + len > jpeg.length) {
        break;
      }
      if (marker === 0xE2 && len >= 12 &&
        HdrGainMap.matchAt(jpeg, pos + 4, HdrGainMap.ascii('MPF\u0000'))) {
        payloadAt = pos + 4;
        break;
      }
      pos += 2 + len;
    }
    if (payloadAt < 0) {
      return jpeg;
    }
    const tiff: number = payloadAt + 4;
    const le: boolean = jpeg[tiff] === 0x49 && jpeg[tiff + 1] === 0x49;
    if (!le && !(jpeg[tiff] === 0x4D && jpeg[tiff + 1] === 0x4D)) {
      return jpeg;
    }
    const ifd: number = tiff + HdrGainMap.u32(jpeg, tiff + 4, le);
    if (ifd < 0 || ifd + 2 > jpeg.length) {
      return jpeg;
    }
    const count: number = HdrGainMap.u16(jpeg, ifd, le);
    let entriesAt: number = -1;
    let entryCount: number = 0;
    let p: number = ifd + 2;
    for (let i = 0; i < count; i++) {
      if (p + 12 > jpeg.length) {
        return jpeg;
      }
      if (HdrGainMap.u16(jpeg, p, le) === 0xB002) {
        entryCount = HdrGainMap.u32(jpeg, p + 4, le);
        entriesAt = tiff + HdrGainMap.u32(jpeg, p + 8, le);
        break;
      }
      p += 12;
    }
    if (entriesAt < 0 || entryCount < 1) {
      return jpeg;
    }
    const out: Uint8Array = jpeg.slice();
    for (let i = 1; i < entryCount; i++) {
      const e: number = entriesAt + i * 16 + 8;
      if (e + 4 > out.length) {
        break;
      }
      const v: number = HdrGainMap.u32(out, e, le);
      if (v > 0) {
        HdrGainMap.putValue(out, e, v + delta, 4, le);
      }
    }
    return out;
  }

  static applyPreview(rgba: Uint8Array, width: number, height: number, level: number): Uint8Array {
    const out: Uint8Array = rgba.slice();
    const strength: number = level === 2 ? 0.34 : (level === 1 ? 0.26 : 0.18);
    for (let i = 0; i < width * height * 4; i += 4) {
      const lum: number = (0.2126 * out[i] + 0.7152 * out[i + 1] + 0.0722 * out[i + 2]) / 255;
      const t: number = Math.max(0, Math.min(1, (lum - 0.62) / 0.38));
      const gain: number = 1 + t * t * strength;
      out[i] = Math.min(255, Math.round(out[i] * gain));
      out[i + 1] = Math.min(255, Math.round(out[i + 1] * gain));
      out[i + 2] = Math.min(255, Math.round(out[i + 2] * gain));
    }
    return out;
  }

  static verify(jpeg: Uint8Array): HdrCheck {
    if (!HdrGainMap.isJpeg(jpeg)) {
      return new HdrCheck(false, 'HDR=非JPEG', '输入不是 JPEG');
    }
    const eoi: number = HdrGainMap.mainEoi(jpeg);
    if (eoi < 0 || eoi + 2 >= jpeg.length || jpeg[eoi] !== 0xFF || jpeg[eoi + 1] !== 0xD8) {
      return new HdrCheck(false, 'HDR=无增益图', '主图 EOI 后没有第二张 JPEG');
    }
    let xmp: boolean = false;
    let mpf: boolean = false;
    HdrGainMap.forEachSegment(jpeg, (segment: HdrSegment): boolean => {
      if (segment.marker === 0xE1 && HdrGainMap.startsWith(segment, HdrGainMap.ascii(HdrGainMap.XMP_NS))) {
        xmp = true;
      }
      if (segment.marker === 0xE2 && HdrGainMap.startsWith(segment, HdrGainMap.ascii('MPF\u0000'))) {
        mpf = true;
      }
      return false;
    });
    const ok: boolean = xmp && mpf;
    return new HdrCheck(ok, ok ? 'HDR=增益图 ok' : 'HDR=增益图有疑问',
      'XMP=' + xmp + ' MPF=' + mpf + ' secondary=' + (jpeg.length - eoi) + 'B');
  }

  private static primaryXmp(length: number, data: HdrData): string {
    return '<x:xmpmeta xmlns:x="adobe:ns:meta/">' +
      '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' +
      '<rdf:Description rdf:about="" xmlns:Container="http://ns.google.com/photos/1.0/container/"' +
      ' xmlns:Item="http://ns.google.com/photos/1.0/container/item/"' +
      ' xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0"' +
      ' hdrgm:GainMapMin="' + data.minLog2 + '" hdrgm:GainMapMax="' + data.maxLog2 + '"' +
      ' hdrgm:Gamma="' + data.gamma + '" hdrgm:OffsetSDR="' + data.offsetSdr + '"' +
      ' hdrgm:OffsetHDR="' + data.offsetHdr + '" hdrgm:HDRCapacityMin="' + data.capMinLog2 +
      '" hdrgm:HDRCapacityMax="' + data.capMaxLog2 + '"><Container:Directory><rdf:Seq>' +
      '<rdf:li rdf:parseType="Resource"><Item:Semantic>Primary</Item:Semantic><Item:Mime>image/jpeg</Item:Mime></rdf:li>' +
      '<rdf:li rdf:parseType="Resource"><Item:Semantic>GainMap</Item:Semantic><Item:Mime>image/jpeg</Item:Mime><Item:Length>' +
      length + '</Item:Length></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>';
  }

  private static secondaryXmp(data: HdrData): string {
    return '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' +
      '<rdf:Description rdf:about="" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0"' +
      ' hdrgm:GainMapMin="' + data.minLog2 + '" hdrgm:GainMapMax="' + data.maxLog2 + '" hdrgm:Gamma="' + data.gamma +
      '" hdrgm:OffsetSDR="' + data.offsetSdr + '" hdrgm:OffsetHDR="' + data.offsetHdr + '" hdrgm:HDRCapacityMin="' +
      data.capMinLog2 + '" hdrgm:HDRCapacityMax="' + data.capMaxLog2 + '"/></rdf:RDF></x:xmpmeta>';
  }

  private static ensureSecondaryXmp(jpeg: Uint8Array, data: HdrData): Uint8Array {
    let found: boolean = false;
    HdrGainMap.forEachSegment(jpeg, (segment: HdrSegment): boolean => {
      if (segment.marker === 0xE1 && HdrGainMap.startsWith(segment, HdrGainMap.ascii(HdrGainMap.XMP_NS))) {
        found = true;
        return true;
      }
      return false;
    });
    return found ? jpeg : HdrGainMap.insert(jpeg, 2, HdrGainMap.app1(HdrGainMap.secondaryXmp(data)));
  }

  private static app1(xml: string): Uint8Array {
    const ns: Uint8Array = HdrGainMap.ascii(HdrGainMap.XMP_NS + '\u0000');
    const body: Uint8Array = HdrGainMap.utf8(xml);
    const length: number = 2 + ns.length + body.length;
    const out: Uint8Array = new Uint8Array(2 + length);
    out[0] = 0xFF;
    out[1] = 0xE1;
    out[2] = (length >>> 8) & 0xFF;
    out[3] = length & 0xFF;
    out.set(ns, 4);
    out.set(body, 4 + ns.length);
    return out;
  }

  private static mpfPayload(primarySize: number, secondarySize: number, secondaryOffset: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(86);
    out.set(HdrGainMap.ascii('MPF\u0000MM\u0000*'), 0);
    HdrGainMap.put32(out, 8, 8);
    HdrGainMap.put16(out, 12, 3);
    HdrGainMap.put16(out, 14, 0xB000);
    HdrGainMap.put16(out, 16, 7);
    HdrGainMap.put32(out, 18, 4);
    out.set(HdrGainMap.ascii('0100'), 22);
    HdrGainMap.put16(out, 26, 0xB001);
    HdrGainMap.put16(out, 28, 4);
    HdrGainMap.put32(out, 30, 1);
    HdrGainMap.put32(out, 34, 2);
    HdrGainMap.put16(out, 38, 0xB002);
    HdrGainMap.put16(out, 40, 7);
    HdrGainMap.put32(out, 42, 32);
    HdrGainMap.put32(out, 46, 50);
    HdrGainMap.put32(out, 50, 0);
    HdrGainMap.put32(out, 54, 0x030000);
    HdrGainMap.put32(out, 58, primarySize);
    HdrGainMap.put32(out, 62, 0);
    HdrGainMap.put16(out, 70, 0);
    HdrGainMap.put16(out, 72, 0);
    HdrGainMap.put32(out, 74, 0);
    HdrGainMap.put32(out, 78, secondarySize);
    HdrGainMap.put32(out, 82, secondaryOffset);
    return out;
  }

  private static strip(jpeg: Uint8Array): Uint8Array {
    // 分段收集 + 一次 set 拼接：push(...spread) 对整段扫描数据（数 MB）会爆栈，
    // 是 HDR 导出闪退的疑似根因之一，禁止再对大数组用 spread
    const segs: Uint8Array[] = [];
    let total: number = 0;
    const head: Uint8Array = jpeg.subarray(0, 2);
    segs.push(head);
    total += head.length;
    let pos: number = 2;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker: number = jpeg[pos + 1];
      if (marker === 0xDA || marker === 0xD9) {
        const tail: Uint8Array = jpeg.subarray(pos);
        segs.push(tail);
        total += tail.length;
        break;
      }
      const len: number = HdrGainMap.u16(jpeg, pos + 2, true);
      if (len < 2 || pos + 2 + len > jpeg.length) {
        return jpeg;
      }
      const drop: boolean = marker === 0xE1 && HdrGainMap.matchAt(jpeg, pos + 4, HdrGainMap.ascii(HdrGainMap.XMP_NS)) ||
        marker === 0xE2 && (HdrGainMap.matchAt(jpeg, pos + 4, HdrGainMap.ascii('MPF\u0000')) ||
          HdrGainMap.matchAt(jpeg, pos + 4, HdrGainMap.ascii('urn:')));
      if (!drop) {
        const seg: Uint8Array = jpeg.subarray(pos, pos + 2 + len);
        segs.push(seg);
        total += seg.length;
      }
      pos += 2 + len;
    }
    const out: Uint8Array = new Uint8Array(total);
    let off: number = 0;
    for (let i = 0; i < segs.length; i++) {
      out.set(segs[i], off);
      off += segs[i].length;
    }
    return out;
  }

  private static truncate(jpeg: Uint8Array): Uint8Array {
    const eoi: number = HdrGainMap.mainEoi(jpeg);
    return eoi < 0 ? jpeg : jpeg.slice(0, eoi);
  }

  private static mainEoi(jpeg: Uint8Array): number {
    let pos: number = 2;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker: number = jpeg[pos + 1];
      if (marker === 0xD9) {
        return pos + 2;
      }
      if (marker === 0xDA) {
        for (let i = pos + 2; i + 1 < jpeg.length; i++) {
          if (jpeg[i] === 0xFF && jpeg[i + 1] === 0xD9) {
            return i + 2;
          }
        }
        return -1;
      }
      if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) {
        pos += 2;
      } else {
        const len: number = HdrGainMap.u16(jpeg, pos + 2, true);
        if (len < 2 || pos + 2 + len > jpeg.length) {
          return -1;
        }
        pos += 2 + len;
      }
    }
    return -1;
  }

  private static findSos(jpeg: Uint8Array): number {
    let pos: number = 2;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker: number = jpeg[pos + 1];
      if (marker === 0xDA) {
        return pos;
      }
      const len: number = HdrGainMap.u16(jpeg, pos + 2, true);
      if (len < 2 || pos + 2 + len > jpeg.length) {
        return -1;
      }
      pos += 2 + len;
    }
    return -1;
  }

  private static forEachSegment(jpeg: Uint8Array, callback: (segment: HdrSegment) => boolean): void {
    let pos: number = 2;
    while (pos + 4 <= jpeg.length && jpeg[pos] === 0xFF) {
      const marker: number = jpeg[pos + 1];
      if (marker === 0xDA || marker === 0xD9) {
        return;
      }
      if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) {
        pos += 2;
        continue;
      }
      const length: number = HdrGainMap.u16(jpeg, pos + 2, true);
      if (length < 2 || pos + 2 + length > jpeg.length) {
        return;
      }
      const segment: HdrSegment = new HdrSegment(jpeg, marker, pos + 4, length - 2);
      if (callback(segment)) {
        return;
      }
      pos += 2 + length;
    }
  }

  private static segmentText(segment: HdrSegment): string {
    return HdrGainMap.decodeUtf8(segment.bytes.slice(segment.dataStart, segment.dataStart + segment.dataLength));
  }

  private static attr(xml: string, name: string, fallback: string): string {
    const start: string = name + '=\"';
    const at: number = xml.indexOf(start);
    if (at < 0) {
      return fallback;
    }
    const from: number = at + start.length;
    const end: number = xml.indexOf('\"', from);
    return end > from ? xml.substring(from, end) : fallback;
  }

  private static insert(src: Uint8Array, at: number, part: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(src.length + part.length);
    out.set(src.slice(0, at), 0);
    out.set(part, at);
    out.set(src.slice(at), at + part.length);
    return out;
  }

  private static startsWith(segment: HdrSegment, prefix: Uint8Array): boolean {
    return HdrGainMap.matchAt(segment.bytes, segment.dataStart, prefix);
  }

  private static matchAt(src: Uint8Array, at: number, prefix: Uint8Array): boolean {
    if (at < 0 || at + prefix.length > src.length) {
      return false;
    }
    for (let i = 0; i < prefix.length; i++) {
      if (src[at + i] !== prefix[i]) {
        return false;
      }
    }
    return true;
  }

  private static isJpeg(src: Uint8Array): boolean {
    return src.length >= 4 && src[0] === 0xFF && src[1] === 0xD8;
  }

  private static u16(src: Uint8Array, at: number, bigEndian: boolean): number {
    if (at < 0 || at + 2 > src.length) {
      return 0;
    }
    return bigEndian ? (src[at] << 8) | src[at + 1] : (src[at + 1] << 8) | src[at];
  }

  private static u32(src: Uint8Array, at: number, bigEndian: boolean): number {
    if (at < 0 || at + 4 > src.length) {
      return 0;
    }
    if (bigEndian) {
      return ((src[at] << 24) >>> 0) | (src[at + 1] << 16) | (src[at + 2] << 8) | src[at + 3];
    }
    return ((src[at + 3] << 24) >>> 0) | (src[at + 2] << 16) | (src[at + 1] << 8) | src[at];
  }

  private static put16(dst: Uint8Array, at: number, value: number): void {
    dst[at] = (value >>> 8) & 0xFF;
    dst[at + 1] = value & 0xFF;
  }

  private static put32(dst: Uint8Array, at: number, value: number): void {
    dst[at] = (value >>> 24) & 0xFF;
    dst[at + 1] = (value >>> 16) & 0xFF;
    dst[at + 2] = (value >>> 8) & 0xFF;
    dst[at + 3] = value & 0xFF;
  }

  private static putValue(b: Uint8Array, off: number, v: number, len: number, le: boolean): void {
    for (let i = 0; i < len; i++) {
      const k: number = le ? i : len - 1 - i;
      b[k + off] = (v >>> (i * 8)) & 0xFF;
    }
  }

  private static ascii(value: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(value.length);
    for (let i = 0; i < value.length; i++) {
      out[i] = value.charCodeAt(i) & 0xFF;
    }
    return out;
  }

  private static utf8(value: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xC0 | (code >>> 6), 0x80 | (code & 0x3F));
      } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < value.length) {
        const low: number = value.charCodeAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          const cp: number = 0x10000 + ((code - 0xD800) << 10) + low - 0xDC00;
          out.push(0xF0 | (cp >>> 18), 0x80 | ((cp >>> 12) & 0x3F),
            0x80 | ((cp >>> 6) & 0x3F), 0x80 | (cp & 0x3F));
          i++;
        } else {
          out.push(0xE0 | (code >>> 12), 0x80 | ((code >>> 6) & 0x3F), 0x80 | (code & 0x3F));
        }
      } else {
        out.push(0xE0 | (code >>> 12), 0x80 | ((code >>> 6) & 0x3F), 0x80 | (code & 0x3F));
      }
    }
    return new Uint8Array(out);
  }

  private static decodeUtf8(value: Uint8Array): string {
    let out: string = '';
    let i: number = 0;
    while (i < value.length) {
      const first: number = value[i];
      if (first < 0x80) {
        out += String.fromCharCode(first);
        i++;
      } else if ((first & 0xE0) === 0xC0 && i + 1 < value.length) {
        out += String.fromCharCode(((first & 0x1F) << 6) | (value[i + 1] & 0x3F));
        i += 2;
      } else if ((first & 0xF0) === 0xE0 && i + 2 < value.length) {
        out += String.fromCharCode(((first & 0x0F) << 12) | ((value[i + 1] & 0x3F) << 6) |
          (value[i + 2] & 0x3F));
        i += 3;
      } else if ((first & 0xF8) === 0xF0 && i + 3 < value.length) {
        const cp: number = ((first & 0x07) << 18) | ((value[i + 1] & 0x3F) << 12) |
          ((value[i + 2] & 0x3F) << 6) | (value[i + 3] & 0x3F);
        const high: number = 0xD800 + ((cp - 0x10000) >>> 10);
        const low: number = 0xDC00 + ((cp - 0x10000) & 0x3FF);
        out += String.fromCharCode(high, low);
        i += 4;
      } else {
        out += '\uFFFD';
        i++;
      }
    }
    return out;
  }
}
