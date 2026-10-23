[← 返回总览](../../../README.md)

# DialogueLib — 剧本解析与推进

一个**纯算法**的对话剧本库：把 `.dk` 源码编译成纯数据 program，再按帧推进，每次返回「下一帧的默认编排形式」。

`class_name DialogueLib`，`extends RefCounted`，**不依赖核心层任何类**，不需要挂场景树、不注册服务、不发事件。

---

## 为什么是 Lib 而不是 Kit

对话运行时天然需要**宿主的事件总线**（任务、成就、战斗系统都要知道剧情发生了什么）。做成 `Kit`（`extends Architecture`）会把它关进独立作用域——`DialogueLineEvent` 出不来，外部系统只能靠轮询查服务。

拆成 Lib 后这条约束消失：

- **不发事件** → 同步返回 `DialogueStep`，调用方自己决定要不要广播；
- **不碰节点** → 不涉及 Control / Node2D 分层与坐标空间；
- **不管 UI 策略** → 连续点击、跳过、自动播放、打字机速度全归显示层，本库只在被调用时推进一步；
- **实例级状态** → 主线对话、旁白、电话各 `new()` 一份，互不干扰。

装配点（谁注册 Model、用哪个 Architecture、绑哪个 UI）留在项目侧，本库不认识它们。

---

## 目录

| 文件 | 职责 |
|---|---|
| `dialogue_lib.gd` | 门面：编译入口、会话推进、变量与状态 |
| `dialogue_compiler.gd` | 分段 → 语法解析 → 语义校验 → `DialogueProgram` |
| `dialogue_condition.gd` | 受限条件表达式（词法 / 语法 / 求值 / 变量提取） |
| `dialogue_program.gd` | 编译产物：节点表、变量声明、行索引、诊断 |
| `dialogue_node.gd` | 节点：进入命令 / 台词 / 退出命令 / 选项 |
| `dialogue_line.gd` | 台词：稳定 ID、说话人、文本、标签 |
| `dialogue_option.gd` | 选项：ID、文本、条件、目标 |
| `dialogue_command.gd` | 声明式指令：op + 参数 |
| `dialogue_step.gd` | 单帧产物：台词 / 选项 / 结束 / 错误 |
| `dialogue_diagnostic.gd` | 编译诊断：file / line / col / code / message |

---

## 语法契约

```text
title: tavern_intro
vars:
	reputation: int = 0
	gold: int = 100
start: true
---
<<bg asset="tavern_night" layer="background" fade="0.5">>
老板: 欢迎来到酒馆。#line:intro_001 #speaker:boss #portrait:boss_smile
老板: 今天想喝点什么？#line:intro_002 #speaker:boss
-> 来一杯酒 #option:opt_wine
	老板: 好嘞。#line:intro_003 #speaker:boss
	<<set var="gold" op="sub" value="50">>
-> 打听消息 if reputation >= 10 #option:opt_rumor
	<<jump tavern_rumor>>
-> 离开 #option:opt_leave
===

title: tavern_rumor
---
老板: 最近不太平。#line:rumor_001 #speaker:boss
===
```

| 元素 | 写法 | 说明 |
|---|---|---|
| 节点标题 | `title: <名称>` | 全局唯一，剧本的原子单位 |
| 变量声明 | `vars:` + 缩进块 | 全局生效，格式 `name: type = default`，type 限 `int / float / bool / string` |
| 起始节点 | `start: true` | 可选，缺省取第一个节点 |
| 正文边界 | `---` / `===` | `---` 开始正文，`===` 结束节点 |
| 台词 | `说话人: 文本 #line:<ID> #tag:value` | `#line` 必填，全局唯一 |
| 旁白 | `文本 #line:<ID>` | 无冒号或前缀超过 20 字时视为旁白 |
| 选项 | `-> 文本 #option:<ID> [if 条件]` | 条件与标签先后顺序均可 |
| 选项分支 | 选项行之下缩进的内容 | 编译为合成节点，可含台词与命令 |
| 命令 | `<<op key="value" ...>>` | 裸参数等价于 `target="..."` |
| 跳转 | `<<jump 节点名>>` | 目标必须存在 |
| 变量 | `<<set var="gold" op="sub" value="50">>` | `op` 限 `set / add / sub / mul` |
| 条件 | `reputation >= 10 and not flag` | 支持比较、`and/or/not`、括号、字符串相等 |
| 注释 | `//` 开头的整行 | 行内注释不支持，避免与 `#tag` 混淆 |

**内容三分类**：台词（呈现）、选项（等待输入）、命令（副作用，不直接呈现）。AI 与本库共享同一套语法边界。

### 编译产物

- 选项分支被编译成合成节点（标题形如 `tavern_intro#1`），因此**每个选项都有真实 target**；
- 选项体为空时 `target` 为空串，语义是「选中即结束对话」；
- 台词前没有台词可依附的命令归入节点 `commands`（进入时执行，resume 时重放，便于复原舞台）；
- 台词之后的命令归入 `exit_commands`（最后一行发出时结算）。

---

## API

### 编译

```gdscript
static func compile(source : String, name : String = "") -> DialogueProgram
```

编译始终返回 program，用 `has_errors()` 判断能否启动；诊断在 `program.diagnostics`：

```gdscript
var program := DialogueLib.compile(source, "tavern.dk")
for d in program.diagnostics:
	print(d)   # tavern.dk:12:1: error [unknown_jump] 跳转目标不存在: tavern_rumor
```

`DialogueCompiler` 还提供两个可调项：

| 成员 | 说明 |
|---|---|
| `auto_line_id : bool` | 台词缺 `#line` 时按行号自动生成（默认 `false`，严格模式报错） |
| `validate_source(source, name) -> Array[DialogueDiagnostic]` | 只取诊断 |

### 会话

```gdscript
func begin(program, from_line := &"", initial_vars := {}) -> DialogueStep
func advance() -> DialogueStep
func choose(choice_id : StringName) -> DialogueStep
func restore_state(program, state : Dictionary) -> DialogueStep
```

- `begin` 直接返回首帧；`from_line` 非空时从该行的**下一行**继续（存档恢复语义：该行已读）。
- `advance` 无条件推进一步——连续点击就是连续调用，跳过就是丢弃中间帧，自动播放就是定时调用。本库不做「当前该不该推进」的判断。
- `choose` 只在上一帧 `has_choices()` 时有效，否则返回 `ERR_UNAVAILABLE`。
- 三个方法统一返回 `DialogueStep`，失败时 `kind == ERROR`，用 `is_error()` 断言。

### 帧结构

```gdscript
enum Kind { NONE, LINE, CHOICES, ENDED, ERROR }

var node : StringName          # 当前节点
var line_id : StringName       # LINE 帧有效
var speaker : StringName
var text : String               # 原文；本地化请按 line_id 自行查表
var tags : Dictionary           # 标签原样透出
var ops : Array[Dictionary]     # [{op: "bg", args: {asset: ..., layer: ...}}]
var choices : Array[Dictionary] # [{id, text, target}]
var var_changes : Dictionary    # 本帧产生的变量变更
```

`ops` 是「声明式编排」的落点：本库认识 `<<op key="value">>` 这个**形状**，但不认识 `bg` / `sprite` 的语义——op 与参数原样交给调用方翻译成演出指令。`jump` 与 `set` 例外，它们直接影响流程与变量。

### 查询与状态

| 方法 | 说明 |
|---|---|
| `has_ended()` / `get_current_node()` / `get_last_line()` | 位置查询 |
| `get_vars()` / `get_var(name)` / `set_var` / `set_vars` | 变量读写，供外部注入全局状态 |
| `get_state() -> Dictionary` | 只含基础类型，可直接进存档 |
| `get_program()` | 取回当前 program |

### 存档

```gdscript
var state := lib.get_state()          # {version, node, line, index, ended, vars}
lib.restore_state(program, state)     # 等价于 begin(program, state.line, state.vars)
```

- 存档以 **`line`（行 ID）** 为准，`index` 仅作辅助；剧本增删行后行 ID 仍能定位。
- 恢复点若落在节点最后一行之后，节点退出命令**不会重放**（当时已结算过），避免 `<<set>>` 二次生效。
- 节点进入命令（切背景、摆立绘）会随恢复后的第一帧重新产出 ops，便于复原舞台。
- 找不到行时返回 `ERR_DOES_NOT_EXIST`，**不回退**——回退到节点头还是弹提示，属于产品决策。

---

## 错误码

| 返回值 | 场景 |
|---|---|
| `ERR_INVALID_PARAMETER` | `begin` 传入 `null` program |
| `ERR_INVALID_DATA` | program 含编译错误，拒绝启动 |
| `ERR_UNCONFIGURED` | 未 `begin` 就 `advance` / `choose` |
| `ERR_UNAVAILABLE` | 当前没有待选项 / 对话已结束 |
| `ERR_DOES_NOT_EXIST` | 行、节点、选项、跳转目标不存在 |
| `ERR_BUSY` | 单次推进超过 `MAX_STEPS`，疑似节点互跳成环 |

## 编译诊断码

`missing_line_id`、`auto_line_id`、`duplicate_line_id`、`duplicate_node`、`duplicate_option_id`、
`unknown_jump`、`jump_no_target`、`unknown_option_target`、`undeclared_var`、`unknown_var`、
`bad_condition`、`bad_set_op`、`missing_body`、`nested_option`、`empty_option_body`、`empty_node`、
`jump_before_lines_end`（中途跳转会吞掉后续台词）、`jump_with_options`（与选项并存时跳转被忽略）。

每条诊断带 `line` 与 `column`，适合直接回灌给 AI 做「生成 → 编译 → 按行号修复」的闭环。

---

## 明确不做的事

- 不做栈机：选项分支不支持「执行完回落到父节点继续」，分支结束即结束（除非显式 `jump`）。
- 不做嵌套选项：分支内出现 `->` 会报 `nested_option`。
- 不做任意表达式：条件只走白名单文法，无法调用函数或访问属性。
- 不做 IO：不吃路径、不加载资源、不缓存。加载与缓存留给调用方。
- 不做本地化：只给 `line_id` 与原文，查表由调用方负责。
- 不做 UI 语义：等待输入、跳过、快进、自动播放全部由显示层决定。

---

## 测试

```bash
Godot_v4.7-stable_win64_console.exe --headless --path <项目根> --script res://tests/run_tests.gd
```

套件 `tests/dialogue_lib_test.gd` 覆盖：编译、推进、条件过滤、选项分支、跳转、存档恢复、诊断定位、状态序列化。
