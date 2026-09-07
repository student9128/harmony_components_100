import { avSession } from '@kit.AVSessionKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'

const TAG: string = 'MediaSession'

/** AVSession 下发给应用的控制指令（来自播控中心 / 锁屏卡片 / 蓝牙耳机等） */
export interface MediaSessionCommands {
  onPlay: () => void
  onPause: () => void
  onStop: () => void
  /** 目标位置，单位 ms */
  onSeek: (timeMs: number) => void
  /** 倍速值，如 1.0 / 1.25 */
  onSetSpeed: (speed: number) => void
}

/**
 *
 * 1. 一个应用进程只允许存在一个会话，重复创建会失败 —— create() 里会先销毁旧的；
 * 2. 播放业务活动期间必须保持 session 存活，否则后台会被管控静音、锁屏卡片异常；
 * 3. 顺序必须是：创建 → 设置元数据 → 注册控制指令 → activate。
 *    反过来（先激活再注册）会导致播控中心按钮置灰或显示不全；
 * 4. position.updateTime 必须传当前时间戳，系统靠它自行推算进度条，不用我们频繁上报。
 */
export class MediaSessionHelper {
  private session: avSession.AVSession | undefined = undefined

  /** 创建并激活会话 */
  async create(context: common.Context, title: string, commands: MediaSessionCommands): Promise<void> {
    if (this.session) {
      await this.destroy() // 进程内只能有一个会话，重复创建会失败
    }
    try {
      this.session = await avSession.createAVSession(context, 'VideoDemoSession', 'video')
      await this.setMeta(title, 0) // 先给元数据，时长拿到后再更新一次
      this.bindCommands(commands)
      await this.session.activate()
      console.info(`${TAG} created`)
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} create failed: code=${err.code}, msg=${err.message}`)
      this.session = undefined
    }
  }

  /** 元数据（标题 / 总时长）；拿到 duration 后必须再调一次，否则播控中心不知道总时长 */
  async setMeta(title: string, durationMs: number): Promise<void> {
    if (!this.session) {
      return
    }
    try {
      await this.session.setAVMetadata({
        assetId: 'video_demo_asset',
        title: title,
        artist: '组件 Demo',
        duration: durationMs
      })
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} setMeta failed: code=${err.code}, msg=${err.message}`)
    }
  }

  /** 同步播放状态与进度到系统；播放 / 暂停 / seek / 倍速变化后都要调用 */
  async setPlaybackState(
    isPlaying: boolean,
    elapsedMs: number,
    durationMs: number,
    speed: number,
    bufferedMs: number
  ): Promise<void> {
    if (!this.session) {
      return
    }
    try {
      await this.session.setAVPlaybackState({
        state: isPlaying
          ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: speed,
        position: {
          elapsedTime: Math.floor(elapsedMs),
          updateTime: new Date().getTime()
        },
        bufferedTime: Math.floor(bufferedMs),
        duration: Math.floor(durationMs)
      })
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} setState failed: code=${err.code}, msg=${err.message}`)
    }
  }

  private bindCommands(commands: MediaSessionCommands): void {
    const session = this.session
    if (!session) {
      return
    }
    // 每个指令支持注册多个回调，重复注册会重复触发 —— 因此必须保证只 bind 一次
    session.on('play', (): void => {
      console.info(`${TAG} command: play`)
      commands.onPlay()
    })
    session.on('pause', (): void => {
      console.info(`${TAG} command: pause`)
      commands.onPause()
    })
    session.on('stop', (): void => {
      console.info(`${TAG} command: stop`)
      commands.onStop()
    })
    session.on('seek', (time: number): void => {
      console.info(`${TAG} command: seek ${time}`)
      commands.onSeek(time)
    })
    session.on('setSpeed', (speed: number): void => {
      console.info(`${TAG} command: setSpeed ${speed}`)
      commands.onSetSpeed(speed)
    })
  }

  async destroy(): Promise<void> {
    const session = this.session
    if (!session) {
      return
    }
    this.session = undefined
    try {
      session.off('play')
      session.off('pause')
      session.off('stop')
      session.off('seek')
      session.off('setSpeed')
      await session.deactivate()
      await session.destroy()
      console.info(`${TAG} destroyed`)
    } catch (error) {
      const err = error as BusinessError
      console.error(`${TAG} destroy failed: code=${err.code}, msg=${err.message}`)
    }
  }
}
