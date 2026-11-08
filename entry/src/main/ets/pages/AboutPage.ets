/**
 * 关于页：应用信息 + 目前已实现 + 原项目/本项目作者与链接 + 鸣谢。
 */

/** 原项目开源地址（L-Moment Android 原版）。 */
const ABOUT_ORIGIN_URL: string = 'https://github.com/a307608689-afk/L-Moment';
/** 本项目开源地址（HarmonyOS ArkTS 重写版）。 */
const ABOUT_REPO_URL: string = 'https://github.com/reventonssk/LMoment-HarmonyOS';

@Entry
@Component
struct AboutPage {
  /** 主页全屏沉浸布局广播的状态栏高度（vp），标题栏避让用。 */
  @State topInset: number = 0;

  aboutToAppear(): void {
    const inset = AppStorage.get<number>('lmTopInset');
    this.topInset = inset !== undefined ? inset : 0;
  }

  @Builder
  private repoRow(title: string, author: string, url: string, hint: string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#EDEDED')
      Text('作者：' + author)
        .fontSize(13)
        .fontColor('#E8B84B')
      Text(url)
        .fontSize(12)
        .fontColor('#B9B9BD')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (hint !== '') {
        Text(hint)
          .fontSize(11)
          .fontColor('#8A8A8A')
          .lineHeight(16)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text('关于')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2E6C9')
        Row() {
          Text('返回')
            .fontSize(14)
            .fontColor('#E8B84B')
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
          Blank()
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .width('100%')
      .height(52)

      Scroll() {
        Column() {
          Stack() {
            Image($r('app.media.background'))
              .width('100%')
              .height('100%')
            Image($r('app.media.foreground'))
              .width('100%')
              .height('100%')
          }
          .width(96)
          .height(96)
          .borderRadius(24)
          .clip(true)
          .margin({ top: 18 })

          Text('L-Moment')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F2E6C9')
            .margin({ top: 14 })
          Text('for HarmonyOS · 1.5.0（对齐原版 1.5.0）')
            .fontSize(12)
            .fontColor('#8A8A8A')
            .margin({ top: 4 })
          Text('离线色彩风格引擎 · 徕卡风格滤镜\n全部处理本地完成，不上传任何照片数据')
            .fontSize(13)
            .fontColor('#B9B9BD')
            .textAlign(TextAlign.Center)
            .lineHeight(20)
            .margin({ top: 10 })

          Column({ space: 8 }) {
            Text('目前已实现')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#EDEDED')
            Text('风格滤镜 · 八档调整（含柔光）\n'
              + '拍照 · 换图 · RAW 导入（DNG）\n'
              + 'HDR · 超分 · 完美档管线\n'
              + '我的色彩 · 模型增强 · 版本历史\n'
              + 'EXIF 迁移 · 后台导出 · 通知栏取消导出 · 全像素导出\n'
              + '徕卡徽章（暂不可用：图库不显示 LEICA 角标，已停用写入）')
              .fontSize(12)
              .fontColor('#B9B9BD')
              .textAlign(TextAlign.Center)
              .lineHeight(19)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 16, right: 16, top: 14, bottom: 16 })
          .backgroundColor('#16161A')
          .borderRadius(14)
          .margin({ top: 24 })

          Column() {
            this.repoRow('原项目', 'a307608689-afk', ABOUT_ORIGIN_URL,
              '徕卡风格滤镜 Android 原版 · MIT License')
            Divider()
              .strokeWidth(1)
              .color('#1C1C20')
              .margin({ left: 16, right: 16 })
            this.repoRow('本项目', 'reventonssk', ABOUT_REPO_URL,
              'HarmonyOS (ArkTS) 完全重写版')
          }
          .width('100%')
          .backgroundColor('#16161A')
          .borderRadius(14)
          .margin({ top: 14 })

          Column() {
            Text('鸣谢')
              .fontSize(12)
              .fontColor('#8A8A8A')
            Text('移植自 a307608689-afk/L-Moment，感谢原作者的开源贡献。\n'
              + '本项目基于 MIT License 二次开发，原版权声明随源码保留。')
              .fontSize(12)
              .fontColor('#8A8A8A')
              .lineHeight(19)
              .margin({ top: 6 })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: 6, right: 6 })
          .margin({ top: 18, bottom: 24 })
        }
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .padding({ left: 14, right: 14 })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset })
    .backgroundColor('#0E0E10')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
