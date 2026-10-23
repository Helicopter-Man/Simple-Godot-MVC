extends RefCounted
## 剧本推进库：编译 .dk、按帧推进、返回「下一帧的默认编排形式」
##
## 定位：纯算法 + 会话内数据。不发射事件、不引用 Node / Texture、不碰 IO、不做 UI 策略
## （连续点击 / 跳过 / 自动播放 / 打字机速度都属于调用方，本库只在被调用时推进一步）
##
## 典型用法
##   var program := DialogueLib.compile(source, "tavern.dk")
##   if program.has_errors(): 打印 program.diagnostics
##   var lib := DialogueLib.new()
##   var step := lib.begin(program)
##   while not step.is_ended():
##       if step.has_choices():
##           step = lib.choose(step.choices[0].id)
##       else:
##           step = lib.advance()
class_name DialogueLib

## 单次推进的最大内部步数，防止节点互跳成环导致死循环
const MAX_STEPS : int = 256

var _program : DialogueProgram = null
var _node : DialogueNode = null
var _line_index : int = 0
var _vars : Dictionary[StringName, Variant] = {}
var _ops : Array[Dictionary] = []
var _var_changes : Dictionary[StringName, Variant] = {}
var _choices : Array[Dictionary] = []
var _pending_jump : StringName = &""
var _last_line : StringName = &""
var _exit_done : bool = false
var _ended : bool = false


## 编译源码的便捷入口；诊断在 program.diagnostics 上
static func compile(source : String, name : String = "") -> DialogueProgram:
	return DialogueCompiler.new().compile(source, name)


# ==================== 会话入口 ====================
## 开始会话；from_line 非空时从该行的「下一行」继续（存档恢复语义）
## initial_vars 会覆盖变量声明里的默认值
func begin(program : DialogueProgram, from_line : StringName = &"", initial_vars : Dictionary = {}) -> DialogueStep:
	_reset()
	if program == null:
		return DialogueStep.make_error(ERR_INVALID_PARAMETER, "program 为空")
	if program.has_errors():
		return DialogueStep.make_error(ERR_INVALID_DATA, "program 含编译错误，拒绝启动")
	_program = program

	for var_name in program.vars:
		_vars[var_name] = program.vars[var_name]["default"]
	for key in initial_vars:
		_vars[StringName(key)] = initial_vars[key]

	if String(from_line) != "":
		var entry : Dictionary = program.line_index.get(from_line, {})
		if entry.is_empty():
			return DialogueStep.make_error(ERR_DOES_NOT_EXIST, "找不到行: %s" % from_line)
		if not _enter_node(entry["node"]):
			return DialogueStep.make_error(ERR_DOES_NOT_EXIST, "行所属节点缺失: %s" % entry["node"])
		# NOTE 定位到该行之后；节点进入命令已进 ops，调用方可借此复原舞台
		_line_index = int(entry["index"]) + 1
		_last_line = from_line
		# NOTE 若恢复点落在该节点最后一行之后，说明退出命令当时已结算过，不能重放
		if _line_index >= _node.lines.size():
			_exit_done = true
	else:
		if not _enter_node(program.start):
			return DialogueStep.make_error(ERR_DOES_NOT_EXIST, "起始节点不存在: %s" % program.start)

	return advance()


## 从存档字典恢复
func restore_state(program : DialogueProgram, state : Dictionary) -> DialogueStep:
	var saved_vars : Dictionary = state.get("vars", {})
	return begin(program, StringName(String(state.get("line", ""))), saved_vars)


## 取当前可序列化状态（只含基础类型，可直接进存档）
func get_state() -> Dictionary:
	return {
		"version": DialogueProgram.FORMAT_VERSION,
		"node": "" if _node == null else String(_node.title),
		"line": String(_last_line),
		"index": _line_index,
		"ended": _ended,
		"vars": _vars.duplicate(),
	}


# ==================== 推进 ====================
## 推进一帧：台词 / 选项 / 结束 / 错误
func advance() -> DialogueStep:
	if _program == null:
		return DialogueStep.make_error(ERR_UNCONFIGURED, "尚未 begin")
	if _ended:
		return _ended_step()

	var guard : int = 0
	while guard < MAX_STEPS:
		guard += 1

		# NOTE 行内 jump 在「上一帧已经交出去」之后才生效，所以放在循环顶部
		if _pending_jump != &"":
			var target : StringName = _pending_jump
			_pending_jump = &""
			if not _enter_node(target):
				return DialogueStep.make_error(ERR_DOES_NOT_EXIST, "跳转目标不存在: %s" % target)
			continue

		if _node == null:
			_ended = true
			return _ended_step()

		if _line_index < _node.lines.size():
			var line : DialogueLine = _node.lines[_line_index]
			_line_index += 1
			for cmd in line.commands:
				_apply_command(cmd)
			_last_line = line.id
			# NOTE 最后一行发出时立刻结算退出命令，避免「玩家不再点下一次」导致 set 丢失
			if _line_index >= _node.lines.size():
				_run_exit_commands()
			return _line_step(line)

		_run_exit_commands()

		# 有可选项时优先等玩家，跳转留到选项处理完之后
		if not _node.options.is_empty():
			var visible : Array[Dictionary] = _visible_options(_node.options)
			if not visible.is_empty():
				_choices = visible
				# NOTE 选项优先：本节点的兜底跳转被丢弃，否则选中分支后会被旧跳转劫持
				_pending_jump = &""
				return _choices_step(visible)

		if _pending_jump == &"":
			_ended = true
			return _ended_step()

	return DialogueStep.make_error(ERR_BUSY, "推进步数超限（%d），疑似节点跳转成环" % MAX_STEPS)


## 选择；choice_id 来自上一帧的 step.choices[i].id
func choose(choice_id : StringName) -> DialogueStep:
	if _program == null:
		return DialogueStep.make_error(ERR_UNCONFIGURED, "尚未 begin")
	if _choices.is_empty():
		return DialogueStep.make_error(ERR_UNAVAILABLE, "当前没有待选项")
	if _ended:
		return DialogueStep.make_error(ERR_UNAVAILABLE, "对话已结束")

	var picked : Dictionary = {}
	for c in _choices:
		if StringName(c["id"]) == choice_id:
			picked = c
			break
	if picked.is_empty():
		return DialogueStep.make_error(ERR_DOES_NOT_EXIST, "选项不存在: %s" % choice_id)

	_choices.clear()
	for cmd in picked["commands"]:
		_apply_command(cmd)

	var target : StringName = StringName(String(picked["target"]))
	if String(target) == "":
		_ended = true
		return _ended_step()
	if not _enter_node(target):
		return DialogueStep.make_error(ERR_DOES_NOT_EXIST, "选项目标不存在: %s" % target)
	return advance()


# ==================== 查询 / 变量 ====================
func get_program() -> DialogueProgram:
	return _program


func has_ended() -> bool:
	return _ended


func get_current_node() -> StringName:
	return &"" if _node == null else _node.title


func get_last_line() -> StringName:
	return _last_line


func get_vars() -> Dictionary:
	return _vars.duplicate()


func get_var(var_name : StringName) -> Variant:
	return _vars.get(var_name, null)


func set_var(var_name : StringName, value : Variant) -> void:
	_vars[var_name] = value


func set_vars(values : Dictionary) -> void:
	for key in values:
		_vars[StringName(key)] = values[key]


# ==================== 内部：指令与帧 ====================
func _reset() -> void:
	_program = null
	_node = null
	_line_index = 0
	_vars.clear()
	_ops.clear()
	_var_changes.clear()
	_choices.clear()
	_pending_jump = &""
	_last_line = &""
	_exit_done = false
	_ended = false


# NOTE 节点退出命令只结算一次；即使 nodes 被多个实例共享也不改写 program 数据
func _run_exit_commands() -> void:
	if _exit_done or _node == null:
		return
	_exit_done = true
	for cmd in _node.exit_commands:
		_apply_command(cmd)


func _enter_node(title : StringName) -> bool:
	if _program == null:
		return false
	var node : DialogueNode = _program.nodes.get(title)
	if node == null:
		return false
	_node = node
	_line_index = 0
	_exit_done = false
	_choices.clear()
	for cmd in node.commands:
		_apply_command(cmd)
	return true


func _apply_command(cmd : DialogueCommand) -> void:
	match cmd.op:
		&"jump":
			_pending_jump = StringName(String(cmd.args.get(&"target", "")))
		&"set":
			_apply_set(cmd)
		_:
			# NOTE 其余 op 原样交给调用方解释，本库不认识它们的语义
			_ops.append({"op": cmd.op, "args": cmd.args.duplicate()})


func _apply_set(cmd : DialogueCommand) -> void:
	var var_name := StringName(String(cmd.args.get(&"var", "")))
	if String(var_name) == "":
		return
	var decl : Dictionary = _program.vars.get(var_name, {})
	if decl.is_empty():
		push_warning("DialogueLib|set|变量未声明: %s" % var_name)
		return
	var type_name : String = String(decl.get("type", "string"))
	var mode : String = String(cmd.args.get(&"op", "set"))
	var value : Variant = _coerce_arg(cmd.args.get(&"value", null), type_name)

	if mode == "set":
		_vars[var_name] = value
		_var_changes[var_name] = value
		return

	var current : Variant = _vars.get(var_name, 0)
	if not (current is int or current is float):
		push_warning("DialogueLib|set|变量 %s 非数值，忽略 %s 运算" % [var_name, mode])
		return

	var result : Variant = current
	match mode:
		"add":
			result = current + value
		"sub":
			result = current - value
		"mul":
			result = current * value
		_:
			push_warning("DialogueLib|set|未知运算 %s" % mode)
			return
	_vars[var_name] = result
	_var_changes[var_name] = result


func _coerce_arg(raw : Variant, type_name : String) -> Variant:
	if raw == null:
		return null
	match type_name:
		"int":
			return String(raw).to_int() if raw is String else int(raw)
		"float":
			return String(raw).to_float() if raw is String else float(raw)
		"bool":
			if raw is String:
				return String(raw).to_lower() == "true"
			return bool(raw)
		_:
			return String(raw)


func _visible_options(options : Array[DialogueOption]) -> Array[Dictionary]:
	var out : Array[Dictionary] = []
	for opt in options:
		if opt.condition != "" and not DialogueCondition.evaluate(opt.condition, _vars):
			continue
		out.append({
			"id": opt.id,
			"text": opt.text,
			"target": opt.target,
			"commands": opt.commands,
		})
	return out


func _line_step(line : DialogueLine) -> DialogueStep:
	var step := DialogueStep.new()
	step.kind = DialogueStep.Kind.LINE
	step.node = _node.title
	step.line_id = line.id
	step.speaker = line.speaker
	step.text = line.text
	for key in line.tags:
		step.tags[key] = line.tags[key]
	step.ops = _take_ops()
	step.var_changes = _take_var_changes()
	return step


func _choices_step(visible : Array[Dictionary]) -> DialogueStep:
	var step := DialogueStep.new()
	step.kind = DialogueStep.Kind.CHOICES
	step.node = &"" if _node == null else _node.title
	step.ops = _take_ops()
	step.var_changes = _take_var_changes()
	# NOTE 只透出选择所需字段，避免调用方拿到 program 内部的命令数组
	for c in visible:
		step.choices.append({"id": c["id"], "text": c["text"], "target": c["target"]})
	return step


func _ended_step() -> DialogueStep:
	var step := DialogueStep.new()
	step.kind = DialogueStep.Kind.ENDED
	step.node = &"" if _node == null else _node.title
	step.ops = _take_ops()
	step.var_changes = _take_var_changes()
	return step


func _take_ops() -> Array[Dictionary]:
	var out : Array[Dictionary] = []
	out.assign(_ops)
	_ops.clear()
	return out


func _take_var_changes() -> Dictionary[StringName, Variant]:
	var out : Dictionary[StringName, Variant] = {}
	for key in _var_changes:
		out[key] = _var_changes[key]
	_var_changes.clear()
	return out
