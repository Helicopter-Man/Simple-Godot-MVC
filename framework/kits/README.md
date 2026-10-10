[← 返回总览](../../README.md)

# 容器型模块 framework/kits

容器型扩展是**自己管理状态、要暴露服务、要有起停**的模块。它继承 `Kit`（即 `Architecture`），因此天然获得作用域总线、服务暴露与生命周期闭环。删除整个 `framework/kits/` 目录不影响核心与其他扩展。

---

## 两类扩展一览

| 形态 | 基类 | 类名后缀 | 目录 | 文档 |
|---|---|---|---|---|
| 容器型 | `extends Kit` | `Kit` | `framework/kits/` | 本文 |
| 库型 | `extends RefCounted` | `Lib` | `framework/libs/` | [库型模块](../libs/README.md) |

判定标准：*这个模块是否需要自己管理状态 / 服务 / 生命周期？* 是 → 容器型；否 → 库型。

---

## 目录

- [Kit 基类](#kit-基类)
- [SaveKit](#savekit)
- [UiKit](#uikit)

---

## Kit 基类

```gdscript
@abstract
extends Architecture
class_name Kit
```

- **语义标记**：`node is Kit` 可判定「这是一个容器型模块」。
- **继承即免费获得**（来自 `Architecture`）：生命周期闭环与 `deinit` 幂等、服务总线、`service_config` 服务暴露、`Model / System / Utility` 注册与查询、事件总线。
- **当前刻意留空**：容器模块的通用操作等实际出现需求时再提炼，避免凭空抽象。

写容器型模块时继承 `Kit` 并重写 `_init_architecture()`（或按具体模块约定），在其中注册本模块的组件。

---

## SaveKit

`class_name SaveKit`，`extends Kit`。它是**版本化整体存档**的容器：承载实现了存档接口的 Model，把它们统一序列化到一个存档文件，并支持版本迁移与默认值填充。

因为继承自 `Kit`/`Architecture`，SaveKit：

- 复用核心的注册与去重（`register_model`）；
- 复用 `service_config`，可把存档 Model 暴露到共享总线，被其他 Architecture 查到；
- 复用生命周期：`_ready()` 自动初始化并调用各 Model 的 `_on_init()`，`_exit_tree()` 自动 `deinit()`。

### 使用方式

子类重写 **`_init_save_kit()`**，用 **`register_saveable()`** 注册存档 Model：

```gdscript
extends SaveKit
class_name GameSaveKit

func _init_save_kit() -> void:
	register_saveable(PlayerSaveModel.new())
	register_saveable(InventorySaveModel.new())
```

节点作为平行节点挂在场景树中，与业务 Architecture 平级：

```
GameRoot (Node)
├── MainArchitecture  (service_config: MainServiceConfig.tres, shared_registry: hub.tres)
└── SaveKit           (service_config: SaveServiceConfig.tres,  shared_registry: hub.tres)
```

给它和业务 Architecture 赋**同一个** `shared_registry`，存档 Model 即可被业务侧经总线查到。

### saveable Model 契约

| 方法 | 必填 | 说明 |
|---|---|---|
| `get_data() -> Dictionary` | 是 | 返回需要持久化的字段 |
| `set_data(data : Dictionary) -> void` | 是 | 从字典恢复字段 |
| `get_version() -> int` | 否 | 数据版本号，未实现时按 1 处理 |
| `migrate(data : Dictionary, from_version : int) -> Dictionary` | 否 | 版本迁移钩子，逐版本向上迁移 |
| `get_defaults() -> Dictionary` | 否 | 默认值字典，用于补齐老存档缺失的字段 |

注册时会用 `has_method()` 校验 `get_data` / `set_data` 是否存在，缺失则 `push_error` 并返回 `ERR_INVALID_PARAMETER`。注册键取 `Model.get_script_name()`，因此 saveable Model 需要 `class_name`。

```gdscript
extends Model
class_name PlayerSaveModel

var hp : int = 100
var level : int = 1

func get_data() -> Dictionary:
	return {"hp": hp, "level": level}

func set_data(data : Dictionary) -> void:
	hp = data.get("hp", hp)
	level = data.get("level", level)

func get_version() -> int:
	return 2

func migrate(data : Dictionary, from_version : int) -> Dictionary:
	if from_version == 1:
		data["level"] = data.get("exp", 1)
		data.erase("exp")
	return data

func get_defaults() -> Dictionary:
	return {"hp": 100, "level": 1}
```

### API

| 方法 | 返回 | 说明 |
|---|---|---|
| `register_saveable(model : Model)` | `Error` | 注册存档 Model（校验接口后复用 `register_model`） |
| `unregister_saveable(model_name : StringName)` | `Error` | 注销 |
| `save(path : String)` | `Error` | 写出存档 |
| `load(path : String)` | `Error` | 读入存档并写回各 Model |
| `has_save(path : String)` | `bool` | 判断存档文件是否存在 |
| `get_save_info(path : String)` | `Dictionary` | 读取元信息，不触发 `set_data`，适合选档界面预览 |

`get_model(name)` / `has_model(name)` 等查询方法由 `Architecture` 提供。

错误码：

| 返回 | 场景 |
|---|---|
| `OK` | 成功 |
| `ERR_INVALID_PARAMETER` | 路径非法；`register_saveable` 传入 `null` 或接口缺失 |
| `ERR_ALREADY_EXISTS` | 同名 Model 重复注册（由 `register_model` 返回） |
| `ERR_FILE_NOT_FOUND` | `load` 时存档文件不存在（预期失败，不写日志） |
| `ERR_CANT_OPEN` | 文件打开失败 |
| `ERR_INVALID_DATA` | 存档信封格式非法 |

### 存档信封

`save()` 用 `var_to_bytes` 序列化以下结构：

```gdscript
{
	"save_version": 1,                     # 信封格式版本
	"saved_at": "2026-07-11 12:34:56",     # 系统本地时间
	"models": {
		"PlayerSaveModel": {
			"version": 2,                  # 该 Model 的数据版本
			"data": { ... }                # get_data() 的返回内容
		},
	},
}
```

`get_data()` 返回的 Dictionary 应只含 Godot 基础类型（`int` / `float` / `String` / `bool` / `Array` / `Dictionary` / `Vector2` 等）。掺入 `Resource` / `Object` 引用时无法可靠跨版本恢复。

### 读档流程

1. 校验路径与文件存在性，反序列化信封。
2. 校验信封与条目结构（根是 Dictionary、含 `models`、条目含 `version` 与 `data`）。
3. 遍历条目，按名字查找当前已注册的 Model（未注册则跳过并 `push_warning`）。
4. 若存档版本 < 当前版本且 Model 实现了 `migrate`，逐版本向上迁移。
5. 若 Model 实现了 `get_defaults`，为 `data` 缺失的键补上默认值。
6. 调用 `model.set_data(data)` 写回。

优雅降级：

- 旧 Model 已被移除（存档有、当前未注册）：跳过并 `push_warning`。
- 新 Model 是新增的（当前已注册、存档没有）：保持初始值不变。
- 存档版本超前于代码版本：`push_warning` 并原样使用，不回滚。
- 迁移失败且无默认值：跳过该 Model 的 `set_data`。

### 路径安全

`save` / `load` / `has_save` / `get_save_info` 都经模块内部的 `_validate_path()` 强制：

- 路径必须以 `user://` 开头；
- 禁止 `..` 目录穿越（反斜杠会被规范化后再校验）。

建议按槽位命名，例如 `user://saves/slot_1.save`。

---

## UiKit

`class_name UiKit`，`extends Kit`。它是 **UI 拔插管理**的容器：持有 `ui_id → PackedScene` 注册表，按每个 UI 自述的池化策略复用实例。

### 拔插与池化

- **拔插**：`open()` 把 UI 挂入挂载点，`close()` 将其**移出场景树但不销毁**。离树会一次性停止该 UI 的绘制、布局重算、逐帧轮询与输入遍历。
- **池化（opt-in，由 UI 自述）**：每个 `UiView` 用导出字段声明自己的策略：

| 字段 | 含义 |
|---|---|
| `singular : bool` | 同一时刻是否只允许一个实例活动；重复 `open` 返回现有实例 |
| `pool_initial : int` | 池初始大小：预实例化的空闲实例数（可由 `prewarm()` 触发） |
| `pool_max : int` | 池上限：关闭后保留在池中的空闲实例数，超出立即释放；0 表示不保留 |

`singular` 时池上限收敛为 1；`pool_initial` 会被 `pool_max` 截断。

### 挂载点

`@export var mount : CanvasLayer`：所有 UI 的父节点。留空时首次使用会自动创建一个 `CanvasLayer`（名为 `UiMount`）作为本 Kit 的子节点。分层与输入拦截**不**由本模块管理，直接用 Control 节点自身的设置（`mouse_filter`、焦点等）。

### 与数据架构的桥

`@export var target_architecture : Architecture`：UI 经事件总线访问的 Model/System 所属作用域；留空则回退为本 Kit 自身。`UiView` 提供：

- `get_arch()` / `get_system()` / `get_model()` / `get_utility()`
- `bind_event(name, callback)` / `send_event(event)`：**`bind_event` 会在 UI 离树时自动解绑**，避免池化复用累积重复回调

### 暂停请求聚合

UI 与暂停动作解耦。UI 通过 `set_pause_request(on)` 向内写入请求，外部通过 `is_pause_requested()` / `get_pause_requests()` 查询。UI 离树时其暂停请求被**自动清空**，隐藏中的 UI 不会永久按住暂停；是否真正暂停仍由外部逻辑决定。

### UiView 契约

子类继承 `UiView`（`extends Control`）并重写：

| 钩子 | 时机 |
|---|---|
| `_ui_enter(params : Dictionary)` | 每次显示（首次与池中复用都会调用）；在此 `bind_event`、按 `params` 刷新 |
| `_ui_exit()` | 每次隐藏 / 离树；在此重置界面自身的可变状态 |

> 不要重写 `_ready` / `_exit_tree`：`_ready` 一生只触发一次（池化复用不会再触发），框架用 `_exit_tree` 兜底清理（自动解绑事件、清空暂停请求）。

### 使用方式

```gdscript
extends UiKit
class_name GameUiKit

func _init_architecture() -> void:
	register(&"PauseMenu", preload("res://ui/pause_menu.tscn"))
	register(&"AchievementToast", preload("res://ui/achievement_toast.tscn"))
	prewarm(&"AchievementToast")
```

```gdscript
extends UiView
class_name PauseMenu

func _ui_enter(params : Dictionary) -> void:
	bind_event(&"GamePausedEvent", _on_paused)
	set_pause_request(true)     # 声明：菜单显示期间请求暂停

func _ui_exit() -> void:
	pass                        # 界面自身状态重置；事件由框架兜底解绑

func _on_paused(event : GamePausedEvent) -> void:
	pass
```

```gdscript
var ui := $GameUiKit as UiKit
ui.open(&"PauseMenu")
get_tree().paused = ui.is_pause_requested()
```

### API

| 方法 | 返回 | 说明 |
|---|---|---|
| `register(ui_id, scene)` | `Error` | 登记 `ui_id → PackedScene`，重名不覆盖 |
| `unregister(ui_id)` | `Error` | 注销并释放该 id 的全部实例 |
| `has_ui(ui_id)` / `get_registered_ids()` | `bool` / `Array[StringName]` | 查询注册表 |
| `prewarm(ui_id)` | `Error` | 预实例化，填充到 `pool_initial` |
| `try_open(ui_id, params := {})` | `Error` | 打开（可断言）；实例经 `get_last_opened()` 取 |
| `open(ui_id, params := {})` | `UiView` | `try_open` 的便捷包装；失败返回 `null` |
| `get_last_opened()` | `UiView` | 最近一次 `try_open` 打开的实例（已释放时返回 `null`） |
| `close(view)` | `Error` | 关闭单个 |
| `close_id(ui_id)` / `close_all()` | `int` | 关闭该 id 全部 / 全部，返回关闭数量 |
| `is_open(ui_id)` | `bool` | 是否有活动实例 |
| `get_active(ui_id)` / `get_all_active()` | `Array[UiView]` | 活动实例 |
| `get_pool_size(ui_id)` / `is_pooled(view)` | `int` / `bool` | 池中空闲实例数量 / 某实例是否在池中 |
| `set_pause_request(view, on)` | `void` | 向内入口（由 `UiView` 转发） |
| `is_pause_requested()` / `get_pause_requests()` | `bool` / `Array[UiView]` | 向外查询 |
| `get_mount()` / `get_target_architecture()` | `CanvasLayer` / `Architecture` | 取挂载点 / 目标架构 |

错误码：

| 返回 | 场景 |
|---|---|
| `OK` | 成功 |
| `ERR_INVALID_PARAMETER` | `ui_id` 为空 / 场景为 `null` / `close` 传入非本 Kit 的实例 |
| `ERR_ALREADY_EXISTS` | `ui_id` 重复注册 |
| `ERR_DOES_NOT_EXIST` | `unregister` 未注册；`close` 的对象已关闭 |
| `ERR_INVALID_DATA` | 场景根节点未挂 `UiView` 脚本（`open` 返回 `null`，`prewarm` 返回此码） |
