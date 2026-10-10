# godot_mvc

一个面向 **Godot 4.7+** 的轻量级 MVC / 分层架构框架。

以 **Architecture（作用域 IoC 容器）** 为核心，将游戏逻辑拆分为 **Model（数据）/ System（逻辑）/ Utility（基础设施）** 三层，并通过内置事件总线与可选 Kit 协作，替代传统全局 Autoload 单例。

---

## 特性

- **作用域化 IoC**：`Architecture` 继承 `Node`，可挂载到场景树，多实例平级并存，支持按场景 / 子模块隔离。
- **无隐式全局**：服务总线 `ServiceRegistry` 是可实例化的 `Resource`。每个 Architecture 自持一个，或由多个 Architecture 显式共享同一个；框架内不存在进程级静态注册表。
- **失败可断言**：所有可失败的公开操作返回 `Error` / `bool` / 计数，而不只是打印日志。
- **生命周期闭环**：节点进入场景树自动初始化，离开场景树自动反初始化（含服务注销）；`deinit()` 幂等，可安全重复调用。
- **事件总线内置**：无需额外 Autoload，事件按 Architecture 作用域分发，`Mutex` 保证线程安全。
- **按需 tick**：System 只有定义了 `on_process` / `on_physics_process` 才会被纳入轮询；没有轮询对象时自动关闭 `_process` / `_physics_process`。
- **扩展二分类**：容器型（`Kit`）与库型（`Lib`）两类可选扩展，各自独立目录，可整体删除，核心保持精简。
- **UI 拔插（UiKit）**：UI 显示时挂入场景树、关闭时离树不销毁并按池化策略复用，停止绘制 / 布局 / 轮询 / 输入遍历；内置暂停请求聚合，UI 与暂停动作解耦。

---

## 目录结构

```
framework/
├── core/                   # 核心层：不依赖任何扩展
│   ├── architecture.gd     # 作用域 IoC 容器 + 事件总线 + 生命周期
│   ├── service_registry.gd # 可实例化的服务总线
│   ├── service_config.gd   # 对外接口的声明式配置
│   ├── model.gd            # 数据层基类（Resource）
│   ├── system.gd           # 逻辑层基类（RefCounted，@abstract）
│   ├── utility.gd          # 基础设施层基类（RefCounted）
│   └── event.gd            # 事件基类（RefCounted）
├── kits/                   # 容器型扩展：extends Kit（可整体删除）
│   ├── kit.gd              # 容器型基类（@abstract Kit extends Architecture）
│   ├── save/save_kit.gd    # SaveKit：版本化整体存档
│   └── ui/                 # UiKit：UI 拔插管理
│       ├── ui_kit.gd       # 拔插 / 池化 / 挂载 / 暂停聚合
│       └── ui_view.gd      # UiView 基类：生命周期钩子 + 架构桥
└── libs/                   # 库型扩展：extends RefCounted，零耦合（可整体删除）
    └── fsm/fsm_lib.gd      # FSMLib：非分层状态机
```

## 安装

将本仓库的 `framework/` 目录整体拷贝到你的 Godot 项目 `res://` 下即可。框架全部以 `class_name` 全局注册，无需配置 Autoload。

---

## 快速开始

以「玩家血量」为例。

**1. 定义 Model**

```gdscript
# player_model.gd
extends Model
class_name PlayerModel

var hp : int = 100
var max_hp : int = 100
```

**2. 定义 Event**

```gdscript
# player_damaged_event.gd
extends Event
class_name PlayerDamagedEvent

var amount : int = 0
var current_hp : int = 0

func _init(_amount : int = 0, _current_hp : int = 0) -> void:
	amount = _amount
	current_hp = _current_hp
```

**3. 定义 System**

```gdscript
# combat_system.gd
extends System
class_name CombatSystem

func _on_init() -> void:
	register_event(&"PlayerDamagedEvent", _on_player_damaged)

func _on_deinit() -> void:
	unregister_event(&"PlayerDamagedEvent", _on_player_damaged)

func deal_damage(amount : int) -> void:
	var model := get_model(&"PlayerModel") as PlayerModel
	if model == null:
		return
	model.hp = max(model.hp - amount, 0)
	send_event(PlayerDamagedEvent.new(amount, model.hp))

func _on_player_damaged(event : PlayerDamagedEvent) -> void:
	print("玩家受到 %d 点伤害，当前血量 %d" % [event.amount, event.current_hp])
```

**4. 定义 Architecture**

```gdscript
# game_architecture.gd
extends Architecture
class_name GameArchitecture

func _init_architecture() -> void:
	register_utility(MyUtility.new())   # 可选：你的无状态工具
	register_model(PlayerModel.new())
	register_system(CombatSystem.new())
```

**5. 挂到场景并使用**

在场景中新建一个 `Node`，附加 `game_architecture.gd`：

```gdscript
# main.gd
extends Node

@onready var arch : Architecture = $GameArchitecture

func _ready() -> void:
	var combat := arch.get_system(&"CombatSystem") as CombatSystem
	combat.deal_damage(30)  # 输出：玩家受到 30 点伤害，当前血量 70
```

---

## 文档

| 文档 | 内容 |
|---|---|
| [核心层文档](./framework/core/README.md) | Architecture / ServiceRegistry / ServiceConfig / Model / System / Utility / Event，生命周期、错误码约定、注册键规则、分层依赖、API 速查 |
| [容器型模块](./framework/kits/README.md) | `Kit` 基类与 `SaveKit`（版本化整体存档） |
| [库型模块](./framework/libs/README.md) | `FSMLib`（非分层状态机） |

## 许可证

[MIT License](LICENSE) © 2026 Helicopter-Man