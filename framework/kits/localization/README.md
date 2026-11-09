[← 返回容器型模块总览](../README.md)

# LocalizationKit

`class_name LocalizationKit`，`extends Kit`。作用域化本地化查表：自持翻译表实例，按 locale → 回退链 → key 本身解析文本，locale 切换经 `LocaleChangedEvent` 通知，可接入 UI 刷新与存档。

不依赖全局 `TranslationServer`，不调用 `tr()`；不自写 CSV / PO 解析器，直接消费 Godot 导入的 `Translation` 资源或代码构造的 `Translation`。

---

## 目录与分层

```
framework/kits/localization/
├── localization_kit.gd            # Kit 门面：注册 / locale / 查表 / 格式化 / 事件转发
├── locale_model.gd                # Model：locale / 翻译表 / 回退链 / 缺失计数
├── events/
│   └── locale_changed_event.gd    # LocaleChangedEvent：old_locale / new_locale
└── README.md
```

**一个 Model + Kit 门面，不设 System**：本地化没有逐帧逻辑，查表与格式化都是门面上的同步方法。依赖方向 `localization → core`，与其他 kit / lib 零依赖。

---

## 设计取向

| 决策 | 说明 |
|---|---|
| 缺失 key | 返回 key 本身，并在 Model 上累计 `missing_total`；不 `push_error`，用 `has_key()` 与计数表达 |
| 空译文 | 视为缺失，继续回退（与 Godot `tr()` 的缺省回退语义一致） |
| locale 比较 | 严格相等，不做 `zh-CN → zh` 前缀匹配；未注册即 `ERR_DOES_NOT_EXIST` |
| 回退链 | 由 `fallback_locales` 显式声明，按序尝试；全部缺失才落到 key |
| 幂等切换 | 切换到相同 locale 返回 `OK` 且**不**发事件，避免 UI 无谓刷新 |
| 事件隔离 | 事件总线按 Architecture 隔离；业务侧需要时配置 `target_architecture` 转发 |
| 无 System | 查表是纯读操作，没有需要 tick 的状态机 |

---

## 接入拓扑

```
GameRoot (Node)
├── MainArchitecture   (service_config: MainServiceConfig.tres,  shared_registry: hub.tres)
├── LocalizationKit    (service_config: LocServiceConfig.tres,   shared_registry: hub.tres,
│                       target_architecture: MainArchitecture)
├── UiKit              (target_architecture: MainArchitecture)
└── SaveKit            (shared_registry: hub.tres)
```

`LocServiceConfig.tres` 只需 `self_name = &"LocalizationKit"`。业务侧：

```gdscript
var loc := arch.get_service(&"LocalizationKit") as LocalizationKit
var title := loc.translate(&"ui.title")
```

---

## 配置与启动顺序

`@export` 字段：

| 字段 | 默认 | 说明 |
|---|---|---|
| `default_locale` | `&"en"` | 进树时自动尝试应用；未注册对应翻译表仅 warning |
| `fallback_locales` | 空 | 回退顺序 |
| `translations` | 空 | 声明式翻译表（编辑器导入的 `.translation`） |
| `target_architecture` | 空 | `LocaleChangedEvent` 转发目标 |

`_bootstrap()` 顺序：

1. 注册 `LocaleChangedEvent` 转发回调；
2. 注册 `translations` 声明式翻译表；
3. 调用 `_init_localization_kit()`（子类用代码注册翻译表）；
4. `try_set_locale(default_locale)`，失败只 warning，不阻塞启动。

第 2、3 步都在设置默认 locale 之前，因此声明式与代码注册的翻译表都能让 `default_locale` 生效。

> `_init_architecture()` 只注册 `LocaleModel`。翻译表注册需在节点进树后（`_ready` 之后）才能调用；进树前的配置走 `@export`。

---

## API

| 方法 | 返回 | 说明 |
|---|---|---|
| `register_translation(translation)` | `Error` | 注册翻译表，locale 取自 `translation.locale` |
| `unregister_translation(locale)` | `Error` | 注销；注销当前 locale 时保留设置，查表走回退链 |
| `try_set_locale(locale)` | `Error` | 目标 locale 必须已注册；相同值幂等且不发事件 |
| `get_locale()` | `StringName` | 当前 locale；未设置或已 deinit 时为空 |
| `translate(key, args := {})` | `String` | 当前 locale → 回退链 → key；`args` 做 `{name}` 替换 |
| `has_key(key)` | `bool` | 当前 locale 或回退链中任一命中 |
| `get_missing_total()` | `int` | 累计缺失次数（诊断 / 测试断言） |

占位符规则：

- `translate(&"greet", {"name": "Ada"})` 把 `{name}` 替换为 `str("Ada")`；
- args 中多余的键忽略；
- 文本中未提供值的占位符原样保留。

错误码：

| 返回 | 场景 |
|---|---|
| `OK` | 成功 |
| `ERR_INVALID_PARAMETER` | 翻译表为 `null`；`translation.locale` 为空 |
| `ERR_ALREADY_EXISTS` | 同 locale 重复注册 |
| `ERR_DOES_NOT_EXIST` | 注销未注册的 locale；切换到未注册的 locale |
| `ERR_UNAVAILABLE` | 尚未进树 / 已 deinit |

预期失败只返回错误码，不写日志。

---

## 使用

### 方式一：声明式

在场景里给 LocalizationKit 的 `translations` 填入导入的 `.translation`，设置 `default_locale` 与 `fallback_locales`。

### 方式二：子类代码注册

```gdscript
extends LocalizationKit
class_name GameLocalizationKit

func _init_localization_kit() -> void:
	var en := Translation.new()
	en.locale = "en"
	en.add_message(&"greet", "Hello {name}")
	register_translation(en)
	register_translation(preload("res://locale/zh.translation"))
```

### UI 刷新

事件经 `target_architecture` 转发进业务作用域；UiView 在 `_ui_enter` 里订阅并在文本节点上重新查表。离树自动解绑由 UiView 现有兜底完成，池化复用不会累积回调。

```gdscript
extends UiView
class_name MainMenu

func _ui_enter(_params : Dictionary) -> void:
	bind_event(&"LocaleChangedEvent", _on_locale_changed)
	_refresh()

func _on_locale_changed(_event : LocaleChangedEvent) -> void:
	_refresh()

func _refresh() -> void:
	var loc := get_arch().get_service(&"LocalizationKit") as LocalizationKit
	$Title.text = loc.translate(&"ui.title")
	$Start.text = loc.translate(&"ui.start")
```

### 对话

`DialogueLib` 保持原文，调用方用 `DialogueStep.line_id` 另行查表：

```gdscript
$Speaker.text = step.speaker
$Body.text = loc.translate(step.line_id)
```

### 存档

LocalizationKit 不认识 SaveKit。项目侧在自己的存档 Model 里经服务总线读写 locale：

```gdscript
extends Model
class_name SettingsSaveModel

var locale : StringName = &""

func get_data() -> Dictionary:
	var loc := get_architecture().get_service(&"LocalizationKit") as LocalizationKit
	return {"locale": String(loc.get_locale())}

func set_data(data : Dictionary) -> void:
	var loc := get_architecture().get_service(&"LocalizationKit") as LocalizationKit
	var target := StringName(data.get("locale", ""))
	if loc.try_set_locale(target) != OK:
		loc.try_set_locale(loc.default_locale)  # 存档中的 locale 不可用时回落默认值
```

---

## 生命周期

与现有 Kit 完全一致：

- `_ready()` → `_init_architecture()` 注册 `LocaleModel` → `_bootstrap()` 应用配置；
- `deinit()` 走 `Architecture` 标准注销：服务注销、事件回调清空、Model 移除；
- 翻译表是 `Resource`，无节点资源，无需额外清理；
- `_exit_tree` 自动 `deinit`，幂等。

`deinit()` 后：`register_translation` / `unregister_translation` / `try_set_locale` 返回 `ERR_UNAVAILABLE`，`translate` 回落到 key，`get_locale()` 返回空，`get_missing_total()` 返回 0。

---

## 测试

`tests/localization_kit_test.gd`（53 用例）覆盖注册、locale 幂等与事件、当前 / 回退链查表、缺失计数、占位符格式化、事件转发与防循环、子类钩子、共享总线注册 / 注销、deinit 幂等与插拔隔离。翻译表全部用 `Translation.new() + add_message()` 代码构造，不依赖编辑器导入流程。

---

## 边界

**不**提供：复数规则、语言自动检测、字体回退、CSV / PO 解析、全局 `TranslationServer` 接管、运行时热重载翻译表。这些待实际需求出现时再提炼。

---

[← 返回容器型模块总览](../README.md)
