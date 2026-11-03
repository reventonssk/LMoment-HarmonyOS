/**
 * 导出后台保障：DATA_TRANSFER 长时任务防止切后台/锁屏时进程冻结，
 * downloadTemplate 进度条通知实时反馈导出进度，完成/失败以文本通知收口。
 * 通知未授权或长时任务申请失败时静默降级，不影响导出主流程。
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xF100;
const TAG = 'leicamoments';
const NOTIFY_ID = 1001;
const MIN_INTERVAL_MS = 600;

export class ExportNotify {
  private static running: boolean = false;
  private static lastTs: number = 0;
  private static lastPct: number = -1;
  private static notifyAsked: boolean = false;

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

  /** 导出开始：启动长时任务 + 发布 0% 进度通知。 */
  static async begin(ctx: common.Context): Promise<void> {
    ExportNotify.prepare();
    ExportNotify.running = true;
    ExportNotify.lastTs = 0;
    ExportNotify.lastPct = -1;
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

  /** 兜底清理（Ability 销毁）：停长时任务并撤下进度通知。 */
  static cleanup(ctx: common.Context): void {
    backgroundTaskManager.stopBackgroundRunning(ctx).catch(() => {
    });
    notificationManager.cancel(NOTIFY_ID).catch(() => {
    });
  }

  private static publishProgress(pct: number, label: string): void {
    const data: Record<string, Object> = {
      'title': 'LMoment 导出',
      'fileName': label,
      'progressValue': pct
    };
    const req: notificationManager.NotificationRequest = {
      id: NOTIFY_ID,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'LMoment 导出',
          text: label,
          additionalText: `${pct}%`
        }
      },
      template: {
        name: 'downloadTemplate',
        data: data
      }
    };
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
