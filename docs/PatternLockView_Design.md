# PatternLockView 设计文档

> 对应实现：`entry/src/main/ets/widget/PatternLockView.ets`
> Demo：`entry/src/main/ets/pages/PatternLockPage.ets`
> 版本：v1.0（含 `@Monitor` 重绘修复）

---

## 1. 背景与目标

### 1.1 为什么不用官方 `PatternLock`

| 诉求 | 官方 `PatternLock` | 结论 |
|---|---|---|
| 圆环 + 圆点 + 连线带方向箭头 | 不支持 | ✗ |
| 水波纹光晕 | 不支持 | ✗ |
| 经典圆环 + 圆点 | 支持（固定样式） | 部分 |
| 官方圆点粗线样式 | 支持（即默认样式） | ✓ |
| 顶部路径缩略图 | 不支持 | ✗ |
| 圆点 / 圆环尺寸自定义 | 仅 `circleRadius` 一个维度 | 受限 |
| 圆环与圆点可分开设置大小 | 不支持 | ✗ |
| 错误态整盘变红（含未选中点、缩略图） | 仅路径变色 | ✗ |
| 拿到路径后自行比对 / 持久化 | 只给 pattern，样式不可控 | 受限 |

结论：官方组件把"绘制"和"外观"绑死，只能整体替换。本组件把**几何计算 + 绘制**全部收到自己手里，外观全部参数化。

### 1.2 设计目标

1. **四种样式**：`ARROW`（箭头）/ `RIPPLE`（水波纹）/ `RING`（圆环+圆点）/ `DOT`（官方风格）。
2. **全部可配**：圆点半径、圆环半径、圆环线宽、连线宽度、四种颜色。
3. **错误态**：整盘（含缩略图、含未选中点）统一变红。
4. **缩略图**：顶部实时回显当前路径，可选开关。
5. **记住路径**：抬手回传完整索引序列，供外部保存/比对。

### 1.3 非目标（明确不做，交给业务层）

- **不持久化**：组件不碰 preferences / 数据库。存明文还是密文、存本地还是服务端，是业务决策。
- **不判定最少点数**：`MIN_POINTS` 是业务规则（demo 里定 4），组件只报路径长度。
- **不做重试次数 / 锁定 / 生物识别兜底**：属于解锁流程编排，不属于绘制控件。

> 这条边界是刻意的：组件只负责"把用户划的路径准确、好看地画出来并交出去"。

---

## 2. 技术选型

### 2.1 绘制方式：Canvas 命令式，而非声明式组件堆叠

另一种做法是 9 个 `Stack` 圆 + 若干 `Path` 连线叠出来。没选它的原因：

| 维度 | 声明式堆叠 | Canvas 命令式（采用） |
|---|---|---|
| 连线 | 每条线一个 `Path`，角度/长度要算 commands 字符串 | `moveTo/lineTo` 直接画 |
| 箭头 | 几乎无法优雅实现 | 三角函数几行 |
| 水波纹 | 需要额外 2 层圆组件 × 选中数量 | 两个 `arc` + `globalAlpha` |
| 半透明叠加、层级顺序 | 依赖声明顺序，改顺序要重构 | 代码顺序即绘制顺序 |
| 手指跟随的"半条线" | 每次移动都要重建组件 | 每帧 `clearRect` + 重画，成本恒定 |

Canvas 的代价是**放弃了 UI 自动刷新**（见 §6），换来绘制自由度，对本组件是划算的。

### 2.2 状态管理：V2，但内部状态刻意"非响应式"

| 数据 | 装饰器 | 理由 |
|---|---|---|
| `style` / 尺寸 / 颜色等 12 个外观参数 | `@Param` | 外部输入，单向 |
| `onPatternComplete` | `@Event` | V2 中函数入参只能用 `@Event`（`@Param` 不支持函数类型） |
| `controller` | `@Require @Param` | 必传，外部控制句柄 |
| `selected` / `drawing` / `isError` / `fingerX` / `fingerY` | **普通私有字段** | 唯一消费者是 Canvas 像素，不是声明式 UI |

最后一行是核心设计决策：`selected` 变化后**没有任何声明式 UI 需要重组**，只需要 `clearRect` 重画。用 `@Local` 只会带来无意义的 diff 开销，还会让人误以为"改数组 UI 就会更新"。所以内部统一走 **改状态 → 手动 `redrawAll()`** 的命令式闭环。

---

## 3. 几何模型

### 3.1 点索引与坐标

索引 **行优先**：`0 1 2 / 3 4 5 / 6 7 8`。

```
cell = size / 3
center(i) = ( cell * (i % 3 + 0.5),  cell * (floor(i / 3) + 0.5) )
```

所有几何都通过 `center(i, size)` 取得，**绘制、命中、缩略图共用同一个函数、同一套坐标系**，缩略图只是把 `size` 换成 `thumbnailSize`。

### 3.2 统一缩放因子

```
k = size / sideLength        // 主画布 k = 1，缩略图 k = thumbnailSize / sideLength
dotR  = dotRadius * k
ringR = ringRadius * k
lineW = lineWidth * k
```

好处：**调一个 `sideLength`，整套尺寸等比缩放**；缩略图无需另写一套参数。

### 3.3 命中判定

```
hitRadius = (sideLength / 3) * 0.45
命中 ⟺ (x - cx)² + (y - cy)² ≤ hitRadius²
```

取格子边长的 0.45（略小于半个格子 0.5），保证相邻命中区不重叠、又不至于难点。这是**唯一影响手感的参数**，真机觉得太灵敏/太迟钝就调这个系数。

### 3.4 穿越激活（划线经过中间点自动带上）

从最后一个选中点 `A` 到当前手指 `F` 的线段，若某个未选中点 `P` 到该线段的距离 ≤ `dotRadius + 4`，则把 `P` 补进路径（例如 0 直接划到 2，自动带上 1）。

点到线段距离用标准投影公式（`t` clamp 到 `[0,1]` 后求距离）。

**为什么只检查一次**：3×3 的点阵里，任意两点的连线上最多只穿过 **1 个**其它点（0→8 穿 4，0→2 穿 1，没有穿两个的情况），所以不需要递归/按距离排序反复扫描。

### 3.5 箭头几何（ARROW）

```
len   = 9 * k                       // 箭头翼长
mid   = 线段中点
angle = atan2(y2-y1, x2-x1)         // 线段方向
两翼   = mid 反向偏转 ±30°（-π/6、+π/6）
```

箭头**只画在已选点之间的线段上**，不画在"最后一个点 → 手指"的跟随段上（那段还在变，画了会抖）。抬手后跟随段转正，箭头自然出现。

### 3.6 水波纹（RIPPLE）

选中点由内向外三层：

| 层 | 半径 | alpha |
|---|---|---|
| 涟漪外圈 | `ringR * 1.25` | 0.15 |
| 涟漪内圈 | `ringR * 0.75` | 0.30 |
| 实心圆点 | `dotR` | 1.0 |

选中时**不画圆环**（RIPPLE 是唯一跳过圆环的样式），靠两层半透明圆表现"被按下"。

---

## 4. 绘制管线

### 4.1 三阶段顺序（不可调换）

```
drawGrid(ctx, size, points, error, drawingFinger, fingerX, fingerY)
  ① 连线：所有已选点依次 lineTo；drawingFinger 时最后再 lineTo(手指 × k)
  ② 箭头：仅 ARROW 样式，遍历 points[i] → points[i+1]
  ③ 九个点：每个点按样式画（环 / 涟漪 / 实心点）
```

**先画线再画点**：连线两端是圆心，如果先画点后画线，线的圆头会盖在点上；先画线则点自然压在线上，视觉干净。

### 4.2 四种样式绘制矩阵

| 样式 | 未选中 | 选中 | 连线 | 箭头 | 延伸段 |
|---|---|---|---|---|---|
| `ARROW` | 圆环 | 圆环 + 实心点 | 有 | 有 | 有 |
| `RIPPLE` | 圆环 | 实心点 + 两层涟漪（不画环） | 有 | 无 | 有 |
| `RING` | 圆环 | 圆环 + 实心点 | 有 | 无 | 有 |
| `DOT` | 实心小点 `dotRadius` | 实心大点 `dotRadius × activeScale` | 有（建议加粗） | 无 | 有 |

### 4.3 颜色裁决（优先级从高到低）

```
1. isError == true        → 所有元素（含未选中点、缩略图）= errorColor
2. 连线单独指定 lineColor → 用 lineColor
3. 其余                   → 未选中 normalColor / 选中 activeColor
```

`lineColor` 为**空串**时回落 `activeColor`（默认行为），这样"只改一个主色"就能换肤。

---

## 5. 交互状态机

### 5.1 触摸事件

| 事件 | 行为 |
|---|---|
| `Down` | 若处于错误态 → 立即清红并清空路径；命中点则 `drawing = true`、`selected = [idx]`，手指坐标初始化到该点圆心 |
| `Move` | 未 `drawing` 直接忽略；更新手指坐标 → 补穿越点 → 命中新点则追加 → 重绘 |
| `Up` / `Cancel` | `drawing = false`，清除手指坐标，重绘，回调 `onPatternComplete(slice())`，按需起自动重置定时器 |

细节：

- **Down 在空白处**（没命中任何点）不会开始绘制，也不会清掉上一次的路径（`autoReset = false` 时）。这是有意的：外部可能在展示"上一次结果"。
- **`touches` / `changedTouches` 兜底**：`Up` 时 `touches` 可能为空，统一取 `touches.length > 0 ? touches : changedTouches`。
- **手指移出组件**：触摸序列仍派发给 down 的目标组件，坐标越界由命中检测天然兜住（不会命中任何点，只会画延伸段）。
- 只取 `touches[0]`，**不支持多指**。

### 5.2 定时器契约

三个参数互相牵制，规则如下：

| 场景 | 行为 |
|---|---|
| `autoReset = true` 且抬手后无错误 | `autoResetDelay`（默认 600ms）后 `doReset()` |
| 外部调用 `showError()` | `isError = true` 整盘变红，`errorAutoResetDelay`（默认 1000ms）后 `doReset()` |
| `showError()` 覆盖 `autoReset` | `scheduleReset()` 内部先 `clearResetTimer()`，后设的定时器胜出，不会双清 |
| `Up` 时已 `isError` | 不再排 `autoReset` 定时器（避免立刻擦掉错误态） |
| `errorAutoResetDelay ≤ 0` | 错误态不自动消失，必须由外部 `reset()` 或用户下一次 Down 清除 |
| 组件销毁 | `aboutToDisappear` 清定时器，避免回调打到已销毁实例 |

**推荐调用顺序**：

```
onPatternComplete(seq)
  → 校验
  → 失败：controller.showError()      （整盘红 → 自动消失）
  → 成功：controller.reset() 或什么都不做（autoReset 兜底）
```

---

## 6. 响应式与命令式的边界（最大的坑）

Canvas 内容是**命令式**的，ArkUI 的状态系统不知道它变了。因此：

```
@Param 变化（如 lineWidth 4 → 1）
   ↓ ArkUI 只做声明式属性 diff
Canvas 像素：纹丝不动（除非正好触发 onReady 或触摸重绘）
```

解决办法是 `@Monitor` 监听全部 12 个外观参数，变化时主动重绘：

```ts
@Monitor('style', 'sideLength', 'thumbnailSize', 'dotRadius', 'ringRadius', 'ringStrokeWidth',
  'activeScale', 'lineWidth', 'normalColor', 'activeColor', 'errorColor', 'lineColor')
onStyleChange(): void {
  this.redrawAll()
}
```

时序说明：`@Monitor` 回调可能早于 `Canvas.onReady`（此时 ctx 还没绑上，画了无效），但 `onReady` 里会再画一次，因此**不需要额外判空或延迟**。

其它两个约束：

- **两个 ctx 实例**：主画布和缩略图各持一个 `CanvasRenderingContext2D`，不能共用。
- **参数/属性命名不能撞 `CommonAttribute`**：V2 自定义组件的属性名与通用属性重名会直接编译失败（本组件上一版 `onDragStart`/`onDragEnd` 就撞了系统拖拽事件，已改名 `onSeekStart` 等）。本组件对外的名字 `controller`、`onPatternComplete`、`lineWidth` 等均已避开。

---

## 7. 对外 API

### 7.1 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `style` | `RING` | 四种样式 |
| `sideLength` | `300` | 画布边长（正方形，vp） |
| `showThumbnail` / `thumbnailSize` | `true` / `44` | 缩略图开关与边长 |
| `dotRadius` | `5` | 实心圆点半径；`DOT` 样式下即未选中点半径 |
| `ringRadius` | `20` | 圆环半径（`DOT` 不使用） |
| `ringStrokeWidth` | `2` | 圆环描边宽度 |
| `activeScale` | `1.6` | `DOT` 样式选中放大倍数 |
| `lineWidth` | `1` | 连线宽度（缩略图按其比例缩放，最小 1vp） |
| `normalColor` | `#5B8DB8` | 未选中 |
| `activeColor` | `#1E88E5` | 选中 |
| `errorColor` | `#F44336` | 错误（优先级最高） |
| `lineColor` | `''` | 连线色，空串跟随 `activeColor` |
| `autoReset` / `autoResetDelay` | `true` / `600` | 抬手后自动清空 |
| `errorAutoResetDelay` | `1000` | 错误态自动清除延时，≤0 不自动清除 |
| `controller` | **必传** | 外部控制句柄 |

### 7.2 Controller 契约

```ts
export class PatternLockController {
  reset: () => void = (): void => {}       // 清空路径 + 清错误态
  showError: () => void = (): void => {}   // 整盘标红 + 延时自动重置
}
```

- 组件在 `aboutToAppear` 里把内部方法注入到 controller。
- **一个组件实例必须配一个独立的 controller 实例**；两个组件共用一个 controller 实例会互相覆盖注入（后挂载的赢）。

### 7.3 路径契约

```ts
@Event onPatternComplete: (sequence: number[]) => void
```

- 元素为 **0~8 的点索引，行优先**，顺序即用户划线顺序。
- **已去重**（同一路径不会重复出现同一个点），**包含穿越自动补的点**。
- 回调传的是 `slice()` 快照，外部可安全持有。
- 长度可能为 1（只点了一个点就抬手），是否算有效由业务判定。
- 持久化建议：`sequence.join(',')` → `"0,1,4,8"`，比对即字符串相等（demo 就是这样做的）。

### 7.4 最小用法

```ts
private controller: PatternLockController = new PatternLockController()

PatternLockView({
  style: PatternLockStyle.RIPPLE,
  sideLength: 288,
  controller: this.controller,
  autoReset: false,                      // 自己控制何时清空
  onPatternComplete: (seq: number[]): void => {
    if (seq.length < 4) {
      this.controller.showError()
      return
    }
    if (seq.join(',') === this.savedPwd) {
      this.controller.reset()
    } else {
      this.controller.showError()
    }
  }
})
```

---

## 8. Demo 页的流程编排（`PatternLockPage.ets`）

组件只给路径，业务流程全部在页面层，完整闭环：

```
启动 → preferences 读密码
  ├─ 无密码（设置模式）
  │    第一次绘制 → 记住 firstPattern，提示"再次绘制解锁图案" + reset() 清盘
  │    第二次绘制 → 相同：preferences 保存 + 提示成功 + reset()
  │                不同：showError() + firstPattern 清空，重来
  └─ 有密码（验证模式）
       绘制 → 相同：解锁成功 + reset()
              不同：showError()
「清除已保存密码」→ 删 preferences，回到设置模式
```

页面还提供了 4 个样式切换按钮，并演示了"不同样式配不同参数"的写法（DOT 用大圆点 + 粗线 + 灰色，其余用圆环 + 细线 + 蓝色），切换时调 `controller.reset()` 触发重绘。

---

## 9. 扩展点

| 想改什么 | 改哪里 |
|---|---|
| 加第五种样式 | 加枚举值 → 在 `drawGrid` 的"九个点"循环里加分支（**保持 线→箭头→点 的顺序**） |
| 箭头形状/大小/位置 | `drawArrow()`：`len` 是翼长，`±π/6` 是张角 |
| 涟漪层数/透明度 | `RIPPLE` 分支的 `globalAlpha` 与半径系数 |
| 手感（命中范围） | `hitTest()` 的 `0.45` |
| 穿越激活灵敏度 | `activatePassedPoints()` 的阈值 `dotRadius + 4` |
| 缩略图点大小 | `drawThumb()` 的 `s * 0.045`（目前固定，不跟随 `dotRadius`） |
| 加绘制动画 | 用 `animator` 驱动 `redrawAll()`；当前是无动画的瞬时绘制 |

---

## 10. 已知限制 / 待验证

1. **命中半径固定**为格子边长的 0.45，未做成参数；手感需真机确认。
2. **穿越阈值** `dotRadius + 4` 与 `dotRadius` 耦合：`DOT` 样式（大圆点）下阈值偏大，可能误激活斜邻点。
3. **缩略图**点半径固定 `thumbnailSize * 0.045`，不跟随 `dotRadius`；缩略图线宽与主画布联动但有 1vp 下限。
4. **`lineWidth` 很小时**（如 1vp）比 `ringStrokeWidth`（默认 2vp）还细，视觉上圆环会比连线更"重"，调细线时建议同步调小 `ringStrokeWidth`。
5. **不支持多指**，只取 `touches[0]`。
6. **无过渡动画**：错误变红、涟漪出现都是瞬时的。
7. **一组件一 controller**：多实例共享会互相覆盖（见 §7.2）。

---

## 11. 测试用例清单

> 分四组：**A 路径正确性**（最核心，错了整个组件没意义）、**B 四种样式视觉**、**C 状态机与定时器**、**D 参数与生命周期**。
> 建议 A、C 每次改动都跑全量；B 只在改绘制代码时跑；D 在改参数/监听时跑。
> 每条都写「操作 → 期望」，便于真机逐条勾。

### A. 路径正确性（与样式无关，任意样式下都应成立）

| # | 操作 | 期望 |
|---|---|---|
| A1 | 单点一下点 0 就抬手 | 回调 `[0]`，长度 1；盘面剩一个选中点（不自动清时） |
| A2 | 依次划 0→1→2 | 回调 `[0,1,2]`，顺序与划线顺序一致 |
| A3 | **穿越**：从 0 直接划到 2（不经过 1 附近停留） | 回调 `[0,1,2]`，1 被自动补上；线是直的（不出现折线） |
| A4 | **穿越**：从 0 划到 8（对角） | 回调 `[0,4,8]` |
| A5 | 从 0 划到 6（同列） | 回调 `[0,3,6]` |
| A6 | **回退**：0→1→2 后手指退回 1 的位置再抬手 | 回调仍为 `[0,1,2]`，不因回退重复追加 1 |
| A7 | **重复进入**：0→1→0 | 回调 `[0,1]`，同一索引不重复出现 |
| A8 | **手指出界**：从 4 划到画布外（右下角外）继续移动再抬手 | 不崩溃；延伸段被画到画布外（被 Canvas 裁掉）；回调仍为已激活的点 |
| A9 | **Down 在空白处**（两排点之间的空隙）后拖动经过 4 | 未命中起点不开始绘制；`drawing` 保持 false，抬手无回调（这是设计行为，见 §5.1） |
| A10 | 划满 9 个点（0→1→2→5→4→3→6→7→8） | 回调长度 9，无重复；线正确连接 |
| A11 | 快速乱划（一秒划完对角线来回） | 无漏点、无乱序；`selected` 只增不减 |
| A12 | **最小反例回归**：改任何绘制代码后重跑 A3、A4 | 穿越激活仍正确（最容易被 drawGrid 改动误伤） |

### B. 四种样式视觉走查（切样式按钮逐个过）

| # | 样式 | 检查点 |
|---|---|---|
| B1 | `ARROW` | 未选中：圆环；选中：圆环 + 实心点；**每两个已选点之间**的线段中点有箭头，方向指向后一个点 |
| B2 | `ARROW` | 绘制过程中，**最后一点 → 手指**的跟随段**没有**箭头（抬手后才出现） |
| B3 | `RIPPLE` | 选中点**不画圆环**，只有实心点 + 两层半透明涟漪（外圈更大更淡） |
| B4 | `RIPPLE` | 未选中点仍是圆环；相邻两个选中点的涟漪不互相遮挡成一片 |
| B5 | `RING` | 未选中圆环、选中圆环 + 实心点；线连接圆心，点压在线上（不是线压在点上） |
| B6 | `DOT` | 未选中为小实心点，选中为放大 `activeScale`（1.6）倍的大点；无圆环 |
| B7 | 四种样式 | **错误态**：`showError()` 后 **9 个点全部变红**（含未选中点）、连线红、**缩略图也整体变红** |
| B8 | 四种样式 | 抬手后缩略图与大盘路径一致；`reset()` 后缩略图回到 9 个空心点 |

### C. 状态机与定时器

| # | 操作 | 期望 |
|---|---|---|
| C1 | `autoReset = true`（默认）：划完抬手 | 图案停留约 600ms 后自动清空，缩略图同步清空 |
| C2 | `autoReset = false`（demo）：划完抬手 | 图案**保留**在盘面，直到外部 `reset()` |
| C3 | **错误态打断**：`showError()` 后 300ms 时按下盘面 | 红色立即消失，清除定时器，从按下点开始新绘制 |
| C4 | **定时器覆盖**：抬手（排了 autoReset 600ms）后立刻 `showError()` | 不会出现"600ms 时图案消失"抢在错误态之前；错误态完整展示 1000ms 后才清 |
| C5 | `errorAutoResetDelay = 0` | 错误态不自动消失，必须外部 `reset()` 或再次 Down |
| C6 | 错误态展示中直接 `reset()` | 立即清红 + 清路径，后续不会再被旧定时器清一次（定时器已取消） |
| C7 | 绘制中（手指未抬）切到后台 / 触发 Cancel | `drawing` 置 false，延伸段消失，按已有路径回调 |
| C8 | 页面退出（`aboutToDisappear`）时定时器未触发 | 无崩溃、无"回调打到已销毁实例"的报错 |
| C9 | 抬手后立刻再按下（<600ms，autoReset=true） | 定时器被新绘制接管，不会画到一半被清掉 |

### D. 参数、响应式与持久化

| # | 操作 | 期望 |
|---|---|---|
| D1 | **`@Monitor` 重绘**：运行中把 `lineWidth` 从 4 改成 1（不触摸盘面） | 盘面**立即**重绘，线变细（这是命令式 Canvas 的坑，见 §6） |
| D2 | 改 `sideLength` 288 → 200 | 整套尺寸等比缩放（点/环/线一起缩），不散架 |
| D3 | 改 `dotRadius` / `ringRadius` / `ringStrokeWidth` | 对应元素实时变化；**注意 demo 传参会覆盖组件默认值**（改默认值无效，要改 demo 传参） |
| D4 | `lineColor` 设为 `''` | 连线色跟随 `activeColor` |
| D5 | `lineColor` 设为具体色 | 连线用该色，点仍用 `activeColor` |
| D6 | `showThumbnail = false` | 缩略图不渲染，主盘正常 |
| D7 | 改 `thumbnailSize` | 缩略图整体缩放，点/线比例不变；线宽有 1vp 下限 |
| D8 | **冷启动**：首次进入绘制 → 设置成功 → 杀进程重进 | 进入验证模式（提示"绘制图案解锁"），说明 preferences 持久化生效 |
| D9 | 验证模式输入错误图案 | 提示"图案错误" + 整盘红，1s 后清空 |
| D10 | 验证模式输入正确图案 | 提示"解锁成功"，盘面清空 |
| D11 | **设置流程**：第一次绘制完 | **盘面立即清空**（提示"再次绘制解锁图案"），不是保留旧图案 |
| D12 | 设置流程：第二次绘制与第一次不同 | 提示"两次绘制不一致"+ 整盘红，`firstPattern` 清空，回到第一次绘制状态 |
| D13 | 设置流程：第二次绘制与第一次相同 | 提示"设置成功"，写入 preferences，进入验证模式 |
| D14 | 点「清除已保存密码」 | 删除 preferences，回到设置模式，盘面清空 |
| D15 | **一组件一 controller**：同页面放两个 `PatternLockView` 且共用同一个 controller 实例 | 已知限制：只有后挂载的那个能被控制（见 §7.2），正确用法是每个组件 `new` 一个 |

### 回归顺序建议

改动后按此顺序快速过一遍，能在 2 分钟内发现问题：

```
A3（穿越）→ A12 → C3（错误态打断）→ C4（定时器覆盖）→ D1（Monitor 重绘）→ B 组当前样式走查
```
