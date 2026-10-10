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
