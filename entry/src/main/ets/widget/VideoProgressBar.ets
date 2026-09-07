/**
 * 视频播放进度条（状态管理 V2）
 *
 * 与系统 Slider 的区别：
 * 1. 支持「缓冲（缓存）进度」第二进度，系统 Slider 只有单进度；
 * 2. 支持点击 / 拖动 seek，拖动过程中不跟随外部进度回弹；
 * 3. 宽度、高度、圆角、颜色、滑块大小均可配置，默认胶囊外观。
 *
 * 用法：
 * VideoProgressBar({
 *   progress: this.currentTime / this.duration,
 *   bufferProgress: this.bufferTime / this.duration,
 *   barHeight: 3,
 *   activeBarHeight: 6,
 *   onSeekEnd: (p: number) => { this.avPlayer.seek(p * this.duration) }
 * }).width('100%')
 */

@ComponentV2
export struct VideoProgressBar {
  /** 当前播放进度，归一化取值 0~1 */
  @Param progress: number = 0
  /** 缓冲（缓存）进度，归一化取值 0~1 */
  @Param bufferProgress: number = 0

  /** 进度条整体宽度，默认撑满父容器（'100%' 或数值 vp） */
  @Param barWidth: Length = '100%'
  /** 轨道高度（vp） */
  @Param barHeight: number = 3
  /** 按下 / 拖动时轨道高度（vp），<= 0 表示不做高度变化 */
  @Param activeBarHeight: number = 6
  /** 轨道圆角（vp），< 0 时自动取高度一半（胶囊型） */
  @Param cornerRadius: number = -1
  /** 触摸热区最小高度（vp），用于提升拖动手感 */
  @Param touchHeight: number = 24

  /** 轨道底色 */
  @Param trackColor: ResourceColor = '#4DFFFFFF'
  /** 缓冲进度颜色 */
  @Param bufferColor: ResourceColor = '#99FFFFFF'
  /** 播放进度颜色 */
  @Param progressColor: ResourceColor = '#FFFFFF'

  /** 是否显示滑块 */
  @Param showThumb: boolean = true
  /** 滑块直径（vp），显示滑块时轨道左右各内缩直径的一半，保证滑块不超出边界 */
  @Param thumbSize: number = 12
  /** 滑块是否常驻显示，false 时仅在按下 / 拖动过程中显示 */
  @Param thumbAlwaysShow: boolean = true
  /** 滑块颜色 */
  @Param thumbColor: ResourceColor = '#FFFFFF'
  /** 滑块阴影开关 */
  @Param thumbShadow: boolean = true

  /** 是否允许拖动（false 时仅作展示） */
  @Param enableDrag: boolean = true
  /** 播放进度变化是否使用动画过渡，拖动过程中自动关闭以保证跟手 */
  @Param smooth: boolean = true

  /**
   * 手指按下（含点击）时回调，参数 0~1。
   * 说明：不能命名为 onDragStart / onDragEnd，这两个名字与系统通用拖拽属性重名，会与 CommonAttribute 冲突编译报错。
   */
  @Event onSeekStart: (progress: number) => void = (): void => {}
  /** 拖动过程中持续回调，参数 0~1 */
  @Event onSeeking: (progress: number) => void = (): void => {}
  /** 手指抬起 / 取消时回调，参数 0~1，一般在此执行 seek */
  @Event onSeekEnd: (progress: number) => void = (): void => {}

  @Local totalWidth: number = 0
  @Local dragging: boolean = false
  @Local pressed: boolean = false
  @Local dragValue: number = 0
  /**
   * 首帧布局完成前【禁用】动画。
   * 组件被重建时（典型场景：播放器控件隐藏后再显示），totalWidth 会从 0 变成真实宽度，
   * 若此时动画已开启，就会看到进度条从 0「滑」到当前值。
   * 因此必须等这一次宽度变化渲染完，再开启动画。
   */
  @Local progressAnimReady: boolean = false
  private animReadyTimer: number = -1

  aboutToDisappear(): void {
    if (this.animReadyTimer >= 0) {
      clearTimeout(this.animReadyTimer)
      this.animReadyTimer = -1
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 轨道：底色 + 缓冲进度 + 播放进度
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor(this.trackColor)
          .borderRadius(this.trackRadius)

        Row()
          .width(this.bufferWidth)
          .height('100%')
          .backgroundColor(this.bufferColor)
          .borderRadius(this.trackRadius)

        Row()
          .width(this.progressWidth)
          .height('100%')
          .backgroundColor(this.progressColor)
          .borderRadius(this.trackRadius)
          .animation({ duration: this.progressAnimationDuration, curve: Curve.Linear })
      }
      .width('100%')
      .height(this.trackHeight)
      .padding({ left: this.insetWidth / 2, right: this.insetWidth / 2 })
      .animation({ duration: 120, curve: Curve.EaseOut })

      if (this.showThumb) {
        Circle({ width: this.thumbSize, height: this.thumbSize })
          .fill(this.thumbColor)
          .offset({ x: this.thumbOffsetX })
          .scale({ x: this.thumbScale, y: this.thumbScale })
          .opacity(this.thumbVisible ? 1 : 0)
          .shadow({
            radius: this.thumbShadow ? 4 : 0,
            color: this.thumbShadow ? '#40000000' : '#00000000',
            offsetX: 0,
            offsetY: 1
          })
          .animation({ duration: this.thumbAnimationDuration, curve: Curve.EaseOut })
      }
    }
    .width(this.barWidth)
    .height(this.wrapperHeight)
    .onSizeChange((oldValue: SizeOptions, newValue: SizeOptions) => {
      const width: Length | undefined = newValue.width
      this.totalWidth = typeof width === 'number' ? width : 0
      // 延后一帧再开启动画，保证「0 → 真实宽度」这一次变化是不带动画的
      if (!this.progressAnimReady && this.totalWidth > 0 && this.animReadyTimer < 0) {
        this.animReadyTimer = setTimeout((): void => {
          this.animReadyTimer = -1
          this.progressAnimReady = true
        }, 32)
      }
    })
    .onTouch((event: TouchEvent) => {
      this.handleTouch(event)
    })
  }

  /** 显示滑块时轨道左右各内缩滑块直径的一半 */
  private get insetWidth(): number {
    return this.showThumb ? this.thumbSize : 0
  }

  /** 轨道可绘制宽度 */
  private get contentWidth(): number {
    return Math.max(this.totalWidth - this.insetWidth, 0)
  }

  /** 当前轨道高度：按下 / 拖动时切换到 activeBarHeight */
  private get trackHeight(): number {
    if ((this.dragging || this.pressed) && this.activeBarHeight > 0) {
      return Math.max(this.activeBarHeight, this.barHeight)
    }
    return this.barHeight
  }

  /** 圆角：< 0 时取高度一半（胶囊） */
  private get trackRadius(): number {
    return this.cornerRadius < 0 ? this.trackHeight / 2 : this.cornerRadius
  }

  /** 组件整体高度：保证轨道变高或滑块放大时不会引起外层布局跳动 */
  private get wrapperHeight(): number {
    return Math.max(this.barHeight, this.activeBarHeight, this.touchHeight, this.insetWidth)
  }

  /** 拖动中优先使用拖动值，避免被播放器回传的进度“拉回” */
  private get currentProgress(): number {
    return this.dragging ? this.dragValue : this.clamp01(this.progress)
  }

  private get progressWidth(): number {
    return this.contentWidth * this.currentProgress
  }

  private get bufferWidth(): number {
    return this.contentWidth * this.clamp01(this.bufferProgress)
  }

  /**
   * Stack 中滑块默认居中，需偏移到进度末端：
   * 目标中心 x = insetWidth / 2 + progressWidth
   */
  private get thumbOffsetX(): number {
    return this.progressWidth + (this.thumbSize - this.totalWidth) / 2
  }

  private get thumbScale(): number {
    return this.pressed ? 1.25 : 1
  }

  private get thumbVisible(): boolean {
    return this.thumbAlwaysShow || this.pressed || this.dragging
  }

  /** 拖动中关闭动画保证跟手；首帧未完成布局时也关闭，避免重建时从 0 滑入 */
  private get progressAnimationDuration(): number {
    return this.smooth && !this.dragging && this.progressAnimReady ? 200 : 0
  }

  private get thumbAnimationDuration(): number {
    return !this.dragging && this.progressAnimReady ? 150 : 0
  }

  private handleTouch(event: TouchEvent): void {
    if (!this.enableDrag) {
      return
    }
    const x: number = this.touchX(event)
    switch (event.type) {
      case TouchType.Down:
        this.pressed = true
        this.dragging = true
        this.dragValue = this.ratioFromX(x)
        this.onSeekStart(this.dragValue)
        break
      case TouchType.Move:
        if (this.dragging) {
          this.dragValue = this.ratioFromX(x)
          this.onSeeking(this.dragValue)
        }
        break
      case TouchType.Up:
      case TouchType.Cancel:
        if (this.dragging) {
          const value: number = this.ratioFromX(x)
          this.dragValue = value
          this.onSeekEnd(value)
        }
        this.dragging = false
        this.pressed = false
        break
      default:
        break
    }
  }

  private touchX(event: TouchEvent): number {
    const points: Array<TouchObject> = event.touches.length > 0 ? event.touches : event.changedTouches
    return points.length > 0 ? points[0].x : 0
  }

  /** 触摸点 x（相对组件左上角，vp）换算为 0~1 进度 */
  private ratioFromX(x: number): number {
    if (this.contentWidth <= 0) {
      return 0
    }
    const ratio: number = (x - this.insetWidth / 2) / this.contentWidth
    return Math.min(1, Math.max(0, ratio))
  }

  private clamp01(value: number): number {
    return Math.min(1, Math.max(0, value))
  }
}
