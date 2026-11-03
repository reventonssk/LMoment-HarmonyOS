/**
 * 「我的色彩」备份 / 导入（Batch F4）。
 *
 * 备份内容：本地全部自定义色彩（`Index.currentCustoms`：name + 分享码 code + crc）。
 * 文件为普通 UTF-8 文本（扩展名 `.lmc`），首行版本标记，其后与本地存储同构的 TSV：
 * ```
 * #LMOMENT_COLORS v1
 * <crc>\t<name>\t<code>
 * ```
 * 之所以用 TSV 而非原版 zip（manifest + custom_styles.json + luts/…）：本移植的自定义
 * 色彩以分享码承载完整 LUT 负载，无需外挂 bin；且避免 ArkTS 严格模式下 JSON.parse 的
 * 类型断言。解析对无首行标记的裸 TSV 亦兼容。
 *
 * 导入语义（对齐原版口径）：**只增不删**——已存在（同名或同 crc）的一律跳过。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

/** 备份条目（与 Index.CustomEntry 同构，跨模块传递用显式类型）。 */
export class ColorBackupItem {
  readonly name: string;
  readonly code: string;
  readonly crc: number;

  constructor(name: string, code: string, crc: number) {
    this.name = name;
    this.code = code;
    this.crc = crc;
  }
}

/** 解析结果：有效条目 + 被跳过的无效行数。 */
export class ColorBackupResult {
  readonly items: ColorBackupItem[];
  readonly skipped: number;

  constructor(items: ColorBackupItem[], skipped: number) {
    this.items = items;
    this.skipped = skipped;
  }
}

function pad2(n: number): string {
  return n < 10 ? ('0' + n) : ('' + n);
}

export class ColorBackup {
  static readonly HEADER: string = '#LMOMENT_COLORS v1';

  /** 默认文件名：LeicaColors_yyyyMMdd_HHmm.lmc */
  static defaultFileName(): string {
    const d = new Date();
    return 'LeicaColors_' + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) +
      '_' + pad2(d.getHours()) + pad2(d.getMinutes()) + '.lmc';
  }

  /** 条目序列化为备份文本（名称去制表/换行并限长）。 */
  static toText(items: ColorBackupItem[]): string {
    const lines: string[] = [ColorBackup.HEADER];
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      let name = it.name.replace(/\t/g, ' ').replace(/\n/g, ' ').replace(/\r/g, ' ').trim();
      if (name.length > 24) {
        name = name.substring(0, 24);
      }
      lines.push(it.crc + '\t' + name + '\t' + it.code);
    }
    return lines.join('\n') + '\n';
  }

  /** 解析备份文本；容错：空行/注释行跳过，字段不足或非法计数为 skipped。 */
  static parse(text: string): ColorBackupResult {
    const items: ColorBackupItem[] = [];
    let skipped = 0;
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line === '' || line.startsWith('#')) {
        continue;
      }
      const parts = line.split('\t');
      if (parts.length < 3) {
        skipped++;
        continue;
      }
      const crc = parseInt(parts[0]);
      const name = parts[1].trim();
      const code = parts.slice(2).join('\t').trim();
      if (isNaN(crc) || name === '' || code === '') {
        skipped++;
        continue;
      }
      items.push(new ColorBackupItem(name, code, crc));
    }
    return new ColorBackupResult(items, skipped);
  }

  /** 通过 DocumentViewPicker 保存备份；取消返回 false。 */
  static async save(context: common.Context, text: string, fileName: string): Promise<boolean> {
    try {
      const doc = new picker.DocumentViewPicker(context);
      const opts: picker.DocumentSaveOptions = { newFileNames: [fileName] };
      const uris = await doc.save(opts);
      if (uris === undefined || uris.length === 0) {
        return false;
      }
      const file = fs.openSync(uris[0],
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 通过 DocumentViewPicker 选择备份文件并读出文本；取消/失败返回 ''。 */
  static async pick(context: common.Context): Promise<string> {
    try {
      const doc = new picker.DocumentViewPicker(context);
      const opts: picker.DocumentSelectOptions = { maxSelectNumber: 1 };
      const uris = await doc.select(opts);
      if (uris === undefined || uris.length === 0) {
        return '';
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      try {
        const size = fs.statSync(file.fd).size;
        if (size <= 0) {
          return '';
        }
        const ab = new ArrayBuffer(size);
        fs.readSync(file.fd, ab);
        const decoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(new Uint8Array(ab));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return '';
    }
  }
}