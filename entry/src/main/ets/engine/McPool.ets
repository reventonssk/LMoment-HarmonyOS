/**
 * 模型参考池容量 / 查重 / 淘汰规则（Batch H，移植自 ModelPool.kt）。
 *
 * 池为「只增 + 版本记前缀张数」语义：淘汰必须与版本 seedCount 的下标重排
 * 在同一次提交里完成，否则旧版本回退/再增强会用错参考。
 * 指纹 = 9x8 dHash（64 位），存两个无符号 32 位半字（number 精度安全）；
 * 全 0 表示未知哈希：永不判重、按兜底分参与淘汰（FIFO）。
 * 纯数组运算，无 UI / SDK 依赖。
 */

import { ModelColorMath } from './ModelColorMath';

export class McPool {
  /** 跨批累计上限。 */
  static readonly MAX_TOTAL: number = 120;
  /** 单次添加上限。 */
  static readonly MAX_BATCH: number = 20;
  /** 判「同一张图」的容差：64 位里差 ≤2 位（重编码/缩放会有抖动）。 */
  private static readonly DUP_DISTANCE: number = 2;
  /** 未知哈希的淘汰分：先于「确实与众不同」的，后于「明确重复」的。 */
  private static readonly UNKNOWN_SCORE: number = 3;

  /** 9x8 dHash → [hi, lo]（无符号 32 位）。先缩 64² 再降 9x8，抗重采样抖动。 */
  static fingerprint(px: Uint8Array, w: number, h: number): number[] {
    const mid = ModelColorMath.scaleRgba(px, w, h, 64, 64);
    const small = ModelColorMath.scaleRgba(mid, 64, 64, 9, 8);
    const g = new Float32Array(72);
    for (let i = 0; i < 72; i++) {
      const o = i * 4;
      g[i] = 0.2126 * small[o] + 0.7152 * small[o + 1] + 0.0722 * small[o + 2];
    }
    let hi = 0;
    let lo = 0;
    for (let r = 0; r < 8; r++) {
      for (let cIdx = 0; cIdx < 8; cIdx++) {
        const bit = g[r * 9 + cIdx + 1] > g[r * 9 + cIdx] ? 1 : 0;
        const k = r * 8 + cIdx;
        if (k < 32) {
          lo |= bit << k;
        } else {
          hi |= bit << (k - 32);
        }
      }
    }
    const out: number[] = [hi >>> 0, lo >>> 0];
    return out;
  }

  static hamming(a: number[], b: number[]): number {
    return McPool.popcount((a[0] ^ b[0]) >>> 0) + McPool.popcount((a[1] ^ b[1]) >>> 0);
  }

  /** fp 是否与 othersFlat（hi/lo 平铺）里任一张重复；未知哈希（全 0）永不判重。 */
  static isDuplicate(fp: number[], othersFlat: number[]): boolean {
    if (fp[0] === 0 && fp[1] === 0) {
      return false;
    }
    for (let i = 0; i + 1 < othersFlat.length; i += 2) {
      const ohi = othersFlat[i];
      const olo = othersFlat[i + 1];
      if (ohi === 0 && olo === 0) {
        continue;
      }
      const d = McPool.popcount((fp[0] ^ ohi) >>> 0) + McPool.popcount((fp[1] ^ olo) >>> 0);
      if (d <= McPool.DUP_DISTANCE) {
        return true;
      }
    }
    return false;
  }

  /**
   * 淘汰方案：从 n 张里挑 need 张「最冗余」的，返回下标（升序）。
   * 判据 = 与池内其它参考的最小哈希距离，越小越像别人、信息量越低，先淘汰；
   * 同分按加入顺序（FIFO）先走；单张不参与淘汰——宁可拒绝新增，也不剩 0 张参考。
   */
  static evictPlan(fps: number[], n: number, need: number): number[] {
    const victims: number[] = [];
    if (need <= 0 || n <= 1) {
      return victims;
    }
    const alive: boolean[] = new Array(n).fill(true);
    const take = Math.min(need, n - 1);
    for (let round = 0; round < take; round++) {
      let best = -1;
      let bestScore = Number.MAX_VALUE;
      for (let i = 0; i < n; i++) {
        if (!alive[i]) {
          continue;
        }
        const hi = fps[i * 2];
        const lo = fps[i * 2 + 1];
        if (hi === 0 && lo === 0) {
          // 未知哈希：没有相似度证据，按兜底分参与比较（FIFO）
          if (bestScore > McPool.UNKNOWN_SCORE) {
            bestScore = McPool.UNKNOWN_SCORE;
            best = i;
          }
          continue;
        }
        let minD = 65;
        for (let j = 0; j < n; j++) {
          if (j === i || !alive[j]) {
            continue;
          }
          const ohi = fps[j * 2];
          const olo = fps[j * 2 + 1];
          if (ohi === 0 && olo === 0) {
            continue;
          }
          const d = McPool.popcount((hi ^ ohi) >>> 0) + McPool.popcount((lo ^ olo) >>> 0);
          if (d < minD) {
            minD = d;
          }
        }
        if (minD < bestScore) {
          bestScore = minD;
          best = i;
        }
      }
      if (best < 0) {
        break;
      }
      victims.push(best);
      alive[best] = false;
    }
    victims.sort((a: number, b: number): number => a - b);
    return victims;
  }

  /** 32 位 SWAR popcount（各步结果均精确可表示，乘积 < 2^32）。 */
  private static popcount(v: number): number {
    let x = v;
    x = x - ((x >>> 1) & 0x55555555);
    x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
    x = (x + (x >>> 4)) & 0x0F0F0F0F;
    return (x * 0x01010101) >>> 24;
  }
}
