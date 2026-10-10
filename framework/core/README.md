[← 返回总览](../../README.md)

# 核心层 framework/core

核心层不依赖任何扩展模块。删除 `framework/kits/` 或 `framework/libs/` 都不影响本层使用。

---

## 目录

- [职责与边界](#职责与边界)
- [Architecture](#architecture)
- [ServiceRegistry（总线与作用域）](#serviceregistry总线与作用域)
- [ServiceConfig](#serviceconfig)
- [错误码约定](#错误码约定)
- [注册键规则](#注册键规则)
- [Model](#model)
- [System](#system)
- [Utility](#utility)
- [Event 与事件总线](#event-与事件总线)
- [生命周期](#生命周期)
- [分层依赖规则](#分层依赖规则)
- [API 速查](#api-速查)
- [FAQ](#faq)

---

## 职责与边界

| 文件 | 基类 | 职责 |
|---|---|---|
| `architecture.gd` | `Node`（`@abstract`） | 作用域 IoC 容器 + 事件总线 + 生命周期 |
| `service_registry.gd` | `Resource` | 服务总线，可实例化、可共享、可快照 |
| `service_config.gd` | `Resource` | 声明式配置：本 Architecture 对外暴露哪些组件 |
| `model.gd` | `Resource` | 数据层基类 |
| `system.gd` | `RefCounted`（`@abstract`） | 逻辑层基类 |
| `utility.gd` | `RefCounted` | 基础设施层基类 |
| `event.gd` | `RefCounted` | 事件基类 |

核心层不包含 View 层抽象。UI / Node 与架构的绑定由业务自行实现（通常是在 System 中通过事件驱动节点）。

---

## Architecture

继承 `Architecture` 并重写 `_init_architecture()`，在其中完成所有注册：

```gdscript
extends Architecture
class_name GameArchitecture

func _init_architecture() -> void:
	# 顺序无强制要求，但建议 Utility → Model → System，便于阅读
	register_utility(MyUtility.new())   # 你的无状态工具，可选
	register_model(PlayerModel.new())
	register_system(CombatSystem.new())
```

### 注册与查询

```gdscript
func register_model(model : Model, model_name : StringName = &"") -> Error
func register_system(system : System, system_name : StringName = &"") -> Error
func register_utility(utility : Utility, utility_name : StringName = &"") -> Error

func unregister_model(model_name : StringName) -> Error
func unregister_system(system_name : StringName) -> Error
func unregister_utility(utility_name : StringName) -> Error

func get_model(model_name : StringName) -> Model
func get_system(system_name : StringName) -> System
func get_utility(utility_name : StringName) -> Utility

func has_model(model_name : StringName) -> bool
func has_system(system_name : StringName) -> bool
func has_utility(utility_name : StringName) -> bool
```

`get_*` 返回基类引用，调用处建议立即用 `as` 转型并判空：

```gdscript
var model := get_model(&"PlayerModel") as PlayerModel
if model == null:
	push_error("PlayerModel 未注册")
	return
```

### 注册时机

- 在 `_init_architecture()` 中注册（即 `_ready()` 内）：所有组件注册完成后，框架统一逐个调用 `_on_init()`。
- 在 `_ready()` 之后注册（运行期动态增删）：注册成功会**立即**调用该组件的 `_on_init()`。
- 在 `deinit()` 之后注册：返回 `ERR_UNAVAILABLE` 并拒绝，防止反初始化后复活。

### 逐帧更新

按需 opt-in。`register_system()` 通过 `has_method()` 探测子类是否定义了对应方法：

```gdscript
extends System
class_name EnemyAISystem

func on_process(delta : float) -> void:
	# 每帧执行
	pass

func on_physics_process(delta : float) -> void:
	# 物理帧执行
	pass
```

未定义这两个方法的 System 不会进入轮询列表，零开销。当轮询列表为空时，Architecture 会自动 `set_process(false)` / `set_physics_process(false)`。

---

## ServiceRegistry（总线与作用域）

`ServiceRegistry` 是一个可实例化的 `Resource`，**没有任何 static 成员**。跨 Architecture 通信通过「显式共享同一个实例」实现，而不是隐式的进程级单例。

```gdscript
func register(service_name : StringName, service : Variant) -> Error
func unregister(service_name : StringName) -> Error
func get_service(service_name : StringName) -> Variant
func has_service(service_name : StringName) -> bool
func get_service_names() -> Array[StringName]
func size() -> int
func clear() -> void
func snapshot() -> Dictionary
func restore(state : Dictionary) -> void
```

### 私有总线（默认）

不赋值 `shared_registry` 时，每个 Architecture 在 `_ready()` 时自建私有实例。此时 `get_service()` 只能查到本作用域暴露的服务。

### 共享总线（跨 Architecture）

在场景编辑器里，为多个 Architecture 节点的 `shared_registry` 赋**同一个** `.tres`，它们即可互相查询：

```
GameRoot (Node)
├── MainArchitecture   (shared_registry: hub.tres, service_config: MainServiceConfig.tres)
├── SaveKit            (service_config: SaveServiceConfig.tres)
└── NetworkArchitecture(shared_registry: hub.tres, service_config: NetworkServiceConfig.tres)
```

也可以在代码里显式注入，便于测试：

```gdscript
var hub := ServiceRegistry.new()
arch_a.shared_registry = hub
arch_b.shared_registry = hub
```

也支持在 Inspector 之外通过 `get_registry()` 读取本作用域总线。

### 关键行为

- **重名不覆盖**：`register()` 遇到已存在的服务名时返回 `ERR_ALREADY_EXISTS` 并保留原值，不会静默覆盖。
- **共享总线上各自注销自己的**：Architecture 在 `deinit()` 时只注销自己在总线上注册过的服务名，不会清空共享总线；只有当它是总线的所有者（即自建的私有实例）时才会整体 `clear()`。
- **共享总线上的同名服务会冲突**：多个 Architecture 暴露同名服务时，后注册者拿到 `ERR_ALREADY_EXISTS`。命名需要全局唯一。
- **共享总线是显式依赖**：忘记给多个 Architecture 赋同一个实例，跨域查询会静默返回 `null`。

`snapshot()` / `restore()` 用于在测试中保存与回滚总线状态。

---

## ServiceConfig

`ServiceConfig` 是声明本 Architecture 对外接口的 `Resource`。在编辑器中新建 `ServiceConfig` 资源（`.tres`），填入组件名称，赋值给 Architecture 节点的 `service_config` 属性。

| 字段 | 类型 | 说明 |
|---|---|---|
| `models` | `Array[StringName]` | 暴露为服务的 Model 名称 |
| `systems` | `Array[StringName]` | 暴露为服务的 System 名称 |
| `utilities` | `Array[StringName]` | 暴露为服务的 Utility 名称 |
| `self_name` | `StringName` | 将 Architecture 自身作为服务暴露的名称；留空则不暴露 |

也可以用代码构造：

```gdscript
var config := ServiceConfig.new()
config.models = [&"PlayerModel"]
config.self_name = &"GameArchitecture"
```

`_ready()` 末尾自动读取 `service_config` 并把声明的服务写入总线；`deinit()` 时自动注销。

**注意**：`service_config` 里写的名字必须与组件实际的**注册键**一致（见下节），否则会 `push_warning` 并跳过该条。

---

## 错误码约定

框架区分「预期内的失败」与「编程错误」：

- **预期内的失败**只用返回码表达，不写日志。例如注销一个不存在的组件 / 服务 / 事件回调 → `ERR_DOES_NOT_EXIST`。
- **编程错误**在返回错误码之外额外 `push_error`，便于定位。例如传入 `null` 实例、服务名为空、脚本缺少 `class_name`。

回调体内部抛出的错误无法被框架捕获（GDScript 没有 `try` / `except`），这类一律保持 `push_error` 日志。

| 返回值 | 出现场景 |
|---|---|
| `OK` | 注册 / 注销成功 |
| `ERR_INVALID_PARAMETER` | 实例为 `null`；名称为空；无 `class_name` 且未显式传名；回调 `Callable` 无效 |
| `ERR_ALREADY_EXISTS` | 组件名 / 服务名 / 事件回调重复注册 |
| `ERR_UNAVAILABLE` | `deinit()` 之后仍尝试注册 |
| `ERR_DOES_NOT_EXIST` | 注销的组件 / 服务 / 事件回调不存在 |

`send_event(event) -> int` 返回实际执行的回调数量，用于断言事件确实被消费。

---

## 注册键规则

组件的注册键按以下顺序确定：

1. 显式传入的 `model_name` / `system_name` / `utility_name`（非空时优先）。
2. 回退到脚本的 `class_name`（即 `GDScript.get_global_name()`）。
3. 两者皆空 → 返回 `ERR_INVALID_PARAMETER` 并 `push_error`，**不会**静默使用空字符串造成碰撞。

因此参与注册的脚本必须有 `class_name`，或调用时显式传名：

```gdscript
register_model(PlayerModel.new())                    # 键 = &"PlayerModel"
register_model(ProbeModel.new(), &"ProbeA")          # 无 class_name 时显式命名
register_model(ProbeModel.new(), &"ProbeB")          # 同一脚本可为多实例分别命名
```

事件类型键同理，由 `Event` 子类的 `class_name` 决定。

---

## Model

- 基类 `Resource`，可被 Godot 原生序列化，也支持 `@export`。
- 承载数据；状态变更应由 System 驱动。

```gdscript
extends Model
class_name InventoryModel

@export var items : Array[String] = []
var selected_index : int = 0
```

| 成员 | 说明 |
|---|---|
| `get_script_name() -> StringName` | 返回脚本的 `class_name` |
| `get_architecture() -> Architecture` | 返回所属 Architecture |
| `_on_init()` / `_on_deinit()` | 生命周期钩子，由所属 Architecture 调用 |
| `get_utility(name) -> Utility` | 同层访问器，经 Architecture 路由 |
| `register_event(name, callback) -> Error` | 委托给所属 Architecture |
| `unregister_event(name, callback) -> Error` | 委托给所属 Architecture |
| `send_event(event) -> int` | 委托给所属 Architecture |

**Model 不提供 `get_system()` / `get_model()`**——Model 不应感知逻辑层。

---

## System

- 基类 `RefCounted`（`@abstract`），承载业务逻辑。

| 成员 | 说明 |
|---|---|
| `get_script_name() -> StringName` | 返回脚本的 `class_name` |
| `get_architecture() -> Architecture` | 返回所属 Architecture |
| `_on_init()` / `_on_deinit()` | 生命周期钩子，由所属 Architecture 调用 |
| `get_system(name) -> System` | 同层访问 |
| `get_model(name) -> Model` | 访问数据层 |
| `get_utility(name) -> Utility` | 访问基础设施层 |
| `register_event(name, callback) -> Error` | 注册事件回调 |
| `unregister_event(name, callback) -> Error` | 注销事件回调 |
| `send_event(event) -> int` | 派发事件，返回执行的回调数 |
| `on_process(delta)` | 可选：定义后自动纳入逐帧轮询 |
| `on_physics_process(delta)` | 可选：定义后自动纳入物理帧轮询 |

事件回调建议在 `_on_init` 注册、在 `_on_deinit` 注销，避免悬挂回调。

---

## Utility

- 基类 `RefCounted`，提供基础设施能力（存储、网络、序列化、配置等）。
- 不持有业务状态，不感知任何业务层。

| 成员 | 说明 |
|---|---|
| `get_script_name() -> StringName` | 返回脚本的 `class_name` |
| `get_architecture() -> Architecture` | 返回所属 Architecture |

---

## Event 与事件总线

事件以类的 `class_name` 作为类型键，携带任意字段：

```gdscript
extends Event
class_name EnemyKilledEvent

var enemy_id : StringName
var killer : StringName

func _init(_enemy_id : StringName = &"", _killer : StringName = &"") -> void:
	enemy_id = _enemy_id
	killer = _killer
```

```gdscript
# 注册（通常在 System._on_init 中）
register_event(&"EnemyKilledEvent", _on_enemy_killed)

func _on_enemy_killed(event : EnemyKilledEvent) -> void:
	print("%s 击杀了 %s" % [event.killer, event.enemy_id])

# 派发；返回实际执行的回调数
var executed := send_event(EnemyKilledEvent.new(&"goblin_01", &"player"))
```

- 事件在**所属 Architecture 作用域内**分发，不会跨 Architecture 传播。
- 回调列表由 `Mutex` 保护；`send_event` 会复制列表并过滤已失效的 `Callable`。
- 高频事件（如每帧的位置更新）建议直接在 System 内调用，不必走事件总线。

---

## 生命周期

```
Architecture._ready()
        │
        ├─ _setup_registry()            ← 复用 shared_registry 或自建私有实例
        │
        ├─ _init_architecture()         ← 子类在此注册 M / S / U
        │
        ├─ for system: _on_init()       ← System 初始化（注册事件等）
        ├─ for model:  _on_init()       ← Model 初始化
        │
        ├─ _initialized = true          ← 此后注册的组件会立即 _on_init()
        │
        ├─ _register_services()         ← 按 service_config 写入总线
        ├─ _sync_tick_flags()           ← 按需开关 _process / _physics_process
        │
        │   ───── 运行期 ─────
        │   on_process / on_physics_process（按 opt-in）
        │   send_event → 回调执行
        │
Architecture._exit_tree()               ← 离开场景树时自动触发
        │
        └─ deinit()
              ├─ 注销本节点在总线上注册过的服务名
              ├─ 自有总线整体 clear()
              ├─ for system: _on_deinit()
              ├─ for model:  _on_deinit()
              └─ 清空所有容器与事件回调

Architecture.deinit()                   ← 也可手动调用，幂等
```

`deinit()` 的特性：

- **幂等**：内部有独立的 `_deinited` 标志，重复调用不会重复触发 `_on_deinit()`。
- **自动触发**：节点离开场景树（`_exit_tree`）时自动调用，无需手动清理。
- **注意**：节点被移出场景树重新挂载（reparent）也会触发一次 `_exit_tree`。需要保活的 Architecture 请避免中途移出树。

---

## 分层依赖规则

```
┌──────────────────────────────────────────────┐
│  System 层（逻辑）                            │
│  ─ 可访问：System、Model、Utility、Event      │
└──────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────┐
│  Model 层（数据）                             │
│  ─ 可访问：Utility、Event（不可访问 System）  │
└──────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────┐
│  Utility 层（基础设施）                       │
│  ─ 可访问：仅自身（无业务依赖）               │
└──────────────────────────────────────────────┘
```

- **System → System**：允许，但应避免环依赖。
- **Model → System**：禁止。Model 不应感知逻辑层。
- **Utility → 任意业务层**：禁止。
- **任意层 → Event**：允许注册与派发。

这些规则不会编译报错，需要在 Code Review 时把关。

---

## API 速查

| 类 | 方法 |
|---|---|
| `Architecture` | `register_model/system/utility(obj, name := &"") -> Error`、`unregister_*(name) -> Error`、`get_*/has_*(name)`、`get_registry()`、`get_service(name)`、`register_event/unregister_event(name, cb) -> Error`、`send_event(e) -> int`、`deinit()` |
| `ServiceRegistry` | `register/unregister(name, obj) -> Error`、`get_service/has_service(name)`、`get_service_names()`、`size()`、`clear()`、`snapshot()`、`restore(state)` |
| `ServiceConfig` | `models` / `systems` / `utilities` / `self_name` |
| `Model` | `get_script_name()`、`get_architecture()`、`get_utility(name)`、`register_event/unregister_event/send_event` |
| `System` | `get_script_name()`、`get_architecture()`、`get_system/get_model/get_utility(name)`、`register_event/unregister_event/send_event`、可选 `on_process/on_physics_process` |
| `Utility` | `get_script_name()`、`get_architecture()` |
| `Event` | `get_script_name()` |

---

## FAQ

**Q1：为什么不用 Autoload 单例？**

全局单例会引入隐式耦合、难以隔离与测试。`Architecture` 作为作用域容器可挂载到任意节点；服务总线是可实例化对象，不存在进程级静态状态。

**Q2：两个 Architecture 怎么互相通信？**

给它们赋同一个 `shared_registry` 实例，然后各自通过 `get_service()` 查询对方用 `service_config` 暴露出来的服务。

**Q3：`deinit()` 已经自动触发了，我还需要手动调用吗？**

通常不需要。需要提前释放或显式重建时手动调用即可，它是幂等的。`deinit()` 之后再调用 `register_*` 会返回 `ERR_UNAVAILABLE`。

**Q4：为什么重名注册不再覆盖？**

静默覆盖会让「多个子系统抢占同一个名字」这类问题极难排查。现在重名会返回 `ERR_ALREADY_EXISTS`，由调用方决定如何处理。

**Q5：脚本没有 `class_name` 怎么办？**

注册时显式传名，例如 `register_model(MyModel.new(), &"MyModel")`；或者给脚本补上 `class_name`。不传名会得到 `ERR_INVALID_PARAMETER`。

**Q6：事件回调里能直接改 Model 吗？**

可以，但建议把数据修改集中在 System 内，事件回调只做通知与触发，职责更清晰。

**Q7：Model 继承 `Resource` 有什么注意点？**

`Resource` 是引用共享的，多处持有同一实例会相互影响。跨文件持久化时请深拷贝（`duplicate(true)`）。

**Q8：注册的组件是单例吗？**

在单个 `Architecture` 作用域内，每个注册键对应唯一实例。不同 Architecture 实例之间互不影响。