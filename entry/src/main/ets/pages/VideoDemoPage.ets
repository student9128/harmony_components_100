import { media } from '@kit.MediaKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { VideoProgressBar } from '../widget/VideoProgressBar'

const VIDEO_SRC: string =
  'https://sf1-cdn-tos.huoshanstatic.com/obj/media-fe/xgplayer_doc_video/mp4/xgplayer-demo-360p.mp4'

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
 * 由 pages/Index.ets 的 Navigation 路由表承载（不是 @Entry 页面）。
 */
@ComponentV2
export struct VideoDemoPage {
  @Local duration: number = 0
  @Local currentTime: number = 0
  @Local bufferTime: number = 0
  @Local isPlaying: boolean = false
  @Local seeking: boolean = false

  private avPlayer: media.AVPlayer | undefined = undefined
  /** createAVPlayer 是异步的，这个标志用于防止它被重复调用（否则会创建出多个播放器） */
  private creating: boolean = false
  private surfaceId: string = ''
  private xComponentController: VideoSurfaceController = new VideoSurfaceController()
  private rebindTimerId: number = -1

  aboutToAppear(): void {
    this.xComponentController.onCreated = (surfaceId: string): void => {
      this.onSurfaceCreate(surfaceId)
    }
    this.xComponentController.onChanged = (surfaceId: string): void => {
      this.onSurfaceChange(surfaceId)
    }
    this.xComponentController.onDestroyed = (): void => {
      this.surfaceId = ''
    }
  }

  aboutToDisappear(): void {
    if (this.rebindTimerId >= 0) {
      clearTimeout(this.rebindTimerId)
      this.rebindTimerId = -1
    }
    if (this.avPlayer) {
      this.avPlayer.release()
      this.avPlayer = undefined
    }
  }

  build() {
    Column() {
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
            Text('播放▶')
              .fontSize(12)
              .fontColor('#FFFFFF')
          }
          .width(56)
          .height(56)
          .onClick(() => {
            this.avPlayer?.play()
          })
        }
      }
      .width('100%')
      .aspectRatio(16 / 9)
      .onClick(() => {
        if (this.isPlaying) {
          this.avPlayer?.pause()
        }
      })

      Row() {
        Text(formatTime(this.currentTime))
          .fontSize(12)
          .fontColor('#CCFFFFFF')

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
            this.avPlayer?.seek(Math.floor(progress * this.duration), media.SeekMode.SEEK_PREV_SYNC)
            this.seeking = false
          }
        })
          .layoutWeight(1)
          .margin({ left: 8, right: 8 })

        Text(formatTime(this.duration))
          .fontSize(12)
          .fontColor('#CCFFFFFF')

        // 调试用：确认是“缓冲数据为 0”还是“进度条没画出来”，验证完可删
        Text(`${Math.round(this.cachedProgress * 100)}%`)
          .fontSize(10)
          .fontColor('#99FFFFFF')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#000000')
    }
    .height('100%')
    .width('100%')
  }

  private get playProgress(): number {
    return this.duration > 0 ? this.currentTime / this.duration : 0
  }

  private get cachedProgress(): number {
    return this.duration > 0 ? this.bufferTime / this.duration : 0
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
        case 'prepared':
          player.play()
          break
        case 'playing':
          this.isPlaying = true
          this.scheduleSurfaceRebind() // 兜底：首绑失败时补一次
          break
        case 'paused':
        case 'completed':
        case 'stopped':
          this.isPlaying = false
          break
        default:
          break
      }
    })

    player.on('durationUpdate', (duration: number) => {
      this.duration = duration
    })

    // 拖动过程中不接收播放器回传的进度，避免把预览值冲掉
    player.on('timeUpdate', (time: number) => {
      if (!this.seeking) {
        this.currentTime = time
      }
    })

    /**
     * 缓冲进度。不同版本 / 不同协议回调的 infoType 不一样，两种都要处理：
     * - CACHED_DURATION：value 为已缓存到的时间点（ms）
     * - BUFFERING_PERCENT：value 为缓冲百分比（0~100）
     */
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      console.info(`bufferingUpdate, infoType: ${infoType}, value: ${value}, duration: ${this.duration}`)
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
