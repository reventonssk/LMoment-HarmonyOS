/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';
import { ExportNotify } from '../engine/ExportNotify';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 供 ExportNotify 等模块取 UIAbilityContext（通知授权等 API 需该类型）
    AppStorage.setOrCreate('abilityCtx', this.context);
    try {
      // 强制深色模式：应用整体深色风格，系统组件（ActionSheet/AlertDialog/picker）
      // 需同步深色背景浅色字体，与页面自定义深色样式一致
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 通知栏"停止"按钮：wantAgent.START_ABILITY 携带 stopExport 参数回到本 Ability
    const p = want.parameters;
    if (p !== undefined) {
      const v = p['stopExport'];
      if (v === 'true' || v === true) {
        hilog.info(DOMAIN, 'testTag', 'stop export requested via notification');
        ExportNotify.requestStop();
      }
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    // 兜底：销毁时停掉导出长时任务并撤下进度通知
    ExportNotify.cleanup(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      try {
        const win = windowStage.getMainWindowSync();
        // 方向策略：手机锁竖屏（UI 为竖屏手机式布局）；平板/PC 解锁跟随系统旋转
        // （module.json5 静态 portrait 为兜底，运行时按设备类型放开）
        const dt = deviceInfo.deviceType;
        if (dt === 'tablet' || dt === '2in1') {
          win.setPreferredOrientation(window.Orientation.AUTO_ROTATION)
            .catch((e: Object) => {
              hilog.error(DOMAIN, 'testTag', 'unlock orientation failed: %{public}s', JSON.stringify(e));
            });
        }
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: '#F2E6C9',
          navigationBarContentColor: '#F2E6C9'
        })
          .catch((e: Object) => {
            hilog.error(DOMAIN, 'testTag', 'immersive setup failed: %{public}s', JSON.stringify(e));
          });
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'getMainWindowSync failed: %{public}s', JSON.stringify(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}