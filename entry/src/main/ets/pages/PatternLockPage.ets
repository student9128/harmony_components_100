import { preferences } from '@kit.ArkData'
import { PatternLockView, PatternLockStyle, PatternLockController } from '../widget/PatternLockView'

const STORE_NAME: string = 'pattern_lock_demo'
const KEY_PATTERN: string = 'pattern'
const MIN_POINTS: number = 4

/**
 * 图案解锁 Demo：完整演示「设置密码 → 确认密码 → 持久化 → 解锁验证」流程。
 * 路径以 "0,1,4,8" 形式存入 preferences，重启应用仍在（验证模式）。
 * 左上角「清除密码」可回到设置模式。
 */
@Entry
@ComponentV2
struct PatternLockPage {
  @Local style: PatternLockStyle = PatternLockStyle.RING
  @Local hint: string = '绘制解锁图案'
  @Local hasStored: boolean = false
  @Local hintColor: string = '#666666'

  private firstPattern: string = ''
  private hasStoredPwd: string = ''
  private controller: PatternLockController = new PatternLockController()
  private store: preferences.Preferences | undefined = undefined

  aboutToAppear(): void {
    this.loadStore()
  }

  private async loadStore(): Promise<void> {
    const store = await preferences.getPreferences(getContext(this), STORE_NAME)
    this.store = store
    const saved = await store.get(KEY_PATTERN, '')
    this.storedPwdChanged(saved as string)
  }

  private storedPwdChanged(pwd: string): void {
    if (pwd === '') {
      this.hasStored = false
      this.hint = '绘制解锁图案'
    } else {
      this.hasStored = true
      this.hint = '绘制图案解锁'
    }
    this.hintColor = '#666666'
  }

  private handleComplete(sequence: number[]): void {
    if (sequence.length < MIN_POINTS) {
      this.hint = `至少连接 ${MIN_POINTS} 个点`
      this.hintColor = '#F44336'
      this.controller.showError()
      return
    }
    const pwd: string = sequence.join(',')
    if (!this.hasStored) {
      this.handleSetup(pwd)
    } else {
      this.handleVerify(pwd)
    }
  }

  /** 设置模式：第一次记录，第二次确认 */
  private handleSetup(pwd: string): void {
    if (this.firstPattern === '') {
      this.firstPattern = pwd
      this.hint = '再次绘制解锁图案'
      this.hintColor = '#666666'
      return
    }
    if (pwd === this.firstPattern) {
      this.savePwd(pwd)
      this.hint = '设置成功'
      this.hintColor = '#4CAF50'
      this.controller.reset()
    } else {
      this.hint = '两次绘制不一致，请重新绘制'
      this.hintColor = '#F44336'
      this.controller.showError()
      this.firstPattern = ''
    }
  }

  /** 验证模式：与持久化的密码比对 */
  private handleVerify(pwd: string): void {
    if (pwd === this.hasStoredPwd) {
      this.hint = '解锁成功'
      this.hintColor = '#4CAF50'
      this.controller.reset()
    } else {
      this.hint = '图案错误，请重试'
      this.hintColor = '#F44336'
      this.controller.showError()
    }
  }

  private savePwd(pwd: string): void {
    this.hasStoredPwd = pwd
    this.hasStored = true
    this.store?.put(KEY_PATTERN, pwd)
    this.store?.flush()
  }

  private clearPwd(): void {
    this.store?.delete(KEY_PATTERN)
    this.store?.flush()
    this.hasStoredPwd = ''
    this.firstPattern = ''
    this.hasStored = false
    this.hint = '已清除，请重新绘制解锁图案'
    this.hintColor = '#666666'
    this.controller.reset()
  }

  build() {
    Column({ space: 20 }) {
      Text('九宫格图案解锁')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)

      // 不同样式使用不同的尺寸 / 颜色组合，切换样式即可预览四种形态
      PatternLockView({
        style: this.style,
        sideLength: 288,
        showThumbnail: true,
        controller: this.controller,
        dotRadius: this.style === PatternLockStyle.DOT ? 9 : 5,
        ringRadius: 20,
        lineWidth: this.style === PatternLockStyle.DOT ? 9 : 2,
        normalColor: this.style === PatternLockStyle.DOT ? '#334155' : '#5B8DB8',
        activeColor: this.style === PatternLockStyle.DOT ? '#9AA0A6' : '#1E88E5',
        lineColor: this.style === PatternLockStyle.DOT ? '#9AA0A6' : '',
        autoReset: false,
        onPatternComplete: (sequence: number[]) => {
          this.handleComplete(sequence)
        }
      })

      Text(this.hint)
        .fontSize(15)
        .fontColor(this.hintColor)

      Row({ space: 8 }) {
        Button('箭头').onClick(() => {
          this.style = PatternLockStyle.ARROW
          this.controller.reset()
        })
        Button('水波纹').onClick(() => {
          this.style = PatternLockStyle.RIPPLE
          this.controller.reset()
        })
        Button('圆圈').onClick(() => {
          this.style = PatternLockStyle.RING
          this.controller.reset()
        })
        Button('官方').onClick(() => {
          this.style = PatternLockStyle.DOT
          this.controller.reset()
        })
      }

      Button('清除已保存密码', { stateEffect: true })
        .backgroundColor('#F44336')
        .onClick(() => {
          this.clearPwd()
        })
    }
    .height('100%')
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }
}
