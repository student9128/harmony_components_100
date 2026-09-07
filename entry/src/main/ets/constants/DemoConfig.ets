export interface DemoItem {
  name: string
  title: string
  desc: string
}

export const DEMO_PATTERN_LOCK: DemoItem = {
  name: 'PatternLock',
  title: '九宫格图案解锁',
  desc: '四种样式 / 错误态整盘变红 / 路径缩略图 / 密码持久化'
}

export const DEMO_WEATHER_STICKY: DemoItem = {
  name: 'WeatherSticky',
  title: 'iOS 天气粘性卡片',
  desc: 'Scroll + header 钉住 + 内容收缩 + 下一张渐隐让位'
}

export const DEMO_VIDEO_PROGRESS: DemoItem = {
  name: 'VideoProgressBar',
  title: '视频进度条（带缓存进度）',
  desc: 'XComponent + AVPlayer + 自绘带缓存进度的进度条'
}

/** 列表渲染顺序（也是唯一的数据源） */
export const DEMO_LIST: DemoItem[] = [
  DEMO_PATTERN_LOCK,
  DEMO_WEATHER_STICKY,
  DEMO_VIDEO_PROGRESS
]
