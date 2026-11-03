/**
 * M7.1 候选生成（Batch H，移植自 StyleCandidates.kt / 22_m7_candidates.py 同口径）：
 * 在逐图风格指纹 e_i 上做列 z-score 白化、k-medoids（最远点初始化 + PAM swap）
 * 与轮廓门限，挑出供用户挑选的候选。
 *
 * 候选 0 = 稳健中心（距全集中位最近的样本）；候选 1.. = 各簇 medoid
 * （按与中心距离排序、去重、上限 4 个）。轮廓系数 < 0.25 → 判参考集一致，单候选。
 * e 为 row-major（n 行 d 列）。纯数组运算，无 UI / SDK 依赖。
 */

/** 一个候选：index = 代表样本行号；members = 聚合 e_r 用的簇成员行号。 */
export class StylePick {
  readonly index: number;
  readonly members: number[];

  constructor(index: number, members: number[]) {
    this.index = index;
    this.members = members;
  }
}

/** 候选结果：single=true 表示参考集一致，只出候选 0。 */
export class StyleCandidateResult {
  readonly single: boolean;
  readonly k: number;
  readonly sil: number;
  readonly picks: StylePick[];

  constructor(single: boolean, k: number, sil: number, picks: StylePick[]) {
    this.single = single;
    this.k = k;
    this.sil = sil;
    this.picks = picks;
  }
}

/** whiten 输出：白化后的 z 与保留维数。 */
class WhitenOut {
  readonly z: Float32Array;
  readonly d: number;

  constructor(z: Float32Array, d: number) {
    this.z = z;
    this.d = d;
  }
}

export class StyleCandidates {
  private static readonly SIL_GATE: number = 0.25;
  private static readonly DEFAULT_MAX_K: number = 3;
  private static readonly MAX_PICKS: number = 4;

  /** 列 z-score 白化；std<1e-3 的维度无信号，直接丢弃。 */
  static whiten(e: Float32Array, n: number, d: number): WhitenOut {
    const mu = new Float32Array(d);
    const sd = new Float32Array(d);
    for (let k = 0; k < d; k++) {
      let m = 0;
      for (let i = 0; i < n; i++) {
        m += e[i * d + k];
      }
      m /= n;
      let s2 = 0;
      for (let i = 0; i < n; i++) {
        const v = e[i * d + k] - m;
        s2 += v * v;
      }
      sd[k] = Math.sqrt(s2 / n);
      mu[k] = m;
    }
    let nk = 0;
    for (let k = 0; k < d; k++) {
      if (sd[k] > 1e-3) {
        nk++;
      }
    }
    const z = new Float32Array(n * nk);
    for (let i = 0; i < n; i++) {
      let o = i * nk;
      for (let k = 0; k < d; k++) {
        if (sd[k] > 1e-3) {
          z[o++] = (e[i * d + k] - mu[k]) / sd[k];
        }
      }
    }
    return new WhitenOut(z, nk);
  }

  private static distMatrix(z: Float32Array, n: number, d: number): Float32Array {
    const dm = new Float32Array(n * n);
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        let s = 0;
        for (let k = 0; k < d; k++) {
          const v = z[i * d + k] - z[j * d + k];
          s += v * v;
        }
        const dd = Math.sqrt(s);
        dm[i * n + j] = dd;
        dm[j * n + i] = dd;
      }
    }
    return dm;
  }

  private static assignTo(dm: Float32Array, n: number, med: number[]): number[] {
    const a: number[] = new Array(n).fill(0);
    for (let i = 0; i < n; i++) {
      let bi = 0;
      let bd = Number.MAX_VALUE;
      for (let j = 0; j < med.length; j++) {
        const dd = dm[i * n + med[j]];
        if (dd < bd) {
          bd = dd;
          bi = j;
        }
      }
      a[i] = bi;
    }
    return a;
  }

  /** k-medoids：最远点初始化 + PAM 式 assign/swap，最多 20 轮（Lehmer 定种子，Kotlin seed=7 同意图）。 */
  private static rngSeed: number = 0;

  private static nextRand(n: number): number {
    // 48271 * seed < 2^50，双精度安全；模 2147483647 的 Lehmer 生成器
    StyleCandidates.rngSeed = (StyleCandidates.rngSeed * 48271) % 2147483647;
    return Math.floor(StyleCandidates.rngSeed % n);
  }

  static medoids(dm: Float32Array, n: number, k: number): number[] {
    const kk = Math.min(k, n);
    StyleCandidates.rngSeed = 7 % 2147483647;
    const med: number[] = new Array(kk).fill(0);
    med[0] = StyleCandidates.nextRand(n);
    for (let m = 1; m < kk; m++) {
      let best = -1;
      let bestD = -1;
      for (let i = 0; i < n; i++) {
        let dmin = Number.MAX_VALUE;
        for (let j = 0; j < m; j++) {
          const v = dm[i * n + med[j]];
          if (v < dmin) {
            dmin = v;
          }
        }
        if (dmin > bestD) {
          bestD = dmin;
          best = i;
        }
      }
      med[m] = best;
    }
    const assign: number[] = new Array(n).fill(0);
    let changed = true;
    let iter = 0;
    while (changed && iter++ < 20) {
      changed = false;
      for (let i = 0; i < n; i++) {
        let bi = 0;
        let bd = Number.MAX_VALUE;
        for (let j = 0; j < kk; j++) {
          const dd = dm[i * n + med[j]];
          if (dd < bd) {
            bd = dd;
            bi = j;
          }
        }
        if (assign[i] !== bi) {
          assign[i] = bi;
          changed = true;
        }
      }
      for (let j = 0; j < kk; j++) {
        let bi = med[j];
        let bsum = Number.MAX_VALUE;
        for (let cand = 0; cand < n; cand++) {
          let s = 0;
          for (let i = 0; i < n; i++) {
            if (assign[i] === j) {
              s += dm[cand * n + i];
            }
          }
          if (s < bsum) {
            bsum = s;
            bi = cand;
          }
        }
        if (bi !== med[j]) {
          med[j] = bi;
          changed = true;
        }
      }
    }
    return med;
  }

  /** 全体点的平均轮廓系数。 */
  static silhouette(dm: Float32Array, n: number, assign: number[]): number {
    let k = 0;
    for (let i = 0; i < n; i++) {
      if (assign[i] > k) {
        k = assign[i];
      }
    }
    if (k < 1) {
      return 0;
    }
    const size: number[] = new Array(k + 1).fill(0);
    for (let i = 0; i < n; i++) {
      size[assign[i]]++;
    }
    let total = 0;
    let counted = 0;
    const acc: number[] = new Array(k + 1).fill(0);
    const cnt: number[] = new Array(k + 1).fill(0);
    for (let i = 0; i < n; i++) {
      const ci = assign[i];
      acc.fill(0);
      cnt.fill(0);
      for (let j = 0; j < n; j++) {
        if (j === i) {
          continue;
        }
        const cj = assign[j];
        acc[cj] += dm[i * n + j];
        cnt[cj]++;
      }
      const a = size[ci] > 1 ? acc[ci] / cnt[ci] : 0;
      let b = Number.MAX_VALUE;
      for (let c = 0; c <= k; c++) {
        if (c !== ci && cnt[c] > 0) {
          const v = acc[c] / cnt[c];
          if (v < b) {
            b = v;
          }
        }
      }
      const m = Math.max(a, b);
      if (m > 0) {
        total += (b - a) / m;
        counted++;
      }
    }
    return counted > 0 ? total / counted : 0;
  }

  /** 稳健中心：距全集中位最近的样本（恒存在，抗离群）。 */
  static robustCenter(e: Float32Array, n: number, d: number): number {
    const med = new Float32Array(d);
    const col = new Float32Array(n);
    for (let k = 0; k < d; k++) {
      for (let i = 0; i < n; i++) {
        col[i] = e[i * d + k];
      }
      col.sort();
      med[k] = n % 2 === 1 ? col[Math.floor(n / 2)] : 0.5 * (col[n / 2 - 1] + col[n / 2]);
    }
    let best = 0;
    let bestD = Number.MAX_VALUE;
    for (let i = 0; i < n; i++) {
      let s = 0;
      for (let k = 0; k < d; k++) {
        const v = e[i * d + k] - med[k];
        s += v * v;
      }
      if (s < bestD) {
        bestD = s;
        best = i;
      }
    }
    return best;
  }

  /**
   * 候选生成主入口（e row-major n 行 d 列）。
   * prune：可选剔除回调（ΔE00 上限裁剪）；传 null 不裁剪。
   */
  static candidates(e: Float32Array, n: number, d: number,
    prune: ((center: number, cand: number) => boolean) | null): StyleCandidateResult {
    const all: number[] = new Array(n).fill(0).map((_v: number, i: number) => i);
    if (n < 4) {
      return new StyleCandidateResult(true, 1, 0,
        [new StylePick(StyleCandidates.robustCenter(e, n, d), all)]);
    }
    const wz = StyleCandidates.whiten(e, n, d);
    if (wz.d === 0) {
      return new StyleCandidateResult(true, 1, 0,
        [new StylePick(StyleCandidates.robustCenter(e, n, d), all)]);
    }
    const dm = StyleCandidates.distMatrix(wz.z, n, wz.d);

    let bestK = 1;
    let bestSil = -1;
    let bestMed: number[] = [];
    let bestAssign: number[] = [];
    const km = Math.min(StyleCandidates.DEFAULT_MAX_K, n - 1);
    if (km >= 2) {
      for (let k = 2; k <= km; k++) {
        const med = StyleCandidates.medoids(dm, n, k);
        const assign = StyleCandidates.assignTo(dm, n, med);
        const sil = StyleCandidates.silhouette(dm, n, assign);
        if (sil > bestSil) {
          bestSil = sil;
          bestK = k;
          bestMed = med;
          bestAssign = assign;
        }
      }
    }

    const center = StyleCandidates.robustCenter(e, n, d);
    if (bestSil < StyleCandidates.SIL_GATE || bestMed.length === 0) {
      return new StyleCandidateResult(true, 1, Math.max(bestSil, 0),
        [new StylePick(center, all)]);
    }

    const picks: StylePick[] = [];
    picks.push(new StylePick(center, StyleCandidates.membersOf(bestAssign, bestAssign[center])));
    // medoid 按与中心距离排序
    const order = bestMed.slice();
    order.sort((a: number, b: number) => {
      const da = StyleCandidates.distTo(e, d, a, center);
      const db = StyleCandidates.distTo(e, d, b, center);
      return da - db;
    });
    for (let oi = 0; oi < order.length; oi++) {
      const med = order[oi];
      if (picks.length >= StyleCandidates.MAX_PICKS) {
        break;
      }
      let dup = false;
      for (let pi = 0; pi < picks.length; pi++) {
        if (picks[pi].index === med) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      if (prune !== null && prune(center, med)) {
        continue;
      }
      let medPos = 0;
      for (let j = 0; j < bestMed.length; j++) {
        if (bestMed[j] === med) {
          medPos = j;
          break;
        }
      }
      picks.push(new StylePick(med, StyleCandidates.membersOf(bestAssign, medPos)));
    }
    return new StyleCandidateResult(false, bestK, bestSil, picks);
  }

  private static distTo(e: Float32Array, d: number, a: number, b: number): number {
    let s = 0;
    for (let k = 0; k < d; k++) {
      const v = e[a * d + k] - e[b * d + k];
      s += v * v;
    }
    return s;
  }

  /** 簇标签 medPos → 成员行号列表。 */
  private static membersOf(assign: number[], medPos: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < assign.length; i++) {
      if (assign[i] === medPos) {
        out.push(i);
      }
    }
    return out;
  }
}
