/**
 * 触摸光效容器：跟随触点的径向光斑 + 按压缩放反馈。
 * - 光斑层 HitTestMode.None 不拦截点击，onClick 留在内容组件上；
 * - 光斑尺寸由 onAreaChange 实测内容尺寸驱动（⚠️ 不可用 '100%'：
 *   自适应容器内百分比按父级约束解析，会把 Stack 撑成全屏、
 *   挤没 Column 里的兄弟节点）；
 * - Stack 按传入圆角裁剪（胶囊传大值如 999）；
 * - ⚠️ 安全组件（SaveButton 等）不可包裹：上层遮挡后其点击授权失效。
 */

function glowLenVp(v: Length): number {
  if (typeof v === 'number') {
    return v;
  }
  if (typeof v === 'string') {
    const f = parseFloat(v);
    return isNaN(f) ? 0 : f;
  }
  return 0;
}

@Component
export struct TouchGlow {
  /** 尾随闭包内容（按钮/文本）。 */
  @BuilderParam content: () => void;
  /** 光斑中心色（建议带 alpha）。 */
  @Prop glowCenter: string = 'rgba(232,184,75,0.35)';
  /** 光斑边缘色（一般同色 alpha=0）。 */
  @Prop glowEdge: string = 'rgba(232,184,75,0)';
  /** 光斑半径（vp）。 */
  @Prop glowRadiusVp: number = 70;
  /** 裁剪圆角（vp）；胶囊传大值如 999。 */
  @Prop cornerRadiusVp: number = 999;
  /** 按压缩放比（1 表示不缩放）。 */
  @Prop pressScale: number = 0.96;
  /** 内容水平留白（vp），给光斑呼吸空间。 */
  @Prop padH: number = 0;
  /** 内容垂直留白（vp）。 */
  @Prop padV: number = 0;
  @State private glowX: number = 0;
  @State private glowY: number = 0;
  @State private pressed: boolean = false;
  @State private boxW: number = 0;
  @State private boxH: number = 0;

  build() {
    Stack() {
      Column() {
        this.content()
      }
      .padding({ left: this.padH, right: this.padH, top: this.padV, bottom: this.padV })
      .onAreaChange((_o: Area, n: Area) => {
        const w = glowLenVp(n.width);
        const h = glowLenVp(n.height);
        if (w !== this.boxW || h !== this.boxH) {
          this.boxW = w;
          this.boxH = h;
        }
      })

      Column()
        .width(this.boxW)
        .height(this.boxH)
        .radialGradient({
          center: [this.glowX, this.glowY],
          radius: this.glowRadiusVp,
          colors: [[this.glowCenter, 0.0], [this.glowEdge, 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)
        .opacity(this.pressed ? 1 : 0)
        .animation({ duration: 140, curve: Curve.EaseOut })
    }
    .clip(true)
    .borderRadius(this.cornerRadiusVp)
    .scale({
      x: this.pressed ? this.pressScale : 1,
      y: this.pressed ? this.pressScale : 1
    })
    .animation({ duration: 140, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.glowX = event.touches[0].x;
        this.glowY = event.touches[0].y;
        this.pressed = true;
      } else if (event.type === TouchType.Move) {
        this.glowX = event.touches[0].x;
        this.glowY = event.touches[0].y;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}
