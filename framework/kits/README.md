[← 返回总览](../../README.md)

# 扩展 Kit framework/kits

Kit 是可选扩展，不参与核心架构。删除整个 `framework/kits/` 目录不影响 [核心层](../core/README.md) 的使用。

---

## 目录

- [Kit 定位](#kit-定位)
- [FSM](#fsm)
- [ResourceKit](#resourcekit)
- [SaveKit](#savekit)
- [与核心层的关系](#与核心层的关系)

---

## Kit 定位

| Kit | 基类 | 类型 |
|---|---|---|
| `fsm_kit.gd` | `RefCounted` | 通用状态机，与核心层无耦合 |
| `resource_kit.gd` | `Utility` | 单个 Resource 的存取工具 |
| `save_kit.gd` | `Node` | 多 Model 的版本化整体存档容器 |

Kit 之间互不依赖，可按需引入。

---

## FSM

一个简洁的**非分层**状态机。`class_name FSM`，`extends RefCounted`，不依赖核心层任何类。

### 组成

- `FSMState`：内部抽象类（`@abstract class FSMState extends RefCounted`），需实现 `enter()` / `update(delta)` / `exit()`。
- `FSM`：状态机本体，用 `StringName` 索引状态。

### API

| 方法 | 说明 |
|---|---|
| `FSM.new(enums : Array[StringName])` | 用允许的状态名列表构造；空列表会 `push_error` |
| `add_state(state : FSMState)` | 添加状态；状态名必须已在构造列表中，且不可重复添加 |
| `start()` | 启动；所有状态都已填充才会成功 |
| `stop()` | 停止 |
| `change_state(name : StringName)` | 切换状态（仅激活状态可用） |
| `update(delta : float)` | 更新当前状态 |
| `clear()` | 停止并清空状态列表 |

### 状态定义约定

`FSMState._init(_name : StringName, fsm : Object)` 需要传入归属的 FSM 实例。构造时会校验：

- `fsm` 必须是有效对象；
- `fsm` 必须带 `ISFSM` 元数据（`FSM` 在构造时 `set_meta`），否则拒绝。

状态内部通过 `WeakRef` 持有状态机，避免循环引用；切换状态调用 `_change_state(name)`。

```gdscript
extends FSM.FSMState
class_name PlayerIdleState

func _init(fsm : Object) -> void:
	super._init(&"Idle", fsm)

func enter() -> void:
	print("进入待机")

func update(delta : float) -> void:
	if Input.is_action_just_pressed("move_right"):
		_change_state(&"Run")

func exit() -> void:
	print("退出待机")
```

```gdscript
# 在某个 System 内
var _fsm : FSM

func _on_init() -> void:
	_fsm = FSM.new([&"Idle", &"Run", &"Jump"])
	_fsm.add_state(PlayerIdleState.new(_fsm))
	_fsm.add_state(PlayerRunState.new(_fsm))
	_fsm.add_state(PlayerJumpState.new(_fsm))
	_fsm.start()

func on_process(delta : float) -> void:
	_fsm.update(delta)

func _on_deinit() -> void:
	_fsm.clear()
```

`FSM.update()` 只在主动调用时推进，因此既可用于逐帧驱动，也可只做事件驱动的状态切换。

---

## ResourceKit

继承 `Utility` 的资源存取工具，用于保存单个 `Resource`。

| 方法 | 说明 |
|---|---|
| `resource_save(resource : Resource, save_path : String) -> void` | 保存到指定路径 |
| `resource_load(save_path : String) -> Resource` | 读取并**深拷贝**返回；文件不存在时返回 `null` |

约束：

- 路径必须以 `user://` 开头，否则 `push_error` 并拒绝。
- 文件名必须以 `.tres` 结尾，否则 `push_error` 并拒绝。
- 保存前会自动创建所需目录；读取时若目录不存在也会先创建再返回 `null`。
- 返回的是 `duplicate(true)` 的结果，修改它不会影响磁盘文件。

```gdscript
var rk := get_utility(&"ResourceKit") as ResourceKit
rk.resource_save(player_model, "user://save/player.tres")

var loaded := rk.resource_load("user://save/player.tres") as PlayerModel
if loaded != null:
	player_model.hp = loaded.hp
```

---

## SaveKit

`class_name SaveKit`，**`extends Node`**（不是 `Architecture`）。它是独立于业务架构的存档作用域容器，只承载实现了存档接口的 Model，避免存档域与业务域互相耦合。

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
├── MainArchitecture  (service_config: MainServiceConfig.tres)
└── SaveKit           (service_config: SaveServiceConfig.tres)
```

### saveable Model 契约

| 方法 | 必填 | 说明 |
|---|---|---|
| `get_data() -> Dictionary` | 是 | 返回需要持久化的字段 |
| `set_data(data : Dictionary) -> void` | 是 | 从字典恢复字段 |
| `get_version() -> int` | 否 | 数据版本号，未实现时按 1 处理 |
| `migrate(data : Dictionary, from_version : int) -> Dictionary` | 否 | 版本迁移钩子，逐版本向上迁移 |
| `get_defaults() -> Dictionary` | 否 | 默认值字典，用于补齐老存档缺失的字段 |

注册时会用 `has_method()` 校验 `get_data` / `set_data` 是否存在，缺失则 `push_error` 并拒绝。注册键取 `Model.get_script_name()`，因此 saveable Model 需要 `class_name`。

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

| 方法 | 说明 |
|---|---|
| `register_saveable(model : Model) -> void` | 注册存档 Model |
| `unregister_saveable(model_name : StringName) -> void` | 注销 |
| `get_model(model_name : StringName) -> Model` | 查询 |
| `has_model(model_name : StringName) -> bool` | 判断是否已注册 |
| `save(path : String) -> void` | 写出存档 |
| `load(path : String) -> void` | 读入存档并写回各 Model |
| `has_save(path : String) -> bool` | 判断存档文件是否存在 |
| `get_save_info(path : String) -> Dictionary` | 读取元信息，不触发 `set_data`，适合选档界面预览 |
| `get_service(service_name : StringName) -> Variant` | 查询本节点总线上的服务 |

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

`save` / `load` / `has_save` / `get_save_info` 都强制：

- 路径必须以 `user://` 开头；
- 禁止 `..` 目录穿越（反斜杠会被规范化后再校验）。

建议按槽位命名，例如 `user://saves/slot_1.save`。

---

## 与核心层的关系

- `FSM` 与核心层完全解耦，可独立使用。
- `ResourceKit` 是 `Utility` 子类，注册进 Architecture 后通过 `get_utility(&"ResourceKit")` 取用。
- `SaveKit` 有自己独立的节点生命周期与存档 Model 容器，不复用 `Architecture` 的组件注册。

### SaveKit 的当前状态

核心层已把服务总线由全局静态表改为可实例化的 `ServiceRegistry`（详见[核心层文档](../core/README.md)）。`SaveKit` 本轮只做了**保证可编译的最小适配**：它自持一个**私有** `ServiceRegistry`，因此：

- 它的 `_ready()` / `_exit_tree()` / `register_saveable()` / `save()` / `load()` 行为与之前一致；
- 但它在总线上暴露的服务目前**无法被其他 Architecture 查询到**（没有共享同一实例的途径）。

`SaveKit` 尚未按新的可注入总线模型重构。在重构完成前，如果需要在业务 System 中访问存档 Model，请直接持有 `SaveKit` 节点引用，而不要依赖 `get_service()` 跨域查询。