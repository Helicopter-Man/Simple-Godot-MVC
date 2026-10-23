extends RefCounted
## DialogueLib 测试套件
## 约定：static func run(root: Node) -> Dictionary

const SRC_TAVERN : String = """title: tavern_intro
vars:
\treputation: int = 0
\tgold: int = 100
start: true
---
<<bg asset="tavern_night" layer="background">>
老板: 欢迎来到酒馆。#line:intro_001 #speaker:boss
老板: 今天想喝点什么？#line:intro_002 #speaker:boss
-> 来一杯酒 #option:opt_wine
\t老板: 好嘞。#line:intro_003 #speaker:boss
\t<<set var="gold" op="sub" value="50">>
-> 打听消息 #option:opt_rumor if reputation >= 10
\t<<jump tavern_rumor>>
-> 离开 #option:opt_leave
===

title: tavern_rumor
---
老板: 最近不太平。#line:rumor_001 #speaker:boss
===
"""


static func run(_root : Node) -> Dictionary:
	var cases : Array = []
	_run_compile(cases)
	_run_flow(cases)
	_run_condition(cases)
	_run_jump_and_resume(cases)
	_run_diagnostics(cases)
	_run_state(cases)
	var failed : int = 0
	for c in cases:
		if not c["ok"]:
			failed += 1
	return {"suite": "DialogueLib", "total": cases.size(), "failed": failed, "cases": cases}


# ---- 编译 ----
static func _run_compile(cases : Array) -> void:
	var program := DialogueLib.compile(SRC_TAVERN, "tavern.dk")
	_check(cases, "合法剧本无编译错误", not program.has_errors(), _diag_text(program))
	var source_nodes : int = 0
	var synthetic : int = 0
	for title in program.nodes:
		if String(title).contains("#"):
			synthetic += 1
		else:
			source_nodes += 1
	_check(cases, "源节点数量为 2", source_nodes == 2, str(source_nodes))
	_check(cases, "两条分支各编译出合成节点", synthetic == 2, str(synthetic))
	_check(cases, "describe 覆盖全部节点", (program.describe()["nodes"] as Array).size() == program.nodes.size())
	_check(cases, "起始节点取自 start: true", program.start == &"tavern_intro")
	_check(cases, "行索引收录 intro_001", program.line_index.has(&"intro_001"))
	_check(cases, "变量声明被解析", program.vars.has(&"gold") and int(program.vars[&"gold"]["default"]) == 100)
	_check(cases, "describe 暴露变量清单", (program.describe()["vars"] as Array).size() == 2)


# ---- 推进 ----
static func _run_flow(cases : Array) -> void:
	var program := DialogueLib.compile(SRC_TAVERN, "tavern.dk")
	var lib := DialogueLib.new()

	var step := lib.begin(program)
	_check(cases, "首帧是台词", step.kind == DialogueStep.Kind.LINE, str(step))
	_check(cases, "首帧行 ID 正确", step.line_id == &"intro_001")
	_check(cases, "说话人解析自 #speaker 标签", step.speaker == &"boss")
	_check(cases, "台词文本不含标签", step.text == "欢迎来到酒馆。")
	_check(cases, "节点进入命令随首帧产出", step.ops.size() == 1 and step.ops[0]["op"] == &"bg")

	step = lib.advance()
	_check(cases, "第二次推进得到第二行", step.line_id == &"intro_002")
	_check(cases, "无命令时 ops 为空", step.ops.is_empty())

	step = lib.advance()
	_check(cases, "台词走完进入选项帧", step.kind == DialogueStep.Kind.CHOICES)
	_check(cases, "reputation=0 时隐藏条件选项", step.choices.size() == 2, str(step.choices.size()))
	_check(cases, "选项帧不含被过滤项", step.find_choice(&"opt_rumor").is_empty())

	step = lib.choose(&"opt_wine")
	_check(cases, "选择后进入分支首行", step.kind == DialogueStep.Kind.LINE and step.line_id == &"intro_003")
	_check(cases, "分支内 set 生效", int(lib.get_var(&"gold")) == 50, str(lib.get_var(&"gold")))
	_check(cases, "set 变更随帧上报", int(step.var_changes.get(&"gold", 0)) == 50)

	step = lib.advance()
	_check(cases, "分支结束即对话结束", step.kind == DialogueStep.Kind.ENDED, str(step))
	_check(cases, "结束后 has_ended 为真", lib.has_ended())
	_check(cases, "结束后再次 advance 仍返回结束", lib.advance().kind == DialogueStep.Kind.ENDED)


# ---- 条件 ----
static func _run_condition(cases : Array) -> void:
	_check(cases, "条件表达式合法", DialogueCondition.validate("reputation >= 10 and not flag") == "")
	_check(cases, "条件可提取变量名", DialogueCondition.identifiers("a and (b or c)").size() == 3)
	_check(cases, "条件求值：数值比较", DialogueCondition.evaluate("reputation >= 10", {&"reputation": 12}))
	_check(cases, "条件求值：不满足", not DialogueCondition.evaluate("reputation >= 10", {&"reputation": 3}))
	_check(cases, "条件求值：布尔与否定", DialogueCondition.evaluate("flag and not other", {&"flag": true, &"other": false}))
	_check(cases, "条件求值：字符串相等", DialogueCondition.evaluate("mood == \"calm\"", {&"mood": "calm"}))
	_check(cases, "条件校验：单等号报错", DialogueCondition.validate("a = 1") != "")
	_check(cases, "条件校验：括号不匹配报错", DialogueCondition.validate("(a and b") != "")

	var program := DialogueLib.compile(SRC_TAVERN, "tavern.dk")
	var lib := DialogueLib.new()
	var step := lib.begin(program, &"", {&"reputation": 15})
	lib.advance()
	step = lib.advance()
	_check(cases, "变量注入后条件选项可见", step.choices.size() == 3, str(step.choices.size()))
	_check(cases, "find_choice 能定位选项", not step.find_choice(&"opt_rumor").is_empty())


# ---- 跳转与存档恢复 ----
static func _run_jump_and_resume(cases : Array) -> void:
	var program := DialogueLib.compile(SRC_TAVERN, "tavern.dk")
	var lib := DialogueLib.new()
	lib.begin(program, &"", {&"reputation": 15})
	lib.advance()
	lib.advance()
	var step := lib.choose(&"opt_rumor")
	_check(cases, "选项分支内的 jump 生效", step.kind == DialogueStep.Kind.LINE and step.line_id == &"rumor_001", str(step))

	var lib2 := DialogueLib.new()
	var step2 := lib2.begin(program, &"intro_001")
	_check(cases, "从行恢复后推进到下一行", step2.line_id == &"intro_002", str(step2))
	_check(cases, "恢复时重放节点进入命令", step2.ops.size() == 1 and step2.ops[0]["op"] == &"bg")

	var lib3 := DialogueLib.new()
	var step3 := lib3.begin(program, &"not_exist")
	_check(cases, "恢复不存在的行返回错误", step3.is_error() and step3.error_code == ERR_DOES_NOT_EXIST)

	var lib4 := DialogueLib.new()
	var step4 := lib4.begin(program, &"intro_002")
	_check(cases, "恢复到最后一行后进入选项", step4.kind == DialogueStep.Kind.CHOICES, str(step4))

	var lib5 := DialogueLib.new()
	lib5.begin(program)
	lib5.advance()
	lib5.advance()
	var end_step := lib5.choose(&"opt_leave")
	_check(cases, "分支为空的选项选中即结束", end_step.kind == DialogueStep.Kind.ENDED, str(end_step))


# ---- 诊断 ----
static func _run_diagnostics(cases : Array) -> void:
	var missing_id := DialogueLib.compile("""title: t
---
老板: 你好。
===
""", "a.dk")
	_check(cases, "缺少 #line 报错", _has_code(missing_id, &"missing_line_id"), _diag_text(missing_id))
	_check(cases, "含错误的 program 拒绝启动",
		DialogueLib.new().begin(missing_id).error_code == ERR_INVALID_DATA)

	var bad_jump := DialogueLib.compile("""title: t
---
<<jump nowhere>>
===
""", "b.dk")
	_check(cases, "未知跳转目标报错", _has_code(bad_jump, &"unknown_jump"), _diag_text(bad_jump))

	var dup_line := DialogueLib.compile("""title: t
---
甲: 一。#line:x
乙: 二。#line:x
===
""", "c.dk")
	_check(cases, "重复行 ID 报错", _has_code(dup_line, &"duplicate_line_id"), _diag_text(dup_line))

	var bad_var := DialogueLib.compile("""title: t
---
-> 走 if gold > 0 #option:o1
===
""", "d.dk")
	_check(cases, "条件引用未声明变量报错", _has_code(bad_var, &"undeclared_var"), _diag_text(bad_var))

	var dup_node := DialogueLib.compile("""title: t
---
甲: 一。#line:a1
===
title: t
---
乙: 二。#line:a2
===
""", "e.dk")
	_check(cases, "重复节点标题报错", _has_code(dup_node, &"duplicate_node"), _diag_text(dup_node))

	var no_line_id := DialogueLib.compile("""title: t
---
甲: 一。
===
""", "f.dk")
	var d : DialogueDiagnostic = no_line_id.diagnostics[0]
	_check(cases, "诊断带行号", d.line == 3, str(d.line))
	_check(cases, "诊断可序列化", d.to_dict()["code"] == "missing_line_id")

	var auto_id := DialogueCompiler.new()
	auto_id.auto_line_id = true
	var auto_program := auto_id.compile("""title: t
---
甲: 一。
===
""", "g.dk")
	_check(cases, "auto_line_id 下自动生成行 ID", not auto_program.has_errors(), _diag_text(auto_program))
	_check(cases, "自动生成只产生警告", _has_code(auto_program, &"auto_line_id"))

	var jump_opts := DialogueLib.compile("""title: t
---
-> 走 #option:o1
<<jump t2>>
===

title: t2
---
甲: 二。#line:b
===
""", "h.dk")
	_check(cases, "选项与兜底跳转并存时告警", _has_code(jump_opts, &"jump_with_options"), _diag_text(jump_opts))

	var jump_mid := DialogueLib.compile("""title: n
---
甲: 一。#line:c
<<jump n>>
甲: 二。#line:d
甲: 三。#line:e
===
""", "i.dk")
	_check(cases, "中途跳转会吞掉后续台词时告警", _has_code(jump_mid, &"jump_before_lines_end"), _diag_text(jump_mid))


# ---- 状态序列化 ----
static func _run_state(cases : Array) -> void:
	var program := DialogueLib.compile(SRC_TAVERN, "tavern.dk")
	var lib := DialogueLib.new()
	lib.begin(program, &"", {&"reputation": 15})
	lib.advance()
	lib.advance()
	lib.choose(&"opt_wine")

	var state := lib.get_state()
	_check(cases, "状态含当前行", String(state["line"]) == "intro_003", str(state))
	_check(cases, "状态含变量快照", int((state["vars"] as Dictionary).get(&"gold", 0)) == 50)

	var restored := DialogueLib.new()
	var step := restored.restore_state(program, state)
	_check(cases, "从状态恢复后可继续推进", not step.is_error(), str(step))
	_check(cases, "恢复后变量一致", int(restored.get_var(&"gold")) == 50)
	_check(cases, "恢复后位置正确", restored.get_last_line() == &"intro_003")


# ---- 辅助 ----
static func _check(cases : Array, name : String, ok : bool, detail : String = "") -> void:
	cases.append({"name": name, "ok": ok, "detail": detail})


static func _has_code(program : DialogueProgram, code : StringName) -> bool:
	for d in program.diagnostics:
		if d.code == code:
			return true
	return false


static func _diag_text(program : DialogueProgram) -> String:
	var parts : Array[String] = []
	for d in program.diagnostics:
		parts.append(str(d))
	return " | ".join(parts)
