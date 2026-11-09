# LocalizationKit 落地方案

## Context

框架目前没有任何本地化实现，但需求口子已在设计上预留：

- `DialogueLib` 明确「文本保持原文，本地化由调用方按 line_id 另行查表」（`framework/libs/dialogue/dialogue_line.gd`），查表能力缺位。
- `UiKit` 的视图经 `bind_event` 订阅数据架构事件，语言切换时的文本刷新目前没有事件源。
- 语言设置最终要进存档（`SaveKit`），需要一个可被持久化读写的 locale 状态源。

形态判定（对照 kit-refactor.md 的二分类判据）：

| 判据 | 本地化 |
|---|---|
| 自己管理状态 | 有：当前 locale、已注册翻译表、回退链 |
| 要暴露服务 | 要：UI / 对话调用方查翻译（带返回值的查询，走服务调用） |
| 要有起停 | 有：翻译表注册/注销，随容器生命周期闭环 |
| 需要发事件 | 需要：`LocaleChangedEvent` 是 1 对多通知 |

四条全中 → **容器型，`extends Kit`，目录 `framework/kits/localization/`**。

## 目标

- 作用域化的翻译查表：key → 文本，支持回退链与占位符格式化。
- locale 切换发 `LocaleChangedEvent`，复用 AudioKit 的 `target_architecture` 转发手法。
- 经 `service_config.self_name` 暴露到共享总线，业务侧 `get_service(&"LocalizationKit")` 取用。
- L1 插拔：删除整个 `framework/kits/localization/` 目录，核心与其他模块不受影响。
- headless 可确定性断言（翻译表用代码构造，不依赖编辑器导入流程）。

## 非目标

- **不重造翻译解析**：不自写 CSV/PO 解析器，直接消费 Godot 导入产出的 `Translation` 资源（`.translation`）；也支持代码 `Translation.new()` + `add_message()`。
- **不依赖全局 `TranslationServer`**：Kit 自持翻译表实例，符合「无隐式全局」哲学；不调用 `tr()`。
- **不做复数规则、不做语言检测、不做字体回退**：待实际需求出现再提炼。
- 不改核心层、不改 `DialogueLib` / `UiKit` / `SaveKit` 的任何代码。
- 不引入共享事件总线（沿用现有 `target_architecture` 转发模式，与 AudioKit 一致）。

## 设计决策

1. **组件最小化：一个 Model + Kit 门面，不设 System。**
   本地化没有逐帧逻辑，不需要 System 层；查表与格式化是 Kit 门面上的同步方法。占位符格式化是私有方法，不抽 Utility（避免凭空抽象）。

2. **缺失 key 策略：返回 key 本身**（Godot 惯例），并在 Model 上累计 `missing_total` 计数，供测试与诊断断言。不 push_error 刷屏——缺失是可探测的预期结果，用 `has_key()` 与计数表达。

3. **`try_set_locale` 要求目标 locale 已注册翻译表**，否则 `ERR_DOES_NOT_EXIST`。切换到相同 locale 返回 OK 且**不发事件**（幂等，避免 UI 无谓刷新）。

4. **回退链显式声明**：`fallback_locales` 数组按序尝试，全部缺失才落到 key 本身。不做隐式的「语言前缀匹配」（如 zh-CN → zh），规则越死，规范越硬。

5. **事件转发带防循环标志**，照抄 AudioKit `_forward()` 手法。

6. **持久化与模块零依赖**：LocalizationKit 不认识 SaveKit。项目侧在自己的存档 Model 的 `get_data/set_data` 里经服务总线读写 locale（接入示例见下）。

## 目标结构

```
framework/kits/localization/
├── localization_kit.gd        # LocalizationKit : Kit（门面 + 生命周期）
├── locale_model.gd            # LocaleModel : Model（locale / 翻译表 / 回退链 / 计数）
├── events/
│   └── locale_changed_event.gd  # LocaleChangedEvent : Event
└── README.md                  # 模块文档（接入拓扑 + API + 边界）
```

依赖方向：`localization → core`，与其他 kit / lib 零依赖。

## API 草案

```gdscript
class_name LocalizationKit
extends Kit

# ---- 可配置（@export）----
@export var default_locale : StringName = &"en"
@export var fallback_locales : Array[StringName] = []
@export var translations : Array[Translation] = []      # 声明式：编辑器导入的 .translation
@export var target_architecture : Architecture          # LocaleChangedEvent 转发目标

# ---- 生命周期钩子 ----
func _init_localization_kit() -> void: pass             # 子类重写，代码注册翻译表

# ---- 翻译表注册（可断言）----
func register_translation(translation : Translation) -> Error
    # null / locale 为空 → ERR_INVALID_PARAMETER；同 locale 重复 → ERR_ALREADY_EXISTS
func unregister_translation(locale : StringName) -> Error
    # 未注册 → ERR_DOES_NOT_EXIST；注销当前 locale 时保留设置但查表走回退链

# ---- locale ----
func try_set_locale(locale : StringName) -> Error
    # 未注册该 locale 的翻译表 → ERR_DOES_NOT_EXIST；相同值 → OK 且不发事件
func get_locale() -> StringName

# ---- 查表 ----
func translate(key : StringName, args : Dictionary = {}) -> String
    # 当前 locale → fallback_locales 依次 → key 本身；args 做 {name} 占位符替换
func has_key(key : StringName) -> bool                  # 当前 locale 或回退链中任一命中
func get_missing_total() -> int                          # 诊断计数
```

```gdscript
class_name LocaleChangedEvent
extends Event

var old_locale : StringName = &""
var new_locale : StringName = &""
```

占位符规则：`translate(&"greet", {"name": "Ada"})` 把文本中的 `{name}` 替换为 `str(args["name"])`；args 中多余的键忽略，文本中未提供值的占位符原样保留。

## 接入拓扑

```
GameRoot (Node)
├── MainArchitecture   (service_config: MainServiceConfig.tres,  shared_registry: hub.tres)
├── LocalizationKit    (service_config: LocServiceConfig.tres,   shared_registry: hub.tres,
│                       target_architecture: MainArchitecture)
├── UiKit              (target_architecture: MainArchitecture)
└── SaveKit            (shared_registry: hub.tres)
```

- `LocServiceConfig.tres`：`self_name = &"LocalizationKit"`。
- 业务侧查表：`arch.get_service(&"LocalizationKit").translate(&"ui.title")`。
- **UI 刷新**：`LocaleChangedEvent` 经 `target_architecture` 转发进业务作用域，UiView 在 `_ui_enter` 里 `bind_event(&"LocaleChangedEvent", ...)` 刷新文本；离树自动解绑由 UiView 现有兜底完成，池化复用无累积。
- **对话**：调用方拿 `DialogueStep.line_id` 查 `translate(line_id)`，DialogueLib 本身不动。
- **存档**：项目侧存档 Model 的 `get_data()` 写入 `get_service(&"LocalizationKit").get_locale()`；`set_data()` 读出后 `try_set_locale()`（失败则回落默认值）。

## 生命周期

与现有 Kit 完全一致，无新机制：

- `_init_architecture()`：注册 `LocaleModel`。
- `_ready()` 末尾 `_bootstrap()`：应用 `translations` 声明式注册 → `try_set_locale(default_locale)`（失败仅 warning，不阻塞启动）→ `_init_localization_kit()`。
- `deinit()`：走 `Architecture` 标准注销（服务注销、事件清空）；无需额外清理（翻译表是 Resource，无节点资源）。

## 实施步骤

1. **骨架**：`locale_model.gd`、`locale_changed_event.gd`、`localization_kit.gd`（注册 / locale / 查表 / 格式化 / 事件转发）。
2. **测试**：`tests/localization_kit_test.gd` + fixtures（代码构造 `Translation`），并注册进 `tests/run_tests.gd` 的 `SUITES`。
3. **文档**：模块 `README.md`；`framework/kits/README.md` 追加 LocalizationKit 章节与两类扩展一览更新；根 README 特性列表补一条。
4. **验证**：headless 跑全套测试，确认既有套件无回归。

## 测试计划（headless 确定性）

| 组 | 用例 |
|---|---|
| 注册 | 正常注册；null / 空 locale 拒绝；同 locale 重复拒绝；注销后可再注册 |
| locale | 未注册 locale 拒绝；相同值幂等且不派发事件；切换派发 `LocaleChangedEvent`（断言 old/new） |
| 查表 | 当前 locale 命中；回退链按序命中；全缺失返回 key 且 `missing_total` 递增；`has_key` 正确 |
| 格式化 | 占位符替换；多余 args 忽略；缺值占位符原样保留 |
| 事件转发 | 配置 `target_architecture` 后业务作用域收到事件；防循环标志生效；未配置时不转发 |
| 生命周期 | 共享总线注册 / deinit 注销服务；deinit 后拒绝注册；`_exit_tree` 幂等 |
| 插拔 | 套件独立起停，不污染其他套件（沿用现有 fixture 手法） |

运行方式不变：

```
Godot_v4.7-stable_win64_console.exe --headless --path <项目根> --script res://tests/run_tests.gd
```

## 验收标准

- 全套测试（含既有 4 个套件）headless 通过，退出码 0。
- 删除 `framework/kits/localization/` 目录后其余代码仍可编译（L1 插拔）。
- 不修改核心层与任何既有 kit / lib 的代码（`tests/run_tests.gd` 的 SUITES 登记与文档除外）。
- 业务侧仅经 `get_service` + `translate` + `bind_event` 三个口子完成接入，无直接节点引用。