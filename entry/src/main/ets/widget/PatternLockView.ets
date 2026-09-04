/**
 * 九宫格图案解锁组件（状态管理 V2 + Canvas 绘制）
 *
 * 四种内置样式（PatternLockStyle）：
 * - ARROW ：圆环 + 圆点 + 连线，每段线中点带方向箭头
 * - RIPPLE：未选中为圆环，选中为圆点 + 两层水波纹光晕
 * - RING  ：未选中为圆环，选中为圆环 + 圆点（经典样式）
 * - DOT   ：官方 PatternLock 风格，小圆点，选中放大 + 粗连线
 *
 * 能力：
 * - 圆点 / 圆环大小、圆环线宽、连线宽度、四种颜色全部可配
 * - 报错时整盘（含缩略图）变红
 * - 顶部缩略图实时回显当前路径（可选）
 * - onPatternComplete 回传完整路径（如 [0,1,4,8]），由外部保存 / 比对
 * - PatternLockController：外部控制 reset（清空重画）/ showError（整盘标红）
 * - 划线穿过中间点时自动激活（如 0 划到 2 自动带上 1）
 *
 * 用法：
 *   controller: PatternLockController = new PatternLockController()
 *   PatternLockView({
 *     controller: this.controller,
 *     onPatternComplete: (seq: number[]) => { this.verify(seq) }
 *   })
 */

/** 解锁图案样式 */
export enum PatternLockStyle {
  /** 圆环 + 圆点 + 带箭头连线 */
  ARROW = 0,
  /** 圆点 + 水波纹光晕 */
  RIPPLE = 1,
  /** 圆圈 + 圆点 */
  RING = 2,
  /** 官方风格：圆点，选中放大 + 粗线 */
  DOT = 3
}

/** 对外控制器：每个组件实例需配一个独立的 controller 实例 */
export class PatternLockController {
  /** 清空当前路径与错误状态，恢复初始 */
  reset: () => void = (): void => {}
  /** 标记错误：整盘（含缩略图）变红，errorAutoResetDelay 后自动重置 */
  showError: () => void = (): void => {}
}

class Point {
  x: number
  y: number

  constructor(x: number, y: number) {
    this.x = x
    this.y = y
  }
}

@ComponentV2
export struct PatternLockView {
  /** 图案样式 */
  @Param style: PatternLockStyle = PatternLockStyle.RING
  /** 画布边长（正方形，vp） */
  @Param sideLength: number = 300
  /** 是否显示顶部路径缩略图 */
  @Param showThumbnail: boolean = true
  /** 缩略图边长（vp） */
  @Param thumbnailSize: number = 44

  /** 圆点（实心）半径，vp；DOT 样式下为未选中点半径 */
  @Param dotRadius: number = 5
  /** 圆环半径，vp；DOT 样式不使用 */
  @Param ringRadius: number = 20
  /** 圆环描边宽度，vp */
  @Param ringStrokeWidth: number = 2
  /** DOT 样式选中时圆点放大倍数 */
  @Param activeScale: number = 1.6
  /** 连线宽度，vp */
  @Param lineWidth: number = 1

  /** 未选中颜色 */
  @Param normalColor: string = '#5B8DB8'
  /** 选中颜色 */
  @Param activeColor: string = '#1E88E5'
  /** 错误颜色（错误时整盘使用） */
  @Param errorColor: string = '#F44336'
  /** 连线颜色，空串时跟随 activeColor */
  @Param lineColor: string = ''

  /** 绘制完成后是否自动重置（需要自行展示成功/失败状态时设为 false，用 controller 控制） */
  @Param autoReset: boolean = true
  /** 绘制完成后自动重置延时 ms（autoReset = true 时生效） */
  @Param autoResetDelay: number = 600
  /** 错误展示后自动重置延时 ms，<= 0 表示不自动重置 */
  @Param errorAutoResetDelay: number = 1000

  /** 绘制完成回调，回传完整路径（点索引序列，0~8，行优先） */
  @Event onPatternComplete: (sequence: number[]) => void = (): void => {}

  @Require @Param controller: PatternLockController

  /** 已激活的点索引序列 */
  private selected: number[] = []
  private isError: boolean = false
  private drawing: boolean = false
  private fingerX: number = 0
  private fingerY: number = 0
  private resetTimerId: number = -1

  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true))
  private thumbCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true))

  aboutToAppear(): void {
    this.controller.reset = (): void => this.doReset()
    this.controller.showError = (): void => this.showPatternError()
  }

  aboutToDisappear(): void {
    this.clearResetTimer()
  }

  /**
   * Canvas 是命令式绘制：只在 onReady 和触摸时重绘，
   * 样式/尺寸/颜色类参数中途变化不会自己刷新，必须监听后手动重绘。
   * （Canvas 未完成 onReady 时调用无效，首次 onReady 仍会绘制一次，不影响。）
   */
  @Monitor('style', 'sideLength', 'thumbnailSize', 'dotRadius', 'ringRadius', 'ringStrokeWidth',
    'activeScale', 'lineWidth', 'normalColor', 'activeColor', 'errorColor', 'lineColor')
  onStyleChange(): void {
    this.redrawAll()
  }

  build() {
    Column({ space: 14 }) {
      if (this.showThumbnail) {
        Canvas(this.thumbCtx)
          .width(this.thumbnailSize)
          .height(this.thumbnailSize)
          .onReady((): void => this.drawThumb())
      }

      Canvas(this.ctx)
        .width(this.sideLength)
        .height(this.sideLength)
        .onReady((): void => this.redraw())
        .onTouch((event: TouchEvent) => this.handleTouch(event))
    }
  }

  // ==================== 触摸 ====================

  private handleTouch(event: TouchEvent): void {
    switch (event.type) {
      case TouchType.Down: {
        const x: number = this.touchX(event)
        const y: number = this.touchY(event)
        if (this.isError) {
          // 错误展示中按下：立即清掉红色，开始新绘制
          this.clearResetTimer()
          this.isError = false
          this.selected = []
        }
        const idx: number = this.hitTest(x, y)
        if (idx >= 0) {
          this.drawing = true
          this.selected = [idx]
          const c: Point = this.center(idx, this.sideLength)
          this.fingerX = c.x
          this.fingerY = c.y
          this.redrawAll()
        }
        break
      }
      case TouchType.Move: {
        if (!this.drawing) {
          break
        }
        const x: number = this.touchX(event)
        const y: number = this.touchY(event)
        this.fingerX = x
        this.fingerY = y
        this.activatePassedPoints(x, y)
        const hit: number = this.hitTest(x, y)
        if (hit >= 0 && !this.selected.includes(hit)) {
          this.selected.push(hit)
        }
        this.redrawAll()
        break
      }
      case TouchType.Up:
      case TouchType.Cancel: {
        if (!this.drawing) {
          break
        }
        this.drawing = false
        this.fingerX = 0
        this.fingerY = 0
        this.redrawAll()
        if (this.selected.length > 0) {
          this.onPatternComplete(this.selected.slice())
          if (this.autoReset && !this.isError) {
            this.scheduleReset(this.autoResetDelay)
          }
        }
        break
      }
      default:
        break
    }
  }

  private touchX(event: TouchEvent): number {
    const points: Array<TouchObject> = event.touches.length > 0 ? event.touches : event.changedTouches
    return points.length > 0 ? points[0].x : 0
  }

  private touchY(event: TouchEvent): number {
    const points: Array<TouchObject> = event.touches.length > 0 ? event.touches : event.changedTouches
    return points.length > 0 ? points[0].y : 0
  }

  /** 命中检测，返回点索引，未命中返回 -1 */
  private hitTest(x: number, y: number): number {
    const hit: number = (this.sideLength / 3) * 0.45
    for (let i = 0; i < 9; i++) {
      const c: Point = this.center(i, this.sideLength)
      const dx: number = x - c.x
      const dy: number = y - c.y
      if (dx * dx + dy * dy <= hit * hit) {
        return i
      }
    }
    return -1
  }

  /** 划线越过中间点时自动激活（一条线段在 3x3 中最多穿过 1 个中间点） */
  private activatePassedPoints(x: number, y: number): void {
    if (this.selected.length === 0) {
      return
    }
    const last: number = this.selected[this.selected.length - 1]
    const from: Point = this.center(last, this.sideLength)
    const threshold: number = this.dotRadius + 4
    for (let i = 0; i < 9; i++) {
      if (this.selected.includes(i)) {
        continue
      }
      const c: Point = this.center(i, this.sideLength)
      const dist: number = this.distanceToSegment(c.x, c.y, from.x, from.y, x, y)
      if (dist <= threshold) {
        this.selected.push(i)
      }
    }
  }

  private distanceToSegment(px: number, py: number, x1: number, y1: number, x2: number, y2: number): number {
    const dx: number = x2 - x1
    const dy: number = y2 - y1
    const lenSq: number = dx * dx + dy * dy
    let t: number = lenSq === 0 ? 0 : ((px - x1) * dx + (py - y1) * dy) / lenSq
    t = Math.max(0, Math.min(1, t))
    const cx: number = x1 + t * dx
    const cy: number = y1 + t * dy
    return Math.hypot(px - cx, py - cy)
  }

  // ==================== 对外控制 ====================

  private doReset(): void {
    this.clearResetTimer()
    this.selected = []
    this.isError = false
    this.drawing = false
    this.redrawAll()
  }

  private showPatternError(): void {
    this.isError = true
    this.redrawAll()
    if (this.errorAutoResetDelay > 0) {
      this.scheduleReset(this.errorAutoResetDelay)
    }
  }

  private scheduleReset(delay: number): void {
    this.clearResetTimer()
    this.resetTimerId = setTimeout((): void => {
      this.resetTimerId = -1
      this.doReset()
    }, delay)
  }

  private clearResetTimer(): void {
    if (this.resetTimerId >= 0) {
      clearTimeout(this.resetTimerId)
      this.resetTimerId = -1
    }
  }

  // ==================== 绘制 ====================

  private redrawAll(): void {
    this.redraw()
    this.drawThumb()
  }

  private redraw(): void {
    const ctx = this.ctx
    ctx.clearRect(0, 0, this.sideLength, this.sideLength)
    this.drawGrid(ctx, this.sideLength, this.selected, this.isError, this.drawing, this.fingerX, this.fingerY)
  }

  /** 点 index 在边长 size 画布中的中心坐标 */
  private center(index: number, size: number): Point {
    const cell: number = size / 3
    const col: number = index % 3
    const row: number = Math.floor(index / 3)
    return new Point(cell * (col + 0.5), cell * (row + 0.5))
  }

  private drawGrid(ctx: CanvasRenderingContext2D, size: number, points: number[], error: boolean,
    drawingFinger: boolean, fingerX: number, fingerY: number): void {
    const k: number = size / this.sideLength
    const normal: string = error ? this.errorColor : this.normalColor
    const active: string = error ? this.errorColor : this.activeColor
    const line: string = error ? this.errorColor : (this.lineColor === '' ? this.activeColor : this.lineColor)
    const dotR: number = this.dotRadius * k
    const ringR: number = this.ringRadius * k
    const ringW: number = this.ringStrokeWidth * k
    const lineW: number = this.lineWidth * k

    // 1. 连线（先画线再画点，点盖在线上）
    if (points.length > 0) {
      ctx.beginPath()
      ctx.strokeStyle = line
      ctx.lineWidth = lineW
      ctx.lineCap = 'round'
      ctx.lineJoin = 'round'
      const first: Point = this.center(points[0], size)
      ctx.moveTo(first.x, first.y)
      for (let i = 1; i < points.length; i++) {
        const p: Point = this.center(points[i], size)
        ctx.lineTo(p.x, p.y)
      }
      if (drawingFinger) {
        ctx.lineTo(fingerX * k, fingerY * k)
      }
      ctx.stroke()
    }

    // 2. 箭头：ARROW 样式在每两个已选点的线段中点画方向箭头
    if (this.style === PatternLockStyle.ARROW) {
      for (let i = 0; i < points.length - 1; i++) {
        const a: Point = this.center(points[i], size)
        const b: Point = this.center(points[i + 1], size)
        this.drawArrow(ctx, a.x, a.y, b.x, b.y, size, line)
      }
    }

    // 3. 九个点
    for (let i = 0; i < 9; i++) {
      const c: Point = this.center(i, size)
      const isSelected: boolean = points.includes(i)

      if (this.style === PatternLockStyle.DOT) {
        // 官方风格：实心圆点，选中放大
        ctx.beginPath()
        ctx.fillStyle = isSelected ? active : normal
        const r: number = isSelected ? this.dotRadius * this.activeScale * k : dotR
        ctx.arc(c.x, c.y, r, 0, Math.PI * 2)
        ctx.fill()
        continue
      }

      // 圆环（RIPPLE 选中时不画环，只画涟漪 + 圆点）
      if (!(this.style === PatternLockStyle.RIPPLE && isSelected)) {
        ctx.beginPath()
        ctx.strokeStyle = isSelected ? active : normal
        ctx.lineWidth = ringW
        ctx.arc(c.x, c.y, ringR, 0, Math.PI * 2)
        ctx.stroke()
      }

      // 水波纹：两层半透明同心圆
      if (this.style === PatternLockStyle.RIPPLE && isSelected) {
        ctx.globalAlpha = 0.15
        ctx.beginPath()
        ctx.fillStyle = active
        ctx.arc(c.x, c.y, ringR * 1.25, 0, Math.PI * 2)
        ctx.fill()
        ctx.globalAlpha = 0.3
        ctx.beginPath()
        ctx.arc(c.x, c.y, ringR * 0.75, 0, Math.PI * 2)
        ctx.fill()
        ctx.globalAlpha = 1
      }

      // 选中实心圆点
      if (isSelected) {
        ctx.beginPath()
        ctx.fillStyle = active
        ctx.arc(c.x, c.y, dotR, 0, Math.PI * 2)
        ctx.fill()
      }
    }
  }

  /** 在 (x1,y1)->(x2,y2) 线段中点画箭头 */
  private drawArrow(ctx: CanvasRenderingContext2D, x1: number, y1: number,
    x2: number, y2: number, size: number, color: string): void {
    const k: number = size / this.sideLength
    const len: number = 9 * k
    const mx: number = (x1 + x2) / 2
    const my: number = (y1 + y2) / 2
    const angle: number = Math.atan2(y2 - y1, x2 - x1)
    ctx.beginPath()
    ctx.strokeStyle = color
    ctx.lineWidth = Math.max(this.ringStrokeWidth, this.lineWidth * 0.6) * k
    ctx.lineCap = 'round'
    ctx.moveTo(mx, my)
    ctx.lineTo(mx - len * Math.cos(angle - Math.PI / 6), my - len * Math.sin(angle - Math.PI / 6))
    ctx.moveTo(mx, my)
    ctx.lineTo(mx - len * Math.cos(angle + Math.PI / 6), my - len * Math.sin(angle + Math.PI / 6))
    ctx.stroke()
  }

  /** 顶部缩略图：小点阵 + 细连线，选中实心、未选中空心，错误时整体变红 */
  private drawThumb(): void {
    const ctx = this.thumbCtx
    const s: number = this.thumbnailSize
    ctx.clearRect(0, 0, s, s)
    const color: string = this.isError ? this.errorColor : this.activeColor
    const normal: string = this.isError ? this.errorColor : this.normalColor

    if (this.selected.length > 1) {
      ctx.beginPath()
      ctx.strokeStyle = color
      // 与主画布的 lineWidth 联动（按缩略图比例缩放），最小 1vp 保证可见
      ctx.lineWidth = Math.max(1, this.lineWidth * (s / this.sideLength))
      ctx.lineCap = 'round'
      ctx.lineJoin = 'round'
      const first: Point = this.center(this.selected[0], s)
      ctx.moveTo(first.x, first.y)
      for (let i = 1; i < this.selected.length; i++) {
        const p: Point = this.center(this.selected[i], s)
        ctx.lineTo(p.x, p.y)
      }
      ctx.stroke()
    }

    const r: number = s * 0.045
    for (let i = 0; i < 9; i++) {
      const c: Point = this.center(i, s)
      if (this.selected.includes(i)) {
        ctx.beginPath()
        ctx.fillStyle = color
        ctx.arc(c.x, c.y, r, 0, Math.PI * 2)
        ctx.fill()
      } else {
        ctx.beginPath()
        ctx.strokeStyle = normal
        ctx.lineWidth = 1
        ctx.arc(c.x, c.y, r, 0, Math.PI * 2)
        ctx.stroke()
      }
    }
  }
}
