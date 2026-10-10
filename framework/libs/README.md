[← 返回总览](../../README.md)

# 库型模块 framework/libs

库型扩展是**纯算法**，随手 `new()` 即可使用，**与核心零耦合**，不注册、不暴露服务。删除整个 `framework/libs/` 目录不影响核心与其他扩展。

两类扩展一览见 [容器型模块文档](../kits/README.md#两类扩展一览)。

---

## 目录

- [FSMLib](#fsmlib)

---

## FSMLib

一个简洁的**非分层**状态机。`class_name FSMLib`，`extends RefCounted`，不依赖核心层任何类。

### 组成

- `FSMLib.FSMState`：内部抽象类（`@abstract class FSMState extends RefCounted`），需实现 `enter()` / `update(delta)` / `exit()`。
- `FSMLib`：状态机本体，用 `StringName` 索引状态。

### API

| 方法 | 返回 | 说明 |
|---|---|---|
| `FSMLib.new(enums : Array[StringName])` | `FSMLib` | 用允许的状态名列表构造；空列表会 `push_error` |
| `add_state(state : FSMState)` | `Error` | 添加状态；名称须在构造列表中，且不可重复添加 |
| `start()` | `Error` | 启动；所有状态都已填充才会成功 |
| `stop()` | `Error` | 停止 |
| `change_state(name : StringName)` | `Error` | 切换状态（仅激活状态可用） |
| `update(delta : float)` | `Error` | 更新当前状态 |
| `clear()` | `void` | 停止并清空状态列表 |

错误码：

| 返回 | 场景 |
|---|---|
| `OK` | 成功 |
| `ERR_INVALID_PARAMETER` | `add_state` 状态无效或名称不在列表中；`change_state` 目标状态不存在或为空 |
| `ERR_ALREADY_EXISTS` | `add_state` 该状态已添加；`start` 状态机已激活 |
| `ERR_UNAVAILABLE` | `start` 仍有状态未填充；`stop` / `change_state` / `update` 时状态机未激活 |

> `update()` 在未激活时**静默返回 `ERR_UNAVAILABLE`**（不写日志），避免逐帧刷屏。逐帧驱动时可忽略其返回值。

### 状态定义约定

`FSMState._init(_name : StringName, fsm : Object)` 需要传入归属的 FSM 实例。构造时会校验：

- `fsm` 必须是有效对象；
- `fsm` 必须带 `ISFSM` 元数据（`FSMLib` 在构造时 `set_meta`），否则拒绝。

状态内部通过 `WeakRef` 持有状态机，避免循环引用；切换状态调用 `_change_state(name)`。

```gdscript
extends FSMLib.FSMState
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
var _fsm : FSMLib

func _on_init() -> void:
	_fsm = FSMLib.new([&"Idle", &"Run", &"Jump"])
	_fsm.add_state(PlayerIdleState.new(_fsm))
	_fsm.add_state(PlayerRunState.new(_fsm))
	_fsm.add_state(PlayerJumpState.new(_fsm))
	_fsm.start()

func on_process(delta : float) -> void:
	_fsm.update(delta)

func _on_deinit() -> void:
	_fsm.clear()
```

`update()` 只在主动调用时推进，因此既可用于逐帧驱动，也可只做事件驱动的状态切换。