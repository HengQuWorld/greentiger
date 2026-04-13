# ArkUI `@Builder` 刷新陷阱排障笔记

## 背景

这份笔记沉淀一次真实踩坑：

- 现象：鸿蒙端连接管理页面中，左侧列表点击切换后，右侧“当前选中”详情区只更新了连接名称，其他字段仍然停留在第一次启动时的值。
- 代价：问题隐蔽，排查耗时长，容易误判成点击事件失效、`@State` 不生效、列表复用异常或布局缓存问题。

本质上，这是 ArkUI `@Builder` 的参数传递与刷新规则导致的 UI 不刷新问题。

## 一句话结论

- `@Builder` 默认按值传参。
- 只有“单参数 + 直接传对象字面量”时，才会按引用传参并跟随状态变化刷新。
- 一旦是多个参数，或者不是对象字面量，`@Builder` 内部 UI 很可能只吃到首次值，后续状态变化不自动刷新。
- 需要动态刷新的 UI，优先在 `@Builder` 内部直接读取 `this` 上的状态，不要把状态拆成多个参数传进去。

## 这次问题的错误写法

### 坑 1：把选中对象作为 `@Builder` 参数传入

```ts
@Builder
private buildDetailPane(): void {
  if (this.selectedConnId) {
    this.buildDetailContent(
      this.connections.find((c: ConnectionItem) => c.id === this.selectedConnId) as ConnectionItem
    );
  }
}

@Builder
private buildDetailContent(c: ConnectionItem): void {
  Text(normalizeConnName(c.name ?? '', c.address ?? '', c.sshTunnel))
}
```

问题点：

- 看起来只传了一个参数，但传入的不是对象字面量，而是表达式结果。
- 这种情况下并不是稳定的按引用刷新。
- 结果就是：`selectedConnId` 变了，但 `buildDetailContent(c)` 内部不一定重绘。

### 坑 2：把明细项拆成两个参数传给 `@Builder`

```ts
@Builder
private buildDetailLine(label: string, value: string): void {
  Text(label)
  Text(value)
}
```

问题点：

- 两个参数的 `@Builder` 一定是按值传递。
- `label` 和 `value` 会在首次构建时被“拍平”成静态值。
- 后续列表选中变化后，这类行内容极易保持旧值。

## 这次问题为什么会出现“只更新了一半”

因为不同 UI 读取状态的方式不一样：

- 标题行如果直接写成 `this.getSelectedConnection()?.name`，会重新读取组件状态，所以能更新。
- 地址、账号、最近使用等如果通过 `buildDetailLine(label, value)` 传参，属于按值传递，后续不跟着状态刷新。

所以才会出现这种极具迷惑性的症状：

- 名称变了。
- 其他字段不变。
- 看起来像“部分刷新成功”，实际上是“部分 UI 仍然绑定在旧值上”。

## 正确写法

原则：让 `@Builder` 直接依赖组件自己的状态。

```ts
@Builder
private buildDetailPane(): void {
  Column() {
    if (this.getSelectedConnection()) {
      this.buildDetailContent();
    }
  }
}

@Builder
private buildDetailContent(): void {
  Column() {
    if (this.getSelectedConnection()) {
      Text(normalizeConnName(
        this.getSelectedConnection()?.name ?? '',
        this.getSelectedConnection()?.address ?? '',
        this.getSelectedConnection()?.sshTunnel
      ))

      Text(this.getSelectedConnection()?.address ?? '')
      Text(this.getSelectedConnection()?.user ?? '未提供')
    }
  }
}
```

优点：

- `selectedConnId` 和 `connections` 会被 ArkUI 正确识别为依赖。
- 点击列表切换时，详情区会重新读取当前状态。
- 不再依赖 `@Builder` 的参数刷新规则。

## 判断是不是这个坑的速查表

如果你遇到下面任意两个以上现象，优先怀疑 `@Builder` 按值传参：

- 首次进入页面显示正常。
- 后续点击切换、筛选切换、Tab 切换后，局部区域不刷新。
- 同一块区域里，只有部分字段会更新。
- `@State` 明明变了，但 UI 还是旧值。
- 列表选中态变了，兄弟区域不变。
- 改成直接在当前 `build()` 或 `@Builder` 里读 `this.xxx` 后问题消失。

## 推荐排查顺序

1. 先确认状态是否真的变化。
2. 再确认“不刷新的 UI”是不是在 `@Builder` 里通过参数取值。
3. 如果是，数一下参数个数。
4. 如果参数大于 1，直接判定高风险。
5. 如果参数等于 1，但不是对象字面量，也按高风险处理。
6. 优先改成在 `@Builder` 内直接读取 `this` 上的状态。
7. 修改后重新执行 `hvigorw assembleApp` 验证。

## 推荐编码约定

为避免以后再踩同一个坑，建议在鸿蒙页面里遵守这些规则：

- 规则 1：`@Builder` 里只做轻量 UI 复用，不承载复杂动态状态同步。
- 规则 2：凡是需要跟随 `@State` 高频刷新的内容，优先在 `@Builder` 内直接读取 `this` 状态。
- 规则 3：避免写多参数 `@Builder` 来展示动态数据。
- 规则 4：如果必须参数化，优先用“单参数 + 对象字面量”方式，并确认它符合官方按引用规则。
- 规则 5：遇到“只更新部分字段”的情况，优先检查是否混用了“直接读状态”和“按值传参”两种写法。

## 本项目的直接案例

本仓库中的真实修复点在：

- `ohos_app/entry/src/main/ets/pages/Index.ets`

修复前：

- 详情区标题和明细项混用了两种状态读取方式。
- 明细项通过多参数 `@Builder` 传值。

修复后：

- 详情区所有动态字段都直接读取 `this.getSelectedConnection()`。
- 移除了导致按值传递的 `buildDetailLine(label, value)` 方案。

## 官方资料

- 华为官方 `@Builder` 文档：
  - https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/arkts-builder-V5
- 英文版说明中也明确写到：
  - 参数只有在“单参数且直接传对象字面量”时才按引用传递。
  - 其他情况默认按值传递。

## 以后遇到类似问题时的检索关键词

- `ArkUI @Builder 不刷新`
- `HarmonyOS Builder by value`
- `ArkTS state changed but UI not rerender`
- `ArkUI 切换选中后详情不更新`
- `HarmonyOS only first render updates`

## 最后一句

以后在 ArkUI 里看到“首屏正常，切换不刷新，甚至只刷新一半”，第一反应不要先怀疑事件没触发，先检查：

- 这块 UI 是不是写在 `@Builder` 里。
- 它是不是通过参数拿数据。
- 参数是不是多于一个，或者不是对象字面量。
