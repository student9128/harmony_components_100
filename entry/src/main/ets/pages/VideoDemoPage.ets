import { media } from '@kit.MediaKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { VideoProgressBar } from '../widget/VideoProgressBar'
import { MediaSessionHelper, MediaSessionCommands } from '../media/MediaSessionHelper'
import { BackgroundPlayHelper } from '../media/BackgroundPlayHelper'
import { ScreenHelper } from '../media/ScreenHelper'

const VIDEO_SRC: string =
  'https://sf1-cdn-tos.huoshanstatic.com/obj/media-fe/xgplayer_doc_video/mp4/xgplayer-demo-360p.mp4'
/** 显示在播控中心 / 锁屏卡片上的标题 */
const VIDEO_TITLE: string = '组件 Demo 视频'

/** 倍速档位：PlaybackSpeed 枚举 / 界面文案 / 上报给 AVSession 的数值 */
const SPEED_LIST: media.PlaybackSpeed[] = [
  media.PlaybackSpeed.SPEED_FORWARD_0_75_X,
  media.PlaybackSpeed.SPEED_FORWARD_1_00_X,
  media.PlaybackSpeed.SPEED_FORWARD_1_25_X,
  media.PlaybackSpeed.SPEED_FORWARD_1_50_X,
  media.PlaybackSpeed.SPEED_FORWARD_2_00_X
]
const SPEED_LABELS: string[] = ['0.75x', '1.00x', '1.25x', '1.50x', '2.00x']
const SPEED_VALUES: number[] = [0.75, 1.0, 1.25, 1.5, 2.0]
const DEFAULT_SPEED_INDEX: number = 1

function formatTime(timeMs: number): string {
  const totalSeconds: number = Math.max(0, Math.floor(timeMs / 1000))
  const minute: number = Math.floor(totalSeconds / 60)
  const second: number = totalSeconds % 60
  return `${minute.toString().padStart(2, '0')}:${second.toString().padStart(2, '0')}`
}

/**
 * XComponent 的 Surface 生命周期回调。
 *
 * 关键点：这三个回调【不是】组件链式回调，而是 XComponentController 的方法，
 * 必须继承 XComponentController 并重写才能收到。
 *
 * 官方文档明确：onLoad 触发时机早于 onSurfaceCreated，
 * 在 onLoad 中调用 getXComponentSurfaceId() 获取 surfaceId 会失败，应在 onSurfaceCreated 中获取。
 */
class VideoSurfaceController extends XComponentController {
  onCreated: (surfaceId: string) => void = (): void => {}
  onChanged: (surfaceId: string) => void = (): void => {}
  onDestroyed: (surfaceId: string) => void = (): void => {}

  /** Surface 创建完成——这才是真正的“就绪”信号 */
  onSurfaceCreated(surfaceId: string): void {
    console.info(`onSurfaceCreated: ${surfaceId}`)
    this.onCreated(surfaceId)
  }

  /** Surface 尺寸变化（含首次创建时的尺寸确定） */
  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    console.info(`onSurfaceChanged: ${surfaceId}, ${rect.surfaceWidth}x${rect.surfaceHeight}`)
    this.onChanged(surfaceId)
  }

  onSurfaceDestroyed(surfaceId: string): void {
    console.info(`onSurfaceDestroyed: ${surfaceId}`)
    this.onDestroyed(surfaceId)
  }
}

/**
 * 视频播放器 Demo：AVPlayer + XComponent + 自绘带缓存进度的进度条。
 *
 * 【播控接入】
 *  - MediaSessionHelper：AVSession，负责播控中心与锁屏卡片；
 *  - BackgroundPlayHelper：AUDIO_PLAYBACK 长时任务，负责退后台 / 锁屏后仍能播；
 *  - ScreenHelper：全屏 + 旋转锁定。
 *
 * 【控制栏】上层：左(当前/总时长) 中(播放暂停) 右(倍速/旋转锁/全屏)；下层：进度条。
 */
@ComponentV2
export struct VideoDemoPage {
  @Local duration: number = 0
  @Local currentTime: number = 0
  @Local bufferTime: number = 0
  @Local isPlaying: boolean = false
  @Local seeking: boolean = false
  @Local speedIndex: number = DEFAULT_SPEED_INDEX
  @Local isFullScreen: boolean = false
  @Local isLocked: boolean = false

  private avPlayer: media.AVPlayer | undefined = undefined
  /** createAVPlayer 是异步的，这个标志用于防止它被重复调用（否则会创建出多个播放器） */
  private creating: boolean = false
  private surfaceId: string = ''
  private xComponentController: VideoSurfaceController = new VideoSurfaceController()
  private rebindTimerId: number = -1
  /** setSpeed 只能在 prepared/playing/paused/completed 调用，未就绪时先记下来 */
  private pendingSpeed: media.PlaybackSpeed | undefined = undefined

  private mediaSession: MediaSessionHelper = new MediaSessionHelper()
  private backgroundPlay: BackgroundPlayHelper = new BackgroundPlayHelper()
  private screen: ScreenHelper = new ScreenHelper()
  private uiContext: common.UIAbilityContext | undefined = undefined

  aboutToAppear(): void {
    this.uiContext = getContext(this) as common.UIAbilityContext
    this.xComponentController.onCreated = (surfaceId: string): void => {
      this.onSurfaceCreate(surfaceId)
    }
    this.xComponentController.onChanged = (surfaceId: string): void => {
      this.onSurfaceChange(surfaceId)
    }
    this.xComponentController.onDestroyed = (): void => {
      this.surfaceId = ''
    }
    const commands: MediaSessionCommands = {
      onPlay: (): void => {
        this.play()
      },
      onPause: (): void => {
        this.pause()
      },
      onStop: (): void => {
        this.pause()
      },
      onSeek: (timeMs: number): void => {
        this.seekTo(timeMs)
      },
      onSetSpeed: (speed: number): void => {
        this.applySystemSpeed(speed)
      }
    }
    if (this.uiContext) {
      void this.mediaSession.create(this.uiContext, VIDEO_TITLE, commands)
    }
  }

  aboutToDisappear(): void {
    if (this.rebindTimerId >= 0) {
      clearTimeout(this.rebindTimerId)
      this.rebindTimerId = -1
    }
    void this.backgroundPlay.stop()
    void this.mediaSession.destroy()
    if (this.uiContext) {
      void this.screen.restore(this.uiContext) // 必须恢复，否则整个应用保持全屏横屏
    }
    if (this.avPlayer) {
      this.avPlayer.release()
      this.avPlayer = undefined
    }
  }

  build() {
    Column() {
      if (this.isFullScreen) {
        Column() {
          this.videoArea()
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        Column() {
          this.videoArea()
        }
        .width('100%')
        .aspectRatio(16 / 9)
      }

      this.controlBar()
    }
    .height('100%')
    .width('100%')
    .backgroundColor('#000000')
  }

  /** 视频画面层（全屏与非全屏共用，外层容器决定它的高度） */
  @Builder
  videoArea(): void {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({
        id: 'videoSurface',
        type: XComponentType.SURFACE,
        controller: this.xComponentController
      })
        .width('100%')
        .height('100%')

      if (!this.isPlaying) {
        Stack() {
          Circle()
            .width(56)
            .height(56)
            .fill('#80F51F1F')
          Image($r('app.media.ic_play'))
            .width(30)
            .height(30)
            // SVG 自带 fill 是 #1F1F1F，必须改色，否则在黑底上看不见
            .fillColor('#FFFFFF')
        }
        .width(56)
        .height(56)
        .onClick(() => {
          this.play()
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .onClick(() => {
      this.togglePlay()
    })
  }

  /** 控制栏：上层 左时长 / 中播放暂停 / 右(倍速·旋转锁·全屏)，下层进度条 */
  @Builder
  controlBar(): void {
    Column({ space: 6 }) {
      Row() {
        Text(`${formatTime(this.currentTime)} / ${formatTime(this.duration)}`)
          .fontSize(12)
          .fontColor('#CCFFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Row() {
          Image(this.isPlaying ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
            .width(22)
            .height(22)
            .fillColor('#FFFFFF')
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor('#33FFFFFF')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.togglePlay()
        })

        Row({ space: 14 }) {
          Row({ space: 2 }) {
            Image($r('app.media.ic_speed'))
              .width(18)
              .height(18)
              .fillColor('#FFFFFF')
            Text(SPEED_LABELS[this.speedIndex])
              .fontSize(12)
              .fontColor('#FFFFFF')
          }
          .onClick(() => {
            this.toggleSpeed()
          })

          Image(this.isLocked ? $r('app.media.ic_lock') : $r('app.media.ic_unlock'))
            .width(20)
            .height(20)
            .fillColor(this.isLocked ? '#FFD60A' : '#FFFFFF')
            .onClick(() => {
              this.toggleLock()
            })

          Image(this.isFullScreen ? $r('app.media.ic_fullscreen_exit') : $r('app.media.ic_fullscreen'))
            .width(22)
            .height(22)
            .fillColor('#FFFFFF')
            .onClick(() => {
              this.toggleFullScreen()
            })
        }
        .layoutWeight(1)
        .height(44)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .height(48)

      VideoProgressBar({
        progress: this.playProgress,
        bufferProgress: this.cachedProgress,
        barHeight: 3,
        activeBarHeight: 6,
        thumbSize: 12,
        trackColor: '#4DFFFFFF',
        bufferColor: '#998E6F23',
        progressColor: '#1747E5',
        onSeekStart: (progress: number) => {
          this.seeking = true
          this.currentTime = progress * this.duration
        },
        onSeeking: (progress: number) => {
          this.currentTime = progress * this.duration
        },
        onSeekEnd: (progress: number) => {
          this.seekTo(Math.floor(progress * this.duration))
        }
      })
        .width('100%')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 12 })
    .backgroundColor('#000000')
  }

  private get playProgress(): number {
    return this.duration > 0 ? this.currentTime / this.duration : 0
  }

  private get cachedProgress(): number {
    return this.duration > 0 ? this.bufferTime / this.duration : 0
  }

  /** 播放 / 暂停统一入口：同时同步给 AVSession 与后台任务 */
  private play(): void {
    if (!this.avPlayer) {
      return
    }
    this.avPlayer.play()
    if (this.uiContext) {
      void this.backgroundPlay.start(this.uiContext)
    }
  }

  private pause(): void {
    if (!this.avPlayer) {
      return
    }
    this.avPlayer.pause()
    void this.backgroundPlay.stop()
  }

  private togglePlay(): void {
    if (this.isPlaying) {
      this.pause()
    } else {
      this.play()
    }
  }

  private toggleSpeed(): void {
    this.speedIndex = (this.speedIndex + 1) % SPEED_LIST.length
    this.applySpeed(SPEED_LIST[this.speedIndex])
  }

  private applySpeed(speed: media.PlaybackSpeed): void {
    if (!this.avPlayer) {
      this.pendingSpeed = speed // 播放器还没创建，等 prepared 后再应用
      return
    }
    try {
      this.avPlayer.setSpeed(speed)
    } catch (error) {
      // 尚未进入 prepared/playing/paused/completed，此时调用会抛错
      this.pendingSpeed = speed
    }
    this.syncSessionState()
  }

  /** 播控中心下发倍速（任意数值）→ 匹配到最接近的档位 */
  private applySystemSpeed(speed: number): void {
    let nearest: number = 0
    let minDiff: number = Number.MAX_VALUE
    for (let i: number = 0; i < SPEED_VALUES.length; i++) {
      const diff: number = Math.abs(SPEED_VALUES[i] - speed)
      if (diff < minDiff) {
        minDiff = diff
        nearest = i
      }
    }
    this.speedIndex = nearest
    this.applySpeed(SPEED_LIST[nearest])
  }

  private toggleFullScreen(): void {
    if (this.isLocked) {
      return // 已锁旋转：不再自动切方向，避免和用户意图打架
    }
    this.isFullScreen = !this.isFullScreen
    if (this.uiContext) {
      void this.screen.setFullScreen(this.uiContext, this.isFullScreen)
    }
  }

  private toggleLock(): void {
    this.isLocked = !this.isLocked
    if (this.uiContext) {
      void this.screen.setLocked(this.uiContext, this.isLocked)
    }
  }

  private seekTo(timeMs: number): void {
    this.currentTime = timeMs
    this.seeking = false
    if (this.avPlayer) {
      this.avPlayer.seek(Math.floor(timeMs), media.SeekMode.SEEK_PREV_SYNC)
    }
    this.syncSessionState()
  }

  /** 把当前状态一次性同步给播控中心 / 锁屏卡片 */
  private syncSessionState(): void {
    void this.mediaSession.setPlaybackState(
      this.isPlaying,
      this.currentTime,
      this.duration,
      SPEED_VALUES[this.speedIndex],
      this.bufferTime
    )
  }

  private onSurfaceCreate(surfaceId: string): void {
    if (surfaceId === '') {
      console.error('XComponent surfaceId 为空')
      return
    }
    this.surfaceId = surfaceId
    if (this.avPlayer) {
      this.avPlayer.surfaceId = surfaceId // surface 重建：重绑即可续播
      return
    }
    if (this.creating) {
      return // createAVPlayer 尚未返回，等它回来后在 initialized 分支绑最新的 id
    }
    this.creating = true
    this.initPlayer()
  }

  /** 尺寸变化：只负责重绑，不负责创建（创建一定已由 onSurfaceCreated 先触发） */
  private onSurfaceChange(surfaceId: string): void {
    if (surfaceId === '') {
      return
    }
    this.surfaceId = surfaceId
    if (this.avPlayer) {
      this.avPlayer.surfaceId = surfaceId
    }
  }

  /**
   * 兜底重绑：surfaceId 绑定是「一次性、失败不补偿」的操作，且没有就绪回调可依赖。
   * 进入 playing 后无条件重设一次，若首次绑定因 surface 未就绪而落空，这里补上（幂等）。
   */
  private scheduleSurfaceRebind(): void {
    if (this.rebindTimerId >= 0) {
      return
    }
    this.rebindTimerId = setTimeout((): void => {
      this.rebindTimerId = -1
      const id: string = this.xComponentController.getXComponentSurfaceId()
      if (id === '' || !this.avPlayer) {
        return
      }
      console.info(`surface 重新绑定: ${id}（首次: ${this.surfaceId}）`)
      this.surfaceId = id
      this.avPlayer.surfaceId = id
    }, 200)
  }

  private initPlayer(): void {
    media.createAVPlayer()
      .then((player: media.AVPlayer) => {
        this.creating = false
        this.avPlayer = player
        this.bindPlayerCallback(player) // 回调必须在设置 url 之前注册
        player.url = VIDEO_SRC
      })
      .catch((error: BusinessError) => {
        this.creating = false // 失败也要复位，否则再也创建不了
        console.error(`createAVPlayer 失败: ${error.code}, ${error.message}`)
      })
  }

  private bindPlayerCallback(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState) => {
      console.info(`AVPlayer state: ${state}`)
      switch (state) {
        case 'initialized': {
          // 绑定前重新取一次：surface 可能在之后被重建过，旧 id 会失效
          const id: string = this.xComponentController.getXComponentSurfaceId()
          if (id !== '') {
            this.surfaceId = id
            player.surfaceId = id
            player.prepare()
          } else {
            console.error('AVPlayer surfaceId 未就绪，跳过 prepare')
          }
          break
        }
        case 'prepared': {
          // 倍速只能在 prepared 之后设置，pendingSpeed 在这里补上
          if (this.pendingSpeed !== undefined) {
            try {
              player.setSpeed(this.pendingSpeed)
            } catch (error) {
              console.error('setSpeed 失败')
            }
            this.pendingSpeed = undefined
          }
          player.play()
          break
        }
        case 'playing':
          this.isPlaying = true
          this.scheduleSurfaceRebind() // 兜底：首绑失败时补一次
          this.syncSessionState()
          break
        case 'paused':
        case 'completed':
        case 'stopped':
          this.isPlaying = false
          this.syncSessionState()
          break
        default:
          break
      }
    })

    player.on('durationUpdate', (duration: number) => {
      this.duration = duration
      // 总时长也要告诉播控中心，否则进度条没有终点
      void this.mediaSession.setMeta(VIDEO_TITLE, duration)
      this.syncSessionState()
    })

    // 拖动过程中不接收播放器回传的进度，避免把预览值冲掉
    player.on('timeUpdate', (time: number) => {
      if (!this.seeking) {
        this.currentTime = time
        this.syncSessionState()
      }
    })

    /**
     * 缓冲进度。不同版本 / 不同协议回调的 infoType 不一样，两种都要处理：
     * - CACHED_DURATION：value 为已缓存到的时间点（ms）
     * - BUFFERING_PERCENT：value 为缓冲百分比（0~100）
     */
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      switch (infoType) {
        case media.BufferingInfoType.CACHED_DURATION:
          this.bufferTime = value
          break
        case media.BufferingInfoType.BUFFERING_PERCENT:
          if (this.duration > 0) {
            this.bufferTime = (value / 100) * this.duration
          }
          break
        default:
          break
      }
    })

    player.on('error', (error: BusinessError) => {
      console.error(`AVPlayer error, code: ${error.code}, message: ${error.message}`)
    })
  }
}
