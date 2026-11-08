/**
 * 导出后台保障：DATA_TRANSFER 长时任务防止切后台/锁屏时进程冻结，
 * downloadTemplate 进度条通知实时反馈导出进度（附"停止"按钮，经 wantAgent
 * 携带 stopExport 参数回到 EntryAbility.onNewWant 置取消标志），
 * 完成/失败/取消以文本通知收口。通知未授权或长时任务申请失败时静默降级，
 * 不影响导出主流程。
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xF100;
const TAG = 'leicamoments';
const NOTIFY_ID = 1001;
const MIN_INTERVAL_MS = 600;

/** 导出被用户取消（通知栏"停止"按钮），doExport 各阶段边界抛出统一收口。 */
export class ExportCancelledError extends Error {
  constructor() {
    super('导出已取消');
  }
}

export class ExportNotify {
  private static running: boolean = false;
  private static lastTs: number = 0;
  private static lastPct: number = -1;
  private static notifyAsked: boolean = false;
  private static stopFlag: boolean = false;
  private static stopAgent: WantAgent | undefined = undefined;

  /** 通知栏"停止"按钮经 onNewWant 调用：置位取消标志。 */
  static requestStop(): void {
    ExportNotify.stopFlag = true;
    hilog.info(DOMAIN, TAG, 'export stop requested');
  }

  static isStopRequested(): boolean {
    return ExportNotify.stopFlag;
  }

  static resetStop(): void {
    ExportNotify.stopFlag = false;
  }

  /** 首次导出前请求通知授权（系统对话框仅弹一次，不阻塞导出）。 */
  static prepare(): void {
    if (ExportNotify.notifyAsked) {
      return;
    }
    ExportNotify.notifyAsked = true;
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityCtx');
    if (ctx === undefined) {
      return;
    }
    notificationManager.requestEnableNotification(ctx)
      .then(() => {
        hilog.info(DOMAIN, TAG, 'notification enabled');
      })
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'notification enable rejected: %{public}d', err.code);
      });
  }

  /** 导出开始：启动长时任务 + 发布 0% 进度通知（含"停止"按钮）。 */
  static async begin(ctx: common.Context): Promise<void> {
    ExportNotify.prepare();
    ExportNotify.running = true;
    ExportNotify.lastTs = 0;
    ExportNotify.lastPct = -1;
    ExportNotify.resetStop();
    try {
      const stopInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'com.leicamoments.app',
            abilityName: 'EntryAbility',
            parameters: { 'stopExport': 'true' }
          }
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      ExportNotify.stopAgent = await wantAgent.getWantAgent(stopInfo);
    } catch (err) {
      // 停止按钮不可用时仍正常导出，仅无按钮
      ExportNotify.stopAgent = undefined;
      hilog.warn(DOMAIN, TAG, 'build stop wantAgent failed: %{public}s', JSON.stringify(err));
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'com.leicamoments.app',
            abilityName: 'EntryAbility'
          }
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      hilog.info(DOMAIN, TAG, 'export background task started');
    } catch (err) {
      // 长时任务申请失败（校验不过等）静默降级：前台导出不受影响
      hilog.warn(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
    ExportNotify.publishProgress(0, '正在导出');
  }

  /** 阶段进度：节流后更新进度条通知。 */
  static progress(pct: number, label: string): void {
    if (!ExportNotify.running) {
      return;
    }
    const p = Math.max(0, Math.min(100, Math.round(pct)));
    const now = Date.now();
    if (p !== 0 && p !== 100 && now - ExportNotify.lastTs < MIN_INTERVAL_MS &&
      p - ExportNotify.lastPct < 3) {
      return;
    }
    ExportNotify.publishProgress(p, label);
  }

  /** 导出收口：停长时任务，进度通知替换为结果文本通知。 */
  static async finish(ctx: common.Context, ok: boolean, msg: string): Promise<void> {
    ExportNotify.running = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
    const title = ok ? '导出完成' : '导出失败';
    ExportNotify.publishText(title, msg);
  }

  /** 取消收口：停长时任务，进度通知替换为取消文本通知。 */
  static async finishCancelled(ctx: common.Context): Promise<void> {
    ExportNotify.running = false;
    ExportNotify.resetStop();
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
    ExportNotify.publishText('导出已取消', '本次导出已停止');
  }

  /** 兜底清理（Ability 销毁）：停长时任务并撤下进度通知。 */
  static cleanup(ctx: common.Context): void {
    backgroundTaskManager.stopBackgroundRunning(ctx).catch(() => {
    });
    notificationManager.cancel(NOTIFY_ID).catch(() => {
    });
  }

  // 普通文本通知 + actionButtons（downloadTemplate 模板通知不渲染自定义按钮，
  // nova 14 Pro 实测面板无"停止"节点；普通通知附按钮 + 文本承载进度百分比）。
  // isAlertOnce: 进度更新只首次发布时提醒，后续同 id 更新降为 LEVEL_LOW，
  // 不再触发震动/响铃（修复导出期间每次进度更新都震动的问题）。
  private static publishProgress(pct: number, label: string): void {
    const req: notificationManager.NotificationRequest = {
      id: NOTIFY_ID,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      isAlertOnce: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'LMoment 导出',
          text: label,
          additionalText: `${pct}%`
        }
      }
    };
    if (ExportNotify.stopAgent !== undefined) {
      req.actionButtons = [
        {
          title: '停止',
          wantAgent: ExportNotify.stopAgent
        }
      ];
    }
    notificationManager.publish(req)
      .then(() => {
        ExportNotify.lastTs = Date.now();
        ExportNotify.lastPct = pct;
      })
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'publish progress failed: %{public}d', err.code);
      });
  }

  private static publishText(title: string, msg: string): void {
    const req: notificationManager.NotificationRequest = {
      id: NOTIFY_ID,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: msg,
          additionalText: ''
        }
      }
    };
    notificationManager.publish(req)
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'publish text failed: %{public}d', err.code);
      });
  }
}
