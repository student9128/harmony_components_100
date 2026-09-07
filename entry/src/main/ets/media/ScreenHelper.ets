import { window } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'

const TAG: string = 'Screen'

/**
 * 视频全屏 + 旋转锁定。
 *
 * 【全屏】
 * setWindowLayoutFullScreen(true) 让布局延伸到系统栏之下（视频全屏要的就是这个），
 * 同时把窗口方向切到 LANDSCAPE。退出时必须 restore()，否则整个应用都会保持全屏。
 *
 * 【旋转锁定】
 * Orientation.LOCKED = 锁定在屏幕当前方向；Orientation.AUTO_ROTATION = 跟随传感器。
 * 播放器里的「锁」图标就是这个语义 —— 不是锁密码，而是锁住当前横竖屏。
 */
export class ScreenHelper {
  private cached: window.Window | undefined = undefined

  private async getWin(context: common.Context): Promise<window.Window | undefined> {
    try {
      if (!this.cached) {
        this.cached = await window.getLastWindow(context)
      }
      return this.cached
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} getWindow failed: code=${err.code}, msg=${err.message}`)
      return undefined
    }
  }

  /** 进入 / 退出全屏（含横竖屏切换） */
  async setFullScreen(context: common.Context, full: boolean): Promise<void> {
    const win = await this.getWin(context)
    if (!win) {
      return
    }
    try {
      await win.setWindowLayoutFullScreen(full)
      await win.setPreferredOrientation(full
        ? window.Orientation.LANDSCAPE
        : window.Orientation.PORTRAIT)
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} setFullScreen failed: code=${err.code}, msg=${err.message}`)
    }
  }

  /** 锁定 / 解锁屏幕旋转 */
  async setLocked(context: common.Context, locked: boolean): Promise<void> {
    const win = await this.getWin(context)
    if (!win) {
      return
    }
    try {
      await win.setPreferredOrientation(locked
        ? window.Orientation.LOCKED
        : window.Orientation.AUTO_ROTATION)
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} setLocked failed: code=${err.code}, msg=${err.message}`)
    }
  }

  /** 离开页面时必须调用：恢复非全屏 + 竖屏跟随 */
  async restore(context: common.Context): Promise<void> {
    const win = await this.getWin(context)
    if (!win) {
      return
    }
    try {
      await win.setWindowLayoutFullScreen(false)
      await win.setPreferredOrientation(window.Orientation.PORTRAIT)
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} restore failed: code=${err.code}, msg=${err.message}`)
    }
  }
}
