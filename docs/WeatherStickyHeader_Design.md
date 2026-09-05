# iOS 天气式粘性卡片滚动 设计文档

> 对应实现：`entry/src/main/ets/pages/WeatherStickyDemo.ets`
> （`StickySectionCard` 组件**内联在同一文件**，没有独立文件，别去 `widget/` 找）
> Demo：同文件 `@Entry WeatherStickyDemo`
> 版本：v1.0 —— `Scroll` + 卡片内 header `translate` 补偿（最终定稿版）

---

## 1. 目标效果

仿 iOS 天气 App 的「卡片堆叠收缩」滚动：

1. 手指上滑，卡片内容整体上移，越过视口顶的部分**被裁掉**（视觉收缩，布局高度不变）；
2. 每张卡片的标题（header）滚到视口顶后**钉住不动**；
3. 下一张卡片滑上来时，旧 header **同步渐隐让位**，不是被硬切；
4. 钉住条与屏幕顶之间留一条背景带（对标 iOS 效果），header **四角圆角始终完整**。

对应的 SwiftUI 参照实现（`kavsoft` 风格）：

```swift
LazyVStack(spacing: 15, pinnedViews: [.sectionHeaders]) {
    Section {
        // 内容行
    } header: {
        // 吸顶 Bar
    }
}
```

`pinnedViews: [.sectionHeaders]` 就是「header 滚到顶钉住」，**与本实现是同一个模型**。
差异仅在观感层：SwiftUI 那边额外用 `.visualEffect { }` 做了视差缩放 / 渐隐 / 下拉弹性，
属于可选加法（见 §9），不影响主干。

### 1.1 术语

| 术语 | 含义 |
|---|---|
| 视口容器 | 外层 `Column`，带 `padding({top: TOP_GAP})` + `clip(true)`，滚动内容只在这块里可见 |
| 视口顶 | **容器内容区顶部**＝屏幕顶往下 `TOP_GAP`（不是屏幕顶） |
| 内容 | `Scroll` 内唯一的 `Column`，包含所有卡片 + 底部空白 |
| `scrollY` | 内容已向上滚动的总距离（vp），整个效果的唯一驱动量 |
| `top` | 第 N 张卡片相对**内容原点**的静态顶部位置（布局后固定，不随滚动变） |

---

## 2. 整体结构

```
Stack
├── 天空渐变背景（Column + linearGradient）
└── Column（width/height 100%）
    ├── 固定标题「北京 / 32°」（不随滚动）
    └── Column   ← 视口容器：layoutWeight(1) + padding(top: TOP_GAP) + clip(true)
        └── Scroll(scroller)          ← 全部滚动由它完成
            └── Column                ← 内容：onAreaChange → contentH
                ├── StickySectionCard × 7
                └── Column().height(viewportH)   ← 底部空白
```

三个高度量：**必须按下面位置测，测错就出 BUG**

| 量 | 挂在哪 | 说明 |
|---|---|---|
| `viewportH` | `Scroll` **自身** | 不能挂视口容器——容器高含 `padding-top`，会偏大 `TOP_GAP`，导致 `maxOffset` 偏小、钉住位置偏移 |
| `contentH` | 内容 `Column` | 含 `padding-bottom` 与底部空白 |
| `maxOffset` | 计算属性 | `max(0, contentH - viewportH)` |

---

## 3. 核心机制

### 3.1 滚动：`Scroll` 原生负责，内容不做任何位移

```ts
Scroll(this.scroller) {
  Column() { /* 卡片们 + 底部空白 */ }
    .padding({ left: 12, right: 12, bottom: 24 })
    // ⚠️ 这里绝对不能出现 translate / offset
    .onAreaChange(...)
}
```

**内容 Column 上不允许再有任何 `translate` / `offset`**。
`Scroll` 自身已经完成了内容滚动，再手动上移一次 ⇒ 内容以 **2 倍速**上滚，
而 header 的补偿按 1 倍算 ⇒ 补偿永远差一半 ⇒ 表现就是「完全不钉住」。
（这是本方案踩过的最严重一次坑，详见 §6.7）

### 3.2 `scrollY`：双通道获取 + clamp

```ts
.onWillScroll((xOffset: number, yOffset: number): void => {
  // yOffset 是相对上一帧的增量（内容向上为正），只能累加
  this.scrollY = Math.min(this.maxOffset, Math.max(0, this.scrollY + yOffset))
})
.onScrollStop((): void => {
  // 停止时用总偏移校准，消除增量累加漂移
  this.scrollY = Math.min(this.maxOffset, Math.max(0, this.scroller.currentOffset().yOffset))
})
```

| 通道 | 时机 | 作用 |
|---|---|---|
| `onWillScroll` | 滚动发生**前**，每帧 | 实时跟手；提前一帧更新，header 与内容同帧渲染 |
| `onScrollStop` | 滚动停止 | 用 `currentOffset()` 绝对值**校准**，消除增量累加漂移 |

两者都过同一 clamp：`[0, maxOffset]`。

> `onWillScroll` 里**不能**读 `currentOffset()`——滚动尚未发生，读到的是旧值。

### 3.3 钉住：`sticky = max(0, -(top - scrollY))`

```ts
private get sticky(): number {
  return Math.max(0, -(this.top - this.scrollY))
}
// header
.translate({ y: this.sticky })
```

推导：header 的静态位置是卡片顶部 `top`。滚动 `scrollY` 后它在视口中的自然位置是
`top - scrollY`。

- `top - scrollY ≥ 0`：还没到顶 → `sticky = 0`，不补偿，header 随内容正常上移；
- `top - scrollY < 0`：已越过视口顶 → `sticky = scrollY - top`，正好把它**拉回视口顶**，
  于是视觉静止 ⇒ 钉住。

`header` 用 `translate` 而非 `offset`：translate **不参与布局**，
不会把卡片内容顶下去，也不会改变卡片高度。

### 3.4 渐隐：由「下一张顶部的位置」驱动

```ts
private get headerOpacity(): number {
  if (this.nextTop < 0) { return 1 }        // 最后一张，常显
  const nextTopRel: number = this.nextTop - this.scrollY
  return Math.min(1, Math.max(0, nextTopRel / HEADER_H))
}
```

关键在于这个公式**不是拍脑袋定的，它就是「未被下一张遮住的比例」**：

```
当前 header 占据视口区间 [0, HEADER_H]
下一张卡片主体顶边位置 = nextTopRel（相对视口顶）

nextTopRel ≥ HEADER_H  → 还没碰到 header 底边   → opacity = 1  完全显示
nextTopRel ↓           → 主体从下往上盖住 header  → opacity 线性下降
nextTopRel = 0         → 完全覆盖 header 区域     → opacity = 0  让位
```

所以「下一张盖上来」和「旧 header 消失」是**同一个量驱动的**，天然同步、无断档、无闪烁。

衔接检查：当前卡片内容滚完时，下一张顶部恰好距视口顶 `SECTION_GAP(12)`，
落进 `[0, HEADER_H]` 渐隐区间内 ⇒ 无需特殊处理即可无缝衔接。

### 3.5 底部空白：让最后一张也能钉到顶

```ts
Column().width('100%').height(this.viewportH)
```

垫在内容末尾，高度 = 一屏视口。
**没有它，滚到最后一张时 `Scroll` 到底了，但那张卡永远顶不到视口顶 ⇒ 永远钉不住。**

### 3.6 圆角融合：为什么 header 要垫一层不透明天空色

这是本效果**最容易穿帮**的一处，务必理解原理再改。

**问题**：header 与内容块用**同一个半透明色** `CARD_BG`（`#8C3A5A9E`，alpha ≈ 0.55）。
两者重叠时是**两层半透明叠加**，比周围深一截：

| 区域 | 合成结果 |
|---|---|
| 卡片主体（圆角缺口处） | `卡片色 ⊕ 天空色` = **X** |
| header 覆盖区（未处理） | `卡片色 ⊕ 卡片色 ⊕ 天空色` = **X′ ≠ X**（更深） |

- 未钉住时：header 在卡片顶部，那块深色看着像标题栏底色，**不违和**；
- 钉住后：`translate` 把它移到卡片中段，那块"更深的圆角"就变成一张**明显的圆角贴纸**。
  而它四周的卡片主体在中段是直角实心的，外层 `clip` 又裁不动内层内容，**圆角缺口必然透出内容**。

**解法**：让 header 覆盖区的合成色 **等于** 身旁卡片主体的合成色 X。
钉住时 header 固定停在**视口顶**，而天空渐变是静态全屏的 ⇒ 该处天空色是**定值** `S`。于是：

```
header 覆盖区 = 卡片色 ⊕ S（不透明垫层）  = X   ← 与身旁一致，且完全遮住内容文字
```

实现：header 包一层 `Stack`，底层垫不透明天空色，透明度由 `stickyProgress` 驱动：

```ts
Stack({ alignContent: Alignment.TopStart }) {
  Column()
    .backgroundColor(STICKY_SKY_BG)      // 不透明的视口顶天空色
    .borderRadius(CARD_RADIUS)
    .opacity(this.stickyProgress)        // 0 → 1
  Row() { Text(this.title) }
    .backgroundColor(CARD_BG)            // 半透明卡片色
    .borderRadius(CARD_RADIUS)
}
.opacity(this.headerOpacity)
.translate({ y: this.sticky })
```

| `sticky` | `stickyProgress` | header 外观 |
|---|---|---|
| 0（未钉住） | 0 | 半透明卡片色，与未滚动时一致 |
| 0 → 40 | 0 → 1 | 平滑过渡到不透明合成色 |
| ≥ 40（钉住） | 1 | 不透明，与视口顶卡片主体同色，圆角不可见 |

> 过渡区间取 `HEADER_H`（40）：刚好是 header 从卡片顶部「剥离」出来的那段距离，观感最自然。

**`STICKY_SKY_BG` 怎么来的**：`PAGE_TOP_BG → PAGE_BOTTOM_BG` 在视口顶（屏幕约 19% 处，
即状态栏 + 标题区 + `TOP_GAP`）的线性插值，得 `#6597DC`。
**改动天空渐变 / 顶部标题区高度 / `TOP_GAP` 后必须重算**，否则 header 会与卡片主体产生色差。

容错评估：屏幕高度不同导致的取值偏差，经卡片 alpha 稀释后通常 < 3/255，肉眼不可见。

### 3.7 `TOP_GAP` 与 `clip`：圆角与顶部背景带

```ts
Column() { Scroll(...) }
  .layoutWeight(1)
  .padding({ top: TOP_GAP })   // 12vp：把裁剪线下移，给钉住的 header 留顶部背景带
  .clip(true)                  // 裁掉超出视口的内容
```

header **始终保持四角圆角**（`borderRadius(CARD_RADIUS)` 写在 header 自身上）。
钉住时圆角缺口透出的是**顶部背景带**，而不是滚动内容——这是 iOS 观感的关键，
也是绕开「Scroll 裁剪 + 圆角不生效」这一 ArkUI 限制的办法（§6.4）。

---

## 4. 参数表

| 常量 | 值 | 说明 |
|---|---|---|
| `HEADER_H` | 40 | header 高度；同时是渐隐区间的分母 |
| `SECTION_GAP` | 12 | 卡片间距；同时决定渐隐衔接的起点 |
| `CARD_RADIUS` | 20 | 卡片与 header 圆角 |
| `CARD_BG` | `#8C3A5A9E` | 卡片背景（含 alpha） |
| `TOP_GAP` | 12 | 钉住条上方的背景带高度（= 视口容器 padding-top） |
| `STICKY_SKY_BG` | `#6597DC` | 视口顶的天空渐变色（不透明），header 钉住垫层用（§3.6） |
| `PAGE_TOP_BG` / `PAGE_BOTTOM_BG` | `#5B8FD9` / `#8FB8E8` | 天空渐变 |
| `DEBUG_LOG` | `false` | 调试日志开关（§7） |

`StickySectionCard` 入参：

| 参数 | 必填 | 说明 |
|---|---|---|
| `title` | ✓ | 标题 |
| `contentHeight` | ✓ | 卡片高度（**必须显式给**，见 §5 约束） |
| `top` | ✓ | 该卡片在内容中的静态顶部（`sectionTop(index)`） |
| `scrollY` | — | 当前滚动量，驱动 sticky 与 opacity |
| `nextTop` | — | 下一张的静态顶部；`-1` 表示最后一张（header 常显） |
| `content` | — | `@BuilderParam` 卡片内容 |

---

## 5. 机制约束（改之前必须知道）

1. **卡片高度必须外部传入，内容不能自适应**。
   header 用 `translate` 脱离了布局流，外层 `Stack` 的高度必须由 `contentHeight` 显式给定；
   `content` 内容超出会溢出，不会被撑开。

2. **`top` / `nextTop` 是静态值**，由 `sectionTop(index)` 在构建时按
   `contentHeight + SECTION_GAP` 累加得出，不依赖测量、不随滚动变。
   若改为动态高度（内容自适应），这两个值必须改成实测，否则钉住位置全错。

3. **卡片之间不能有其他可变高度元素插在中间**，否则 `sectionTop()` 的累加值失效。
   新增区块必须同时更新 `SECTIONS` 数组与 `build()` 里的组件调用（目前是手写展开，非 `ForEach`）。

---

## 6. 踩坑记录（务必勿重蹈）

### 6.1 `onScroll` 的 `yOffset` 是帧间增量，不是总偏移

且 **API 12 起已废弃**。总偏移要用 `Scroller.currentOffset()`。

### 6.2 `onDidScroll` 驱动 translate 必然抖动

`onDidScroll` 在滚动**之后**触发，状态更新再驱动 `translate` 补偿 ⇒ 永远比原生滚动慢一帧。
必须用 `onWillScroll` 提前一帧 + `onScrollStop` 校准。

### 6.3 自定义组件属性名不能与通用属性重名

`offset`、`onDragStart` 等都会编译报错（与 `CommonAttribute` 冲突）。

### 6.4 `Scroll` / `Stack` 的 `clip` + `borderRadius` 对滚动内容不生效

指望用它裁剪出圆角列表是行不通的，还会切掉 `translate` 补偿出来的 header 自身，
造成「突出一块」的直角/缺口。
**正解：header 自身保持四角圆角 + 顶部留背景带（§3.7）。**

### 6.5 `backgroundBlurStyle` 材质不受父容器裁剪约束

颜色档位也不可控，深色场景慎用。

### 6.6 `List.sticky(StickyStyle.Header)` 是「顶替」模型，不是本效果

它是「下一个 header 顶替上一个」，没有 content 收缩，与 iOS 的叠层 + 渐隐不符，
叠加渐隐后观感混乱。已弃用该方案。

### 6.7 ⚠️ 内容 Column 上多写一行 `translate` ⇒ 整个效果失效（曾发生）

```ts
Column() { /* 内容 */ }
  .translate({ y: -this.scrollY })   // ❌ 致命
```

`Scroll` 已经在滚动内容，再手动上移一次 ⇒ 内容 **2 倍速**上滚，
header 补偿只按 1 倍 ⇒ 补偿差一半 ⇒ 表现为「什么都不对、完全不钉住」。

这行是从早期「Column + PanGesture 自绘滚动」版本回退时**残留**下来的。
自绘版需要它（因为没有 `Scroll`），`Scroll` 版有它就是毒药。

### 6.8 ⚠️ 同色半透明叠加 ⇒ 圆角贴纸（曾发生）

header 与内容块用同一个半透明 `CARD_BG`，重叠区会深一截；钉住后这块更深的圆角
移到卡片中段，外部 `clip` 又裁不动内层内容 ⇒ 圆角缺口透出内容，像贴了张圆角贴纸。
**直角时看不出来，圆角必现。**

解法不是去裁内容（做不到），而是垫一层不透明天空色让合成色对齐（§3.6）。

> 备选（未采用）：把 `CARD_BG` 改成不透明，header 同色 —— 一劳永逸且绝对无缝，
> 代价是卡片不再透出天空渐变，失去 iOS 半透明质感。

### 6.9 `viewportH` 测错位置会引入偏移

挂在视口容器上会带入 `padding-top`（偏大 `TOP_GAP`）⇒ `maxOffset` 偏小
⇒ 滚到底时 `scrollY` 被 clamp 得偏小 ⇒ 钉住位置偏移。
**必须挂在 `Scroll` 自身**（§2 表格）。

---

## 7. 调试开关

文件头 `const DEBUG_LOG = false`。打开后：

- `StickySectionCard` 的 `@Monitor('scrollY')` 逐张打印
  `scrollY / sticky / nextTopRel / opacity`；
- 页面 `logPosition()` 打印三张卡的 opacity；
- `logLayout()` 打印 `viewport / content / maxOffset`。

> **评估流畅度前必须关掉**——每帧 `console.info` 本身就会造成掉帧，会误导性能判断。

---

## 8. 改动后的回归自检清单

动过这个文件、或效果异常时，按序核对：

- [ ] 内容 `Column` 上没有 `translate` / `offset`（§6.7）
- [ ] `viewportH` 挂 `Scroll`，`contentH` 挂内容 `Column`（§6.8）
- [ ] `scrollY` 只在 `onWillScroll` / `onScrollStop` 里更新，且过 `[0, maxOffset]` clamp
- [ ] 底部空白高度 = `viewportH`（§3.5）
- [ ] 视口容器有 `clip(true)`，且 `padding({top: TOP_GAP})` 与 `TOP_GAP` 常量一致
- [ ] header 自身带 `borderRadius(CARD_RADIUS)`，没有依赖父容器裁剪（§6.4）
- [ ] 钉住后 header 是**不透明**的（垫层 `stickyProgress = 1`），圆角缺口不露出内容（§3.6）
- [ ] 若改过天空渐变 / 标题区高度 / `TOP_GAP`：`STICKY_SKY_BG` 已重算（§3.6）
- [ ] 新增区块：`SECTIONS` 数组 + `build()` 组件调用**两处都改**，且 `nextTop` 正确
      （最后一张传 `-1`）
- [ ] `DEBUG_LOG = false`

验证动作：

1. 慢滑：第一张标题顶到视口顶后应**纹丝不动**，下方内容继续穿过；
2. 继续滑：下一张盖上来时旧标题**平滑淡出**，不是突然消失；
3. 滑到底：最后一张标题也能钉住；
4. 钉住时：header 四角圆角完整，上方 `TOP_GAP` 区域是天空背景，没有滚动内容露出；
5. 钉住时：header 与卡片主体**看不出色差**，四角圆角不像贴纸，
   内容文字被完全遮住而不是隐约透出（§3.6）。

---

## 9. 可选增强（未实现，纯加法）

对标 SwiftUI 的 `.visualEffect { }` 层，可在不改动主干的前提下叠加：

| 效果 | 做法 | 风险 |
|---|---|---|
| 下拉弹性视差 | 顶部标题区按负 `scrollY` 放大 `scale` | 低；需处理 `scrollY < 0` |
| 内容视差收缩 | 卡片内容按 `sticky` 做轻微 `scale(1 - progress*0.3)` | 中；会改变内容视觉尺寸，需重调 `contentHeight` 观感 |
| 标题渐隐 | 顶部固定标题按 `scrollY` 淡出 | 低 |

**前提是钉住主干先验证通过**，这几项任何时候加都不会动摇 §3 的机制。
