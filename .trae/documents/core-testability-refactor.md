# 核心架构可测性重构 + README 拆分

## Context

`framework/core/` 目前有三处结构性缺陷，使得「用 headless 自动化测试」这件事在现状下必然 flaky：

1. **全局静态总线**：`ServiceMiddleware` 用 `static var _services` 做进程级注册表（service_middleware.gd:7），无作用域隔离，重复注册只 `push_warning` 后覆盖（:10-13）。用例之间不 `clear()` 就互相污染。
2. **生命周期不闭环**：`Architecture.deinit()`（architecture.gd:200）全仓库无调用点，节点释放后其在总线里的注册会残留（`save_kit.gd:27` 反而实现了 `_exit_tree`，两边不对称）。
3. **失败不可断言**：所有错误通道都是 `push_error/push_warning`，公开 API 返回 `void`，调用方与测试都无法用返回值判断「应当失败」。

同时 `README.md`（927 行）混合了「稳定事实」与「某一时刻的评价」（架构优缺点分析、适用场景、性能取舍），后者会随演进过期，且核心内容与 kit 内容混在一处。

**用户已确认的方向**：允许破坏性改动，目标是更先进（模块化、易测试、AI 友好）的框架；kit 暂不重构（但可以被打断）；评价性章节直接移除；本轮不新建测试文件。

## 目标

- 核心层所有共享状态可实例化、可注入、可隔离 → 任何用例都能独立起停，无隐式全局。
- 核心层所有可失败操作返回错误码 → `assert(x == ERR_ALREADY_EXISTS)` 这类断言成立。
- 生命周期闭环，节点进出场景树自动完成注册/注销，且幂等。
- README 三拆，评价性内容移除，总 README 只留稳定事实 + 链接。

## 非目标（本轮不做）

- 不重构 kit 的功能与设计，不做 `SaveKit`/`ResourceKit`/`FSM` 的行为改造。
- 不新建 `tests/`、`.tscn` 场景、CI 配置。
- 不改 `ServiceConfig` 的字段语义（仍声明 models/systems/utilities/self_name）。

---

## 设计

### 1. 新总线：`ServiceRegistry`（替换 `ServiceMiddleware`）

新建 `framework/core/service_registry.gd`，**删除** `framework/core/service_middleware.gd`。

- 基类选 **`Resource`**（而非 `RefCounted`）：可 `@export` 到 Inspector、可用一个 `.tres` 被多个 Architecture 节点共享、测试里也能 `ServiceRegistry.new()` 自由实例化。
- 无任何 `static` 成员 → 天然无跨用例污染。
- 全部方法返回错误码：

```gdscript
extends Resource
class_name ServiceRegistry

var _services : Dictionary[StringName, Variant] = {}

func register(service_name : StringName, service : Variant) -> Error   # OK / ERR_INVALID_PARAMETER / ERR_ALREADY_EXISTS
func unregister(service_name : StringName) -> Error                      # OK / ERR_DOES_NOT_EXIST
func get_service(service_name : StringName) -> Variant
func has_service(service_name : StringName) -> bool
func get_service_names() -> Array[StringName]
func clear() -> void
func snapshot() -> Dictionary                                            # 浅快照
func restore(state : Dictionary) -> void                                 # 回滚
```

**关键行为变更**：重名注册由「warning 后覆盖」改为 **返回 `ERR_ALREADY_EXISTS` 且不覆盖**。这是有意的——静默覆盖正是多用例互相污染时最难查的坑。

### 2. `Architecture`：注入式总线 + 生命周期闭环

保持 `extends Node` 与 `_init_architecture()` 钩子不变，改动如下：

- **共享总线改为显式注入**，去掉隐式全局：

```gdscript
@export var service_config : ServiceConfig
## 共享总线：多个 Architecture 赋同一个 .tres 即可互相查询；留空则自建私有实例
@export var shared_registry : ServiceRegistry
var _registry : ServiceRegistry
var _owns_registry : bool = false
```

`_ready()` 中：`shared_registry == null` → 自建并 `_owns_registry = true`；否则复用传入实例。`get_service()` 直接查 `_registry`。跨 Architecture 通信能力被保留，但依赖关系从「隐式全局」变为「场景里可见的显式赋值」——这对 AI 与人都更友好。

- **生命周期闭环 + 幂等**：

```gdscript
var _deinited : bool = false

func _exit_tree() -> void:
    deinit()

func deinit() -> void:
    if _deinited: return
    # ... 原有清理 + 仅在 _owns_registry 时 _registry.clear()
    _deinited = true
```

**不要用 `_initialized` 做幂等键**：节点若从未 `_ready` 但已注册组件，复用它会提前 return 导致 `_on_deinit()` 丢失。

- `register_*` 在 `_deinited` 为真时返回 `ERR_UNAVAILABLE`，防止 deinit 后复活。
- **按需开帧**：`_process`/`_physics_process` 改为 `set_process(!_updatable_systems.is_empty())` 按需开关，不再无条件常驻。

### 3. 注册键健壮性

`register_*` 首行校验 `get_script_name()`：为空 `StringName`（脚本无 `class_name`）时 **fail-fast** 返回 `ERR_INVALID_PARAMETER`，不再静默落到 `&""` 造成碰撞。同时新增可选显式名参数：

```gdscript
func register_model(model : Model, model_name : StringName = &"") -> Error
```

`model_name` 非空即作为注册键，兼顾无 `class_name` 的脚本与同一脚本多实例。

### 4. 错误通道（全面返回码）

| 方法 | 新签名 | 说明 |
|---|---|---|
| `register_model` / `register_system` / `register_utility` | `-> Error` | OK / ERR_INVALID_PARAMETER / ERR_ALREADY_EXISTS / ERR_UNAVAILABLE |
| `unregister_model` / `unregister_system` / `unregister_utility` | `-> Error` | OK / ERR_DOES_NOT_EXIST |
| `register_event` | `-> Error` | OK / ERR_ALREADY_EXISTS。持锁，需先把结果存局部变量，`unlock()` 后再 `return` |
| `unregister_event` | `-> Error` | OK / ERR_DOES_NOT_EXIST |
| `send_event` | `-> int` | 命中并执行的回调数，便于断言事件确实被消费 |
| `ServiceRegistry.*` | 见上 | — |
| `Model` / `System` / `Utility` 委托层 | 同步透传 | 不回吞错误码 |

**不适合返回码**的地方：回调体内部的 `push_error`（GDScript 无 try/except，框架无法捕获）——这类保持日志。

---

## 分步实施

| 步 | 内容 | 文件 |
|---|---|---|
| 1 | 新建 `ServiceRegistry`，全方法返回错误码，重名不覆盖 | 新增 `framework/core/service_registry.gd` |
| 2 | 删除 `ServiceMiddleware` | 删除 `framework/core/service_middleware.gd`（及其 `.uid`） |
| 3 | `Architecture` 注入式总线 + `_deinited`/`_exit_tree`/`deinit` 幂等 + 按需 `set_process` + 注册键校验与显式 name | `framework/core/architecture.gd` |
| 4 | `register_*`/`unregister_*`/事件总线全面改返回码 | `framework/core/architecture.gd` |
| 5 | 委托层透传返回码 | `framework/core/model.gd`、`system.gd`、`utility.gd` |
| 6 | **kit 最小机械适配**（只为让仓库能加载，不改行为、不重构） | `framework/kits/save_kit.gd`（`ServiceMiddleware.*` → 新的 registry 调用；注意它 `extends Node` 而非 Architecture，需自行持有/接受 registry） |
| 7 | README 三拆 | `README.md`、新增 `framework/core/README.md`、新增 `framework/kits/README.md` |

第 6 步是**不可避免的**：`save_kit.gd` 直接引用 `ServiceMiddleware`，类被删除后会产生编译错误，导致整个项目的脚本加载失败、连静态校验都做不了。适配范围严格限制在「让调用点编译通过」，并在文件顶部加一行 `# NOTE 待按新核心重构`。

---

## README 拆分

| 文件 | 内容 | 明确排除 |
|---|---|---|
| `README.md`（项目总览，目标 ~110 行） | 一句话定位 / 稳定特性清单 / 安装（拷贝 `framework/`）/ 目录结构 / 最小快速开始 5 步 / **文档索引（链接到两个子 README）/ 许可证** | 优缺点分析、适用场景、性能取舍、任何评测性表述 |
| `framework/core/README.md` | 核心概念（Architecture/Model/System/Utility/Event/ServiceConfig/ServiceRegistry）/ 生命周期图（含自动 deinit）/ 总线与作用域（私有 vs 共享）/ **错误码约定表** / 注册键规则 / 事件总线 / 分层依赖规则 / API 速查 | kit 内容 |
| `framework/kits/README.md` | Kit 定位（可选扩展、非核心、当前为待重构的旧模式）/ FSM / ResourceKit / SaveKit（迁移现有 8.x 全段）/ 与核心的关系 | 核心内容 |

链接规则：总 README 用相对链接 `[核心层文档](./framework/core/README.md)`、`[Kit 文档](./framework/kits/README.md)`；两个子 README 顶部各加 `[← 返回总览](../../README.md)`；**禁止正文复制粘贴**，否则必然分叉过期。

被移除的「架构优缺点分析 / 适用场景 / 性能取舍」等评价性内容，本轮按确认结论**直接删除**，不新建 `docs/`。

---

## 验证

本轮无运行时测试入口，验证分三层，全部可零文件落盘：

1. **解析与静态分析**（每步都跑）
   - MCP `validate_script`：逐个校验改动过的 `.gd`，专防 `try/except` 这类语法雷（本项目刚因此出过 `save_kit.gd:239` 解析错误）。
   - 命令行全项目扫描：`Godot_v4.7-stable_win64_console.exe --headless --path <项目> --editor --quit`，要求零 script error。
   - MCP `validate_project`：检查坏引用与空 UID（删文件后尤其必要）。
2. **结构断言**
   - MCP `read_script_structure`：断言 `architecture.gd` 含 `_exit_tree` 与 `deinit`、`service_middleware.gd` 已不存在、`service_registry.gd` 方法集合符合设计。
3. **语义抽查（不落盘）**
   - MCP `editor_run_gdscript` 在编辑器上下文临时执行断言片段，例如：新建两个 `ServiceRegistry` 验证互不干扰、对同一 registry 重复 `register` 期望拿到 `ERR_ALREADY_EXISTS`、`Architecture.deinit()` 连续调用两次不报错。这是本轮唯一能验证「逻辑真的对」的手段，用完即弃。

**验收标准**：全项目 `--editor --quit` 零 script error；上面三条结构断言全部通过；`editor_run_gdscript` 的临时断言无失败。

## 风险

- **第 4~5 步改动面最大**：`register_*` 与事件总线的签名变更会波及 `Model`/`System`/`Utility` 的委托层，任何遗漏都会变成解析错误——靠 `validate_script` 逐个兜住。
- **`register_event` 持锁返回**：必须 `unlock()` 后再 `return`，否则死锁。
- **kit 适配可能不彻底**：`save_kit.gd` 的 `extends Node` 与新的「Architecture 持有 registry」模型不一致，第 6 步只保证编译通过，行为正确性留给后续 kit 重构。
- **共享总线的 `.tres` 依赖人工赋值**：若场景里忘记给多个 Architecture 赋同一个 `ServiceRegistry`，跨域查询会静默失败（返回 null）。这是显式注入的固有代价，子 README 中需明确写出。