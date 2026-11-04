# L-Moment for HarmonyOS

离线色彩风格引擎 · 徕卡风格滤镜 —— HarmonyOS (ArkTS) 完全重写版，移植自 [a307608689-afk/L-Moment](https://github.com/a307608689-afk/L-Moment)。

全部处理本地完成，不上传任何照片数据。

## 功能

- 风格滤镜（L-Moment / 一瞬 M / ARRI / CCD / F 胶片等）· 八档调整（含柔光）
- 拍照 · 换图 · RAW 导入（DNG，EXIF 迁移）
- HDR 增益图合成 · 超分辨率（快 / 质两档）· M9 完美档管线
- 我的色彩 · 模型增强 · 版本历史（可回退）
- 徕卡徽章水印 · 后台导出 · 全像素导出
- 沉浸式玻璃 UI · 触摸光效（TouchGlow）

## 技术

- HarmonyOS NEXT · ArkTS / ArkUI
- MindSpore Lite 端侧推理（风格蒸馏 / 增强模型），全部离线运行
- TaskPool 异步解码与像素处理管线，主线程零阻塞
- 长时任务后台导出 + 系统通知

## 构建

1. 安装 DevEco Studio（HarmonyOS SDK 26.0.0 及以上）。
2. 克隆本仓库并用 DevEco Studio 打开工程根目录。
3. 配置签名：File > Project Structure > Signing Configs，勾选 Automatically generate signature。
4. Build > Build Hap(s)/APPs，或连接真机直接 Run。

## 致谢与许可

- 原项目：[a307608689-afk/L-Moment](https://github.com/a307608689-afk/L-Moment)（Android 原版，MIT License），感谢原作者的开源贡献。
- 本项目基于 MIT License 二次开发，原版权声明随源码保留，见 [LICENSE](LICENSE)。
