# godot_mvc

一个面向 **Godot 4.7+** 的轻量级 MVC / 分层架构框架。

以 **Architecture（作用域 IoC 容器）** 为核心，将游戏逻辑拆分为 **Model（数据）/ System（逻辑）/ Utility（基础设施）** 三层，并通过内置事件总线与可选 Kit（FSM、ResourceKit）协作，替代传统全局 Autoload 单例。

---

## 目录

- [架构总览](#架构总览)
- [核心概念](#核心概念)
  - [Architecture](#architecture)
  - [Model](#model)
  - [System](#system)
  - [Utility](#utility)
  - [Event](#event)
- [Kit 扩展](#kit-扩展)
  - [FSM](#fsm)
  - [ResourceKit](#resourcekit)
- [安装](#安装)
- [快速开始](#快速开始)
- [详细使用指南](#详细使用指南)
  - [1. 创建自己的 Architecture](#1-创建自己的-architecture)
  - [2. 定义 Model](#2-定义-model)
  - [3. 定义 System](#3-定义-system)
  - [4. 定义 Utility](#4-定义-utility)
  - [5. 定义与发送 Event](#5-定义与发送-event)
  - [6. 使用 FSM](#6-使用-fsm)
  - [7. 持久化数据](#7-持久化数据)
- [分层依赖规则](#分层依赖规则)
- [生命周期](#生命周期)
- [最佳实践](#最佳实践)
- [架构优缺点分析](#架构优缺点分析)
- [常见问题（FAQ）](#常见问题faq)
- [许可证](#许可证)

---

## 架构总览

```
┌────────────────────────────────────────────────────────────┐
│                      Architecture                          │
│              （作用域 IoC 容器 / 事件总线）                │
│                                                            │
│   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   │
│   │   Model(s)   │   │  System(s)   │   │ Utility(s)   │   │
│   │  数据层      │◀──│  逻辑层      │──▶│  基础设施层  │   │
│   │ extends      │   │ extends      │   │ extends      │   │
│   │  Resource    │   │  RefCounted  │   │  RefCounted  │   │
│   └──────────────┘   └──────────────┘   └──────────────┘   │
│           ▲                   ▲                   ▲         │
│           └─────────── Event Bus（线程安全）────────┘         │
│                                                            │
│   可选 Kit：FSM（状态机） / ResourceKit（资源存取）          │
└────────────────────────────────────────────────────────────┘
            ▲                                       ▲
            │                                       │
        Godot 场景树                            View 层
       （Node / Scene / UI）              （由业务自行组织）
```

**设计要点：**

1. **作用域化**：`Architecture` 继承自 `Node`，可作为场景节点挂载，多个 Architecture 实例可并存（适合分场景 / 子模块隔离）。
2. **分层清晰**：Model 只承载数据，System 承载逻辑，Utility 提供基础设施，依赖方向单一。
3. **事件总线内置**：无需额外 Autoload，事件按 Architecture 作用域分发，并使用 `Mutex` 保证线程安全。
4. **按需 tick**：System 通过定义 `on_process` / `on_physics_process` 方法 opt-in 逐帧更新，未定义的 System 不会进入轮询列表。
5. **Kit 化扩展**：FSM、ResourceKit 等以可选 Kit 形式提供，核心保持精简。

---

## 核心概念

### Architecture

[framework/core/architecture.gd](framework/core/architecture.gd)

- **角色**：作用域 IoC 容器 + 事件总线 + 生命周期管理器。
- **职责**：
  - 注册 / 注销 / 查询 Model、System、Utility。
  - 维护 `on_process` / `on_physics_process` 的 System 列表并驱动逐帧更新。
  - 提供线程安全的事件注册、注销、派发。
  - 在 `_ready()` 中自动调用 `_init_architecture()`，并依次触发 System / Model 的 `_on_init()`。
- **关键 API**：
  - `register_model(system, utility)` / `unregister_xxx(name)` / `get_xxx(name)`
  - `register_event(name, callback)` / `unregister_event(name, callback)` / `send_event(event)`
  - `deinit()`：手动反初始化，清理所有组件。

### Model

[framework/core/model.gd](framework/core/model.gd)

- **基类**：`Resource`（可被 Godot 原生序列化）。
- **职责**：存储数据；通过 `@export` 暴露需要持久化的字段。
- **可见性**：可被 System 读写；自身不应直接调用 System。
- **路由能力**：`get_utility()`、`register_event()` / `send_event()` 均委托给所属 Architecture。

### System

[framework/core/system.gd](framework/core/system.gd)

- **基类**：`RefCounted`，`@abstract`。
- **职责**：承载业务逻辑，读写 Model，调用 Utility。
- **逐帧更新**：opt-in——子类按需定义 `func on_process(delta)` 或 `func on_physics_process(delta)`，注册时自动被加入轮询列表。
- **同层访问**：`get_system()` / `get_model()` / `get_utility()` 经 Architecture 路由。

### Utility

[framework/core/utility.gd](framework/core/utility.gd)

- **基类**：`RefCounted`。
- **职责**：提供基础设施能力（存储、网络、序列化、配置等）。
- **特点**：不持有业务状态，纯工具性质；可被任意层通过 `get_utility()` 取用。

### Event

[framework/core/event.gd](framework/core/event.gd)

- **基类**：`RefCounted`。
- **使用方式**：业务自定义子类（携带任意字段），以类的 `global_name` 作为事件类型键。
- **派发**：调用 `architecture.send_event(event)` 或 `model/system.send_event(event)`。
- **线程安全**：内部使用 `Mutex` 保护回调列表。

---

## Kit 扩展

### FSM

[framework/kits/fsm_kit.gd](framework/kits/fsm_kit.gd)

一个简洁的非分层状态机：

- `FSMState`（内部抽象类）：实现 `enter()` / `update(delta)` / `exit()`。
- 状态通过 `StringName` 索引；构造时传入允许的状态枚举数组。
- 通过 `WeakRef` 引用状态机，避免循环引用。
- 严格的状态校验：未激活时切换状态、状态为空、状态不存在等都会 `push_error`。

### ResourceKit

[framework/kits/resource_kit.gd](framework/kits/resource_kit.gd)

继承自 `Utility`，提供资源持久化能力：

- `resource_save(resource, path)`：保存到 `user://` 下的 `.tres` 文件。
- `resource_load(path)`：读取并 **深拷贝** 返回，避免直接修改源资源。
- 自动创建所需目录。

---

## 安装

### 直接复制 framework 目录

将本仓库的 `framework/` 目录整体拷贝到你的 Godot 项目的 `res://` 下即可。框架全部以 `class_name` 全局注册，无需配置 Autoload。

## 快速开始

下面以一个「玩家血量」的最小示例演示完整流程。

### 1. 定义 Model

```gdscript
# player_model.gd
extends Model
class_name PlayerModel

var hp: int = 100
var max_hp: int = 100

func damage(amount: int) -> void:
    hp = max(hp - amount, 0)
```

### 2. 定义 Event

```gdscript
# player_damaged_event.gd
extends Event
class_name PlayerDamagedEvent

var amount: int
var current_hp: int

func _init(_amount: int = 0, _current_hp: int = 0) -> void:
    amount = _amount
    current_hp = _current_hp
```

### 3. 定义 System

```gdscript
# combat_system.gd
extends System
class_name CombatSystem

func _on_init() -> void:
    register_event(&"PlayerDamagedEvent", _on_player_damaged)

func _on_deinit() -> void:
    unregister_event(&"PlayerDamagedEvent", _on_player_damaged)

func deal_damage(amount: int) -> void:
    var model := get_model(&"PlayerModel") as PlayerModel
    model.damage(amount)
    send_event(PlayerDamagedEvent.new(amount, model.hp))

func _on_player_damaged(event: PlayerDamagedEvent) -> void:
    print("玩家受到 %d 点伤害，当前血量 %d" % [event.amount, event.current_hp])
```

### 4. 定义 Architecture

```gdscript
# game_architecture.gd
extends Architecture
class_name GameArchitecture

func _init_architecture() -> void:
    register_model(PlayerModel.new())
    register_system(CombatSystem.new())
    register_utility(ResourceKit.new())
```

### 5. 在场景中挂载

1. 创建一个 `Node` 作为根节点。
2. 为其附加脚本 `game_architecture.gd`。
3. 在子节点中通过 `get_node("/root/Architecture节点")` 或信号获取引用：

```gdscript
# main.gd
extends Node

@onready var arch: Architecture = $Architecture

func _ready() -> void:
    var combat := arch.get_system(&"CombatSystem") as CombatSystem
    combat.deal_damage(30)  # 输出：玩家受到 30 点伤害，当前血量 70
```

---

## 详细使用指南

### 1. 创建自己的 Architecture

继承 `Architecture`，重写 `_init_architecture()`，在其中完成所有注册：

```gdscript
extends Architecture
class_name MyArch

func _init_architecture() -> void:
    # 顺序：Utility → Model → System（建议）
    register_utility(ResourceKit.new())
    register_utility(NetworkKit.new())

    register_model(PlayerModel.new())
    register_model(EnemyModel.new())

    register_system(CombatSystem.new())
    register_system(SpawnerSystem.new())
```

> 注册顺序无强制要求（`_ready` 中会统一在所有注册完成后才调用 `_on_init`），但保持一致顺序便于阅读。

### 2. 定义 Model

```gdscript
extends Model
class_name InventoryModel

# 可被 @export 持久化
@export var items: Array[String] = []

# 运行时状态
var selected_index: int = 0

func add_item(item_id: String) -> void:
    items.append(item_id)
```

**注意**：Model 内部 **不要** 直接 `get_system()`——这是层级违规。Model 的状态变更应由 System 驱动，并通过事件通知外界。

### 3. 定义 System

#### 静态逻辑 System

```gdscript
extends System
class_name InventorySystem

func add_item(item_id: String) -> void:
    var model := get_model(&"InventoryModel") as InventoryModel
    model.add_item(item_id)
    send_event(InventoryChangedEvent.new(model.items))
```

#### 逐帧 System（opt-in）

只需定义 `on_process` 或 `on_physics_process`，注册时会被自动纳入轮询：

```gdscript
extends System
class_name EnemyAILogicSystem

func _on_init() -> void:
    register_event(&"SpawnEnemyEvent", _on_spawn)

func on_process(delta: float) -> void:
    # 每帧执行
    var model := get_model(&"EnemyModel") as EnemyModel
    model.tick_timers(delta)

func on_physics_process(delta: float) -> void:
    # 物理帧执行
    pass

func _on_spawn(event) -> void:
    # ...
    pass
```

> 不需要逐帧的 System 不定义这两个方法即可，零额外开销。

### 4. 定义 Utility

```gdscript
extends Utility
class_name NetworkKit

var _base_url: String = "https://api.example.com"

func get_base_url() -> String:
    return _base_url

func request(path: String) -> void:
    # ...HTTPRequest 封装
    pass
```

获取：

```gdscript
var net := get_utility(&"NetworkKit") as NetworkKit
```

### 5. 定义与发送 Event

**定义：**

```gdscript
extends Event
class_name EnemyKilledEvent

var enemy_id: StringName
var killer: StringName

func _init(_enemy_id: StringName = &"", _killer: StringName = &"") -> void:
    enemy_id = _enemy_id
    killer = _killer
```

**监听：**

```gdscript
# 在任意 System / Model 的 _on_init 中
register_event(&"EnemyKilledEvent", _on_enemy_killed)

func _on_enemy_killed(event: EnemyKilledEvent) -> void:
    print("%s 击杀了 %s" % [event.killer, event.enemy_id])
```

**派发：**

```gdscript
send_event(EnemyKilledEvent.new(&"goblin_01", &"player"))
```

**注销：** 在 `_on_deinit` 中调用 `unregister_event`，避免悬挂回调。

> **类型键说明**：事件类型键使用类的 `global_name`（即 `&"EnemyKilledEvent"`）。框架在 `send_event` 中会通过 `event.get_script_name()` 自动获取，因此注册时传入对应字符串即可。

### 6. 使用 FSM

#### 6.1 定义状态

```gdscript
extends FSM.FSMState
class_name PlayerIdleState

func _init() -> void:
    super._init(&"Idle", null)  # 真实使用见下文

func enter() -> void:
    print("进入待机状态")

func update(delta: float) -> void:
    if Input.is_action_just_pressed("move_right"):
        _change_state(&"Run")

func exit() -> void:
    print("退出待机状态")
```

#### 6.2 组装并启动

```gdscript
# 在某个 System 内
var _fsm: FSM

func _on_init() -> void:
    _fsm = FSM.new([&"Idle", &"Run", &"Jump"])
    _fsm.add_state(PlayerIdleState.new(_fsm))
    _fsm.add_state(PlayerRunState.new(_fsm))
    _fsm.add_state(PlayerJumpState.new(_fsm))
    _fsm.start()

func on_process(delta: float) -> void:
    _fsm.update(delta)

func _on_deinit() -> void:
    _fsm.clear()
```

> **状态构造约定**：`FSMState._init(name, fsm)` 需要传入归属的 FSM 实例（框架内部使用 `WeakRef` 避免循环引用）。子类的 `_init` 通常直接 `super._init(&"状态名", fsm)`。

### 7. 持久化数据

```gdscript
# 保存
var rk := get_utility(&"ResourceKit") as ResourceKit
var player_model := get_model(&"PlayerModel") as PlayerModel
rk.resource_save(player_model, "user://save/player.tres")

# 读取
var loaded := rk.resource_load("user://save/player.tres") as PlayerModel
if loaded:
    # 替换当前 Model 数据
    player_model.hp = loaded.hp
    player_model.max_hp = loaded.max_hp
```

> `ResourceKit` 强制使用 `user://` 目录与 `.tres` 后缀，避免误写工程目录。读取时会返回深拷贝，修改不会影响磁盘文件。

---

## 分层依赖规则

```
┌──────────────────────────────────────────────┐
│  System 层（逻辑）                           │
│  ─ 可访问：System、Model、Utility、Event     │
└──────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────┐
│  Model 层（数据）                            │
│  ─ 可访问：Utility、Event（不可访问 System） │
└──────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────┐
│  Utility 层（基础设施）                      │
│  ─ 可访问：仅自身（无业务依赖）              │
└──────────────────────────────────────────────┘
```

- **System → System**：允许（通过 `get_system`），但应避免环依赖。
- **Model → System**：禁止。Model 不应感知逻辑层的存在。
- **Utility → 任意业务层**：禁止。Utility 必须保持纯净。
- **任意层 → Event**：允许注册与派发。

违反规则的代码不会编译报错，但会破坏架构的可维护性，应在 Code Review 时把关。

---

## 生命周期

```
Architecture._ready()
        │
        ├─ _init_architecture()        ← 子类在此注册 M/S/U
        │
        ├─ for system: _on_init()      ← System 初始化（注册事件等）
        ├─ for model:  _on_init()      ← Model 初始化
        │
        ├─ _initialized = true         ← 此后注册的组件会立即 _on_init
        │
        │   ───── 运行期 ─────
        │   on_process / on_physics_process（按 opt-in）
        │   send_event → 回调执行
        │
        └─ Architecture.deinit()       ← 手动调用（场景退出时建议触发）
              ├─ for system: _on_deinit()
              ├─ for model:  _on_deinit()
              └─ 清空所有容器
```

> **重要**：`deinit()` 不会自动触发，建议在 Architecture 节点的 `_notification(NOTIFICATION_PREDELETE)` 或上层场景的 `_exit_tree()` 中显式调用。

---

## 最佳实践

### 命名规范

- Model：`XxxModel`（如 `PlayerModel`）
- System：`XxxSystem`（如 `CombatSystem`）
- Utility：`XxxKit`（如 `NetworkKit`）或 `XxxUtility`
- Event：`XxxEvent`（如 `PlayerDamagedEvent`）
- 状态：`XxxState`（如 `PlayerIdleState`）

### 注册与注销

- **事件**：始终在 `_on_init` 中注册，在 `_on_deinit` 中注销。
- **动态组件**：如需运行时增删 Model/System，使用 `register_xxx` / `unregister_xxx`，注意 `_initialized` 为 true 时注册会立即触发 `_on_init`。

### 类型安全

`get_model` / `get_system` / `get_utility` 返回基类引用，建议立即 `as` 转型：

```gdscript
var model := get_model(&"PlayerModel") as PlayerModel
if not model:
    push_error("PlayerModel 未注册")
    return
```

### 多 Architecture 隔离

由于 Architecture 是作用域化的，可以同时存在多个实例（例如：主场景一个、某个子 UI 一个）。事件不会跨 Architecture 传播——这是优势，也意味着跨域通信需要业务自行桥接。

### FSM 使用

- 状态机不要嵌套过深，复杂 AI 考虑使用多个独立 FSM 或行为树 Kit。
- 状态对象持有 FSM 的 `WeakRef`，确保 FSM 被释放后状态不会悬挂。

### 性能

- System opt-in 机制确保只有真正需要逐帧的 System 才会被 tick。
- 高频事件（如每帧触发的位置更新）应考虑直接在 System 内调用，而非走事件总线。
- `send_event` 会 `duplicate` 回调列表并过滤无效回调，对超大订阅者列表有一定开销。

---

## 架构优缺点分析

### 优点

| 维度 | 说明 |
|------|------|
| **分层清晰** | Model / System / Utility 三层职责单一，依赖方向单向，业务代码组织规范。 |
| **作用域化 IoC** | `Architecture` 继承 `Node` 可挂载到场景树，替代全局 Autoload 单例，支持多实例并存与子模块隔离。 |
| **事件总线内置** | 无需第三方库即可实现发布订阅；使用 `Mutex` 保证线程安全，适合多线程场景。 |
| **opt-in 逐帧更新** | System 仅在定义 `on_process` / `on_physics_process` 时才进入轮询列表，未定义的 System 零开销，避免空函数调用浪费。 |
| **类型友好的键** | 使用 `StringName` 作为注册键，兼顾性能与可读性。 |
| **Model 基于 Resource** | 天然支持 Godot 序列化，配合 `ResourceKit` 可直接持久化，无需额外序列化代码。 |
| **Kit 化扩展** | FSM、ResourceKit 等以可选 Kit 提供，核心精简，按需引入。 |
| **WeakRef 破循环引用** | FSM 状态对状态机的引用使用弱引用，避免内存泄漏。 |
| **生命周期完备** | `_on_init` / `_on_deinit` 钩子覆盖初始化与反初始化场景。 |
| **严格校验** | 重复注册、空状态、未激活切换等均会 `push_error`，问题早暴露。 |

### 缺点与局限

| 维度 | 说明 | 建议 |
|------|------|------|
| **无 View 层抽象** | 框架只规范了 M/S/U，UI/Node 与架构的绑定需要业务自行实现。 | 在 System 中通过事件驱动 Node，或自建薄 View 层。 |
| **类型擦除** | `get_model` 等返回基类，需要手动 `as` 转型，缺少编译期类型安全。 | 统一在调用处立即转型并判空；或封装类型化 getter。 |
| **事件类型键为类名** | 同名类（不同命名空间）会冲突；事件类型由 `global_name` 决定。 | 命名上加前缀区分；避免重名。 |
| **无示例 / 单元测试** | 仓库当前不含 demo 场景与测试用例，新手上手成本较高。 | 参考本 README 的最小示例起步。 |
| **deinit 需手动调用** | `Architecture` 不会在场景退出时自动反初始化。 | 在 `_exit_tree` 或 `NOTIFICATION_PREDELETE` 中显式调用 `deinit()`。 |
| **事件总线性能** | `send_event` 会复制回调数组并过滤无效项，订阅者极多时存在开销。 | 高频事件改走直接调用；按 Architecture 拆分事件域。 |
| **FSM 非分层** | 不支持状态嵌套 / 并行状态，复杂 AI 表达力有限。 | 复杂场景使用多个 FSM，或自行扩展分层状态机 Kit。 |
| **ResourceKit 路径限制严格** | 仅允许 `user://` + `.tres`，不支持二进制 `.res` 或自定义路径。 | 如需更灵活存储，继承 `Utility` 自行实现。 |
| **仅支持 GDScript** | `get_script_name()` 通过 `GDScript.get_global_name()` 实现，C# 脚本不兼容。 | 框架定位为 GDScript 项目使用。 |
| **Model 行为膨胀风险** | Model 可调用 Utility 与发送事件，若放任易演变为「胖 Model」。 | Code Review 把关，Model 仅暴露纯数据操作。 |
| **跨 Architecture 通信缺失** | 事件不跨域传播，多 Architecture 协作需业务桥接。 | 顶层 Architecture 统一管理，或显式转发事件。 |

### 适用场景

- **适合**：中大型 Godot 项目、需要清晰分层与可维护性的团队协作项目、希望摆脱 Autoload 单例地狱的场景。
- **不太适合**：极小型 Game Jam 项目（框架开销大于收益）、强依赖分层状态机的复杂 AI 项目（需自行扩展）、C# 项目。

---

## 常见问题（FAQ）

### Q1：为什么不用 Autoload 单例？

全局单例容易导致隐式耦合、测试困难、多场景隔离困难。`Architecture` 作为作用域容器，可挂载到任意节点，天然支持隔离与多实例。

### Q2：System 之间互相调用怎么办？

通过 `get_system(&"XxxSystem")` 获取。注意避免环依赖（A 调 B，B 又调 A），环依赖通常意味着职责划分需要重新设计。

### Q3：事件回调里能直接修改 Model 吗？

可以，但建议在 System 内完成 Model 修改，事件回调只做「通知」与「触发其他 System 逻辑」，保持职责清晰。

### Q4：注册的 Model / System 是单例吗？

在单个 `Architecture` 作用域内是单例（按 `global_name` 索引）。但不同 Architecture 实例之间互不影响。

### Q5：如何调试事件订阅？

可在 `register_event` / `unregister_event` 处加日志，或在 `send_event` 中打印 `event.get_script_name()` 与回调数量。生产环境建议通过条件编译或日志级别控制。

### Q6：FSM 的状态对象需要每帧 update 吗？

`FSM.update(delta)` 仅在主动调用时触发（通常在 System 的 `on_process` 中）。不调用则状态机不更新，适合事件驱动的状态切换场景。

### Q7：Model 继承 Resource 会有什么坑？

- Resource 默认是共享引用，多个持有者修改同一实例会相互影响。
- `ResourceKit.resource_load` 已通过 `duplicate(true)` 深拷贝规避此问题，但业务代码中直接传递 Model 引用时仍需注意。

---

## 许可证

[MIT License](LICENSE) © 2026 Helicopter-Man
