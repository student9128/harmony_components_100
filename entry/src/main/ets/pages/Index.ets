import {
  DemoItem,
  DEMO_LIST,
  DEMO_PATTERN_LOCK,
  DEMO_WEATHER_STICKY,
  DEMO_VIDEO_PROGRESS
} from '../constants/DemoConfig'
import { PatternLockPage } from './PatternLockPage'
import { WeatherStickyDemo } from './WeatherStickyDemo'
import { VideoDemoPage } from './VideoDemoPage'

@Entry
@ComponentV2
struct Index {
  private pathStack: NavPathStack = new NavPathStack()

  @Builder
  pageMap(name: string): void {
    if (name === DEMO_PATTERN_LOCK.name) {
      NavDestination() {
        PatternLockPage()
      }
      .title(DEMO_PATTERN_LOCK.title)
    } else if (name === DEMO_WEATHER_STICKY.name) {
      NavDestination() {
        WeatherStickyDemo()
      }
      .title(DEMO_WEATHER_STICKY.title)
    } else if (name === DEMO_VIDEO_PROGRESS.name) {
      NavDestination() {
        VideoDemoPage()
      }
      .title(DEMO_VIDEO_PROGRESS.title)
    }
  }

  build() {
    Navigation(this.pathStack) {
      List({ space: 10 }) {
        ForEach(DEMO_LIST, (item: DemoItem) => {
          ListItem() {
            this.demoRow(item)
          }
          .onClick((): void => {
            this.pathStack.pushPath({ name: item.name })
          })
        }, (item: DemoItem) => item.name)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    }
    .title('组件 Demo')
    .mode(NavigationMode.Stack)
    .navDestination(this.pageMap)
  }

  @Builder
  demoRow(item: DemoItem): void {
    Column({ space: 4 }) {
      Row() {
        Text(item.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
        Text('›')
          .fontSize(18)
          .fontColor('#B0B0B0')
      }
      .width('100%')

      Text(item.desc)
        .fontSize(13)
        .fontColor('#8A8A8A')
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .borderRadius(12)
    .backgroundColor('#FFFFFF')
  }
}
