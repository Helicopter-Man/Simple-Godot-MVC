# 测试规范 framework tests

本目录是框架的自动化测试。**此前没有测试规范**，本文件即第一版约定；`SaveKit` 是首个被测模块（36 个用例全绿）。

测试不依赖任何第三方测试框架，只用 Godot 自带的 GDScript + headless 运行。

---

## 目录结构

```
tests/
├── README.md            # 本规范
├── run_tests.gd         # 入口：汇总所有套件、打印报告、设置退出码
├── save_kit_test.gd     # SaveKit 测试套件
├── _report.json         # 运行时产物（勿提交）
└── fixtures/            # 测试夹具（Model / Kit 子类等）
    ├── test_save_model.gd
    ├── plain_test_model.gd
    ├── versioned_test_model.gd
    ├── lifecycle_test_model.gd
    └── test_save_kit.gd
```

---

## 运行方式

用 **console 版** Godot（非 console 版在 Windows 上不回传 stdout）：

```
<godot_console.exe> --headless --path <项目根> --script res://tests/run_tests.gd
```

例如本机：

```
"D:\workspase\godot\godot_origin\Godot_v4.7-stable_win64_console.exe" ^
  --headless --path "d:\workspase\godot_projects\godot_mvc" --script res://tests/run_tests.gd
```

结果有两处：

1. **stdout**：`TEST_REPORT_BEGIN` 与 `TEST_REPORT_END` 之间是 JSON 汇总。
2. **退出码**：`0` = 全部通过；`1` = 有失败。可直接用于 CI 判定。

同时会在 `res://tests/_report.json` 落一份同样的 JSON（无控制台时读取）。

> 负面用例（非法路径、重复注册等）会按预期打印 `ERROR:` / `WARNING:`。**这是被断言的预期行为，不代表失败**；判定一律以报告与退出码为准。

---

## 套件约定

每个套件脚本暴露一个静态入口：

```gdscript
static func run(root : Node) -> Dictionary
```

返回结构：

```gdscript
{
    "suite":  String,   # 套件名
    "total":  int,      # 用例总数
    "failed": int,      # 失败数
    "cases":  Array,    # [{"name": String, "ok": bool, "detail": String}]
}
```

`root` 是场景树根，传给需要真实生命周期的用例（见下）。

新增套件后，把它加进 [run_tests.gd](file:///d:/workspase/godot_projects/godot_mvc/tests/run_tests.gd) 的 `SUITES` 数组即可。

### 断言

套件内用一个极简收集器，不引入断言库：

```gdscript
static func _check(cases : Array, name : String, ok : bool, detail : String = "") -> void:
    cases.append({"name": name, "ok": ok, "detail": detail})
```

断言直接对**错误码**与**返回值**做判断——这正是核心层「可失败操作返回 `Error`」带来的可测性：

```gdscript
_check(cases, "重复注册返回 ERR_ALREADY_EXISTS", kit.register_saveable(dup) == ERR_ALREADY_EXISTS)
```

### 生命周期用例需要真实场景树

`Architecture` / `Kit` 的 `_ready` 只在节点真正进入场景树时触发。因此：

- 入口 [run_tests.gd](file:///d:/workspase/godot_projects/godot_mvc/tests/run_tests.gd) 用 `process_frame` 在**首帧**执行（`--script` 模式下 `_initialize()` 时 root 尚未进树，直接跑会漏掉 `_ready`）。
- 用例里 `root.add_child(kit)` 触发 `_ready`，`root.remove_child(kit)` 触发 `_exit_tree → deinit`，据此验证注册、`_on_init`、服务暴露、`deinit` 后拒绝注册等闭环行为。

不需要生命周期的纯逻辑用例（注册、存档信封、迁移等）用 `SaveKit.new()` 即可，不必进树。

### 夹具（fixtures）

- 需要作为**注册键**的 Model 必须有 `class_name`（注册键取自 `Model.get_script_name()`）。
- 测试脚本里用 `preload("res://tests/fixtures/xxx.gd")` 引用夹具，避免依赖全局类缓存的新鲜度。

---

## 关于 godot MCP

运行中的 Godot 编辑器若装了 `addons/godot-mcp` 插件，会在 `127.0.0.1:9876` 暴露 TCP 指令通道（无 `godot_mcp/auth_token` 时不鉴权），协议是**一行一条 JSON**：

```
{"method":"<命令>","params":{...},"id":1}\n
```

可用命令见 [plugin.gd](file:///d:/workspase/godot_projects/godot_mvc/addons/godot-mcp/plugin.gd) 的 `_execute_command`（`health_check`、`run_gdscript`、`evaluate_expression`、`get_error_list` 等）。

**定位与限制（实测）**：

- `run_gdscript` / `evaluate_expression` 底层是 `Expression`，且以**当前打开的场景根**为 `self`。没有打开场景时直接报 `实例为 null（未传递），无法使用 self`；也无法执行多语句脚本。
- 因此 **MCP 只适合「编辑器内临时片段」**（如查一下某表达式、某节点属性），**不适合跑测试套件**。
- 本仓库的测试约定以 **headless CLI** 为主；MCP 作为可选的临时排查手段。

若通过 MCP 客户端（而非直连 TCP）调用，需在客户端侧配置该 godot-mcp server；本环境未配置时，工具不可直接调用，可退化为上面的 TCP 直连方式。

---

## 约定速查

| 事项 | 约定 |
|---|---|
| 入口 | `tests/run_tests.gd`（`extends SceneTree`，首帧执行） |
| 套件入口 | `static func run(root : Node) -> Dictionary` |
| 用例注册 | 在 `run_tests.gd` 的 `SUITES` 中 `preload` |
| 断言 | `_check(cases, name, ok, detail)`，判错误码/返回值 |
| 需要生命周期的用例 | 传 `root`，`add_child` / `remove_child` |
| 报告 | stdout `TEST_REPORT_BEGIN/END` + `tests/_report.json` |
| 成功判定 | 退出码 `0` |
| 运行 | console 版 Godot `--headless --script res://tests/run_tests.gd` |