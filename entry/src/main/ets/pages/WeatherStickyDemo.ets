import { componentUtils } from '@kit.ArkUI'

/**
 * 仿 iOS 天气 App 式「粘性卡片堆叠收缩」滚动效果
 *
 * 【实现方式：Scroll + 卡片内 header translate 补偿（最终回退定稿版）】
 * 每张卡片（StickySectionCard）= content 随滚动上移 + header 用 translate({y: sticky}) 补偿钉住：
 *   - 偏移量在 onWillScroll（滚动【前】）里累加帧间增量，header 与内容基本同帧渲染，不抖；
 *   - 滚出视口顶的内容被 Scroll 天然裁掉（视觉收缩），布局高度不变；
 *   - 渐隐由「下一张卡片的顶部分数」驱动：叠加时才让位，无断档；
 *   - 钉住位置下移 TOP_GAP(12vp)：header 始终保持四角圆角，
 *     圆角缺口透出的是顶部背景带而不是滚动内容。
 *
 * 【踩坑记录（勿重蹈）】
 * 1. Scroll.onScroll 的 yOffset 是「相对上一帧」的增量，不是总偏移量，且 API 12 起已废弃；
 *    总偏移要用 Scroller.currentOffset()。
 * 2. onDidScroll 更新状态再驱动 translate 补偿，永远比原生滚动慢一帧 → 抖动；
 *    必须用 onWillScroll 提前一帧更新 + onScrollStop 校准。
 * 3. 自定义组件的属性名不能与通用属性重名（offset、onDragStart 都会编译报错）。
 * 4. Scroll / Stack 的 clip+borderRadius 对 Scroll 内的滚动内容圆角裁剪不生效，
 *    且会切掉 translate 补偿的 header 自己 → "突出一块"的直角/缺口都源于此；
 *    header 始终保持四角圆角 + 顶部留背景带，才是正解。
 * 5. backgroundBlurStyle 材质不受父容器裁剪约束，且颜色档位不可控，深色场景慎用。
 * 6. List 的 .sticky(StickyStyle.Header) 是「下一个 header 顶替上一个」的模型，
 *    没有 content 收缩效果，与 iOS 的叠层+渐隐不符，且与渐隐叠加时观感混乱。
 * 7. 内容 Column 上【绝不能】再加 translate({y: -scrollY})：Scroll 已在滚动内容，
 *    再上移一次会让内容 2 倍速上滚，而 header 补偿只按 1 倍算 → 完全不钉住。
 *
 * 完整设计说明与踩坑记录：docs/WeatherStickyHeader_Design.md
 */

const HEADER_H = 40
const SECTION_GAP = 12
const CARD_RADIUS = 20
const CARD_BG = '#8C3A5A9E'
/** 钉住的 header 距视口顶的间隙：顶部留背景色带，保证 header 四角圆角完整可见 */
const TOP_GAP = 12
const PAGE_TOP_BG = '#5B8FD9'
const PAGE_BOTTOM_BG = '#8FB8E8'
/**
 * 视口顶所在位置的天空渐变色（不透明）。
 * header 钉住后垫这一层，使它的合成色 = 卡片色 ⊕ 视口顶天空色，
 * 与身旁卡片主体的合成色完全相同 → 四角圆角不再透出"更深的一层"。
 * 取值 = PAGE_TOP_BG→PAGE_BOTTOM_BG 在视口顶（屏幕约 19% 处）的插值。
 * ⚠️ 改动天空渐变 / 顶部标题区高度 / TOP_GAP 后需重算此值。
 */
const STICKY_SKY_BG = '#6597DC'
/** 调试开关：打开后滚动时打印 header 状态，评估流畅度时必须关闭 */
const DEBUG_LOG = false

interface HourItem {
  label: string
  temp: string
}

interface DayItem {
  day: string
  low: number
  high: number
}

interface StickySection {
  title: string
  contentHeight: number
}

const HOURS: HourItem[] = [
  { label: '现在', temp: '32°' },
  { label: '17时', temp: '32°' },
  { label: '18时', temp: '30°' },
  { label: '18:41', temp: '日落' },
  { label: '19时', temp: '28°' },
  { label: '20时', temp: '27°' },
]

const DAYS: DayItem[] = [
  { day: '今天', low: 17, high: 33 },
  { day: '周六', low: 21, high: 32 },
  { day: '周日', low: 21, high: 30 },
  { day: '周一', low: 20, high: 29 },
  { day: '周二', low: 17, high: 20 },
  { day: '周三', low: 18, high: 26 },
  { day: '周四', low: 19, high: 28 },
  { day: '周五', low: 20, high: 31 },
  { day: '周六', low: 21, high: 32 },
  { day: '周日', low: 22, high: 33 },
  { day: '周一', low: 21, high: 29 },
  { day: '周二', low: 19, high: 27 },
  { day: '周三', low: 18, high: 25 },
  { day: '周四', low: 17, high: 26 },
  { day: '周五', low: 18, high: 28 },
  { day: '周六', low: 19, high: 30 },
  { day: '周日', low: 20, high: 31 },
  { day: '周一', low: 21, high: 30 },
  { day: '周二', low: 20, high: 28 },
  { day: '周三', low: 19, high: 27 },
]

const SECTIONS: StickySection[] = [
  { title: '空气质量', contentHeight: 180 },
  { title: '每小时天气预报', contentHeight: 215 },
  { title: '20日天气预报', contentHeight: 950 },
  { title: '紫外线指数', contentHeight: 170 },
  { title: '风', contentHeight: 170 },
  { title: '降水与湿度', contentHeight: 215 },
  { title: '日出日落', contentHeight: 170 },
]

/**
 * 单张卡片：content 随滚动上移（滚出视口顶的部分被 Scroll 裁掉 → 视觉收缩），
 * header 用 translate({y: sticky}) 补偿钉住。
 */
@ComponentV2
struct StickySectionCard {
  @Param @Require title: string
  @Param @Require contentHeight: number
  /** 卡片在内容中的静态顶部位置（布局后固定） */
  @Param @Require top: number
  @Param scrollY: number = 0
  /** 下一张卡片的静态顶部位置；-1 表示最后一张（header 常显） */
  @Param nextTop: number = -1
  @BuilderParam content: () => void = EmptyContent

  /** 钉住量：header 下移多少能钉在视口顶 */
  private get sticky(): number {
    return Math.max(0, -(this.top - this.scrollY))
  }

  /**
   * 钉住进度 0→1（钉住后 HEADER_H 距离内完成过渡）。
   * 驱动「不透明天空垫层」的透明度：0 时 header 是半透明卡片色（与未滚动时一致），
   * 1 时 header 变成不透明的合成色，与视口顶的卡片主体同色，并把内容完全遮住。
   */
  private get stickyProgress(): number {
    return Math.min(1, this.sticky / HEADER_H)
  }

  /**
   * 抬头透明度：下一张卡片顶部分数从 HEADER_H 降到 0（叠加覆盖的过程）→ 1 → 0。
   * content 滚完时下一张顶部恰好距视口顶 SECTION_GAP，正好落进渐隐区间，无缝衔接。
   */
  private get headerOpacity(): number {
    if (this.nextTop < 0) {
      return 1
    }
    const nextTopRel: number = this.nextTop - this.scrollY
    return Math.min(1, Math.max(0, nextTopRel / HEADER_H))
  }

  @Monitor('scrollY')
  onOffsetChange(): void {
    if (!DEBUG_LOG) {
      return
    }
    console.info(
      `weather== [${this.title}] scrollY=${this.scrollY.toFixed(1)} sticky=${this.sticky.toFixed(1)}` +
      ` nextTopRel=${(this.nextTop - this.scrollY).toFixed(1)} opacity=${this.headerOpacity.toFixed(2)}`
    )
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 内容块：自带卡片背景，随滚动上移，越出视口顶的部分被 Scroll 裁掉
      Column() {
        this.content()
      }
      .width('100%')
      .padding({ top: HEADER_H + 8, left: 16, right: 16, bottom: 16 })
      .backgroundColor(CARD_BG)
      .borderRadius(CARD_RADIUS)

      // 抬头：四角始终保持圆角；钉住后透出的是顶部背景带（TOP_GAP），不会露出缺口
      Stack({ alignContent: Alignment.TopStart }) {
        // 钉住垫层：不透明的「视口顶天空色」。
        // 没有它时，header 的半透明卡片色叠在内容块的半透明卡片色上会深一截，
        // 钉住后这块更深的圆角移到卡片中段 → 明显的圆角贴纸。
        // 垫上它之后：header 合成色 = 卡片色 ⊕ 视口顶天空色 = 身旁卡片主体的合成色，
        // 四角圆角视觉上消失，同时内容被完全遮住（不会隐约透出文字）。
        Column()
          .width('100%')
          .height(HEADER_H)
          .backgroundColor(STICKY_SKY_BG)
          .borderRadius(CARD_RADIUS)
          .opacity(this.stickyProgress)

        Row() {
          Text(this.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#D9E7FF')
        }
        .width('100%')
        .height(HEADER_H)
        .padding({ left: 16, right: 16 })
        .backgroundColor(CARD_BG)
        .borderRadius(CARD_RADIUS)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(HEADER_H)
      .opacity(this.headerOpacity)
      .translate({ y: this.sticky })
    }
    .width('100%')
    .height(this.contentHeight)
    .margin({ bottom: SECTION_GAP })
  }
}

@Builder
function EmptyContent(): void {
}

@ComponentV2
export struct WeatherStickyDemo {
  /** 当前滚动总偏移量（vp） */
  @Local scrollY: number = 0
  @Local viewportH: number = 0
  @Local contentH: number = 0
  private scroller: Scroller = new Scroller()

  private get maxOffset(): number {
    return Math.max(0, this.contentH - this.viewportH)
  }

  private logLayout(): void {
    if (!DEBUG_LOG) {
      return
    }
    console.info(
      `weather== layout viewport=${Math.round(this.viewportH)} content=${Math.round(this.contentH)}` +
      ` maxOffset=${Math.round(this.maxOffset)}`
    )
  }

  /** 第 index 个区块的静态顶部位置（header 的顶部，不含滚动偏移） */
  private sectionTop(index: number): number {
    let top: number = 0
    for (let i = 0; i < index; i++) {
      top += SECTIONS[i].contentHeight + SECTION_GAP
    }
    return top
  }

  /** 第 index 个 header 的吸顶量：区块顶滚过视口顶之后为正 */
  private stickyOf(index: number): number {
    return Math.max(0, -(this.sectionTop(index) - this.scrollY))
  }

  /**
   * header 透明度：由「下一个 header 的顶替位置」驱动——
   * 下一区块顶部从 HEADER_H 降到 0（header 顶替叠加的过程）→ 1 → 0。
   * 最后一个 header 常显。
   */
  private headerOpacity(index: number): number {
    if (index >= SECTIONS.length - 1) {
      return 1
    }
    const nextTopRel: number = this.sectionTop(index + 1) - this.scrollY
    return Math.min(1, Math.max(0, nextTopRel / HEADER_H))
  }

  build() {
    Stack() {
      // 天空背景
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[PAGE_TOP_BG, 0], [PAGE_BOTTOM_BG, 1]]
        })

      Column() {
        // 固定标题（不随滚动）
        Column({ space: 4 }) {
          Text('北京')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          Text('32° | 大部晴朗')
            .fontSize(16)
            .fontColor('#E6FFFFFF')
        }
        .width('100%')
        .padding({ top: 12, bottom: 16 })

        // 视口容器：padding-top(TOP_GAP) 把滚动内容的裁剪线下移，
        // 给钉住的 header（含四角圆角）留出顶部背景带
        Column() {
          Scroll(this.scroller) {
            Column() {
              StickySectionCard({
                title: SECTIONS[0].title,
                contentHeight: SECTIONS[0].contentHeight,
                top: this.sectionTop(0),
                scrollY: this.scrollY,
                nextTop: this.sectionTop(1),
                content: this.airQualityContent
              })
              StickySectionCard({
                title: SECTIONS[1].title,
                contentHeight: SECTIONS[1].contentHeight,
                top: this.sectionTop(1),
                scrollY: this.scrollY,
                nextTop: this.sectionTop(2),
                content: this.hourlyContent
              })
              StickySectionCard({
                title: SECTIONS[2].title,
                contentHeight: SECTIONS[2].contentHeight,
                top: this.sectionTop(2),
                scrollY: this.scrollY,
                nextTop: this.sectionTop(3),
                content: this.dailyContent
              })
              StickySectionCard({
                title: SECTIONS[3].title,
                contentHeight: SECTIONS[3].contentHeight,
                top: this.sectionTop(3),
                scrollY: this.scrollY,
                nextTop: this.sectionTop(4),
                content: this.uvContent
              })
              StickySectionCard({
                title: SECTIONS[4].title,
                contentHeight: SECTIONS[4].contentHeight,
                top: this.sectionTop(4),
                scrollY: this.scrollY,
                nextTop: this.sectionTop(5),
                content: this.windContent
              })
              StickySectionCard({
                title: SECTIONS[5].title,
                contentHeight: SECTIONS[5].contentHeight,
                top: this.sectionTop(5),
                scrollY: this.scrollY,
                nextTop: this.sectionTop(6),
                content: this.precipContent
              })
              StickySectionCard({
                title: SECTIONS[6].title,
                contentHeight: SECTIONS[6].contentHeight,
                top: this.sectionTop(6),
                scrollY: this.scrollY,
                nextTop: -1, // 最后一张：没有下一张，header 常显
                content: this.sunContent
              })
              // 底部补一屏空白：没有它，最后一张卡片滚不到顶，也就永远钉不住
              Column()
                .width('100%')
                .height(this.viewportH)
            }
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 24 })
            // 注意：这里【不能】再加 translate({y: -scrollY})！
            // Scroll 自身已经在滚动内容，再手动上移一次会让内容以 2 倍速上滚，
            // 而 header 的 sticky 补偿只按 1 倍算 → 补偿差一半，看着就是完全不钉住
            .onAreaChange((oldValue: Area, newValue: Area) => {
              this.contentH = newValue.height as number
              this.logLayout()
            })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
          // 滚动发生【前】更新：onDidScroll 晚一帧会让 header 抖动
          .onWillScroll((xOffset: number, yOffset: number): void => {
            // yOffset 是相对上一帧的增量（内容向上为正），只能累加；
            // 不能读 currentOffset()——滚动尚未发生，读到的是旧值
            this.scrollY = Math.min(this.maxOffset, Math.max(0, this.scrollY + yOffset))
            this.logPosition()
          })
          .onScrollStop((): void => {
            // 停止时用准确的总偏移量校准，消除增量累加的漂移
            try {
              this.scrollY = Math.min(this.maxOffset,
                Math.max(0, this.scroller.currentOffset().yOffset))
            } catch (error) {
              console.error('weather== currentOffset 获取失败')
            }
          })
          // 视口高度在 Scroll 自身上测（容器高含 padding，会偏大 TOP_GAP）
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.viewportH = newValue.height as number
            this.logLayout()
          })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: TOP_GAP })
        .clip(true)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  private logPosition(): void {
    if (!DEBUG_LOG) {
      return
    }
    console.info(
      `weather== scrollY=${this.scrollY.toFixed(1)}` +
      ` op0=${this.headerOpacity(0).toFixed(2)} op1=${this.headerOpacity(1).toFixed(2)}` +
      ` op2=${this.headerOpacity(2).toFixed(2)}`
    )
  }

  @Builder
  airQualityContent() {
    Text('84 - 良')
      .fontSize(22)
      .fontWeight(FontWeight.Bold)
      .fontColor(Color.White)
    Row()
      .width('100%')
      .height(6)
      .borderRadius(3)
      .linearGradient({
        angle: 90,
        colors: [['#4CD964', 0], ['#FFCC00', 0.3], ['#FF3B30', 0.75], ['#8E1717', 1]]
      })
      .margin({ top: 10, bottom: 10 })
    Text('当前 AQI (CN) 为 84。')
      .fontSize(15)
      .fontColor(Color.White)
  }

  @Builder
  hourlyContent() {
    Text('未来数小时内以晴为主，气温 27°~32°。')
      .fontSize(14)
      .fontColor('#DCE9FF')
      .margin({ bottom: 10 })
    Row() {
      ForEach(HOURS, (item: HourItem) => {
        Column({ space: 8 }) {
          Text(item.label)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
          Circle()
            .width(28)
            .height(28)
            .fill('#CCE0FF')
          Text(item.temp)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
        }
        .layoutWeight(1)
      }, (item: HourItem) => item.label)
    }
    .width('100%')
  }

  @Builder
  dailyContent() {
    Column() {
      ForEach(DAYS, (item: DayItem) => {
        Row({ space: 10 }) {
          Text(item.day)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .width(52)
          Circle()
            .width(24)
            .height(24)
            .fill('#CCE0FF')
          Text(`${item.low}°`)
            .fontSize(16)
            .fontColor('#BFD4F2')
            .width(40)
          Row()
            .layoutWeight(1)
            .height(5)
            .borderRadius(3)
            .linearGradient({
              angle: 90,
              colors: [['#FFD60A', 0], ['#FF9F0A', 0.6], ['#FF453A', 1]]
            })
          Text(`${item.high}°`)
            .fontSize(16)
            .fontColor(Color.White)
            .width(40)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .height(44)
      }, (item: DayItem, index: number) => index.toString()) // 日期名会重复，key 用索引
    }
    .width('100%')
  }

  @Builder
  uvContent() {
    Text('7 - 高')
      .fontSize(22)
      .fontWeight(FontWeight.Bold)
      .fontColor(Color.White)
    Row()
      .width('100%')
      .height(6)
      .borderRadius(3)
      .margin({ top: 10, bottom: 10 })
      .linearGradient({
        angle: 90,
        colors: [['#4CD964', 0], ['#FFCC00', 0.35], ['#FF9500', 0.65], ['#FF453A', 1]]
      })
    Text('10 点至 16 点请尽量在阴凉处活动，注意防晒。')
      .fontSize(14)
      .fontColor('#DCE9FF')
  }

  @Builder
  windContent() {
    Row({ space: 16 }) {
      Column({ space: 4 }) {
        Text('东南风')
          .fontSize(16)
          .fontColor(Color.White)
        Text('3 级')
          .fontSize(13)
          .fontColor('#BFD4F2')
      }
      Column({ space: 4 }) {
        Text('阵风')
          .fontSize(16)
          .fontColor(Color.White)
        Text('21 km/h')
          .fontSize(13)
          .fontColor('#BFD4F2')
      }
      Column({ space: 4 }) {
        Text('气压')
          .fontSize(16)
          .fontColor(Color.White)
        Text('1008 hPa')
          .fontSize(13)
          .fontColor('#BFD4F2')
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .margin({ bottom: 12 })
    Text('未来 1 小时风力平稳，平均风速 12 km/h。')
      .fontSize(14)
      .fontColor('#DCE9FF')
  }

  @Builder
  precipContent() {
    Row({ space: 16 }) {
      Column({ space: 4 }) {
        Text('降水')
          .fontSize(15)
          .fontColor('#BFD4F2')
        Text('0 毫米')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      Column({ space: 4 }) {
        Text('湿度')
          .fontSize(15)
          .fontColor('#BFD4F2')
        Text('45%')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      Column({ space: 4 }) {
        Text('能见度')
          .fontSize(15)
          .fontColor('#BFD4F2')
        Text('16 公里')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .margin({ bottom: 12 })
    Row()
      .width('100%')
      .height(6)
      .borderRadius(3)
      .linearGradient({
        angle: 90,
        colors: [['#3A82F6', 0], ['#38BDF8', 1]]
      })
      .margin({ bottom: 10 })
    Text('未来一小时无明显降水，天气以多云间晴为主。')
      .fontSize(14)
      .fontColor('#DCE9FF')
  }

  @Builder
  sunContent() {
    Row({ space: 16 }) {
      Column({ space: 4 }) {
        Text('日出')
          .fontSize(15)
          .fontColor('#BFD4F2')
        Text('05:12')
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      Column({ space: 4 }) {
        Text('日落')
          .fontSize(15)
          .fontColor('#BFD4F2')
        Text('18:41')
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      Column({ space: 4 }) {
        Text('日照时长')
          .fontSize(15)
          .fontColor('#BFD4F2')
        Text('13 时 29 分')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .margin({ bottom: 12 })
    Text('日落时间比昨天晚 1 分钟。')
      .fontSize(14)
      .fontColor('#DCE9FF')
  }
}
