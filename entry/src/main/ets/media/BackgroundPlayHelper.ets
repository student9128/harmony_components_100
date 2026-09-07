import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { common, wantAgent } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'

const TAG: string = 'BackgroundPlay'

/**
 * AUDIO_PLAYBACK 长时任务：让退后台 / 锁屏后的播放不被系统暂停。
 *
 * 【为什么还要它】
 * AVSession 只负责"播控"（显示与控制），系统仍可能在后台暂停播放。
 * 要真正在后台持续播放，必须再申请 AUDIO_PLAYBACK 长时任务，并在 module.json5 里
 * 声明权限与后台模式（见 module.json5 的 KEEP_BACKGROUND_RUNNING / backgroundModes）。
 *
 * 【配套配置，缺一不可】
 * module.json5:
 *   requestPermissions: [{ "name": "ohos.permission.KEEP_BACKGROUND_RUNNING" }]
 *   abilities: [{ "backgroundModes": ["audioPlayback"] }]
 *
 * 【注意】接入 AVSession 后，通知栏由 AVSession 发出，后台任务模块不会再发一条通知，
 * 因此不会出现两条重复通知。
 */
export class BackgroundPlayHelper {
  private running: boolean = false
  private context: common.UIAbilityContext | undefined = undefined

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      return
    }
    this.context = context
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [
          {
            bundleName: context.abilityInfo.bundleName,
            abilityName: context.abilityInfo.name
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      })
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent
      )
      this.running = true
      console.info(`${TAG} started`)
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} start failed: code=${err.code}, msg=${err.message}`)
    }
  }

  async stop(): Promise<void> {
    if (!this.running || !this.context) {
      return
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context)
      this.running = false
      console.info(`${TAG} stopped`)
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} stop failed: code=${err.code}, msg=${err.message}`)
    }
  }
}
