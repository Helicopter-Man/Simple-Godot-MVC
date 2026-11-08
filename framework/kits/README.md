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
- [AudioKit](#audiokit)

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

---

## AudioKit

`class_name AudioKit`，`extends Kit`。**Godot 原生音频引擎**：把业界主流中间件那套「事件驱动 + 资源组 + 状态参数 + 混音 + voice 预算 + 交互音乐」的工作流落进框架的 Model / System / Utility 分层，不依赖任何中间件，也不用 Autoload。

设计取向：业务代码只发**语义事件**（`cue_id`），永不接触 `AudioStreamPlayer`；播放、池化、抢占、位置跟随、淡变全部由 Kit 收口。

### 能力对照

| 业界概念 | AudioKit |
|---|---|
| Event / PlayingID | `post(cue_id)` → `AudioHandle` |
| SoundBank / LoadBank | `AudioBankDef` + `load_bank` / `unload_bank`（引用计数） |
| Random / Sequence Container | `AudioCue.container`：SINGLE / RANDOM / SEQUENCE / SHUFFLE |
| Priority / Voice Limit / Virtualization | `max_voices` + `priority` + `max_instances` + `min_interval` + 抢占 |
| State / Switch | `set_state` / `set_switch`；Cue 可按 Switch 门控 |
| Game Parameter / RTPC | `set_rtpc` + `AudioRtpcBinding`（Curve → 总线音量 / voice 音量 / 音高） |
| Bus / Mix Snapshot / Ducking | `set_bus_volume` / `apply_snapshot` / `duck` |
| Game Object / Listener | `AudioEmitter` 桥 / `set_listener` |
| Interactive Music | `set_music_state` + 组交叉淡变 + 纵向分层 `set_music_layer` |
| Suspend / Resume | `set_paused` |
| Event Callback / Profiler | `AudioPlaybackEvent` / `AudioStateEvent` / `AudioDiagnostic` |

### 目录与分层

```
framework/kits/audio/
├── audio_kit.gd             # Kit 门面：生命周期、配置、对外 API、事件转发
├── audio_cue.gd             # Cue：流 / 容器 / 优先级 / 空间 / 淡变
├── audio_bank_def.gd        # Bank：一组 Cue + auto_load
├── audio_handle.gd          # 句柄（PlayingID 风格，弱引用 Kit）
├── audio_rtpc_binding.gd    # 参数 → 目标属性映射（Curve）
├── audio_diagnostic.gd      # 纯数据诊断快照
├── audio_emitter.gd         # 发声体桥（extends Node，离树自动解绑）
├── audio_state_model.gd     # Model：Bank / Cue / 状态 / 参数 / 统计
├── audio_selector.gd        # Utility：取流、抢占、曲线、dB 换算（纯算法）
├── systems/
│   ├── audio_bank_system.gd      # 资源组引用计数
│   ├── audio_event_system.gd     # post 门控与回调
│   ├── audio_voice_system.gd     # player 池 / 淡变 / 3D 跟随 / 回收
│   └── audio_mix_music_system.gd # 总线 / 状态 / 音乐分层
└── events/
    ├── audio_playback_event.gd   # started / ended / dropped
    └── audio_state_event.gd      # bank / state / switch / rtpc / music
```

组件在 `_init_architecture()` 中注册：`AudioStateModel`（Model）+ `AudioSelector`（Utility）+ 4 个 System。`AudioVoiceSystem` 与 `AudioMixMusicSystem` 定义 `on_process`，由核心的按需 tick 驱动；配置应用延后到 `_ready()` 末尾的 `_bootstrap()`，保证 player 池已建好。

### 接入

```
GameRoot (Node)
├── MainArchitecture  (service_config: MainServiceConfig.tres, shared_registry: hub.tres)
└── AudioKit          (service_config: AudioServiceConfig.tres, shared_registry: hub.tres)
```

给 `service_config.self_name = &"AudioKit"`，业务侧用 `arch.get_service(&"AudioKit")` 取用。**事件总线按 Architecture 隔离**：音频回调默认只在 AudioKit 作用域内派发；需要业务侧收到时，把 `target_architecture` 指向业务 Architecture（与 `UiKit.target_architecture` 同一手法），Kit 会转发两类回调事件并带防循环标志。

`@export` 配置：

| 字段 | 默认 | 说明 |
|---|---|---|
| `target_architecture` | 空 | 回调事件转发目标 |
| `max_voices` | 32 | 全局同时发声上限 |
| `silent` | `false` | 不调用 `play()`，用逻辑时长推进；headless / 无声设备可确定性断言 |
| `default_bus` | `&"Master"` | Cue 总线不存在时回退 |
| `banks` / `rtpc_bindings` / `music_states` | 空 | 声明式资源组 / 参数绑定 / 音乐状态表 |
| `listener` | 空 | `AudioListener2D/3D` 或 Camera |

也可继承 AudioKit 重写 `_init_audio_kit()` 用代码注册。**必须挂入场景树**，`_ready` 才会注册组件。

### 使用

```gdscript
# 1. 资源（建议编辑器建 .tres；示例为代码构造）
var cue := AudioCue.new()
cue.cue_id = &"Play_Footstep"
cue.streams = [preload("res://audio/step_01.wav"), preload("res://audio/step_02.wav")]
cue.container = AudioCue.ContainerMode.SHUFFLE
cue.bus = &"SFX"
cue.priority = 40
cue.max_instances = 3
cue.volume_jitter_db = 2.0
cue.spatial = AudioCue.SpatialMode.POSITIONAL_3D

var bank := AudioBankDef.new()
bank.bank_id = &"Bank_Common"
bank.cues = [cue]
bank.auto_load = true
# 填入 AudioKit 的 banks，或在 _init_audio_kit() 中 register_bank(bank)
```

```gdscript
# 2. 业务 System 内：只发语义事件
var audio := get_architecture().get_service(&"AudioKit") as AudioKit
var h := audio.post(&"Play_Footstep", emitter_id, {"volume_db": -3.0})
if h != null:
	h.set_pitch(1.1)

audio.set_state(&"Music", &"Combat")
audio.set_rtpc(&"Intensity", 0.8)
audio.set_music_state(&"Combat")
audio.apply_snapshot({&"Music": 0.6, &"SFX": 1.0}, 0.4)
audio.duck(&"Music", 0.4, 0.6)   # 语音 / 过场时压低音乐
```

```gdscript
# 3. 3D 发声体：挂到角色节点下并绑定，位置由 Kit 的 tick 自动跟随
var emitter := AudioEmitter.new()
add_child(emitter)
audio.attach_emitter(emitter)
audio.post(&"Play_Footstep", emitter)   # 也可直接传实例，自动绑定
# 节点离树时自动解绑并停掉自己的 voice
```

### Cue 关键字段

| 字段 | 说明 |
|---|---|
| `streams` / `weights` | 变体流 / RANDOM 权重 |
| `container` | SINGLE / RANDOM / SEQUENCE / SHUFFLE |
| `spatial` / `max_distance` / `attenuation` / `unit_size` | 非空间 / 2D / 3D 与衰减 |
| `priority` / `max_instances` / `min_interval` | 抢占、实例上限、触发节流 |
| `volume_db` / `volume_jitter_db` / `pitch` / `pitch_jitter` | 音量与音高随机化 |
| `fade_in` / `fade_out` / `duration_hint` | 淡变、silent 模式逻辑时长 |
| `switch_group` / `switch_value` | Switch 门控 |
| `bus` | 目标总线（不存在则回退 `default_bus`） |

### API

| 分类 | 方法 |
|---|---|
| 资源组 | `register_bank` / `load_bank` / `unload_bank(id, force)` / `is_bank_registered` / `is_bank_loaded` / `get_bank_refcount` / `get_registered_banks` / `has_cue` |
| 事件 | `try_post(cue_id, emitter_id, params) -> Error` / `post(...) -> AudioHandle` / `get_last_handle` / `stop_voice` / `stop_cue` / `stop_all` / `is_voice_active` |
| 句柄 | `AudioHandle.stop(fade)` / `is_playing()` / `set_volume_db` / `set_pitch` |
| 状态参数 | `set_state` / `get_state` / `set_switch` / `get_switch` / `set_rtpc` / `get_rtpc` / `bind_rtpc` |
| 混音 | `set_bus_volume` / `get_bus_volume` / `apply_snapshot` / `duck` |
| 音乐 | `register_music_state` / `set_music_state` / `get_music_state` / `play_music` / `stop_music` / `set_music_layer` / `get_music_cue_id` |
| 发声体 / 监听者 | `attach_emitter` / `detach_emitter` / `get_emitter_count` / `set_listener` / `get_listener` / `clear_listener` |
| 全局 | `set_paused` / `is_paused` |
| 诊断 | `get_diagnostics() -> AudioDiagnostic` / `get_snapshot() -> Dictionary` / `tick(delta)`（仅测试用） |

错误码（沿用核心约定，预期失败只返码不写日志）：

| 返回 | 场景 |
|---|---|
| `OK` | 成功 |
| `ERR_INVALID_PARAMETER` | 空 id / null 实例 / 非法 Cue / 非法监听者 |
| `ERR_ALREADY_EXISTS` | Bank 或 Cue 重名、音乐状态重复 |
| `ERR_DOES_NOT_EXIST` | 未注册的 Bank / Cue / voice / 音乐层 / 总线；未加载时卸载 |
| `ERR_BUSY` | 触发节流、实例上限、voice 上限且优先级不足、Switch 不匹配 |
| `ERR_UNAVAILABLE` | 组件未就绪 / 已 deinit / 监听者未进树 |
| `ERR_INVALID_DATA` | Cue 无可用流 |
| `ERR_CANT_CREATE` | voice 创建失败 |

### 生命周期与测试

`deinit()` 重写为「先 `stop_all(0)` + `stop_music(0)`，再 `super.deinit()`」；各 System 的 `_on_deinit` 释放 player 池与音乐节点、解绑所有 emitter。`AudioEmitter._exit_tree` 自动解绑，池化角色不会产生悬挂 id。

`silent=true` 时不调用 `play()`，voice 由 `cue.duration_hint`（或 `stream.get_length()`）在 `tick` 中推进并回收，`started` / `ended` 事件照常派发——headless 测试可断言完整生命周期。`tests/audio_kit_test.gd` 覆盖 Bank 引用计数、节流、抢占、RTPC、混音、音乐、Emitter、事件转发与 deinit 幂等。

### 边界

原生实现**不**提供：可视化 authoring 工具、实时 mix profiler、SoundBank 打包、Room/Portal 几何声学、平台级编解码优化；RTPC 通过每帧插值逼近，不是采样级精确。本模块对齐的是**调用语义与工作流**，不是功能等价——这些缺口属于音频中间件范畴，框架刻意不引入。
