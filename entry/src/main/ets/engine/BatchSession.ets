/**
 * 批量多图编辑会话（移植自 v1.5.0 BatchSession/EditItem/Recipe）。
 *
 * 语义（与上游 2026-11-02 拍板口径一致）：
 *  - 单独调过的图（touched）保留自己的设置；
 *  - 从未调整的图跟随配方（Recipe），切到它时立即套用并渲染——预览即导出结果；
 *  - 全部导出前再把配方兜底写一遍（只覆盖从未显示/调整过的图）。
 *
 * 只存轻状态（风格 key / 八档 / HDR / 超分开关）；工作缓冲与派生缓存
 * 始终只有活动图一份，由 Index 在切图时整体换装（与上游 LRU 热状态等效的
 * 单槽简化：批次内切图即重新解码，内存恒定为单图峰值）。
 */

/** 批量会话条目：一张图 + 它自己的轻状态。 */
export class BatchItem {
  static readonly LEVEL_COUNT: number = 8;

  readonly uri: string;
  /** 选中的风格 key（''=原图；含 cust:/model: 前缀，与 Index.selectedKey 同口径）。 */
  styleKey: string = '';
  /** 八档调整值（亮度/曝光/高光/阴影/黑色阶/饱和度/对比度/柔光）。 */
  levels: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
  hdrOn: boolean = false;
  superResOn: boolean = false;
  /** 用户是否单独调整过（批量导出时保自有设置；false 则跟随配方）。 */
  touched: boolean = false;

  constructor(uri: string) {
    this.uri = uri;
  }

  /** 是否已有任何色彩/档位（「未调整」判定与导出预检共用）。 */
  hasSettings(): boolean {
    if (this.styleKey !== '') {
      return true;
    }
    for (let i = 0; i < this.levels.length; i++) {
      if (this.levels[i] !== 0) {
        return true;
      }
    }
    return false;
  }

  /** 把配方写进本项（仅批量导出前对未调整项调用）。 */
  applyRecipe(recipe: BatchRecipe): void {
    this.styleKey = recipe.styleKey;
    for (let i = 0; i < this.levels.length && i < recipe.levels.length; i++) {
      this.levels[i] = recipe.levels[i];
    }
    this.hdrOn = recipe.hdrOn;
    this.superResOn = recipe.superResOn;
  }
}

/** 当前色彩配方：从被用户操作过的那张图提炼出的「这批图长什么样」。 */
export class BatchRecipe {
  styleKey: string = '';
  levels: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
  hdrOn: boolean = false;
  superResOn: boolean = false;

  /** 空配方 = 没有任何色彩，此时无法批量导出。 */
  isEmpty(): boolean {
    if (this.styleKey !== '') {
      return false;
    }
    for (let i = 0; i < this.levels.length; i++) {
      if (this.levels[i] !== 0) {
        return false;
      }
    }
    return true;
  }

  /** 从活动图现场状态捕获配方（有设置时调用）。 */
  capture(styleKey: string, levels: number[], hdrOn: boolean, superResOn: boolean): void {
    this.styleKey = styleKey;
    for (let i = 0; i < this.levels.length && i < levels.length; i++) {
      this.levels[i] = levels[i];
    }
    this.hdrOn = hdrOn;
    this.superResOn = superResOn;
  }
}
