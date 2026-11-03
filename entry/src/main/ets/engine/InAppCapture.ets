/**
 * 应用内拍摄能力探测（Batch E+ 前置）。
 * auto 模式回落链：应用内 DNG 直拍 → YUV 直拍 → cameraPicker（系统相机）。
 * 本模块只做「设备是否会走应用内直拍」的能力判定与缓存，不代替自定义预览 UI（后续批次）。
 */

import { camera } from '@kit.CameraKit';
import { abilityAccessCtrl, Permissions, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 设备拍摄能力快照。 */
export class CaptureCapability {
  readonly hasCamera: boolean;
  readonly dng: boolean;
  readonly yuv: boolean;

  constructor(hasCamera: boolean, dng: boolean, yuv: boolean) {
    this.hasCamera = hasCamera;
    this.dng = dng;
    this.yuv = yuv;
  }

  /** 是否具备应用内直拍条件（DNG 或 YUV 任一可用）。 */
  get inAppCapable(): boolean {
    return this.hasCamera && (this.dng || this.yuv);
  }

  /** 回落链的目标档位描述（供设置项显示）。 */
  get fallbackLabel(): string {
    if (!this.hasCamera) {
      return '无相机 → 系统相机';
    }
    if (this.dng) {
      return '应用内 RAW 直拍可用';
    }
    // 实测多数机型（如 nova 14 Pro）只向第三方开放 JPEG 拍摄档，无 DNG 档
    return '本机未开放 RAW 拍摄档 → 系统相机';
  }
}

export class InAppCapture {
  private static cached: CaptureCapability | undefined = undefined;

  /** 探测相机能力（同步；结果缓存，避免重复打开相机服务）。 */
  static probe(context: common.Context): CaptureCapability {
    const hit = InAppCapture.cached;
    if (hit !== undefined) {
      return hit;
    }
    let has = false;
    let dng = false;
    let yuv = false;
    try {
      const mgr = camera.getCameraManager(context);
      const cams = mgr.getSupportedCameras();
      if (cams !== undefined && cams.length > 0) {
        has = true;
        for (let i = 0; i < cams.length; i++) {
          try {
            const modes = mgr.getSupportedSceneModes(cams[i]);
            if (modes === undefined || modes.indexOf(camera.SceneMode.NORMAL_PHOTO) < 0) {
              hilog.info(0x0D00, 'InAppCapture',
                'cam[%{public}d] no NORMAL_PHOTO mode', i);
              continue;
            }
            const cap = mgr.getSupportedOutputCapability(cams[i], camera.SceneMode.NORMAL_PHOTO);
            if (cap === undefined) {
              hilog.info(0x0D00, 'InAppCapture',
                'cam[%{public}d] no output capability', i);
              continue;
            }
            const photo = cap.photoProfiles;
            const fmts: string[] = [];
            if (photo !== undefined) {
              for (let j = 0; j < photo.length; j++) {
                fmts.push(`${photo[j].format}x${photo[j].size.width}x${photo[j].size.height}`);
                if (photo[j].format === camera.CameraFormat.CAMERA_FORMAT_DNG) {
                  dng = true;
                }
              }
            }
            hilog.info(0x0D00, 'InAppCapture',
              'cam[%{public}d] pos=%{public}d photoProfiles=%{public}s',
              i, cams[i].cameraPosition, fmts.join(','));
            const prev = cap.previewProfiles;
            if (prev !== undefined) {
              for (let j = 0; j < prev.length; j++) {
                if (prev[j].format === camera.CameraFormat.CAMERA_FORMAT_YUV_420_SP) {
                  yuv = true;
                }
              }
            }
          } catch (e) {
          }
        }
      }
    } catch (e) {
      has = false;
    }
    const result = new CaptureCapability(has, dng, yuv);
    hilog.info(0x0D00, 'InAppCapture',
      'probe has=%{public}d dng=%{public}d yuv=%{public}d', has ? 1 : 0, dng ? 1 : 0, yuv ? 1 : 0);
    InAppCapture.cached = result;
    return result;
  }

  /** 清空探测缓存（切换设备/权限后重探）。 */
  static reset(): void {
    InAppCapture.cached = undefined;
  }

  /** 申请 CAMERA 权限，已授予时直接返回 true。 */
  static async ensurePermission(context: common.Context): Promise<boolean> {
    try {
      const at = abilityAccessCtrl.createAtManager();
      const perms: Permissions[] = ['ohos.permission.CAMERA'];
      const res = await at.requestPermissionsFromUser(context, perms);
      return res.authResults.length > 0 && res.authResults[0] === 0;
    } catch (e) {
      return false;
    }
  }
}