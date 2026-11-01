/**
 * L-Moment 主界面：预览（长按对比原图）/ 分类 / 风格卡 / 七档色调滑杆 /
 * 导入·分享码 / SaveButton 导出。神经链风格经 MindSpore 推理，模型缺失时逐级降级并提示。
 */

import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { StyleDef, StyleDefs, StyleMode, StyleCategory, StyleCategories } from '../engine/StyleDefs';
import { StyleEngine } from '../engine/StyleEngine';
import { Lut3D } from '../engine/Lut3D';
import { StyleAModel } from '../engine/StyleAEngine';
import { ToneCurves } from '../engine/ToneCurves';
import { ColorCode, CodePayload } from '../engine/ColorCode';
import { ImagePipeline, DecodedImage } from '../engine/ImagePipeline';
import { StyleRunner } from '../engine/ExportTask';
import { NeuralEngine } from '../engine/NeuralEngine';

class ThumbEntry {
  readonly key: string;
  readonly label: string;
  readonly pm: image.PixelMap | undefined;
  readonly code: string;

  constructor(key: string, label: string, pm: image.PixelMap | undefined, code: string) {
    this.key = key;
    this.label = label;
    this.pm = pm;
    this.code = code;
  }
}

class CustomEntry {
  name: string;
  code: string;
  crc: number;

  constructor(name: string, code: string, crc: number) {
    this.name = name;
    this.code = code;
    this.crc = crc;
  }
}

@Entry
@Component
struct Index {
  @State hasImage: boolean = false;
  @State displayPM: image.PixelMap | undefined = undefined;
  @State comparing: boolean = false;
  @State processing: boolean = false;
  @State exporting: boolean = false;
  @State currentCategory: string = 'all';
  @State selectedKey: string = '';
  @State levels: number[] = [0, 0, 0, 0, 0, 0, 0];
  @State showAdjust: boolean = false;
  @State showImport: boolean = false;
  @State importText: string = '';
  @State notice: string = '';
  @State thumbEntries: ThumbEntry[] = [];

  private origBuf: Uint8Array = new Uint8Array(0);
  private origW: number = 0;
  private origH: number = 0;
  private origPM: image.PixelMap | undefined = undefined;
  private styledBuf: Uint8Array = new Uint8Array(0);
  private pickedUri: string = '';
  private thumbBuf: Uint8Array = new Uint8Array(0);
  private thumbW: number = 0;
  private thumbH: number = 0;
  private rawCache: Map<string, Uint8Array> = new Map();
  private lutCache: Map<string, Lut3D> = new Map();
  private saModelCache: StyleAModel | undefined = undefined;
  private styledCache: Map<string, Uint8Array> = new Map();
  private noticeCache: Map<string, string> = new Map();
  private customBinCache: Map<string, Uint8Array> = new Map();
  private customLutCache: Map<string, Lut3D> = new Map();
  private customs: CustomEntry[] = [];
  private renderSeq: number = 0;
  private toneTimer: number = -1;

  aboutToAppear(): void {
    this.loadCustoms();
    const c = this.ctx();
    if (c !== undefined) {
      NeuralEngine.init(c.resourceManager);
      NeuralEngine.preload();
    }
  }

  private ctx(): common.Context | undefined {
    return this.getUIContext().getHostContext();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2200 });
  }

  private stylesForCategory(cat: string): StyleDef[] {
    const all = StyleDefs.uiVisible();
    if (cat === 'all') {
      return all;
    }
    const out: StyleDef[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].category === cat) {
        out.push(all[i]);
      }
    }
    return out;
  }

  private async rawBin(name: string): Promise<Uint8Array | undefined> {
    const hit = this.rawCache.get(name);
    if (hit !== undefined) {
      return hit;
    }
    const c = this.ctx();
    if (c === undefined) {
      return undefined;
    }
    try {
      const d = await c.resourceManager.getRawFileContent(name);
      this.rawCache.set(name, d);
      return d;
    } catch (e) {
      return undefined;
    }
  }

  private async lutFor(lutFile: string): Promise<Lut3D | undefined> {
    const hit = this.lutCache.get(lutFile);
    if (hit !== undefined) {
      return hit;
    }
    const bin = await this.rawBin(lutFile);
    if (bin === undefined) {
      return undefined;
    }
    const lut = Lut3D.decode(bin);
    if (lut !== undefined) {
      this.lutCache.set(lutFile, lut);
    }
    return lut;
  }

  private async saModel(): Promise<StyleAModel | undefined> {
    if (this.saModelCache !== undefined) {
      return this.saModelCache;
    }
    const bin = await this.rawBin('styleA_s0.bin');
    if (bin === undefined) {
      return undefined;
    }
    const m = StyleAModel.decode(bin);
    if (m !== undefined) {
      this.saModelCache = m;
    }
    return m;
  }

  private findCustom(name: string): CustomEntry | undefined {
    for (let i = 0; i < this.customs.length; i++) {
      if (this.customs[i].name === name) {
        return this.customs[i];
      }
    }
    return undefined;
  }

  private async customLut(e: CustomEntry): Promise<Lut3D | undefined> {
    const hit = this.customLutCache.get(e.code);
    if (hit !== undefined) {
      return hit;
    }
    const payload = await ColorCode.decode(e.code);
    if (payload === undefined || payload.lut === undefined) {
      return undefined;
    }
    const bin = ColorCode.inflateLut(payload.lut, payload.dim);
    if (bin === undefined) {
      return undefined;
    }
    const lut = Lut3D.decode(bin);
    if (lut !== undefined) {
      this.customLutCache.set(e.code, lut);
    }
    return lut;
  }

  private async customBin(e: CustomEntry): Promise<Uint8Array | undefined> {
    const hit = this.customBinCache.get(e.code);
    if (hit !== undefined) {
      return hit;
    }
    const payload = await ColorCode.decode(e.code);
    if (payload === undefined || payload.lut === undefined) {
      return undefined;
    }
    const bin = ColorCode.inflateLut(payload.lut, payload.dim);
    if (bin !== undefined) {
      this.customBinCache.set(e.code, bin);
    }
    return bin;
  }

  private customsPath(c: common.Context): string {
    return c.filesDir + '/custom_styles.txt';
  }

  private loadCustoms(): void {
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    const path = this.customsPath(c);
    if (!fs.accessSync(path)) {
      return;
    }
    try {
      const txt = fs.readTextSync(path);
      const lines = txt.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (line === '') {
          continue;
        }
        const parts = line.split('\t');
        if (parts.length < 3) {
          continue;
        }
        const crc = parseInt(parts[0]);
        if (isNaN(crc)) {
          continue;
        }
        const name = parts[1];
        const code = parts.slice(2).join('\t');
        if (name !== '' && code.startsWith(ColorCode.PREFIX)) {
          this.customs.push(new CustomEntry(name, code, crc));
        }
      }
    } catch (e) {
    }
  }

  private saveCustoms(): void {
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    const lines: string[] = [];
    for (let i = 0; i < this.customs.length; i++) {
      const e = this.customs[i];
      lines.push(e.crc + '\t' + e.name + '\t' + e.code);
    }
    try {
      const file = fs.openSync(this.customsPath(c),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, lines.join('\n'));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
    }
  }

  private async pickAndLoad(): Promise<void> {
    try {
      const uri = await ImagePipeline.pickImage();
      if (uri === '') {
        return;
      }
      await this.loadFromUri(uri);
    } catch (e) {
      this.toast('选择照片失败');
    }
  }

  private async loadFromUri(uri: string): Promise<void> {
    this.processing = true;
    const d = await ImagePipeline.decodeUri(uri, ImagePipeline.PREVIEW_EDGE);
    if (d === undefined) {
      this.processing = false;
      this.toast('图片解码失败');
      return;
    }
    this.pickedUri = uri;
    try {
      await this.applyDecoded(d);
    } catch (e) {
      this.processing = false;
      this.toast('图片加载失败');
    }
  }

  private async loadTestImage(): Promise<void> {
    this.processing = true;
    try {
      const d = await ImagePipeline.makeTestImage(1600, 1200);
      this.pickedUri = '';
      await this.applyDecoded(d);
    } catch (e) {
      this.processing = false;
      this.toast('生成测试图失败');
    }
  }

  private async applyDecoded(d: DecodedImage): Promise<void> {
    this.origBuf = d.data;
    this.origW = d.width;
    this.origH = d.height;
    const oldOrig = this.origPM;
    const oldDisp = this.displayPM;
    this.origPM = d.pixelMap;
    this.displayPM = d.pixelMap;
    if (oldOrig !== undefined && oldOrig !== d.pixelMap) {
      oldOrig.release().catch(() => {
      });
    }
    if (oldDisp !== undefined && oldDisp !== d.pixelMap && oldDisp !== oldOrig) {
      oldDisp.release().catch(() => {
      });
    }
    this.styledBuf = d.data;
    this.styledCache.clear();
    this.noticeCache.clear();
    this.selectedKey = '';
    this.notice = '';
    this.hasImage = true;
    this.processing = false;
    this.makeThumbSource();
    await this.rebuildThumbs();
    await this.renderTone();
  }

  private makeThumbSource(): void {
    const scale = Math.min(1, ImagePipeline.THUMB_EDGE / Math.max(this.origW, this.origH));
    const tw = Math.max(1, Math.round(this.origW * scale));
    const th = Math.max(1, Math.round(this.origH * scale));
    this.thumbBuf = ImagePipeline.downscaleRgba(this.origBuf, this.origW, this.origH, tw, th);
    this.thumbW = tw;
    this.thumbH = th;
  }

  private async thumbPmOf(px: Uint8Array): Promise<image.PixelMap> {
    return ImagePipeline.rgbaToPixelMap(px, this.thumbW, this.thumbH);
  }

  private async rebuildThumbs(): Promise<void> {
    if (!this.hasImage || this.thumbBuf.byteLength === 0) {
      this.thumbEntries = [];
      return;
    }
    const entries: ThumbEntry[] = [];
    const tw = this.thumbW;
    const th = this.thumbH;
    entries.push(new ThumbEntry('__orig', '原图', await this.thumbPmOf(this.thumbBuf), ''));
    const defs = this.stylesForCategory(this.currentCategory);
    for (let i = 0; i < defs.length; i++) {
      const def = defs[i];
      const px = this.thumbBuf.slice();
      let lut: Lut3D | undefined = undefined;
      if (def.mode === StyleMode.LUT) {
        lut = await this.lutFor(def.lutFile);
      }
      let sa: StyleAModel | undefined = undefined;
      if (def.mode === StyleMode.SA) {
        sa = await this.saModel();
      }
      if (NeuralEngine.isNeuralMode(def.mode)) {
        await NeuralEngine.applyNeural(px, tw, th, def.mode);
      } else {
        StyleEngine.apply(px, tw, th, def, lut, sa);
      }
      entries.push(new ThumbEntry(def.id, def.label, await this.thumbPmOf(px), ''));
    }
    if (this.currentCategory === 'custom') {
      for (let i = 0; i < this.customs.length; i++) {
        const e = this.customs[i];
        const px = this.thumbBuf.slice();
        const lut = await this.customLut(e);
        if (lut !== undefined) {
          lut.applyPx(px);
        }
        entries.push(new ThumbEntry('cust:' + e.name, e.name, await this.thumbPmOf(px), e.code));
      }
      entries.push(new ThumbEntry('__import', '导入码', undefined, ''));
    }
    this.thumbEntries = entries;
  }

  private onCategory(id: string): void {
    if (this.currentCategory === id) {
      return;
    }
    this.currentCategory = id;
    this.rebuildThumbs();
  }

  private selectStyle(key: string): void {
    if (this.selectedKey === key) {
      return;
    }
    this.selectedKey = key;
    this.renderStyle();
  }

  private noticeForKey(key: string): string {
    if (key === '' || key.startsWith('cust:')) {
      return '';
    }
    const hit = this.noticeCache.get(key);
    return hit !== undefined ? hit : '';
  }

  private async renderStyle(): Promise<void> {
    if (!this.hasImage) {
      return;
    }
    const key = this.selectedKey;
    const seq = ++this.renderSeq;
    const cached = this.styledCache.get(key);
    if (cached !== undefined) {
      this.styledBuf = cached;
      this.notice = this.noticeForKey(key);
      await this.renderTone();
      return;
    }
    this.processing = true;
    try {
      const neutral: number[] = [0, 0, 0, 0, 0, 0, 0];
      let styled: Uint8Array | undefined = undefined;
      let notice = '';
      if (key === '') {
        styled = this.origBuf;
      } else if (key.startsWith('cust:')) {
        const e = this.findCustom(key.substring(5));
        if (e !== undefined) {
          const bin = await this.customBin(e);
          if (bin !== undefined) {
            styled = await StyleRunner.run(this.origBuf, this.origW, this.origH,
              StyleMode.CUSTOM, 0, 0, false, bin, undefined, neutral);
          } else {
            notice = '分享码数据无效，已输出原图';
          }
        }
      } else {
        const def = StyleDefs.byId(key);
        if (def !== undefined) {
          if (NeuralEngine.isNeuralMode(def.mode)) {
            const px = this.origBuf.slice();
            notice = await NeuralEngine.applyNeural(px, this.origW, this.origH, def.mode);
            styled = px;
          } else {
            let lutBin: Uint8Array | undefined = undefined;
            if (def.mode === StyleMode.LUT) {
              lutBin = await this.rawBin(def.lutFile);
            }
            let saBin: Uint8Array | undefined = undefined;
            if (def.mode === StyleMode.SA) {
              saBin = await this.rawBin('styleA_s0.bin');
            }
            styled = await StyleRunner.run(this.origBuf, this.origW, this.origH, def.mode,
              def.grain, def.vignette, def.p9, lutBin, saBin, neutral);
          }
          this.noticeCache.set(key, notice);
        }
      }
      if (seq !== this.renderSeq) {
        this.processing = false;
        return;
      }
      if (styled === undefined) {
        styled = this.origBuf;
        notice = '风格暂不可用，已输出原图';
      }
      if (key !== '') {
        if (this.styledCache.size >= 5) {
          this.styledCache.clear();
        }
        this.styledCache.set(key, styled);
      }
      this.styledBuf = styled;
      this.notice = notice;
      this.processing = false;
      await this.renderTone();
    } catch (e) {
      if (seq === this.renderSeq) {
        this.processing = false;
        this.styledBuf = this.origBuf;
        this.notice = '风格处理失败，已输出原图';
        await this.renderTone();
      }
    }
  }

  private async renderTone(): Promise<void> {
    if (!this.hasImage) {
      return;
    }
    const seq = ++this.renderSeq;
    let px = this.styledBuf;
    if (!ToneCurves.isNeutral(this.levels)) {
      px = await StyleRunner.run(this.styledBuf, this.origW, this.origH,
        StyleMode.MODEL_PASSTHROUGH, 0, 0, false, undefined, undefined, this.levels);
    }
    if (seq !== this.renderSeq) {
      return;
    }
    const pm = await ImagePipeline.rgbaToPixelMap(px, this.origW, this.origH);
    if (seq !== this.renderSeq) {
      return;
    }
    const old = this.displayPM;
    this.displayPM = pm;
    if (old !== undefined && old !== pm && old !== this.origPM) {
      old.release().catch(() => {
      });
    }
  }

  private onSlider(idx: number, value: number): void {
    this.levels[idx] = Math.round(value);
    if (this.toneTimer >= 0) {
      clearTimeout(this.toneTimer);
    }
    this.toneTimer = setTimeout(() => {
      this.toneTimer = -1;
      this.renderTone();
    }, 120);
  }

  private resetLevels(): void {
    for (let i = 0; i < this.levels.length; i++) {
      this.levels[i] = 0;
    }
    if (this.toneTimer >= 0) {
      clearTimeout(this.toneTimer);
      this.toneTimer = -1;
    }
    this.renderTone();
  }

  private async doExport(): Promise<void> {
    if (!this.hasImage) {
      this.toast('请先加载图片');
      return;
    }
    if (this.exporting) {
      return;
    }
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    this.exporting = true;
    let target: string = '';
    try {
      target = await ImagePipeline.createAssetTarget(c, 'jpg');
      let src: Uint8Array;
      let w: number;
      let h: number;
      if (this.pickedUri !== '') {
        const d = await ImagePipeline.decodeUri(this.pickedUri,
          ImagePipeline.WORK_LONG, ImagePipeline.WORK_SHORT);
        if (d === undefined) {
          throw new Error('原图解码失败');
        }
        src = d.data;
        w = d.width;
        h = d.height;
      } else {
        src = this.origBuf;
        w = this.origW;
        h = this.origH;
      }
      const key = this.selectedKey;
      let out: Uint8Array;
      if (key === '') {
        out = await StyleRunner.run(src, w, h, StyleMode.MODEL_PASSTHROUGH, 0, 0, false,
          undefined, undefined, this.levels);
      } else if (key.startsWith('cust:')) {
        const e = this.findCustom(key.substring(5));
        if (e === undefined) {
          throw new Error('自定义色彩不存在');
        }
        const bin = await this.customBin(e);
        if (bin === undefined) {
          throw new Error('分享码数据无效');
        }
        out = await StyleRunner.run(src, w, h, StyleMode.CUSTOM, 0, 0, false,
          bin, undefined, this.levels);
      } else {
        const def = StyleDefs.byId(key);
        if (def === undefined) {
          throw new Error('风格不存在');
        }
        if (NeuralEngine.isNeuralMode(def.mode)) {
          const px = src.slice();
          await NeuralEngine.applyNeural(px, w, h, def.mode);
          if (ToneCurves.isNeutral(this.levels)) {
            out = px;
          } else {
            out = await StyleRunner.run(px, w, h, StyleMode.MODEL_PASSTHROUGH,
              0, 0, false, undefined, undefined, this.levels);
          }
        } else {
          let lutBin: Uint8Array | undefined = undefined;
          if (def.mode === StyleMode.LUT) {
            lutBin = await this.rawBin(def.lutFile);
          }
          let saBin: Uint8Array | undefined = undefined;
          if (def.mode === StyleMode.SA) {
            saBin = await this.rawBin('styleA_s0.bin');
          }
          out = await StyleRunner.run(src, w, h, def.mode, def.grain, def.vignette, def.p9,
            lutBin, saBin, this.levels);
        }
      }
      const pm = await ImagePipeline.rgbaToPixelMap(out, w, h);
      const jpeg = await ImagePipeline.packJpeg(pm, 95);
      await ImagePipeline.writeToGallery(target, jpeg);
      pm.release().catch(() => {
      });
      this.toast('已保存到图库');
    } catch (e) {
      const msg = e instanceof Error ? e.message : '未知错误';
      this.toast('导出失败：' + msg);
    }
    this.exporting = false;
  }

  private uniqueName(base: string): string {
    let name = base;
    let n = 2;
    while (this.findCustom(name) !== undefined && n < 999) {
      name = base + ' ' + n;
      n++;
    }
    return name;
  }

  private async doImport(): Promise<void> {
    const text = this.importText.trim();
    if (text === '') {
      this.toast('请粘贴分享码');
      return;
    }
    let payload: CodePayload | undefined = undefined;
    try {
      payload = await ColorCode.decode(text);
    } catch (e) {
      payload = undefined;
    }
    if (payload === undefined || payload.lut === undefined) {
      this.toast('无法识别该分享码（仅支持 LUT 分享码）');
      return;
    }
    for (let i = 0; i < this.customs.length; i++) {
      if (this.customs[i].crc === payload.crc) {
        this.toast('已存在相同色彩「' + this.customs[i].name + '」');
        return;
      }
    }
    let name = payload.name.trim();
    if (name === '') {
      name = '分享的色彩';
    }
    name = name.replace(/\t/g, ' ').replace(/\n/g, ' ').replace(/\r/g, ' ').trim();
    if (name.length > 24) {
      name = name.substring(0, 24);
    }
    name = this.uniqueName(name);
    const extracted = ColorCode.extractPayload(text);
    const code = extracted !== undefined ? ColorCode.PREFIX + extracted : text;
    this.customs.push(new CustomEntry(name, code, payload.crc));
    this.saveCustoms();
    this.showImport = false;
    this.importText = '';
    this.toast('已导入「' + name + '」');
    if (this.currentCategory === 'custom') {
      await this.rebuildThumbs();
    }
  }

  private copyCustomCode(code: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, code);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => {
        this.toast('分享码已复制到剪贴板');
      })
      .catch(() => {
        this.toast('复制失败');
      });
  }

  private onCardClick(e: ThumbEntry): void {
    if (e.key === '__import') {
      this.showImport = true;
      return;
    }
    this.selectStyle(e.key);
  }

  private onCardLongPress(e: ThumbEntry): void {
    if (e.code !== '') {
      this.copyCustomCode(e.code);
    }
  }

  @Builder
  private styleCard(e: ThumbEntry) {
    Column({ space: 5 }) {
      if (e.key === '__import') {
        Column() {
          Text('+')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor('#E8B84B')
        }
        .width(72)
        .height(72)
        .borderRadius(12)
        .backgroundColor('#26262A')
        .border({ width: 1, color: '#3A3A3E', style: BorderStyle.Dashed })
        .justifyContent(FlexAlign.Center)
      } else if (e.pm !== undefined) {
        Image(e.pm)
          .width(72)
          .height(72)
          .borderRadius(12)
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width(72)
          .height(72)
          .borderRadius(12)
          .backgroundColor('#26262A')
      }
      Text(e.label)
        .fontSize(11)
        .fontColor(this.selectedKey === e.key ? '#E8B84B' : '#C9C9C9')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 76 })
    }
    .width(84)
    .padding({ top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(this.selectedKey === e.key ? '#2B2416' : Color.Transparent)
    .onClick(() => {
      this.onCardClick(e);
    })
    .gesture(LongPressGesture({ repeat: false, duration: 350 })
      .onAction(() => {
        this.onCardLongPress(e);
      }))
  }

  @Builder
  private catChip(cat: StyleCategory) {
    Text(cat.title)
      .fontSize(13)
      .fontColor(this.currentCategory === cat.id ? '#1A1A1A' : '#C9C9C9')
      .backgroundColor(this.currentCategory === cat.id ? '#E8B84B' : '#242428')
      .borderRadius(15)
      .height(30)
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        this.onCategory(cat.id);
      })
  }

  @Builder
  private sliderRow(label: string, idx: number) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(12)
        .fontColor('#BBBBBB')
        .width(40)
      Slider({ value: this.levels[idx], min: -10, max: 10, step: 1 })
        .layoutWeight(1)
        .selectedColor('#E8B84B')
        .trackColor('#3A3A3E')
        .blockColor('#F2E6C9')
        .onChange((value: number) => {
          this.onSlider(idx, value);
        })
      Text((this.levels[idx] > 0 ? '+' : '') + this.levels[idx].toFixed(0))
        .fontSize(12)
        .fontColor('#E8B84B')
        .width(34)
        .textAlign(TextAlign.RIGHT)
    }
    .width('100%')
    .height(34)
  }

  @Builder
  private importOverlay() {
    Column() {
      Column() {
        Text('导入分享码')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2E6C9')
        TextArea({ text: this.importText, placeholder: '粘贴 LMC1. 开头的分享码' })
          .onChange((v: string) => {
            this.importText = v;
          })
          .height(120)
          .backgroundColor('#26262A')
          .fontColor('#EEEEEE')
          .placeholderColor('#777777')
          .fontSize(13)
          .margin({ top: 14, bottom: 14 })
        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .backgroundColor('#333338')
            .fontColor('#DDDDDD')
            .onClick(() => {
              this.showImport = false;
            })
          Button('导入')
            .layoutWeight(1)
            .backgroundColor('#E8B84B')
            .fontColor('#1A1A1A')
            .onClick(() => {
              this.doImport();
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .backgroundColor('#1C1C1E')
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.6)')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('L-Moment')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F2E6C9')
          Blank()
          if (this.hasImage) {
            Text(this.selectedKey === '' ? '原图' : (this.findCustomOrDefLabel()))
              .fontSize(12)
              .fontColor('#8A8A8A')
          }
        }
        .width('100%')
        .height(52)
        .padding({ left: 20, right: 20 })

        Stack({ alignContent: Alignment.Center }) {
          if (!this.hasImage) {
            Column({ space: 18 }) {
              Text('离线色彩风格引擎')
                .fontSize(15)
                .fontColor('#8A8A8A')
              Button('选择照片')
                .width(190)
                .backgroundColor('#E8B84B')
                .fontColor('#1A1A1A')
                .fontSize(15)
                .onClick(() => {
                  this.pickAndLoad();
                })
              Button('生成测试图')
                .width(190)
                .backgroundColor('#26262A')
                .fontColor('#E8B84B')
                .fontSize(15)
                .onClick(() => {
                  this.loadTestImage();
                })
            }
          } else if (this.comparing && this.origPM !== undefined) {
            Image(this.origPM)
              .objectFit(ImageFit.Contain)
              .width('100%')
              .height('100%')
              .gesture(LongPressGesture({ repeat: false, duration: 250 })
                .onAction(() => {
                  this.comparing = true;
                })
                .onActionEnd(() => {
                  this.comparing = false;
                }))
          } else if (this.displayPM !== undefined) {
            Image(this.displayPM)
              .objectFit(ImageFit.Contain)
              .width('100%')
              .height('100%')
              .gesture(LongPressGesture({ repeat: false, duration: 250 })
                .onAction(() => {
                  this.comparing = true;
                })
                .onActionEnd(() => {
                  this.comparing = false;
                }))
          }

          if (this.notice !== '' && this.hasImage) {
            Text(this.notice)
              .fontSize(11)
              .fontColor('#FFD9A0')
              .backgroundColor('rgba(60,40,10,0.85)')
              .borderRadius(8)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .position({ x: 12, y: 10 })
              .constraintSize({ maxWidth: '86%' })
          }

          if (this.processing || this.exporting) {
            Column({ space: 10 }) {
              LoadingProgress()
                .width(44)
                .height(44)
                .color('#E8B84B')
              Text(this.exporting ? '导出中…' : '处理中…')
                .fontSize(12)
                .fontColor('#CCCCCC')
            }
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.45)')
            .justifyContent(FlexAlign.Center)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .backgroundColor('#141416')

        Scroll() {
          Row({ space: 8 }) {
            ForEach(StyleCategories.LIST, (cat: StyleCategory) => {
              this.catChip(cat)
            }, (cat: StyleCategory) => cat.id)
          }
          .padding({ left: 14, right: 14 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(46)
        .align(Alignment.Center)

        Scroll() {
          Row({ space: 4 }) {
            ForEach(this.thumbEntries, (e: ThumbEntry) => {
              this.styleCard(e)
            }, (e: ThumbEntry) => e.key)
          }
          .padding({ left: 10, right: 10 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(122)
        .align(Alignment.Center)

        Row({ space: 10 }) {
          Button(this.showAdjust ? '收起' : '调整')
            .fontSize(14)
            .height(38)
            .backgroundColor('#26262A')
            .fontColor('#E8B84B')
            .onClick(() => {
              this.showAdjust = !this.showAdjust;
            })
          Button('导入码')
            .fontSize(14)
            .height(38)
            .backgroundColor('#26262A')
            .fontColor('#E8B84B')
            .onClick(() => {
              this.showImport = true;
            })
          Blank()
          SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE })
            .onClick(async (_e: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result === SaveButtonOnClickResult.SUCCESS) {
                await this.doExport();
              } else {
                this.toast('未获得保存授权');
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 10, top: 6, bottom: 6 })

        if (this.showAdjust) {
          Column() {
            Row() {
              Text('色调调整')
                .fontSize(13)
                .fontColor('#DDDDDD')
              Blank()
              Button('重置')
                .fontSize(12)
                .height(28)
                .backgroundColor('#26262A')
                .fontColor('#E8B84B')
                .onClick(() => {
                  this.resetLevels();
                })
            }
            .width('100%')
            this.sliderRow('亮度', 0)
            this.sliderRow('曝光', 1)
            this.sliderRow('高光', 2)
            this.sliderRow('阴影', 3)
            this.sliderRow('黑阶', 4)
            this.sliderRow('饱和', 5)
            this.sliderRow('对比', 6)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 4, bottom: 8 })
        }
      }
      .width('100%')
      .height('100%')

      if (this.showImport) {
        this.importOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0E0E10')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private findCustomOrDefLabel(): string {
    if (this.selectedKey.startsWith('cust:')) {
      return this.selectedKey.substring(5);
    }
    const def = StyleDefs.byId(this.selectedKey);
    return def !== undefined ? def.label : '';
  }
}
