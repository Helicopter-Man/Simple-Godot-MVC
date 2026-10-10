# 扩展模块（Kit / Lib）重构

## Context

核心层已完成可测试化重构：`ServiceRegistry` 可实例化/可共享、公开操作全面返回错误码、生命周期闭环（`_exit_tree`→`deinit` 幂等）、依赖显式注入（无隐式全局）。

`framework/kits/` 起点状态：

- `fsm_kit.gd`：`extends RefCounted`，与核心**零耦合**。
- `resource_kit.gd`：`extends Utility`，依赖核心；类名带 `Kit` 后缀却并非容器，语义误导。
- `save_kit.gd`：`extends Node`，为「保证可编译」自持了一个**私有** `ServiceRegistry`，并重复实现了 `Architecture` 的 `_register_services` / `_unregister_services`。

用户目标：扩展模块要成为**可方便拔插的模块**；「任意模块也可以是一个 Architecture」，但**允许而非强制**。

## 目标

- **插拔性**
  - L1 文件级：删除某个模块目录，核心与其他模块不受影响。
  - L2 接入级：每个模块有明确的接入 / 拔出方式。
  - **发现口统一**：容器型模块经共享总线 `ServiceRegistry`（hub）被发现。
- **单向依赖**：`module → core`，核心永不反向依赖；模块之间零依赖。
- **可断言**：模块的公开可失败操作返回 `Error` / `bool`，与核心约定一致。

## 非目标

- 不做「所有模块强制同一基类」。
- 不改核心层 public API；核心 `Utility` 层保留。

## 决策记录（最终）

1. **二分类**，判定标准：*这个模块是否需要自己管理状态 / 服务 / 生命周期？*

   | 形态 | 何时用 | 基类 | 类名后缀 | 目录 |
   |---|---|---|---|---|
   | 容器型 | 自己有状态、要暴露服务、要起停 | `extends Kit`（即 `Architecture`） | `Kit` | `framework/kits/` |
   | 库型 | 纯算法，随手实例化、零耦合 | `extends RefCounted` | `Lib` | `framework/libs/` |

2. **新增 `Kit` 基类**：语义标记（`node is Kit`），`@abstract extends Architecture`。**当前刻意留空**，容器通用操作待实际需求出现再提炼。

3. `FSM` → `FSMLib`（`RefCounted`）；`SaveKit` 升级为 `extends Kit`。

4. **类名统一带后缀**：容器 `*Kit`、库 `*Lib`；见类名即知位置。

5. **`ResourceUtility` 删除**：它的定位已被 `SaveKit` 取代；**整个服务型目录 `framework/utilities/` 删除**——服务型模块都可通过容器型实现，保留中间态无必要。

6. **路径校验内联**：`SaveKit._validate_path()` 私有方法，作为模块内部工具，不再对外复用，核心不新增概念。

7. **核心 `Utility` 基类、`Architecture.register_utility()`、`ServiceConfig.utilities` 保留不动**：业务代码仍可在自己的 Architecture 内定义并注册无状态 Utility，只是框架不再以「服务型扩展目录」的形式出货。

## 修订记录（本轮演进）

- 方案曾经历 **三分类**（容器型 `Kit` / 服务型 `Utility` / 库型 `Lib`），并一度把公共路径校验抽到核心 `PathGuard`。
- 随后确认两点收敛，退回 **二分类**：
  1. `SaveKit` 本就是用来替代 `ResourceUtility` 的，`ResourceUtility` 无保留价值；
  2. 既然 `ResourceUtility` 不再存在，`PathGuard` 唯一的使用者只剩 `SaveKit`，没有"被复用"的理由，内联回模块内部更单纯。
- 由此服务型目录整目录删除，扩展收敛为 **容器型（`Kit`）/ 库型（`Lib`）**。
- 保留本条修订痕迹，便于回溯为何放弃三分类。

## 目标结构

```
framework/
├── core/                     # 内核，永不反向依赖任何扩展模块
│   ├── architecture.gd
│   ├── service_registry.gd
│   ├── service_config.gd
│   ├── model.gd  system.gd  utility.gd  event.gd
│   └── README.md
├── kits/                     # 容器型：extends Kit
│   ├── kit.gd                # @abstract Kit extends Architecture（基类，空）
│   └── save/
│       └── save_kit.gd       # SaveKit : Kit
└── libs/                     # 库型：extends RefCounted，与核心零耦合
    └── fsm/
        └── fsm_lib.gd        # FSMLib : RefCounted
```

依赖方向：

```
   业务层（游戏代码）
        │ 依赖
        ▼
   kits / libs （可选，可整体删除）
        │ 依赖
        ▼
   core/（内核）
   库型谁都不依赖；容器型只依赖 core；模块之间零依赖
```

接入 / 拔出：

| 模块 | 形态 | 插 | 拔 |
|---|---|---|---|
| FSMLib | 库型 | `FSMLib.new(...)`，无需注册 | 删 `framework/libs/fsm/` |
| SaveKit | 容器型 | 场景树挂 `SaveKit` 节点 + 共享 hub | 删节点 / 删 `framework/kits/save/` |

## `Kit` 基类设计

```gdscript
@abstract
extends Architecture
class_name Kit
```

**继承即免费获得**（来自 `Architecture`，无需重写）：生命周期闭环与 `deinit` 幂等、服务总线、`service_config` 服务暴露、`Model/System/Utility` 注册与查询、事件总线。

**`Kit` 当前为空类**。容器模块的通用操作待实际需求出现再提炼。`SaveKit.register_saveable()` 直接复用核心的 `register_model`，不额外抽象：

```gdscript
func register_saveable(model : Model) -> Error:
	# 先校验 get_data / set_data 接口
	return register_model(model)
```

## 各模块改造概要（已完成）

### FSMLib（库型）

- 类名 `FSM` → `FSMLib`；文件 `fsm_lib.gd`；目录 `framework/libs/fsm/`。
- `add_state/start/stop/change_state/update -> Error`；`update` 未激活时静默返回 `ERR_UNAVAILABLE`（不再逐帧刷屏）。
- `FSMState._init` 先赋 `name` 再校验，行为可控。
- 保留 `set_meta(FSM_FLAG)` 类型探测；保持零耦合。

### SaveKit（容器型）

- `extends Kit`，删除自持 `ServiceRegistry` 与重复的 `_register_services` / `_unregister_services`。
- `register_saveable(model) -> Error`：校验 `get_data` / `set_data` 接口后复用 `register_model`。
- `save(path) -> Error` / `load(path) -> Error` / `has_save -> bool` / `get_save_info -> Dictionary`。
- 路径校验为内部 `_validate_path()`。
- 保留存档信封、版本迁移链、默认值填充等既有行为。

## 分步实施（已完成）

| 步 | 内容 | 状态 |
|---|---|---|
| 1 | 目录改造：`kits/` `libs/` 二分，文件与类名按后缀约定重命名 | 完成 |
| 2 | FSMLib 对齐（返回码、类型安全修正） | 完成 |
| 3 | 新增 `framework/kits/kit.gd`（`@abstract Kit extends Architecture`，空类） | 完成 |
| 4 | SaveKit 升级为 `extends Kit`，去重复逻辑、返回码化、路径校验内联 | 完成 |
| 5 | 删除 `ResourceUtility` 与服务型目录 `framework/utilities/`；删除核心 `PathGuard` | 完成 |
| 6 | 文档：根 README、core README、`kits/` `libs/` 两份 README | 完成 |

## 待决

- SaveKit 是否需要槽位 / 部分存档等新功能（本轮只做结构对齐，未加）。
- 若后续出现第二个容器型模块，再评估是否把通用操作提炼进 `Kit`。

## 验证

- 无 Godot 可执行文件时以结构断言为主：基类正确、方法签名齐全、模块之间无引用、核心无反向引用。
- 若能取得 Godot：`--headless --editor --quit` 零 script error。