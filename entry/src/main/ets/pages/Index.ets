/**
 * L-Moment 主界面：预览（长按对比原图）/ 分类 / 风格卡 / 八档调整滑杆（含柔光，双击行归零）/
 * 导入·分享码 / 拍照（cameraPicker）/ SaveButton 导出。神经链风格经 MindSpore 推理，
 * 模型缺失时逐级降级并提示。
 */

import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { StyleDef, StyleDefs, StyleMode, StyleCategory, StyleCategories } from '../engine/StyleDefs';
import { StyleEngine } from '../engine/StyleEngine';
import { Lut3D } from '../engine/Lut3D';
import { StyleAModel } from '../engine/StyleAEngine';
import { ToneCurves } from '../engine/ToneCurves';
import { ColorCode, CodePayload } from '../engine/ColorCode';
import { ImagePipeline, DecodedImage } from '../engine/ImagePipeline';
import { StyleRunner, ModelColorRunner } from '../engine/ExportTask';
import { ModelColorNet, McStyle, McRef } from '../engine/ModelColorNet';
import { ModelColorMath } from '../engine/ModelColorMath';
import { ModelColorStore, ModelColorEntry, McVersion } from '../engine/ModelColorStore';
import { McPool } from '../engine/McPool';
import { StyleCandidates, StyleCandidateResult } from '../engine/StyleCandidates';
import { NeuralEngine } from '../engine/NeuralEngine';
import { SettingsStore } from '../engine/SettingsStore';
import { HdrGainMap } from '../engine/HdrGainMap';
import { SuperResEngine, SuperResMode } from '../engine/SuperResEngine';
import { InAppCapture } from '../engine/InAppCapture';
import { AppCamera, CaptureShot } from '../engine/AppCamera';
import { LeicaMark } from '../engine/LeicaMark';
import { ColorBackup, ColorBackupItem } from '../engine/ColorBackup';
import { M9PerfectEngine, RgbaImg } from '../engine/M9PerfectEngine';
import { yieldUI } from '../engine/PixAsync';
import { GlassButton, GlassCanvas, GlassPanel, estimateTextWidth } from '../common/GlassPanel';
import { ImmersiveStyle } from '../common/ImmersiveStyle';

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

/** 模型色彩候选（创建流程预览用）：风格 + 单色标记 + 预览图 + 簇成员指纹池。 */
class ModelCand {
  readonly style: McStyle;
  readonly mono: boolean;
  readonly pm: image.PixelMap;
  readonly embs: Float32Array;
  readonly fps: number[];
  readonly chroma: number[];

  constructor(style: McStyle, mono: boolean, pm: image.PixelMap,
    embs: Float32Array, fps: number[], chroma: number[]) {
    this.style = style;
    this.mono = mono;
    this.pm = pm;
    this.embs = embs;
    this.fps = fps;
    this.chroma = chroma;
  }
}

/** 版本历史面板行（模型色彩）：版本下标 + 展示文案 + 当前版本标记。 */
class HistoryRow {
  readonly idx: number;
  readonly label: string;
  readonly sub: string;
  readonly isCur: boolean;

  constructor(idx: number, label: string, sub: string, isCur: boolean) {
    this.idx = idx;
    this.label = label;
    this.sub = sub;
    this.isCur = isCur;
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
  @State levels: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
  @State showAdjust: boolean = false;
  @State showImport: boolean = false;
  /** SaveButton 玻璃托盘实测尺寸（px），>1 后渲染玻璃衬底。 */
  @State private saveTrayW: number = 0;
  @State private saveTrayH: number = 0;
  @State importText: string = '';
  @State notice: string = '';
  @State thumbEntries: ThumbEntry[] = [];
  @State thumbRev: number = 0;
  @State hdrEnabled: boolean = false;
  @State superResMode: SuperResMode = SuperResMode.FAST;
  @State perfectOn: boolean = false;
  @State exportProgress: number = 0;
  /** 预览缩放/平移（Batch G，对齐 ZoomableImageView：1~6 倍、双击切换、长按对比）。 */
  @State pvScale: number = 1;
  @State pvOffX: number = 0;
  @State pvOffY: number = 0;
  @State pvW: number = 0;
  @State pvH: number = 0;
  /** 重命名自定义色彩浮层。 */
  @State showRename: boolean = false;
  @State renameText: string = '';
  @State showCoach: boolean = false;
  @State superResEnabled: boolean = false;
  /** 系统避让高度（vp）：全屏沉浸布局下悬浮玻璃栏的 padding。 */
  @State topInset: number = 0;
  @State bottomInset: number = 0;
  /** 模型色彩候选浮层（Batch H）。 */
  @State showModelSheet: boolean = false;
  @State modelCands: ModelCand[] = [];
  @State modelBusy: boolean = false;
  /** 模型增强预览浮层（Batch H）：旧/新渲染各缓存一次，滑杆只调不透明度交叉淡化。 */
  @State showEnhance: boolean = false;
  @State enhanceOldPM: image.PixelMap | undefined = undefined;
  @State enhanceNewPM: image.PixelMap | undefined = undefined;
  @State enhanceStrength: number = 70;
  @State enhanceAdded: number = 0;
  @State enhanceTotal: number = 0;
  /** 版本历史面板（模型色彩）。 */
  @State showHistory: boolean = false;
  @State historyRows: HistoryRow[] = [];
  @State historySelIdx: number = 0;
  /** 应用内 RAW 直拍浮层（auto 回落链首档）。 */
  @State showCamera: boolean = false;
  @State cameraReady: boolean = false;
  @State cameraBusy: boolean = false;
  /** 色调重绘进行中（轻量非阻断提示，区别于全屏 processing 遮罩）。 */
  @State rendering: boolean = false;

  private origBuf: Uint8Array = new Uint8Array(0);
  private origW: number = 0;
  private origH: number = 0;
  private origPM: image.PixelMap | undefined = undefined;
  private styledBuf: Uint8Array = new Uint8Array(0);
  private pickedUri: string = '';
  private rawSourceUri: string = '';
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
  private models: ModelColorEntry[] = [];
  /** 重命名浮层目标类型（false = 自定义色彩，true = 模型色彩）。 */
  private renameIsModel: boolean = false;
  /** 缩放手势锚点与重命名目标（Batch G）。 */
  private pinchStart: number = 1;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private renameOld: string = '';
  private renderSeq: number = 0;
  private toneTimer: number = -1;
  private tapIdx: number = -1;
  private tapTs: number = 0;
  private downX: number = 0;
  private downY: number = 0;
  private zeroGuardIdx: number = -1;
  private zeroGuardTs: number = 0;
  /** 增强待提交数据（浮层打开期间持有，应用/取消后清空）。 */
  private enhanceName: string = '';
  private enhanceNewAff: Float32Array = new Float32Array(0);
  private enhanceNewKnots: Float32Array = new Float32Array(0);
  private enhancePoolEmbs: Float32Array = new Float32Array(0);
  private enhancePoolFps: number[] = [];
  private enhancePoolChroma: number[] = [];
  private enhanceRemap: number[] = [];
  private historyName: string = '';
  private historyCurIdx: number = 0;
  /** 相机会话与预览 surface 控制器。 */
  private appCamera: AppCamera | undefined;
  private xcc: XComponentController = new XComponentController();
  /** 源图 EXIF APP1 段（含 FFE1 头），导出时移植回 JPEG；无源 EXIF 时为空数组。 */
  private srcExifApp1: Uint8Array = new Uint8Array(0);

  aboutToAppear(): void {
    this.loadCustoms();
    const c = this.ctx();
    if (c !== undefined) {
      SettingsStore.init(c);
      NeuralEngine.init(c.resourceManager);
      SuperResEngine.init(c.resourceManager);
      this.models = ModelColorStore.load(c.filesDir);
    }
    // 冷启动分类：固定值直接用，「记忆上次」取 last，无效回落 L-Moment（与原版一致）
    const start = SettingsStore.startCategory();
    this.currentCategory = start;
    SettingsStore.setLastCategory(start);
    this.hdrEnabled = SettingsStore.hdrDefaultOn();
    // 首用引导浮层（Batch G）：仅首次进入时展示
    this.showCoach = !SettingsStore.isCoachShown();
    // 沉浸光感：启动探测设备能力 + 广播当前挡位（顶栏/底栏玻璃即时生效）
    ImmersiveStyle.probe();
    ImmersiveStyle.publish(SettingsStore.immersiveLevel());
    // 全屏沉浸布局：内容延伸到物理边缘，顶/底悬浮玻璃栏自行避让状态栏与手势条
    if (c !== undefined) {
      this.enterImmersiveLayout(c);
    }
  }

  /** 全屏沉浸：窗口 layoutFullScreen + 读取系统避让高度（vp）供悬浮栏 padding。 */
  private enterImmersiveLayout(c: common.Context): void {
    window.getLastWindow(c).then((win: window.Window) => {
      win.setWindowLayoutFullScreen(true).then(() => {
        const ui = this.getUIContext();
        const top = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
        const bot = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
        this.topInset = ui.px2vp(top);
        this.bottomInset = ui.px2vp(bot);
        AppStorage.setOrCreate('lmTopInset', this.topInset);
      }).catch(() => {
      });
    }).catch(() => {
    });
  }

  aboutToDisappear(): void {
    const cam = this.appCamera;
    this.appCamera = undefined;
    if (cam !== undefined) {
      cam.release();
    }
  }

  private ctx(): common.Context | undefined {
    return this.getUIContext().getHostContext();
  }

  // ---- Batch G：预览缩放 ----

  private areaNum(v: Length): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      const f = parseFloat(v);
      return isNaN(f) ? 0 : f;
    }
    return 0;
  }

  private resetZoom(): void {
    this.pvScale = 1;
    this.pvOffX = 0;
    this.pvOffY = 0;
  }

  private clampZoom(): void {
    let s = this.pvScale;
    if (s < 1) {
      s = 1;
    } else if (s > 6) {
      s = 6;
    }
    this.pvScale = s;
    const mx = (s - 1) * this.pvW / 2;
    const my = (s - 1) * this.pvH / 2;
    if (this.pvOffX > mx) {
      this.pvOffX = mx;
    } else if (this.pvOffX < -mx) {
      this.pvOffX = -mx;
    }
    if (this.pvOffY > my) {
      this.pvOffY = my;
    } else if (this.pvOffY < -my) {
      this.pvOffY = -my;
    }
  }

  private onDoubleTap(): void {
    if (this.pvScale > 1.05) {
      this.resetZoom();
    } else {
      this.pvScale = 2;
      this.pvOffX = 0;
      this.pvOffY = 0;
      this.clampZoom();
    }
  }

  private onPinchStart(): void {
    this.pinchStart = this.pvScale;
  }

  private onPinchUpdate(ev: GestureEvent): void {
    if (ev.scale <= 0) {
      return;
    }
    this.pvScale = this.pinchStart * ev.scale;
    this.clampZoom();
  }

  private onPanStart(): void {
    this.panStartX = this.pvOffX;
    this.panStartY = this.pvOffY;
  }

  private onPanUpdate(ev: GestureEvent): void {
    if (this.pvScale <= 1.01) {
      return;
    }
    this.pvOffX = this.panStartX + ev.offsetX;
    this.pvOffY = this.panStartY + ev.offsetY;
    this.clampZoom();
  }

  // ---- Batch G：自定义色彩操作 ----

  private openRename(name: string): void {
    this.renameIsModel = false;
    this.renameOld = name;
    this.renameText = name;
    this.showRename = true;
  }

  /** 打开模型色彩重命名浮层（复用 renameOverlay）。 */
  private openModelRename(name: string): void {
    this.renameIsModel = true;
    this.renameOld = name;
    this.renameText = name;
    this.showRename = true;
  }

  private doRename(): void {
    const nn = this.renameText.trim();
    if (nn === '' || nn === this.renameOld) {
      this.showRename = false;
      return;
    }
    if (this.renameIsModel) {
      if (this.findModel(nn) !== undefined) {
        this.toast('名称已存在');
        return;
      }
      for (let i = 0; i < this.models.length; i++) {
        if (this.models[i].name === this.renameOld) {
          this.models[i].name = nn;
          break;
        }
      }
      this.saveModels();
      if (this.selectedKey === 'model:' + this.renameOld) {
        this.selectedKey = 'model:' + nn;
      }
      this.showRename = false;
      this.rebuildThumbs();
      this.toast('已重命名');
      return;
    }
    for (let i = 0; i < this.customs.length; i++) {
      if (this.customs[i].name === nn) {
        this.toast('名称已存在');
        return;
      }
    }
    for (let i = 0; i < this.customs.length; i++) {
      if (this.customs[i].name === this.renameOld) {
        this.customs[i] = new CustomEntry(nn, this.customs[i].code, this.customs[i].crc);
        break;
      }
    }
    this.saveCustoms();
    if (this.selectedKey === 'cust:' + this.renameOld) {
      this.selectedKey = 'cust:' + nn;
    }
    this.showRename = false;
    this.rebuildThumbs();
    this.toast('已重命名');
  }

  private deleteCustom(name: string): void {
    const next: CustomEntry[] = [];
    for (let i = 0; i < this.customs.length; i++) {
      if (this.customs[i].name !== name) {
        next.push(this.customs[i]);
      }
    }
    this.customs = next;
    SettingsStore.removePinned('cust:' + name);
    this.saveCustoms();
    if (this.selectedKey === 'cust:' + name) {
      this.selectStyle('');
    }
    this.rebuildThumbs();
    this.toast('已删除');
  }

  // ---- Batch H：模型色彩 ----

  private findModel(name: string): ModelColorEntry | undefined {
    for (let i = 0; i < this.models.length; i++) {
      if (this.models[i].name === name) {
        return this.models[i];
      }
    }
    return undefined;
  }

  private saveModels(): boolean {
    const c = this.ctx();
    if (c === undefined) {
      return false;
    }
    return ModelColorStore.save(c.filesDir, this.models);
  }

  private uniqueModelName(base: string): string {
    let name = base;
    let n = 2;
    while (this.findModel(name) !== undefined && n < 999) {
      name = base + ' ' + n;
      n++;
    }
    return name;
  }

  /** 候选簇成员行的 e 子集聚合（mean/amax/std → 108）。 */
  private aggregateMembers(e: Float32Array, members: number[]): Float32Array {
    const sub = new Float32Array(members.length * 36);
    for (let i = 0; i < members.length; i++) {
      const row = members[i] * 36;
      for (let k = 0; k < 36; k++) {
        sub[i * 36 + k] = e[row + k];
      }
    }
    return ModelColorNet.aggregate(sub, members.length);
  }

  /**
   * 模型色彩创建（Batch H）：多选参考图 → stage1 指纹 → 候选聚类 →
   * 单一风格直接保存；多候选弹候选浮层供挑选。参考集一致（轮廓 <0.25）时同直接保存。
   * 每参考同时留指纹池（dHash + 36 维指纹 + 平均色度），供后续增强重拟合。
   */
  private async startModelCreate(): Promise<void> {
    if (this.modelBusy) {
      return;
    }
    let uris: string[] = [];
    try {
      uris = await ImagePipeline.pickImages(12);
    } catch (e) {
      this.toast('选择参考图失败');
      return;
    }
    if (uris.length === 0) {
      return;
    }
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    this.modelBusy = true;
    try {
      // 参考图解码：边 ~640（refPatch 需 ≥256 短边，留余量防极端长宽比）
      const refs: McRef[] = [];
      const fps: number[] = [];
      const chroma: number[] = [];
      for (let i = 0; i < uris.length; i++) {
        const d = await ImagePipeline.decodeUri(uris[i], 640);
        if (d !== undefined) {
          const ref = new McRef(d.data, d.width, d.height);
          refs.push(ref);
          const fp = McPool.fingerprint(ref.px, ref.w, ref.h);
          fps.push(fp[0], fp[1]);
          chroma.push(ModelColorNet.refsMeanChroma([ref]));
          d.pixelMap.release().catch(() => {
          });
        }
        await yieldUI();
      }
      if (refs.length === 0) {
        this.modelBusy = false;
        this.toast('参考图解码失败');
        return;
      }
      const e = await ModelColorNet.encodeStats(c.resourceManager, refs);
      if (e === undefined) {
        this.modelBusy = false;
        this.toast('模型推理失败');
        return;
      }
      // 黑白参考门限：逐参考平均色度的均值（各参考 patch 同为 128²，等权成立）
      let meanChroma = 0;
      for (let i = 0; i < chroma.length; i++) {
        meanChroma += chroma[i];
      }
      meanChroma /= chroma.length;
      const mono = meanChroma < ModelColorMath.MONO_MEAN_CHROMA;
      const r = refs.length;
      const res: StyleCandidateResult = StyleCandidates.candidates(e, r, 36, null);
      if (res.single) {
        const fused = await ModelColorNet.fuse(c.resourceManager,
          ModelColorNet.aggregate(e, r));
        if (fused === undefined) {
          this.modelBusy = false;
          this.toast('模型推理失败');
          return;
        }
        const style = mono ? this.monoStyleOf(fused) : fused;
        this.modelBusy = false;
        await this.saveModelStyle(style, mono, e, fps, chroma);
        return;
      }
      // 多候选：逐簇聚合 → fuse → 单色补救 → 预览图（候选自带簇成员指纹子集）
      const base = this.modelPreviewBase(refs);
      const cands: ModelCand[] = [];
      for (let i = 0; i < res.picks.length; i++) {
        const pick = res.picks[i];
        const fused = await ModelColorNet.fuse(c.resourceManager,
          this.aggregateMembers(e, pick.members));
        if (fused === undefined) {
          continue;
        }
        const style = mono ? this.monoStyleOf(fused) : fused;
        const pm = await this.modelPreviewPm(style, mono, base);
        const cEmbs = new Float32Array(pick.members.length * 36);
        const cFps: number[] = [];
        const cChroma: number[] = [];
        for (let j = 0; j < pick.members.length; j++) {
          const row = pick.members[j];
          cEmbs.set(e.subarray(row * 36, row * 36 + 36), j * 36);
          cFps.push(fps[row * 2], fps[row * 2 + 1]);
          cChroma.push(chroma[row]);
        }
        cands.push(new ModelCand(style, mono, pm, cEmbs, cFps, cChroma));
        await yieldUI();
      }
      this.modelBusy = false;
      if (cands.length === 0) {
        this.toast('模型推理失败');
        return;
      }
      if (cands.length === 1) {
        const one = cands[0];
        await this.saveModelStyle(one.style, one.mono, one.embs, one.fps, one.chroma);
        return;
      }
      this.modelCands = cands;
      this.showModelSheet = true;
    } catch (e) {
      this.modelBusy = false;
      this.toast('模型色彩创建失败');
    }
  }

  /** 候选预览基图：当前照片缩至 ~360；未加载时用第一张参考图。 */
  private modelPreviewBase(refs: McRef[]): Uint8Array {
    const EDGE = 360;
    let sw = 0;
    let sh = 0;
    let src: Uint8Array = new Uint8Array(0);
    if (this.hasImage && this.origBuf.length > 0) {
      src = this.origBuf;
      sw = this.origW;
      sh = this.origH;
    } else {
      src = refs[0].px;
      sw = refs[0].w;
      sh = refs[0].h;
    }
    const s = Math.min(1, EDGE / Math.max(sw, sh));
    const dw = Math.max(1, Math.round(sw * s));
    const dh = Math.max(1, Math.round(sh * s));
    this.modelPvW = dw;
    this.modelPvH = dh;
    return ImagePipeline.downscaleRgba(src, sw, sh, dw, dh);
  }

  private modelPvW: number = 0;
  private modelPvH: number = 0;

  /** 候选预览：风格套用到基图（360px 级，主线程可承受）。 */
  private async modelPreviewPm(style: McStyle, mono: boolean,
    base: Uint8Array): Promise<image.PixelMap> {
    const px = base.slice();
    ModelColorMath.apply(px, this.modelPvW, this.modelPvH, style.aff, style.knots,
      true, true, 1, false);
    return ImagePipeline.rgbaToPixelMap(px, this.modelPvW, this.modelPvH);
  }

  /** 保存一个模型色彩（自动命名「模型 N」）：初始版本 + 参考指纹池。 */
  private async saveModelStyle(style: McStyle, mono: boolean, embs: Float32Array,
    fps: number[], chroma: number[]): Promise<void> {
    const name = this.uniqueModelName(mono ? '黑白模型' : '模型');
    const now = Date.now();
    const v = new McVersion(`${now}`, '初始', now, style.aff, style.knots,
      Math.floor(embs.length / 36));
    this.models.push(new ModelColorEntry(name, [v], 0, embs, fps, chroma));
    this.saveModels();
    this.toast('已保存「' + name + '」，见我的色彩分类');
    if (this.currentCategory === 'custom') {
      await this.rebuildThumbs();
    }
  }

  /** 单色补救：无彩色参数置零（降饱和），保留明度与保护参数。 */
  private monoStyleOf(s: McStyle): McStyle {
    const aff = new Float32Array(s.aff);
    for (let i = 0; i < 6; i++) {
      aff[i] = 0;
    }
    return new McStyle(aff, s.knots);
  }

  /** 候选浮层点按：保存该候选。 */
  private async pickModelCand(idx: number): Promise<void> {
    const cand = this.modelCands[idx];
    this.showModelSheet = false;
    this.modelCands = [];
    if (cand !== undefined) {
      await this.saveModelStyle(cand.style, cand.mono, cand.embs, cand.fps, cand.chroma);
    }
  }

  private deleteModel(name: string): void {
    const next: ModelColorEntry[] = [];
    for (let i = 0; i < this.models.length; i++) {
      if (this.models[i].name !== name) {
        next.push(this.models[i]);
      }
    }
    this.models = next;
    SettingsStore.removePinned('model:' + name);
    this.saveModels();
    if (this.selectedKey === 'model:' + name) {
      this.selectStyle('');
    }
    this.rebuildThumbs();
    this.toast('已删除');
  }

  /**
   * 模型增强（Batch H）：选新参考 → 与池内指纹查重 → 补全/重拟合 →
   * 双图预览（旧=当前版本，新=增强）→ 应用后作为新版本入链。
   * 滑杆只调新图不透明度（参数线性插值 ≈ 像素交叉淡化），应用时才做参数插值。
   */
  private async startModelEnhance(name: string): Promise<void> {
    if (this.modelBusy) {
      return;
    }
    const m = this.findModel(name);
    if (m === undefined) {
      return;
    }
    let uris: string[] = [];
    try {
      uris = await ImagePipeline.pickImages(McPool.MAX_BATCH);
    } catch (e) {
      this.toast('选择参考图失败');
      return;
    }
    if (uris.length === 0) {
      return;
    }
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    this.modelBusy = true;
    try {
      const cur = m.current();
      const oldRefCount = m.refCount();
      // 新参考解码 + 与全池查重
      const refs: McRef[] = [];
      const newEmbs = new Float32Array(uris.length * 36);
      const newFps: number[] = [];
      const newChroma: number[] = [];
      let embFill = 0;
      for (let i = 0; i < uris.length; i++) {
        const d = await ImagePipeline.decodeUri(uris[i], 640);
        if (d === undefined) {
          continue;
        }
        const ref = new McRef(d.data, d.width, d.height);
        const fp = McPool.fingerprint(ref.px, ref.w, ref.h);
        if (!McPool.isDuplicate(fp, m.fps) && !McPool.isDuplicate(fp, newFps)) {
          refs.push(ref);
          newFps.push(fp[0], fp[1]);
          newChroma.push(ModelColorNet.refsMeanChroma([ref]));
        }
        d.pixelMap.release().catch(() => {
        });
        await yieldUI();
      }
      if (refs.length === 0) {
        this.modelBusy = false;
        this.toast('所选参考与已有重复，未添加');
        return;
      }
      const e = await ModelColorNet.encodeStats(c.resourceManager, refs);
      if (e === undefined) {
        this.modelBusy = false;
        this.toast('模型推理失败');
        return;
      }
      newEmbs.set(e, 0);
      embFill = e.length;
      const newEmbSlice = newEmbs.subarray(0, embFill);
      // 合并池：旧 ‖ 新，超限按淘汰规则裁剪
      const total = oldRefCount + refs.length;
      let poolEmbs: Float32Array;
      let poolFps: number[];
      let poolChroma: number[];
      if (total > McPool.MAX_TOTAL) {
        const need = total - McPool.MAX_TOTAL;
        const allFps: number[] = m.fps.concat(newFps);
        const victims = McPool.evictPlan(allFps, total, need);
        const keep: number[] = [];
        for (let i = 0; i < total; i++) {
          if (victims.indexOf(i) < 0) {
            keep.push(i);
          }
        }
        poolEmbs = new Float32Array(keep.length * 36);
        poolFps = [];
        poolChroma = [];
        for (let j = 0; j < keep.length; j++) {
          const row = keep[j];
          let src: Float32Array;
          let hi = 0;
          let lo = 0;
          let ch = 0;
          if (row < oldRefCount) {
            src = m.embs.subarray(row * 36, row * 36 + 36);
            hi = m.fps[row * 2];
            lo = m.fps[row * 2 + 1];
            ch = m.chroma[row];
          } else {
            const k = row - oldRefCount;
            src = newEmbSlice.subarray(k * 36, k * 36 + 36);
            hi = newFps[k * 2];
            lo = newFps[k * 2 + 1];
            ch = newChroma[k];
          }
          poolEmbs.set(src, j * 36);
          poolFps.push(hi, lo);
          poolChroma.push(ch);
        }
      } else {
        poolEmbs = new Float32Array(total * 36);
        poolEmbs.set(m.embs, 0);
        poolEmbs.set(newEmbSlice, oldRefCount * 36);
        poolFps = m.fps.concat(newFps);
        poolChroma = m.chroma.concat(newChroma);
      }
      const newCount = poolEmbs.length / 36;
      if (newCount === 0) {
        this.modelBusy = false;
        this.toast('增强失败：参考池为空');
        return;
      }
      // 淘汰后每版本 seedCount 重排：新值 = 旧池前缀（旧 seedCount 张）中的幸存张数
      const survivorsOld: number[] = [];
      for (let j = 0; j < oldRefCount; j++) {
        const hi = m.fps.length > j * 2 + 1 ? m.fps[j * 2] : 0;
        const lo = m.fps.length > j * 2 + 1 ? m.fps[j * 2 + 1] : 0;
        let alive = false;
        for (let k = 0; k < poolFps.length; k += 2) {
          if (poolFps[k] === hi && poolFps[k + 1] === lo) {
            alive = true;
            break;
          }
        }
        survivorsOld.push(alive ? 1 : 0);
      }
      const remap: number[] = [];
      for (let i = 0; i < m.versions.length; i++) {
        const sc = m.versions[i].seedCount;
        if (sc <= 0) {
          remap[i] = sc;
          continue;
        }
        let cnt = 0;
        for (let j = 0; j < Math.min(sc, oldRefCount); j++) {
          cnt += survivorsOld[j];
        }
        remap[i] = cnt;
      }
      const added = refs.length;
      // 重拟合新风格
      const fused = await ModelColorNet.fuse(c.resourceManager,
        ModelColorNet.aggregate(poolEmbs, newCount));
      if (fused === undefined) {
        this.modelBusy = false;
        this.toast('模型推理失败');
        return;
      }
      let meanChroma = 0;
      for (let i = 0; i < poolChroma.length; i++) {
        meanChroma += poolChroma[i];
      }
      meanChroma /= poolChroma.length;
      const mono = meanChroma < ModelColorMath.MONO_MEAN_CHROMA;
      const newStyle = mono ? this.monoStyleOf(fused) : fused;
      // 预览基图：当前照片（与主预览同源），否则第一张新增参考
      let base: Uint8Array | undefined = undefined;
      let bw = 0;
      let bh = 0;
      if (this.hasImage) {
        base = this.origBuf.slice();
        bw = this.origW;
        bh = this.origH;
      } else if (refs.length > 0) {
        base = refs[0].px;
        bw = refs[0].w;
        bh = refs[0].h;
      }
      if (base === undefined) {
        this.modelBusy = false;
        this.toast('增强失败：无预览基图');
        return;
      }
      const maxSide = 640;
      if (Math.max(bw, bh) > maxSide) {
        const ratio = maxSide / Math.max(bw, bh);
        const dw = Math.max(1, Math.round(bw * ratio));
        const dh = Math.max(1, Math.round(bh * ratio));
        base = ModelColorMath.scaleRgba(base, bw, bh, dw, dh);
        bw = dw;
        bh = dh;
      }
      const neutral: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
      // ModelColorRunner.run 内部拷贝，两次调用共用 base 互不污染
      const oldPx = await ModelColorRunner.run(base, bw, bh,
        cur.aff, cur.knots, true, true, false, 1, neutral);
      const newPx = await ModelColorRunner.run(base, bw, bh,
        newStyle.aff, newStyle.knots, true, true, false, 1, neutral);
      const oldPM = await ImagePipeline.rgbaToPixelMap(oldPx, bw, bh);
      const newPM = await ImagePipeline.rgbaToPixelMap(newPx, bw, bh);
      this.enhanceName = name;
      this.enhanceNewAff = newStyle.aff;
      this.enhanceNewKnots = newStyle.knots;
      this.enhancePoolEmbs = poolEmbs;
      this.enhancePoolFps = poolFps;
      this.enhancePoolChroma = poolChroma;
      this.enhanceRemap = remap;
      this.enhanceOldPM = oldPM;
      this.enhanceNewPM = newPM;
      this.enhanceStrength = 70;
      this.enhanceAdded = added;
      this.enhanceTotal = newCount;
      this.modelBusy = false;
      this.showEnhance = true;
    } catch (e) {
      this.modelBusy = false;
      this.toast('模型增强失败');
    }
  }

  /** 应用增强：参数插值（旧→新 × 强度）→ 新版本入链 → 池提交 → 刷新。 */
  private async applyModelEnhance(): Promise<void> {
    const m = this.findModel(this.enhanceName);
    if (m === undefined) {
      this.cancelModelEnhance();
      return;
    }
    const s = Math.min(1, Math.max(0, this.enhanceStrength / 100));
    const cur = m.current();
    const curIdx = Math.min(Math.max(m.currentIdx, 0), m.versions.length - 1);
    let aff = new Float32Array(12);
    let knots = new Float32Array(27);
    if (s >= 0.995) {
      aff = new Float32Array(this.enhanceNewAff);
      knots = new Float32Array(this.enhanceNewKnots);
    } else {
      for (let i = 0; i < 12; i++) {
        aff[i] = cur.aff[i] + (this.enhanceNewAff[i] - cur.aff[i]) * s;
      }
      for (let i = 0; i < 27; i++) {
        knots[i] = cur.knots[i] + (this.enhanceNewKnots[i] - cur.knots[i]) * s;
      }
    }
    // 分叉覆盖：截断当前版本之后的，版本链只保留一条前进路径
    const versions: McVersion[] = [];
    for (let i = 0; i <= curIdx; i++) {
      versions.push(m.versions[i]);
    }
    for (let i = 0; i < versions.length; i++) {
      const sc = this.enhanceRemap.length > i ? this.enhanceRemap[i] : versions[i].seedCount;
      const v = versions[i];
      versions[i] = new McVersion(v.id, v.label, v.createdAt, v.aff, v.knots,
        sc > 0 ? sc : v.seedCount);
    }
    const poolCount = Math.floor(this.enhancePoolEmbs.length / 36);
    let ord = 1;
    for (let i = 0; i < versions.length; i++) {
      if (versions[i].label.startsWith('增强')) {
        ord++;
      }
    }
    const now = Date.now();
    const label = s >= 0.995 ? `增强 ${ord}` : `增强 ${ord} ${Math.round(s * 100)}%`;
    versions.push(new McVersion(`${now}`, label, now, aff, knots, poolCount));
    // 版本数上限：初始版（下标 0）永不删除
    while (versions.length > 6) {
      versions.splice(1, 1);
    }
    const newCur = versions.length - 1;
    m.versions = versions;
    m.currentIdx = newCur;
    m.embs = this.enhancePoolEmbs;
    m.fps = this.enhancePoolFps;
    m.chroma = this.enhancePoolChroma;
    this.saveModels();
    this.styledCache.delete('model:' + m.name);
    await this.rebuildThumbs();
    if (this.selectedKey === 'model:' + m.name) {
      await this.renderStyle();
    }
    this.toast('已增强「' + m.name + '」');
    this.cancelModelEnhance();
  }

  /** 关闭增强浮层并释放预览图。 */
  private cancelModelEnhance(): void {
    this.releaseEnhancePMs();
    this.showEnhance = false;
    this.enhanceName = '';
    this.enhanceNewAff = new Float32Array(0);
    this.enhanceNewKnots = new Float32Array(0);
    this.enhancePoolEmbs = new Float32Array(0);
    this.enhancePoolFps = [];
    this.enhancePoolChroma = [];
    this.enhanceRemap = [];
    this.enhanceOldPM = undefined;
    this.enhanceNewPM = undefined;
  }

  private releaseEnhancePMs(): void {
    if (this.enhanceOldPM !== undefined) {
      this.enhanceOldPM.release().catch(() => {
      });
    }
    if (this.enhanceNewPM !== undefined) {
      this.enhanceNewPM.release().catch(() => {
      });
    }
  }

  /** 打开版本历史面板（单版本无历史时提示）。 */
  private openModelHistory(name: string): void {
    const m = this.findModel(name);
    if (m === undefined) {
      return;
    }
    if (m.versions.length <= 1) {
      this.toast('暂无历史版本');
      return;
    }
    const rows: HistoryRow[] = [];
    for (let i = m.versions.length - 1; i >= 0; i--) {
      const v = m.versions[i];
      rows.push(new HistoryRow(i, v.label, `${v.seedCount} 张参考图 · ${this.fmtTime(v.createdAt)}`,
        i === m.currentIdx));
    }
    this.historyName = name;
    this.historyCurIdx = m.currentIdx;
    this.historyRows = rows;
    this.historySelIdx = m.currentIdx;
    this.showHistory = true;
  }

  /** 历史面板选中项回退：仅移动游标（参数快照未动，随时可再切回）。 */
  private async doModelRollback(): Promise<void> {
    const m = this.findModel(this.historyName);
    if (m === undefined) {
      this.showHistory = false;
      return;
    }
    const idx = this.historySelIdx;
    if (idx < 0 || idx >= m.versions.length) {
      this.showHistory = false;
      return;
    }
    m.currentIdx = idx;
    this.saveModels();
    this.styledCache.delete('model:' + m.name);
    this.showHistory = false;
    await this.rebuildThumbs();
    if (this.selectedKey === 'model:' + m.name) {
      await this.renderStyle();
    }
    this.toast('已回退到「' + m.versions[idx].label + '」');
  }

  /** 历史面板「新增色彩」：以选中版本为起点分裂出独立模型（含参考池前缀）。 */
  private async doModelSplit(): Promise<void> {
    const m = this.findModel(this.historyName);
    if (m === undefined) {
      this.showHistory = false;
      return;
    }
    const idx = this.historySelIdx;
    if (idx < 0 || idx >= m.versions.length) {
      this.showHistory = false;
      return;
    }
    const v = m.versions[idx];
    const n = Math.min(v.seedCount, m.refCount());
    const embs = new Float32Array(n * 36);
    embs.set(m.embs.subarray(0, n * 36), 0);
    const fps: number[] = [];
    const chroma: number[] = [];
    for (let i = 0; i < n; i++) {
      fps.push(m.fps[i * 2], m.fps[i * 2 + 1]);
      chroma.push(m.chroma[i]);
    }
    const name = this.uniqueModelName('模型');
    const now = Date.now();
    const nv = new McVersion(`${now}`, v.label, now, v.aff, v.knots, n);
    this.models.push(new ModelColorEntry(name, [nv], 0, embs, fps, chroma));
    this.saveModels();
    this.showHistory = false;
    await this.rebuildThumbs();
    this.toast('已生成「' + name + '」，见我的色彩分类');
  }

  /** 版本时间文案：MM-dd HH:mm。 */
  private fmtTime(ts: number): string {
    const d = new Date(ts);
    return `${this.pad2(d.getMonth() + 1)}-${this.pad2(d.getDate())} ` +
      `${this.pad2(d.getHours())}:${this.pad2(d.getMinutes())}`;
  }

  private pad2(v: number): string {
    return v < 10 ? `0${v}` : `${v}`;
  }

  /** 分享：复制分享码到剪贴板（可粘贴到任意应用）。 */
  private shareCustom(code: string, name: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, code);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => {
        this.toast('分享码已复制，可粘贴到任意应用分享');
      })
      .catch(() => {
        this.toast('分享失败');
      });
  }

  /** 分类弹窗（Batch G）：7 分类 + 模型色彩入口。 */
  private showCategoryPopup(): void {
    const sheets: SheetInfo[] = [];
    for (let i = 0; i < StyleCategories.LIST.length; i++) {
      const cat = StyleCategories.LIST[i];
      sheets.push({
        title: cat.title,
        action: () => {
          this.onCategory(cat.id);
        }
      });
    }
    sheets.push({
      title: '模型色彩',
      action: () => {
        this.startModelCreate();
      }
    });
    this.getUIContext().showActionSheet({
      title: '选择分类',
      message: '',
      sheets: sheets
    });
  }

  private dismissCoach(): void {
    this.showCoach = false;
    SettingsStore.markCoachShown();
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

  private async takeAndLoad(): Promise<void> {
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    try {
      if (SettingsStore.inappCaptureMode() === 'auto' && await this.captureAuto(c)) {
        return; // 已进入应用内 RAW 拍摄浮层
      }
      const uri = await ImagePipeline.takePhoto(c);
      if (uri === '') {
        return;
      }
      await this.loadFromUri(uri);
    } catch (e) {
      this.toast('拍照不可用');
    }
  }

  /**
   * auto 模式回落链首档判定：授权 CAMERA → 重探测能力 → 有 DNG 拍照档则
   * 打开应用内拍摄浮层（返回 true）；无权限 / 无相机 / 无 DNG 档返回 false（降级系统相机）。
   */
  private async captureAuto(c: common.Context): Promise<boolean> {
    const granted = await InAppCapture.ensurePermission(c);
    if (!granted) {
      return false;
    }
    InAppCapture.reset(); // 权限刚授予，清缓存重探（此前可能因无权限探测失败）
    const cap = InAppCapture.probe(c);
    if (!cap.dng) {
      return false;
    }
    this.cameraReady = false;
    this.cameraBusy = false;
    this.showCamera = true;
    return true;
  }

  /** XComponent surface 就绪后建立相机会话；失败即降级系统相机。 */
  private async initCamera(surfaceId: string): Promise<void> {
    const c = this.ctx();
    if (c === undefined) {
      this.showCamera = false;
      return;
    }
    const cam = await AppCamera.open(c, surfaceId);
    if (!this.showCamera) {
      // 等待期间浮层已关闭
      if (cam !== undefined) {
        await cam.release();
      }
      return;
    }
    if (cam === undefined) {
      this.showCamera = false;
      this.toast('应用内 RAW 拍摄不可用，已改用系统相机');
      await this.fallbackSystemCamera();
      return;
    }
    this.appCamera = cam;
    this.cameraReady = true;
  }

  /** 降级拍摄：cameraPicker（免权限）。 */
  private async fallbackSystemCamera(): Promise<void> {
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    const uri = await ImagePipeline.takePhoto(c);
    if (uri !== '') {
      await this.loadFromUri(uri);
    }
  }

  /** 应用内拍摄快门：拍 → 落盘 → RAW 走解码管线进编辑器，JPEG 兜底走常规加载。 */
  private async captureFromInApp(): Promise<void> {
    if (this.cameraBusy || !this.cameraReady) {
      return;
    }
    const cam = this.appCamera;
    const c = this.ctx();
    if (cam === undefined || c === undefined) {
      return;
    }
    this.cameraBusy = true;
    const shot = await cam.capture();
    this.cameraBusy = false;
    if (shot === undefined) {
      this.toast('拍摄失败，请重试');
      return;
    }
    await this.closeCamera();
    this.processing = true;
    try {
      const ext = shot.isDng ? 'dng' : 'jpg';
      const path = `${c.filesDir}/capture_${Date.now()}.${ext}`;
      const file = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, shot.bytes.buffer);
      } finally {
        fs.closeSync(file);
      }
      if (shot.isDng) {
        const d = await ImagePipeline.decodeRaw(path, SettingsStore.rawThr(),
          ImagePipeline.PREVIEW_EDGE);
        if (d === undefined) {
          this.processing = false;
          this.toast('RAW 解码失败');
          return;
        }
        this.deleteCapturedFile();
        this.pickedUri = '';
        this.rawSourceUri = path;
        this.srcExifApp1 = new Uint8Array(0); // DNG 直拍无 JPEG APP1
        await this.applyDecoded(d);
      } else {
        // JPEG 兜底（DNG 档意外产出 JPEG 时）：常规加载路径
        await this.loadFromUri(path);
      }
    } catch (e) {
      this.processing = false;
      this.toast('拍摄处理失败');
    }
  }

  /** 清理上一张应用内拍摄文件（新图接管前调用）。 */
  private deleteCapturedFile(): void {
    const c = this.ctx();
    if (c === undefined || this.rawSourceUri === '') {
      return;
    }
    const prefix = `${c.filesDir}/capture_`;
    if (this.rawSourceUri.startsWith(prefix)) {
      try {
        fs.unlinkSync(this.rawSourceUri);
      } catch (e) {
      }
    }
  }

  /** 关闭拍摄浮层并释放相机会话。 */
  private async closeCamera(): Promise<void> {
    this.showCamera = false;
    this.cameraReady = false;
    this.cameraBusy = false;
    const cam = this.appCamera;
    this.appCamera = undefined;
    if (cam !== undefined) {
      await cam.release();
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
    // 捕获源图 EXIF（真实设备/时间），导出时移植；读头 256KB 足够容纳 APP1
    const head = ImagePipeline.readHead(uri, 262144);
    const app1 = LeicaMark.extractApp1(head);
    this.srcExifApp1 = app1 !== undefined ? app1 : new Uint8Array(0);
    try {
      await this.applyDecoded(d);
    } catch (e) {
      this.processing = false;
      this.toast('图片加载失败');
    }
  }

  private async pickRawAndLoad(): Promise<void> {
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    this.processing = true;
    try {
      const uri = await ImagePipeline.pickRaw(c);
      if (uri === '') {
        this.processing = false;
        return;
      }
      const d = await ImagePipeline.decodeRaw(uri, SettingsStore.rawThr(), ImagePipeline.PREVIEW_EDGE);
      if (d === undefined) {
        this.processing = false;
        this.toast('RAW 解码失败');
        return;
      }
      this.pickedUri = '';
      this.rawSourceUri = uri;
      this.srcExifApp1 = new Uint8Array(0); // RAW 无 JPEG APP1，导出走 Software 模板
      await this.applyDecoded(d);
    } catch (e) {
      this.processing = false;
      this.toast('RAW 导入失败');
    }
  }

  private async loadTestImage(): Promise<void> {
    this.processing = true;
    try {
      const d = await ImagePipeline.makeTestImage(1600, 1200);
      this.pickedUri = '';
      this.srcExifApp1 = new Uint8Array(0);
      await this.applyDecoded(d);
    } catch (e) {
      this.processing = false;
      this.toast('生成测试图失败');
    }
  }

  private async applyDecoded(d: DecodedImage): Promise<void> {
    // 新图：八档调整归零、收起面板、取消挂起的重绘（与 Android 换图重置口径一致）
    for (let i = 0; i < this.levels.length; i++) {
      this.levels[i] = 0;
    }
    if (this.toneTimer >= 0) {
      clearTimeout(this.toneTimer);
      this.toneTimer = -1;
    }
    this.showAdjust = false;
    this.comparing = false;
    this.resetZoom();
    this.hdrEnabled = SettingsStore.hdrDefaultOn();
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

  /** 返回首页：释放当前图与派生缓存，恢复初始选图界面（顶部「换图」入口）。 */
  private returnHome(): void {
    if (this.toneTimer >= 0) {
      clearTimeout(this.toneTimer);
      this.toneTimer = -1;
    }
    this.renderSeq++;
    this.rendering = false;
    for (let i = 0; i < this.levels.length; i++) {
      this.levels[i] = 0;
    }
    this.showAdjust = false;
    this.comparing = false;
    this.resetZoom();
    const oldOrig = this.origPM;
    const oldDisp = this.displayPM;
    if (oldOrig !== undefined) {
      oldOrig.release().catch(() => {
      });
    }
    if (oldDisp !== undefined && oldDisp !== oldOrig) {
      oldDisp.release().catch(() => {
      });
    }
    this.origPM = undefined;
    this.displayPM = undefined;
    this.origBuf = new Uint8Array(0);
    this.origW = 0;
    this.origH = 0;
    this.styledBuf = new Uint8Array(0);
    this.thumbBuf = new Uint8Array(0);
    this.thumbW = 0;
    this.thumbH = 0;
    this.thumbEntries = [];
    this.styledCache.clear();
    this.noticeCache.clear();
    this.selectedKey = '';
    this.notice = '';
    this.deleteCapturedFile();
    this.pickedUri = '';
    this.rawSourceUri = '';
    this.srcExifApp1 = new Uint8Array(0);
    this.hasImage = false;
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
      await yieldUI();
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
      // 模型色彩卡（Batch H）：当前版本 aff/knots 直接套 128px 缩略图（16k 像素，主线程可承受）
      for (let i = 0; i < this.models.length; i++) {
        const m = this.models[i];
        const cv = m.current();
        const px = this.thumbBuf.slice();
        ModelColorMath.apply(px, this.thumbW, this.thumbH, cv.aff, cv.knots,
          true, true, 1, false);
        entries.push(new ThumbEntry('model:' + m.name, m.name, await this.thumbPmOf(px), ''));
        await yieldUI();
      }
      entries.push(new ThumbEntry('__import', '导入码', undefined, ''));
      entries.push(new ThumbEntry('__model', '模型', undefined, ''));
    }
    let ordered: ThumbEntry[] = entries;
    if (SettingsStore.pinnedCrossCategory() && entries.length > 1) {
      const orig: ThumbEntry[] = [];
      const head: ThumbEntry[] = [];
      const rest: ThumbEntry[] = [];
        for (let i = 0; i < entries.length; i++) {
          const it = entries[i];
          if (it.key === '__orig' || it.key === '__import' || it.key === '__model') {
          orig.push(it);
        } else if (SettingsStore.isPinned(it.key)) {
          head.push(it);
        } else {
          rest.push(it);
        }
      }
      ordered = orig.concat(head).concat(rest);
    }
    this.thumbEntries = ordered;
    this.thumbRev++;
  }

  private onCategory(id: string): void {
    if (this.currentCategory === id) {
      return;
    }
    this.currentCategory = id;
    SettingsStore.setLastCategory(id);
    this.rebuildThumbs();
  }

  private openSettings(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' });
  }

  private selectStyle(key: string): void {
    if (this.selectedKey === key) {
      return;
    }
    this.selectedKey = key;
    this.resetZoom();
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
      const neutral: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
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
      } else if (key.startsWith('model:')) {
        const m = this.findModel(key.substring(6));
        if (m !== undefined) {
          const cv = m.current();
          styled = await ModelColorRunner.run(this.origBuf, this.origW, this.origH,
            cv.aff, cv.knots, true, true, false, 1, neutral);
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
    this.rendering = true;
    let px = this.styledBuf;
    const glowSet = this.levels.length > ToneCurves.TONE_COUNT &&
      this.levels[ToneCurves.TONE_COUNT] !== 0;
    if (!ToneCurves.isNeutral(this.levels) || glowSet) {
      px = await StyleRunner.run(this.styledBuf, this.origW, this.origH,
        StyleMode.MODEL_PASSTHROUGH, 0, 0, false, undefined, undefined, this.levels);
    }
    if (this.hdrEnabled) {
      px = HdrGainMap.applyPreview(px, this.origW, this.origH, SettingsStore.hdrBoostLevel());
    }
    if (seq !== this.renderSeq) {
      return; // 更新的重绘已在进行，提示由其负责清除
    }
    const pm = await ImagePipeline.rgbaToPixelMap(px, this.origW, this.origH);
    if (seq !== this.renderSeq) {
      return;
    }
    const old = this.displayPM;
    this.displayPM = pm;
    this.rendering = false;
    if (old !== undefined && old !== pm && old !== this.origPM) {
      old.release().catch(() => {
      });
    }
  }

  private onSlider(idx: number, value: number): void {
    // 双击归零后 ~300ms 内到达的跳变回声（Slider 点按跳转动画结束才提交 onChange），
    // 会把刚归零的档位改回跳变值，吞掉。
    if (value !== 0 && idx === this.zeroGuardIdx && Date.now() - this.zeroGuardTs < 450) {
      return;
    }
    this.levels[idx] = Math.round(value);
    if (this.toneTimer >= 0) {
      clearTimeout(this.toneTimer);
    }
    this.toneTimer = setTimeout(() => {
      this.toneTimer = -1;
      this.renderTone();
    }, 120);
  }

  /** 双击滑杆行归零（与 Android 双击 SeekBar 归零一致）。 */
  private zeroSlider(idx: number): void {
    if (this.levels[idx] === 0) {
      return;
    }
    this.levels[idx] = 0;
    this.zeroGuardIdx = idx;
    this.zeroGuardTs = Date.now();
    if (this.toneTimer >= 0) {
      clearTimeout(this.toneTimer);
      this.toneTimer = -1;
    }
    this.renderTone();
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

  /** 完美档：M9 系 StyleTrans high + 真 ColorFix（输出已摆正、已配色，跳过风格/色调链）。 */
  private async perfectExport(src: Uint8Array, w: number, h: number): Promise<RgbaImg | undefined> {
    const c = this.ctx();
    if (c === undefined) {
      return undefined;
    }
    this.exportProgress = 0;
    this.toast('完美档处理中…');
    const r = await M9PerfectEngine.process(src, w, h, c.resourceManager, (v: number) => {
      this.exportProgress = v;
    });
    if (r === undefined) {
      this.exportProgress = 0;
    }
    return r;
  }

  /**
   * 导出源解码：full_res_export 开启且（拟用尺寸的）像素在安全预算内 → 原分辨率；
   * M9 系 + m9_hires_export → 长边上限 8192；否则沿用 3072/2304 工作口径。
   * 超过预算回落工作分辨率（防大图内存峰值）。
   */
  private async exportDecode(): Promise<DecodedImage | undefined> {
    if (SettingsStore.fullResEnabled()) {
      const size = await ImagePipeline.probeSize(this.pickedUri);
      if (size.length === 2) {
        let edge = ImagePipeline.FULL_EDGE;
        if (this.isM9Family() && SettingsStore.m9HiResEnabled()) {
          edge = ImagePipeline.HIRES_M9_EDGE;
        }
        const long = Math.max(size[0], size[1]);
        const scale = Math.min(1, edge / long);
        const px = size[0] * size[1] * scale * scale;
        if (px <= ImagePipeline.SAFE_EXPORT_PIXELS) {
          return ImagePipeline.decodeUri(this.pickedUri, edge, 0);
        }
        this.toast('图片过大，已按工作分辨率导出');
      }
    }
    return ImagePipeline.decodeUri(this.pickedUri, 3072, 2304);
  }

  /** 当前风格是否属 M9 系（M9 / M9+ / M10R）——m9_hires_export 的作用域。 */
  private isM9Family(): boolean {
    const key = this.selectedKey;
    if (key === '' || key.startsWith('cust:')) {
      return false;
    }
    const def = StyleDefs.byId(key);
    if (def === undefined) {
      return false;
    }
    return def.mode === StyleMode.MODEL_M9 || def.mode === StyleMode.MODEL_M9P ||
      def.mode === StyleMode.MODEL_M10R;
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
    let exportPm: image.PixelMap | undefined = undefined;
    try {
      target = await ImagePipeline.createAssetTarget(c, 'jpg');
      let src: Uint8Array;
      let w: number;
      let h: number;
      if (this.pickedUri !== '') {
        const d = await this.exportDecode();
        if (d === undefined) {
          throw new Error('原图解码失败');
        }
        src = d.data;
        w = d.width;
        h = d.height;
        d.pixelMap.release().catch(() => {
        });
      } else {
        src = this.origBuf;
        w = this.origW;
        h = this.origH;
      }
      const key = this.selectedKey;
      const perfectOut = (this.perfectOn && this.isM9Family())
        ? await this.perfectExport(src, w, h) : undefined;
      let out: Uint8Array;
      if (perfectOut !== undefined) {
        out = perfectOut.px;
      } else if (key === '') {
        if (ToneCurves.isNeutral(this.levels)) {
          out = src;
        } else {
          out = await StyleRunner.run(src, w, h, StyleMode.MODEL_PASSTHROUGH, 0, 0, false,
            undefined, undefined, this.levels);
        }
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
      } else if (key.startsWith('model:')) {
        const m = this.findModel(key.substring(6));
        if (m === undefined) {
          throw new Error('模型色彩不存在');
        }
        const cv = m.current();
        out = await ModelColorRunner.run(src, w, h, cv.aff, cv.knots,
          true, true, false, 1, this.levels);
      } else {
        const def = StyleDefs.byId(key);
        if (def === undefined) {
          throw new Error('风格不存在');
        }
        if (NeuralEngine.isNeuralMode(def.mode)) {
          const glowSet = this.levels.length > ToneCurves.TONE_COUNT &&
            this.levels[ToneCurves.TONE_COUNT] !== 0;
          const cachedStyle = this.styledCache.get(key);
          let styled: Uint8Array;
          if (this.pickedUri === '' && cachedStyle !== undefined &&
            cachedStyle.length === w * h * 4) {
            styled = cachedStyle;
          } else {
            const px = this.pickedUri !== '' ? src : src.slice();
            await NeuralEngine.applyNeural(px, w, h, def.mode);
            styled = px;
          }
          if (ToneCurves.isNeutral(this.levels) && !glowSet) {
            out = styled;
          } else {
            out = await StyleRunner.run(styled, w, h, StyleMode.MODEL_PASSTHROUGH,
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
      const canRunSuperRes: boolean = this.superResEnabled;
      const safeSuperRes: boolean = canRunSuperRes &&
        w * h <= SuperResEngine.MAX_SAFE_INPUT_PIXELS;
      if (canRunSuperRes && !safeSuperRes) {
        this.toast('手机内存保护：图片过大，超分已跳过，保留完整普通导出');
      }
      if (safeSuperRes) {
        const upscaled = await SuperResEngine.upscale(out, w, h, this.superResMode);
        if (upscaled !== undefined) {
          out = upscaled.data;
          w = upscaled.width;
          h = upscaled.height;
        } else {
          this.toast('当前图像较大，超分已降级为普通导出');
        }
      }
      exportPm = await ImagePipeline.rgbaToPixelMap(out, w, h);
      const jpeg = await ImagePipeline.packJpeg(exportPm, 95);
      // 徽章收口先于 HDR 回嵌：mark 剥离 XMP/MPF/ISO 复合容器并移植源图 EXIF，
      // 必须在增益图写入前执行；徽章 = EXIF 私有 tag + FFE4 段（原版口径，无像素水印）。
      const marked = LeicaMark.mark(jpeg, this.srcExifApp1, SettingsStore.leicaBadgeEnabled());
      let finalJpeg: Uint8Array = marked;
      if (this.hdrEnabled) {
        const hdr = await HdrGainMap.synthFromRgba(out, w, h, SettingsStore.hdrBoostLevel());
        if (hdr !== undefined) {
          finalJpeg = HdrGainMap.embed(marked, hdr);
        }
      } else {
        finalJpeg = HdrGainMap.truncateToPrimary(marked);
      }
      await ImagePipeline.writeToGallery(target, finalJpeg);
      exportPm.release().catch(() => {
      });
      exportPm = undefined;
      this.toast('已保存到图库');
    } catch (e) {
      if (exportPm !== undefined) {
        exportPm.release().catch(() => {
        });
        exportPm = undefined;
      }
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

  /** 导出「我的色彩」备份（.lmc 文本，DocumentViewPicker 保存）。 */
  private async backupColors(): Promise<void> {
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    if (this.customs.length === 0) {
      this.toast('还没有自定义色彩');
      return;
    }
    this.saveCustoms();
    const items: ColorBackupItem[] = [];
    for (let i = 0; i < this.customs.length; i++) {
      const e = this.customs[i];
      items.push(new ColorBackupItem(e.name, e.code, e.crc));
    }
    const ok = await ColorBackup.save(c, ColorBackup.toText(items), ColorBackup.defaultFileName());
    this.toast(ok ? ('已导出 ' + items.length + ' 个色彩') : '导出已取消');
  }

  /** 导入「我的色彩」备份（只增不删：同名或同 crc 跳过）。 */
  private async restoreColors(): Promise<void> {
    const c = this.ctx();
    if (c === undefined) {
      return;
    }
    const text = await ColorBackup.pick(c);
    if (text === '') {
      this.toast('已取消');
      return;
    }
    const res = ColorBackup.parse(text);
    if (res.items.length === 0) {
      this.toast('备份文件无可导入色彩');
      return;
    }
    let added = 0;
    let merged = 0;
    for (let i = 0; i < res.items.length; i++) {
      const it = res.items[i];
      let dup = false;
      for (let j = 0; j < this.customs.length; j++) {
        if (this.customs[j].crc === it.crc || this.customs[j].name === it.name) {
          dup = true;
          break;
        }
      }
      if (dup) {
        merged++;
        continue;
      }
      this.customs.push(new CustomEntry(it.name, it.code, it.crc));
      added++;
    }
    if (added > 0) {
      this.saveCustoms();
      if (this.currentCategory === 'custom') {
        await this.rebuildThumbs();
      }
    }
    let msg = '已导入 ' + added + ' 个色彩';
    if (merged > 0) {
      msg += '，跳过 ' + merged + ' 个已有';
    }
    if (res.skipped > 0) {
      msg += '，忽略 ' + res.skipped + ' 条无效';
    }
    this.toast(msg);
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
    if (e.key === '__model') {
      this.startModelCreate();
      return;
    }
    this.selectStyle(e.key);
  }

  private onCardLongPress(e: ThumbEntry): void {
    if (e.key === '__import' || e.key === '__model' || e.key === '__orig') {
      return;
    }
    const sheets: SheetInfo[] = [];
    const pinned = SettingsStore.isPinned(e.key);
    sheets.push({
      title: pinned ? '取消置顶' : '置顶',
      action: () => {
        SettingsStore.togglePinned(e.key);
        this.rebuildThumbs();
        this.toast(pinned ? '已取消置顶' : '已置顶');
      }
    });
    if (e.key.startsWith('cust:')) {
      const name = e.key.substring(5);
      sheets.push({
        title: '重命名',
        action: () => {
          this.openRename(name);
        }
      });
      sheets.push({
        title: '回退版本',
        action: () => {
          this.toast('该色彩暂无历史版本');
        }
      });
      sheets.push({
        title: '复制分享码',
        action: () => {
          this.copyCustomCode(e.code);
        }
      });
      sheets.push({
        title: '分享',
        action: () => {
          this.shareCustom(e.code, name);
        }
      });
      sheets.push({
        title: '删除',
        action: () => {
          this.deleteCustom(name);
        }
      });
    } else if (e.key.startsWith('model:')) {
      const name = e.key.substring(6);
      sheets.push({
        title: '增强',
        action: () => {
          this.startModelEnhance(name);
        }
      });
      sheets.push({
        title: '版本历史',
        action: () => {
          this.openModelHistory(name);
        }
      });
      sheets.push({
        title: '重命名',
        action: () => {
          this.openModelRename(name);
        }
      });
      sheets.push({
        title: '删除',
        action: () => {
          this.deleteModel(name);
        }
      });
    }
    this.getUIContext().showActionSheet({
      title: e.label,
      message: '',
      sheets: sheets
    });
  }

  @Builder
  private styleCard(e: ThumbEntry) {
    Column({ space: 5 }) {
      if (e.key === '__import' || e.key === '__model') {
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
    GlassButton({
      label: cat.title,
      buttonWidth: 28 + estimateTextWidth(cat.title, 13),
      buttonHeight: 30,
      labelSize: 13,
      labelColor: this.currentCategory === cat.id ? '#E8B84B' : '#C9C9C9',
      selected: this.currentCategory === cat.id,
      clickAction: (): void => {
        this.onCategory(cat.id);
      },
      longPressAction: (): void => {
        this.showCategoryPopup();
      }
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
    .onTouch((event: TouchEvent) => {
      // 双击行归零：onTouch 被动观测，不参与手势仲裁（Slider 原生点按跳转/拖动不受影响）
      if (event.type === TouchType.Down) {
        const d = event.changedTouches[0];
        if (d !== undefined) {
          this.downX = d.x;
          this.downY = d.y;
        }
      } else if (event.type === TouchType.Up) {
        const u = event.changedTouches[0];
        if (u === undefined) {
          return;
        }
        const dx = u.x - this.downX;
        const dy = u.y - this.downY;
        if (dx * dx + dy * dy > 100) {
          return;
        }
        const now = Date.now();
        if (this.tapIdx === idx && now - this.tapTs < 320) {
          this.tapIdx = -1;
          this.tapTs = 0;
          this.zeroSlider(idx);
        } else {
          this.tapIdx = idx;
          this.tapTs = now;
        }
      }
    })
  }

  @Builder
  private perfectOverlay() {
    Column() {
      Column({ space: 10 }) {
        Text('完美档处理中')
          .fontSize(16)
          .fontColor('#F2E6C9')
        Text(this.exportProgress + '%')
          .fontSize(28)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E8B84B')
        Text('StyleTrans high + 真 ColorFix，耗时较长请稍候')
          .fontSize(11)
          .fontColor('#8A8A8A')
      }
      .padding(24)
      .backgroundColor('#1C1C1E')
      .borderRadius(16)
      .width('70%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.6)')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private renameOverlay() {
    Column() {
      Column({ space: 12 }) {
        Text('重命名色彩')
          .fontSize(17)
          .fontColor('#F2E6C9')
        TextInput({ text: this.renameText, placeholder: '输入新名称' })
          .onChange((v: string) => {
            this.renameText = v;
          })
          .height(44)
          .backgroundColor('#26262A')
          .fontColor('#EEEEEE')
          .fontSize(14)
        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .backgroundColor('#333338')
            .fontColor('#DDDDDD')
            .onClick(() => {
              this.showRename = false;
            })
          Button('确定')
            .layoutWeight(1)
            .backgroundColor('#E8B84B')
            .fontColor('#1A1A1A')
            .onClick(() => {
              this.doRename();
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

  @Builder
  private coachOverlay() {
    Column() {
      Column({ space: 12 }) {
        Text('欢迎使用 L-Moment')
          .fontSize(17)
          .fontColor('#F2E6C9')
        Text('· 点风格卡套用徕卡色彩；长按卡片可置顶 / 重命名 / 分享 / 删除\n' +
          '· 预览图支持双指缩放、双击放大、长按对比原图\n' +
          '· 「调整」面板八档滑杆精调影调，双击滑杆行归零\n' +
          '· M9 系风格可开启「完美档」获得高保真导出\n' +
          '· 设置页可切换全像素导出、HDR、超分等档位')
          .fontSize(12)
          .fontColor('#BBBBBB')
          .lineHeight(20)
        Button('知道了')
          .width('100%')
          .backgroundColor('#E8B84B')
          .fontColor('#1A1A1A')
          .onClick(() => {
            this.dismissCoach();
          })
      }
      .width('86%')
      .padding(22)
      .backgroundColor('#1C1C1E')
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.6)')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private importOverlay() {
    Column() {
      Column() {
        Text('我的色彩')
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
        Row({ space: 12 }) {
          Button('导出备份')
            .layoutWeight(1)
            .backgroundColor('#2A2A2E')
            .fontColor('#E8B84B')
            .fontSize(14)
            .onClick(() => {
              this.showImport = false;
              this.backupColors();
            })
          Button('导入备份')
            .layoutWeight(1)
            .backgroundColor('#2A2A2E')
            .fontColor('#E8B84B')
            .fontSize(14)
            .onClick(() => {
              this.showImport = false;
              this.restoreColors();
            })
        }
        .width('100%')
        .margin({ top: 10 })
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

  /** 模型色彩候选浮层（Batch H）：对齐 StyleCandidateSheet 的候选挑选。 */
  @Builder
  private modelSheetOverlay() {
    Column() {
      Column({ space: 12 }) {
        Text('选择模型色彩')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2E6C9')
        Text('参考集包含多种色彩倾向，点按要保存的候选')
          .fontSize(11)
          .fontColor('#8A8A8A')
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.modelCands, (c: ModelCand, idx: number) => {
              Column({ space: 5 }) {
                Image(c.pm)
                  .width(104)
                  .height(104)
                  .borderRadius(12)
                  .objectFit(ImageFit.Cover)
                Text('候选 ' + (idx + 1) + (c.mono ? ' · 黑白' : ''))
                  .fontSize(11)
                  .fontColor('#C9C9C9')
              }
              .onClick(() => {
                this.pickModelCand(idx);
              })
            }, (c: ModelCand, idx: number) => 'cand#' + idx)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Center)
        Button('取消')
          .width('100%')
          .backgroundColor('#333338')
          .fontColor('#DDDDDD')
          .onClick(() => {
            this.showModelSheet = false;
            this.modelCands = [];
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 18 })
      .backgroundColor('#1C1C1E')
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.6)')
    .justifyContent(FlexAlign.End)
  }

  /** 模型增强预览浮层（Batch H）：旧/新渲染叠放，滑杆调新图不透明度交叉淡化。 */
  @Builder
  private enhanceOverlay() {
    Column() {
      Column({ space: 14 }) {
        Text('模型增强')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2E6C9')
        Text(`已添加 ${this.enhanceAdded} 张参考 · 共 ${this.enhanceTotal} 张`)
          .fontSize(11)
          .fontColor('#8A8A8A')
        Stack() {
          if (this.enhanceOldPM !== undefined) {
            Image(this.enhanceOldPM)
              .width('100%')
              .height(240)
              .objectFit(ImageFit.Contain)
              .borderRadius(12)
          }
          if (this.enhanceNewPM !== undefined) {
            Image(this.enhanceNewPM)
              .width('100%')
              .height(240)
              .objectFit(ImageFit.Contain)
              .borderRadius(12)
              .opacity(this.enhanceStrength / 100)
          }
        }
        .width('100%')
        Row() {
          Text('增强强度')
            .fontSize(12)
            .fontColor('#BBBBBB')
          Blank()
          Text(`${this.enhanceStrength}%`)
            .fontSize(12)
            .fontColor('#E8B84B')
        }
        .width('100%')
        Slider({ value: this.enhanceStrength, min: 0, max: 100, step: 1 })
          .onChange((v: number) => {
            this.enhanceStrength = Math.round(v);
          })
          .blockColor('#E8B84B')
          .selectedColor('#8A6D1F')
          .trackColor('#333338')
        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .backgroundColor('#333338')
            .fontColor('#DDDDDD')
            .onClick(() => {
              this.cancelModelEnhance();
            })
          Button('应用增强')
            .layoutWeight(1)
            .backgroundColor('#E8B84B')
            .fontColor('#1A1A1A')
            .onClick(() => {
              this.applyModelEnhance();
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

  /** 版本历史面板（Batch H）：单选行 + 回退 / 新增色彩。 */
  @Builder
  private historyOverlay() {
    Column() {
      Column({ space: 12 }) {
        Text('版本历史')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2E6C9')
        Text('点选版本后可回退或以其为起点生成新色彩')
          .fontSize(11)
          .fontColor('#8A8A8A')
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.historyRows, (r: HistoryRow) => {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text(r.label)
                    .fontSize(14)
                    .fontColor(r.idx === this.historySelIdx ? '#E8B84B' : '#DDDDDD')
                  Text(r.sub)
                    .fontSize(11)
                    .fontColor('#8A8A8A')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (r.isCur) {
                  Text('当前')
                    .fontSize(10)
                    .fontColor('#E8B84B')
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(8)
                    .backgroundColor('#2B2416')
                }
                if (r.idx === this.historySelIdx) {
                  Text('✓')
                    .fontSize(14)
                    .fontColor('#E8B84B')
                }
              }
              .width('100%')
              .padding(12)
              .borderRadius(12)
              .backgroundColor(r.idx === this.historySelIdx ? '#2B2416' : '#222226')
              .onClick(() => {
                this.historySelIdx = r.idx;
              })
            }, (r: HistoryRow) => 'h#' + r.idx)
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .constraintSize({ maxHeight: 320 })
        Row({ space: 12 }) {
          Button('回退')
            .layoutWeight(1)
            .backgroundColor('#333338')
            .fontColor(this.historySelIdx === this.historyCurIdx ? '#666666' : '#E8B84B')
            .enabled(this.historySelIdx !== this.historyCurIdx)
            .onClick(() => {
              this.doModelRollback();
            })
          Button('新增色彩')
            .layoutWeight(1)
            .backgroundColor(this.historySelIdx === this.historyCurIdx ? '#333338' : '#E8B84B')
            .fontColor(this.historySelIdx === this.historyCurIdx ? '#666666' : '#1A1A1A')
            .enabled(this.historySelIdx !== this.historyCurIdx)
            .onClick(() => {
              this.doModelSplit();
            })
        }
        .width('100%')
        Button('关闭')
          .width('100%')
          .backgroundColor('#26262A')
          .fontColor('#DDDDDD')
          .onClick(() => {
            this.showHistory = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 18 })
      .backgroundColor('#1C1C1E')
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.6)')
    .justifyContent(FlexAlign.End)
  }

  /** 应用内 RAW 拍摄浮层（Batch H+）：XComponent 取景 + 快门；启动失败自动降级系统相机。 */
  @Builder
  private cameraOverlay() {
    Stack() {
      XComponent({ type: XComponentType.SURFACE, controller: this.xcc })
        .onLoad(() => {
          this.initCamera(this.xcc.getXComponentSurfaceId());
        })
        .width('100%')
        .height('100%')
      Column() {
        Row() {
          Text('×')
            .fontSize(22)
            .fontColor('#FFFFFF')
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .backgroundColor('rgba(0,0,0,0.4)')
            .onClick(() => {
              this.closeCamera();
            })
          Blank()
          Text('RAW')
            .fontSize(11)
            .fontColor('#E8B84B')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(8)
            .backgroundColor('rgba(0,0,0,0.5)')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })
        Blank()
        if (!this.cameraReady) {
          Text('相机启动中…')
            .fontSize(13)
            .fontColor('#CCCCCC')
            .margin({ bottom: 24 })
        } else {
          Text('DNG 直拍 · 未压缩 RAW')
            .fontSize(11)
            .fontColor('#999999')
            .margin({ bottom: 14 })
        }
        Stack() {
          Column()
            .width(76)
            .height(76)
            .borderRadius(38)
            .border({ width: 3, color: this.cameraBusy ? '#888888' : '#FFFFFF' })
          Column()
            .width(60)
            .height(60)
            .borderRadius(30)
            .backgroundColor(this.cameraBusy ? '#AAAAAA' : '#FFFFFF')
            .onClick(() => {
              this.captureFromInApp();
            })
            .enabled(this.cameraReady && !this.cameraBusy)
        }
        .margin({ bottom: 40 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }

  build() {
    Stack() {
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
              GlassButton({
                label: '拍照',
                buttonWidth: 190,
                buttonHeight: 40,
                labelSize: 15,
                clickAction: (): void => {
                  this.takeAndLoad();
                }
              })
              GlassButton({
                label: '生成测试图',
                buttonWidth: 190,
                buttonHeight: 40,
                labelSize: 15,
                clickAction: (): void => {
                  this.loadTestImage();
                }
              })
              GlassButton({
                label: '导入 RAW',
                buttonWidth: 190,
                buttonHeight: 40,
                labelSize: 15,
                clickAction: (): void => {
                  this.pickRawAndLoad();
                }
              })            }
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
              .scale({ x: this.pvScale, y: this.pvScale })
              .translate({ x: this.pvOffX, y: this.pvOffY })
              .gesture(
                GestureGroup(GestureMode.Parallel,
                  LongPressGesture({ repeat: false, duration: 250 })
                    .onAction(() => {
                      this.comparing = true;
                    })
                    .onActionEnd(() => {
                      this.comparing = false;
                    }),
                  TapGesture({ count: 2 })
                    .onAction(() => {
                      this.onDoubleTap();
                    }),
                  PinchGesture({ fingers: 2 })
                    .onActionStart(() => {
                      this.onPinchStart();
                    })
                    .onActionUpdate((ev: GestureEvent) => {
                      this.onPinchUpdate(ev);
                    }),
                  PanGesture({ fingers: 1, distance: 5 })
                    .onActionStart(() => {
                      this.onPanStart();
                    })
                    .onActionUpdate((ev: GestureEvent) => {
                      this.onPanUpdate(ev);
                    })
                )
              )
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

          if (this.rendering && this.hasImage && !this.processing) {
            Row({ space: 6 }) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color('#E8B84B')
              Text('处理中…')
                .fontSize(11)
                .fontColor('#CCCCCC')
            }
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor('rgba(0,0,0,0.55)')
            .borderRadius(12)
            .position({ x: '50%', y: '94%' })
            .translate({ x: '-50%' })
          }

          if (this.processing || this.exporting || this.modelBusy) {
            Column({ space: 10 }) {
              LoadingProgress()
                .width(44)
                .height(44)
                .color('#E8B84B')
              Text(this.modelBusy ? '模型推理中…'
                : (this.exporting ? '导出中…' : '处理中…'))
                .fontSize(12)
                .fontColor('#CCCCCC')
            }
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.45)')
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#141416')
        .onAreaChange((_o: Area, n: Area) => {
          this.pvW = this.areaNum(n.width);
          this.pvH = this.areaNum(n.height);
        })

      // 顶部悬浮玻璃栏（内容穿越玻璃；状态栏经 topInset 避让）
      Column() {
        GlassPanel() {
          Column() {
            Row() {
              Text('L-Moment')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor('#F2E6C9')
              Blank()
              Scroll() {
                Row({ space: 12 }) {
                  if (this.hasImage) {
                    Text(this.selectedKey === '' ? '原图' : (this.findCustomOrDefLabel()))
                      .fontSize(12)
                      .fontColor('#8A8A8A')
                    Text('换图')
                      .fontSize(13)
                      .fontColor('#E8B84B')
                      .onClick(() => {
                        this.returnHome();
                      })
                    Text(this.hdrEnabled ? 'HDR开' : 'HDR')
                      .fontSize(13)
                      .fontColor(this.hdrEnabled ? '#F2E6C9' : '#E8B84B')
                      .onClick(() => {
                        this.hdrEnabled = !this.hdrEnabled;
                        SettingsStore.setHdrDefaultOn(this.hdrEnabled);
                        this.renderTone();
                      })
                    Text(this.superResEnabled ? (this.superResMode === SuperResMode.FAST ? '超分快' : '超分质') : '超分')
                      .fontSize(13)
                      .fontColor(this.superResEnabled ? '#F2E6C9' : '#E8B84B')
                      .onClick(() => {
                        if (!this.superResEnabled) {
                          this.superResEnabled = true;
                          this.superResMode = SuperResMode.FAST;
                        } else if (this.superResMode === SuperResMode.FAST) {
                          this.superResMode = SuperResMode.QUALITY;
                        } else {
                          this.superResEnabled = false;
                        }
                      })
                  }
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .constraintSize({ minWidth: 0, maxWidth: '72%' })
              Text('设置')
                .fontSize(13)
                .fontColor('#E8B84B')
                .onClick(() => {
                  this.openSettings();
                })
            }
            .width('100%')
            .height(52)
            .padding({ left: 20, right: 20 })
          }
          .width('100%')
          .padding({ top: this.topInset })
        }
        Blank()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)

      // 底部悬浮玻璃容器（分类 / 风格卡 / 操作栏 / 调整面板；手势条经 bottomInset 避让）
      // bleed 80：玻璃画布两侧各出血 80 再被裁剪，HDS 材质圆角推出可视区 → 直角玻璃边缘
      Column() {
        Blank()
        GlassPanel({ bleed: 80 }) {
          Column() {
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
                }, (e: ThumbEntry) => e.key + '#' + this.thumbRev)
              }
              .padding({ left: 10, right: 10 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            .height(122)
            .align(Alignment.Center)

            Row({ space: 10 }) {
              GlassButton({
                label: this.showAdjust ? '收起' : '调整',
                buttonWidth: 76,
                buttonHeight: 38,
                clickAction: (): void => {
                  this.showAdjust = !this.showAdjust;
                }
              })
              GlassButton({
                label: '导入码',
                buttonWidth: 90,
                buttonHeight: 38,
                clickAction: (): void => {
                  this.showImport = true;
                }
              })
              if (this.isM9Family()) {
                GlassButton({
                  label: this.perfectOn ? '完美 ✓' : '完美',
                  buttonWidth: 98,
                  buttonHeight: 38,
                  selected: this.perfectOn,
                  clickAction: (): void => {
                    this.perfectOn = !this.perfectOn;
                  }
                })
              }
              Blank()
              // SaveButton（安全组件不可重构）玻璃托盘：实测尺寸+边距的玻璃衬底垫在按钮下
              Stack() {
                if (this.saveTrayW > 1 && this.saveTrayH > 1) {
                  GlassCanvas({
                    canvasWidth: this.saveTrayW,
                    canvasHeight: this.saveTrayH
                  })
                }
                // SaveButton 自身不支持 onAreaChange，用透明 Column 包裹测量
                Column() {
                  SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE })
                    .onClick(async (_e: ClickEvent, result: SaveButtonOnClickResult) => {
                      if (result === SaveButtonOnClickResult.SUCCESS) {
                        await this.doExport();
                      } else {
                        this.toast('未获得保存授权');
                      }
                    })
                }
                .onAreaChange((_oldArea: Area, newArea: Area): void => {
                  const w = Number(newArea.width) + 16;
                  const h = Number(newArea.height) + 12;
                  if (Math.abs(w - this.saveTrayW) > 0.5 || Math.abs(h - this.saveTrayH) > 0.5) {
                    this.saveTrayW = w;
                    this.saveTrayH = h;
                  }
                })
              }
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
                this.sliderRow('柔光', 7)
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 4, bottom: 8 })
            }
          }
          .width('100%')
          .padding({ bottom: this.bottomInset })
        }
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)

      if (this.showImport) {
        this.importOverlay()
      }
      if (this.showModelSheet) {
        this.modelSheetOverlay()
      }
      if (this.showEnhance) {
        this.enhanceOverlay()
      }
      if (this.showHistory) {
        this.historyOverlay()
      }
      if (this.showCamera) {
        this.cameraOverlay()
      }
      if (this.exporting && this.perfectOn) {
        this.perfectOverlay()
      }
      if (this.showRename) {
        this.renameOverlay()
      }
      if (this.showCoach) {
        this.coachOverlay()
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
    if (this.selectedKey.startsWith('model:')) {
      return this.selectedKey.substring(6);
    }
    const def = StyleDefs.byId(this.selectedKey);
    return def !== undefined ? def.label : '';
  }
}
