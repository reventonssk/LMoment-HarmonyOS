/**
 * 风格定义与配方（移植自 LeicaEngine.Style / FilterCategory）。
 *
 * 神经链风格（MODEL_*）由 NeuralEngine 经 MindSpore Lite 推理输出，
 * 模型缺失时按各风格降级链路回退；SA 隐藏自 UI（保留处理链）。
 */

export enum StyleMode {
  LUT = 0,
  M3 = 1,
  SA = 2,
  MODEL_PASSTHROUGH = 3,
  MODEL_M10R = 5,
  CUSTOM = 6,
  MODEL_M9 = 7,
  MODEL_M9P = 8,
  MODEL_M9D = 9,
  MODEL_LM9 = 10,
  MODEL_CCD_COOL = 11,
  MODEL_CCD_PINK = 12,
  MODEL_CCD_WARM = 13
}

export class StyleDef {
  readonly id: string;
  readonly label: string;
  readonly desc: string;
  readonly category: string;
  readonly mode: StyleMode;
  readonly lutFile: string;
  readonly grain: number;
  readonly vignette: number;
  readonly p9: boolean;

  constructor(id: string, label: string, desc: string, category: string, mode: StyleMode,
    lutFile: string, grain: number, vignette: number, p9: boolean) {
    this.id = id;
    this.label = label;
    this.desc = desc;
    this.category = category;
    this.mode = mode;
    this.lutFile = lutFile;
    this.grain = grain;
    this.vignette = vignette;
    this.p9 = p9;
  }
}

export class StyleDefs {
  static readonly M3: StyleDef = new StyleDef('M3', 'M3', '黑白经典', 'leica',
    StyleMode.M3, '', 0, 0, false);
  static readonly M9: StyleDef = new StyleDef('M9', 'M9', '彩色经典', 'leica',
    StyleMode.MODEL_M9, '', 0, 0, false);
  static readonly M9P: StyleDef = new StyleDef('M9P', 'M9+', '彩色经典·激进版', 'leica',
    StyleMode.MODEL_M9P, '', 0, 0, false);
  static readonly M10R: StyleDef = new StyleDef('M10R', 'M10-R', '暗角颗粒', 'leica',
    StyleMode.MODEL_M10R, '', 0, 0, false);
  static readonly M4: StyleDef = new StyleDef('M4', 'ARRI 2049', '浓青橙 · 电影暗调', 'arri',
    StyleMode.LUT, 'lut_alexa.bin', 0.22, 1.0, false);
  static readonly A709: StyleDef = new StyleDef('A709', 'ARRI 709', '基础影视 · 干净中性', 'arri',
    StyleMode.LUT, 'lut_arri709.bin', 0.14, 0.70, false);
  static readonly REVEAL: StyleDef = new StyleDef('REVEAL', 'Reveal', '通透还原 · 柔和低反差', 'arri',
    StyleMode.LUT, 'lut_arrireveal.bin', 0.10, 0.50, false);
  static readonly DUNE: StyleDef = new StyleDef('DUNE', 'Dune', '沙漠哑光 · 冷蓝砂橙', 'arri',
    StyleMode.LUT, 'lut_arridune.bin', 0.26, 0.85, false);
  static readonly LALALAND: StyleDef = new StyleDef('LALALAND', 'LaLaLand', '黄昏绚丽 · 霓虹饱和', 'arri',
    StyleMode.LUT, 'lut_arrilala.bin', 0.12, 0.80, false);
  static readonly JOKER: StyleDef = new StyleDef('JOKER', 'Joker', '绿调阴郁 · 低饱和', 'arri',
    StyleMode.LUT, 'lut_arrijoker.bin', 0.30, 1.00, false);
  static readonly M13: StyleDef = new StyleDef('M13', 'CCD·冷白', '冷白胶片', 'ccd',
    StyleMode.MODEL_CCD_COOL, '', 0, 0, false);
  static readonly CCDP: StyleDef = new StyleDef('CCDP', 'CCD·粉', '粉白通透', 'ccd',
    StyleMode.MODEL_CCD_PINK, '', 0, 0, false);
  static readonly CCDW: StyleDef = new StyleDef('CCDW', 'CCD·暖', '柯达暖黄', 'ccd',
    StyleMode.MODEL_CCD_WARM, '', 0, 0, false);
  static readonly LP9: StyleDef = new StyleDef('LP9', 'L-P9', 'P9 鲜艳', 'leica',
    StyleMode.LUT, 'lut_p9vibrant.bin', 0, 0.3, true);
  static readonly LM9: StyleDef = new StyleDef('LM9', 'L-M9', '一瞬 M9 · CCD', 'leica',
    StyleMode.MODEL_LM9, '', 0, 0, false);
  static readonly M9D: StyleDef = new StyleDef('M9D', 'M9 蒸馏', '一体化微网', 'leica',
    StyleMode.MODEL_M9D, '', 0, 0, false);
  static readonly FCHROME: StyleDef = new StyleDef('FCHROME', '经典铬', '哑光纪实 · 低饱和硬调', 'fuji',
    StyleMode.LUT, 'lut_fuji_chrome.bin', 0.14, 0.55, false);
  static readonly FCNEG: StyleDef = new StyleDef('FCNEG', '经典负片', '高对比 · 青影暖高', 'fuji',
    StyleMode.LUT, 'lut_fuji_cneg.bin', 0.16, 0.55, false);
  static readonly FNN: StyleDef = new StyleDef('FNN', '怀旧负片', '琥珀暖调 · 柔和褪色', 'fuji',
    StyleMode.LUT, 'lut_fuji_nn.bin', 0.12, 0.45, false);
  static readonly FPNH: StyleDef = new StyleDef('FPNH', '人像负片·高', '人像高对比 · 肤色优先', 'fuji',
    StyleMode.LUT, 'lut_fuji_pnh.bin', 0.10, 0.40, false);
  static readonly FACROS: StyleDef = new StyleDef('FACROS', '细腻黑白', '深黑细粒 · 平滑灰阶', 'fuji',
    StyleMode.LUT, 'lut_fuji_acros.bin', 0.15, 0.60, false);
  static readonly KP400: StyleDef = new StyleDef('KP400', 'K400', '人像奶油 · 暖柔', 'kodak',
    StyleMode.LUT, 'lut_kodak_400.bin', 0.12, 0.45, false);
  static readonly KG200: StyleDef = new StyleDef('KG200', 'K200', '金黄怀旧 · 蓝天压暗', 'kodak',
    StyleMode.LUT, 'lut_kodak_200.bin', 0.20, 0.55, false);
  static readonly KE100: StyleDef = new StyleDef('KE100', 'K100', '浓彩风光 · 锐利', 'kodak',
    StyleMode.LUT, 'lut_kodak_100.bin', 0.10, 0.38, false);
  static readonly KC64: StyleDef = new StyleDef('KC64', 'K64', '浓红反转 · 实黑', 'kodak',
    StyleMode.LUT, 'lut_kodak_64.bin', 0.13, 0.50, false);
  // H 色彩家族（HNCS 式自然还原，LUT 查表 + 极轻颗粒/暗角）
  static readonly HN: StyleDef = new StyleDef('HN', 'H·自然', '自然还原 · 通透', 'hassel',
    StyleMode.LUT, 'lut_hassel_hn.bin', 0.09, 0.45, false);
  static readonly HB: StyleDef = new StyleDef('HB', 'H·蓝', '天空深青 · 层次', 'hassel',
    StyleMode.LUT, 'lut_hassel_hb.bin', 0.08, 0.55, false);
  static readonly HG: StyleDef = new StyleDef('HG', 'H·绿', '橄榄绿植 · 不荧光', 'hassel',
    StyleMode.LUT, 'lut_hassel_hg.bin', 0.10, 0.45, false);
  static readonly HP: StyleDef = new StyleDef('HP', 'H·人像', '肤色金黄 · 柔调', 'hassel',
    StyleMode.LUT, 'lut_hassel_hp.bin', 0.07, 0.40, false);
  static readonly HW: StyleDef = new StyleDef('HW', 'H·暖阳', '黄昏金调 · 浓郁', 'hassel',
    StyleMode.LUT, 'lut_hassel_hw.bin', 0.14, 0.70, false);
  static readonly HS: StyleDef = new StyleDef('HS', 'H·灰', '低饱和 · 高级灰', 'hassel',
    StyleMode.LUT, 'lut_hassel_hs.bin', 0.14, 0.40, false);
  static readonly HM: StyleDef = new StyleDef('HM', 'H·黑白', '平滑灰阶 · 干净', 'hassel',
    StyleMode.LUT, 'lut_hassel_hm.bin', 0.14, 0.50, false);
  static readonly HC: StyleDef = new StyleDef('HC', 'H·冷调', '青灰冷调 · 通透', 'hassel',
    StyleMode.LUT, 'lut_hassel_hc.bin', 0.07, 0.38, false);
  static readonly SA: StyleDef = new StyleDef('SA', 'Style A', '闭式拟合 · 参考图直算', 'arri',
    StyleMode.SA, 'styleA_s0.bin', 0, 0, false);

  /** 内置风格全表（枚举顺序）。 */
  static readonly ALL: StyleDef[] = [
    StyleDefs.M3, StyleDefs.M9, StyleDefs.M9P, StyleDefs.M10R, StyleDefs.M4,
    StyleDefs.A709, StyleDefs.REVEAL, StyleDefs.DUNE, StyleDefs.LALALAND, StyleDefs.JOKER,
    StyleDefs.HN, StyleDefs.HB, StyleDefs.HG, StyleDefs.HP, StyleDefs.HW,
    StyleDefs.HS, StyleDefs.HM, StyleDefs.HC,
    StyleDefs.M13, StyleDefs.CCDP, StyleDefs.CCDW, StyleDefs.LP9, StyleDefs.LM9, StyleDefs.M9D,
    StyleDefs.FCHROME, StyleDefs.FCNEG, StyleDefs.FNN, StyleDefs.FPNH, StyleDefs.FACROS,
    StyleDefs.KP400, StyleDefs.KG200, StyleDefs.KE100, StyleDefs.KC64
  ];

  /** UI 可见内置风格（SA 隐藏）。 */
  static uiVisible(): StyleDef[] {
    const out: StyleDef[] = [];
    for (let i = 0; i < StyleDefs.ALL.length; i++) {
      if (StyleDefs.ALL[i].mode !== StyleMode.SA) {
        out.push(StyleDefs.ALL[i]);
      }
    }
    return out;
  }

  static byId(id: string): StyleDef | undefined {
    for (let i = 0; i < StyleDefs.ALL.length; i++) {
      if (StyleDefs.ALL[i].id === id) {
        return StyleDefs.ALL[i];
      }
    }
    return undefined;
  }
}

/** 分类定义（只影响 UI 展示）。 */
export class StyleCategory {
  readonly id: string;
  readonly title: string;

  constructor(id: string, title: string) {
    this.id = id;
    this.title = title;
  }
}

export class StyleCategories {
  static readonly LIST: StyleCategory[] = [
    new StyleCategory('all', 'L-Moment'),
    new StyleCategory('leica', '一瞬 M'),
    new StyleCategory('arri', 'ARRI'),
    new StyleCategory('hassel', 'H 色彩'),
    new StyleCategory('ccd', 'CCD'),
    new StyleCategory('fuji', 'F 胶片'),
    new StyleCategory('kodak', 'K 胶片'),
    new StyleCategory('custom', '我的色彩')
  ];
}
