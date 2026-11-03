/**
 * 应用内 RAW 直拍会话控制（Batch H+）。
 *
 * 相机管线：后置摄像头 NORMAL_PHOTO 会话，preview 输出绑 XComponent surface，
 * photo 输出取 CAMERA_FORMAT_DNG 档（无 DNG 档时 open 返回 undefined，调用方降级）。
 * 拍摄经 photoOutput.capture 触发，photoAvailable 回调里取 main 组件字节：
 * 按魔数判定 DNG（TIFF II/MM）或 JPEG，拷贝后立刻 release（不 release 会卡后续拍摄）。
 * 8 秒未回报视为失败；release 幂等，浮层关闭/页面销毁时调用。
 * 全异步链路，不在主线程做像素数学。
 */

import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 一次拍摄结果：完整文件字节（DNG 或 JPEG，按魔数判定）。 */
export class CaptureShot {
  readonly bytes: Uint8Array;
  readonly isDng: boolean;

  constructor(bytes: Uint8Array, isDng: boolean) {
    this.bytes = bytes;
    this.isDng = isDng;
  }
}

export class AppCamera {
  private static readonly CAPTURE_TIMEOUT_MS: number = 8000;

  private mgr: camera.CameraManager | undefined;
  private input: camera.CameraInput | undefined;
  private preview: camera.PreviewOutput | undefined;
  private photo: camera.PhotoOutput | undefined;
  private session: camera.CaptureSession | undefined;
  private pending: ((shot: CaptureShot | undefined) => void) | undefined;
  private pendingTimer: number = -1;
  private released: boolean = false;

  /**
   * 打开后置相机会话（DNG 拍照档）。
   * 设备无相机 / 无 NORMAL_PHOTO / 无 DNG photoProfile / 会话建立失败 → undefined（调用方降级系统相机）。
   */
  static async open(context: common.Context, surfaceId: string): Promise<AppCamera | undefined> {
    let mgr: camera.CameraManager;
    try {
      mgr = camera.getCameraManager(context);
    } catch (e) {
      return undefined;
    }
    let dev: camera.CameraDevice | undefined = undefined;
    const cams = mgr.getSupportedCameras();
    if (cams === undefined || cams.length === 0) {
      return undefined;
    }
    for (let i = 0; i < cams.length; i++) {
      if (cams[i].cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
        dev = cams[i];
        break;
      }
    }
    if (dev === undefined) {
      dev = cams[0];
    }
    let modes: camera.SceneMode[] = [];
    try {
      modes = mgr.getSupportedSceneModes(dev);
    } catch (e) {
      return undefined;
    }
    if (modes.indexOf(camera.SceneMode.NORMAL_PHOTO) < 0) {
      return undefined;
    }
    const cap = mgr.getSupportedOutputCapability(dev, camera.SceneMode.NORMAL_PHOTO);
    if (cap === undefined) {
      return undefined;
    }
    // DNG 拍照档：取最大分辨率
    let dngProf: camera.Profile | undefined = undefined;
    const photoProfiles = cap.photoProfiles;
    if (photoProfiles !== undefined) {
      for (let i = 0; i < photoProfiles.length; i++) {
        const p = photoProfiles[i];
        if (p.format !== camera.CameraFormat.CAMERA_FORMAT_DNG) {
          continue;
        }
        if (dngProf === undefined || p.size.width * p.size.height >
          dngProf.size.width * dngProf.size.height) {
          dngProf = p;
        }
      }
    }
    if (dngProf === undefined) {
      return undefined;
    }
    // 预览档：优先 YUV_420_SP 最大档
    let prevProf: camera.Profile | undefined = undefined;
    const prevProfiles = cap.previewProfiles;
    if (prevProfiles !== undefined) {
      for (let i = 0; i < prevProfiles.length; i++) {
        const p = prevProfiles[i];
        if (prevProf === undefined || p.size.width * p.size.height >
          prevProf.size.width * prevProf.size.height) {
          prevProf = p;
        }
      }
    }
    if (prevProf === undefined) {
      return undefined;
    }
    let input: camera.CameraInput;
    try {
      input = mgr.createCameraInput(dev);
      await input.open();
    } catch (e) {
      return undefined;
    }
    let preview: camera.PreviewOutput;
    let photo: camera.PhotoOutput;
    let session: camera.CaptureSession;
    try {
      preview = mgr.createPreviewOutput(prevProf, surfaceId);
      photo = mgr.createPhotoOutput(dngProf);
      session = mgr.createCaptureSession();
      session.beginConfig();
      session.addInput(input);
      session.addOutput(preview);
      session.addOutput(photo);
      await session.commitConfig();
      await session.start();
    } catch (e) {
      try {
        await input.close();
      } catch (e2) {
      }
      return undefined;
    }
    const cam = new AppCamera();
    cam.mgr = mgr;
    cam.input = input;
    cam.preview = preview;
    cam.photo = photo;
    cam.session = session;
    photo.on('photoAvailable', (err: BusinessError, ph: camera.Photo) => {
      cam.onPhoto(err, ph);
    });
    return cam;
  }

  /** 触发一次拍摄；会话未就绪/上次未完成/8 秒超时 → undefined。 */
  async capture(): Promise<CaptureShot | undefined> {
    if (this.released || this.session === undefined || this.photo === undefined) {
      return undefined;
    }
    if (this.pending !== undefined) {
      return undefined;
    }
    const photoOut = this.photo;
    return new Promise<CaptureShot | undefined>((resolve: (v: CaptureShot | undefined) => void) => {
      this.pending = resolve;
      this.pendingTimer = setTimeout(() => {
        const r = this.pending;
        this.pending = undefined;
        this.pendingTimer = -1;
        if (r !== undefined) {
          r(undefined);
        }
      }, AppCamera.CAPTURE_TIMEOUT_MS);
      photoOut.capture().catch((e: BusinessError) => {
        if (this.pendingTimer >= 0) {
          clearTimeout(this.pendingTimer);
          this.pendingTimer = -1;
        }
        const r = this.pending;
        this.pending = undefined;
        if (r !== undefined) {
          r(undefined);
        }
      });
    });
  }

  /** 释放全部相机资源（幂等；未决拍摄立即以 undefined 结清）。 */
  async release(): Promise<void> {
    if (this.released) {
      return;
    }
    this.released = true;
    if (this.pendingTimer >= 0) {
      clearTimeout(this.pendingTimer);
      this.pendingTimer = -1;
    }
    const r = this.pending;
    this.pending = undefined;
    if (r !== undefined) {
      r(undefined);
    }
    const session = this.session;
    const preview = this.preview;
    const photo = this.photo;
    const input = this.input;
    this.session = undefined;
    this.preview = undefined;
    this.photo = undefined;
    this.input = undefined;
    this.mgr = undefined;
    if (session !== undefined) {
      try {
        await session.stop();
      } catch (e) {
      }
      try {
        await session.release();
      } catch (e) {
      }
    }
    if (preview !== undefined) {
      try {
        await preview.release();
      } catch (e) {
      }
    }
    if (photo !== undefined) {
      try {
        await photo.release();
      } catch (e) {
      }
    }
    if (input !== undefined) {
      try {
        await input.close();
      } catch (e) {
      }
    }
  }

  private onPhoto(err: BusinessError, ph: camera.Photo): void {
    if (this.pendingTimer >= 0) {
      clearTimeout(this.pendingTimer);
      this.pendingTimer = -1;
    }
    const r = this.pending;
    this.pending = undefined;
    if (r === undefined) {
      ph.release().catch(() => {
      });
      return;
    }
    if (err) {
      ph.release().catch(() => {
      });
      r(undefined);
      return;
    }
    ph.main.getComponent(image.ComponentType.JPEG).then((comp: image.Component) => {
      // byteBuffer 在 release 后可能失效：先拷贝
      const bytes = new Uint8Array(comp.byteBuffer.byteLength);
      bytes.set(new Uint8Array(comp.byteBuffer));
      ph.release().catch(() => {
      });
      r(new CaptureShot(bytes, AppCamera.isDngBytes(bytes)));
    }).catch((e: BusinessError) => {
      ph.release().catch(() => {
      });
      r(undefined);
    });
  }

  /** TIFF 魔数判定 DNG（II*\0 / MM\0*）。 */
  private static isDngBytes(b: Uint8Array): boolean {
    if (b.length < 4) {
      return false;
    }
    const ii = b[0] === 0x49 && b[1] === 0x49 && b[2] === 0x2A && b[3] === 0x00;
    const mm = b[0] === 0x4D && b[1] === 0x4D && b[2] === 0x00 && b[3] === 0x2A;
    return ii || mm;
  }
}
