extends RefCounted
## .dk 剧本编译器：分段 → 语法解析 → 语义校验 → DialogueProgram
##
## 语法契约（v0.1）
##   title: <节点名>            节点头，唯一
##   vars:                     变量声明块（缩进，格式 name: type = default）
##   start: true               标记起始节点（可选，缺省取第一个节点）
##   ---                       正文开始
##   <<op key="value" ...>>    命令；裸参数等价于 target="..."
##   speaker: text #tag:value  台词；必须带 #line:<唯一 ID>
##   -> 文本 #option:<ID> if 条件   选项；其后缩进块为该分支正文
##   ===                       节点结束
##
## 约定：命令归属于它之后的第一条台词；若其后没有台词则归入节点的退出命令
class_name DialogueCompiler

const SEP_HEADER : String = "---"
const SEP_END : String = "==="
const MAX_SPEAKER_LEN : int = 20

static var _tag_re : RegEx = null

## 源码名，仅用于诊断定位
var source_name : String = ""
## 台词缺少 #line 时是否自动生成（默认为严格模式：报错）
var auto_line_id : bool = false
var diagnostics : Array[DialogueDiagnostic] = []

var _program : DialogueProgram = null
var _sub_counter : int = 0


## 编译源码；始终返回 program，用 has_errors() 判断是否可用
func compile(source : String, name : String = "") -> DialogueProgram:
	source_name = name
	diagnostics.clear()
	_sub_counter = 0
	_program = DialogueProgram.new()
	_program.source_name = name

	var rows : Array = _split_rows(source)
	_parse_rows(rows)
	_validate()
	_program.diagnostics = diagnostics
	return _program


## 只做校验，不返回产物（供 CLI / 编辑器诊断使用）
func validate_source(source : String, name : String = "") -> Array[DialogueDiagnostic]:
	compile(source, name)
	return diagnostics


# ==================== 行切分 ====================
# NOTE 缩进按「空格数」计算，Tab 记 4；空行与 // 注释不参与语法
func _split_rows(source : String) -> Array:
	var out : Array = []
	var normalized : String = source.replace("\r\n", "\n").replace("\r", "\n")
	var raw_lines : PackedStringArray = normalized.split("\n")
	for i in raw_lines.size():
		var raw : String = raw_lines[i]
		var text : String = raw.strip_edges()
		if text == "" or text.begins_with("//"):
			continue
		var indent : int = 0
		for ch in raw:
			if ch == "\t":
				indent += 4
			elif ch == " ":
				indent += 1
			else:
				break
		out.append({"text": text, "indent": indent, "no": i + 1})
	return out


# ==================== 节点解析 ====================
func _parse_rows(rows : Array) -> void:
	var i : int = 0
	var n : int = rows.size()
	var node_count : int = 0

	while i < n:
		var row : Dictionary = rows[i]
		if int(row["indent"]) != 0:
			_error(&"unexpected_indent", "顶层不应有缩进", row["no"])
			i += 1
			continue
		var text : String = row["text"]
		if not text.begins_with("title:"):
			_error(&"expected_title", "期望节点头 'title: <名称>'，实际为 '%s'" % text, row["no"])
			i += 1
			continue

		var node := DialogueNode.new()
		node.line = int(row["no"])
		node.title = StringName(text.substr(6).strip_edges())
		node_count += 1
		i += 1

		# ---- 节点头：vars / start / --- ----
		var has_body : bool = false
		while i < n:
			var r : Dictionary = rows[i]
			var r_text : String = r["text"]
			if int(r["indent"]) == 0 and r_text == SEP_HEADER:
				has_body = true
				i += 1
				break
			if int(r["indent"]) == 0 and r_text.begins_with("title:"):
				break
			if r_text.begins_with("vars:"):
				i = _parse_vars(rows, i)
				continue
			if r_text.begins_with("start:"):
				var flag : String = r_text.substr(6).strip_edges().to_lower()
				if flag == "true":
					if _program.start != &"":
						_error(&"duplicate_start", "只允许一个 start: true", r["no"])
					_program.start = node.title
				elif flag != "false":
					_error(&"bad_start", "start 只能是 true / false", r["no"])
				i += 1
				continue
			_error(&"unknown_header", "未知的节点头 '%s'" % r_text, r["no"])
			i += 1

		if not has_body:
			_error(&"missing_body", "节点 %s 缺少 '%s' 正文分隔符" % [node.title, SEP_HEADER], node.line)
			_register(node)
			continue

		# ---- 正文 ----
		i = _parse_body(rows, i, node)
		_register(node)

	if node_count == 0:
		_error(&"no_node", "文件里没有任何 'title:' 节点", 1)


func _parse_body(rows : Array, start : int, node : DialogueNode) -> int:
	var i : int = start
	var n : int = rows.size()
	var pending : Array[DialogueCommand] = []
	var options_started : bool = false

	while i < n:
		var r : Dictionary = rows[i]
		var text : String = r["text"]
		var no : int = int(r["no"])
		var indent : int = int(r["indent"])

		if indent == 0 and text == SEP_END:
			i += 1
			break
		if indent == 0 and text.begins_with("title:"):
			break
		if indent != 0:
			_error(&"unexpected_indent", "正文顶层不应缩进（缩进只用于选项分支）", no)
			i += 1
			continue

		if text.begins_with("->"):
			var body : Array = []
			i += 1
			while i < n and int(rows[i]["indent"]) > 0:
				body.append(rows[i])
				i += 1
			if not pending.is_empty():
				_error(&"cmd_before_option", "选项之前的命令没有可依附的台词，请移入节点开头或分支内", no)
				pending.clear()
			_parse_option(node, r, body)
			options_started = true
			continue

		if text.begins_with("<<"):
			var cmd := _parse_command(text, no)
			if cmd != null:
				# NOTE 首条台词之前的命令归节点（resume 时重放，便于恢复演出状态）；
				# 台词或选项之后的命令走 pending，最终落到行命令或节点退出命令
				if node.lines.is_empty() and not options_started:
					node.commands.append(cmd)
				else:
					pending.append(cmd)
			i += 1
			continue

		var line := _parse_line(text, no)
		line.commands = pending.duplicate()
		pending.clear()
		node.lines.append(line)
		i += 1

	node.exit_commands = pending.duplicate()
	return i


func _parse_vars(rows : Array, start : int) -> int:
	var base_indent : int = int(rows[start]["indent"])
	var i : int = start + 1
	var n : int = rows.size()
	while i < n and int(rows[i]["indent"]) > base_indent:
		var r : Dictionary = rows[i]
		var text : String = r["text"]
		var no : int = int(r["no"])
		var colon : int = text.find(":")
		if colon <= 0:
			_error(&"bad_var", "变量声明应为 'name: type = default'", no)
			i += 1
			continue
		var var_name : String = text.substr(0, colon).strip_edges()
		var rest : String = text.substr(colon + 1).strip_edges()
		var eq : int = rest.find("=")
		var type_name : String = (rest.substr(0, eq) if eq >= 0 else rest).strip_edges().to_lower()
		var default_raw : String = (rest.substr(eq + 1) if eq >= 0 else "").strip_edges()

		if not type_name in ["int", "float", "bool", "string"]:
			_error(&"bad_var_type", "变量类型只能是 int / float / bool / string，实际为 '%s'" % type_name, no)
			i += 1
			continue
		var key := StringName(var_name)
		if _program.vars.has(key):
			_error(&"duplicate_var", "变量重复声明: %s" % var_name, no)
			i += 1
			continue
		_program.vars[key] = {"type": type_name, "default": _coerce(default_raw, type_name)}
		i += 1
	return i


func _parse_option(parent : DialogueNode, row : Dictionary, body : Array) -> void:
	var text : String = row["text"]
	var no : int = int(row["no"])
	var rest : String = text.substr(2).strip_edges()
	var condition : String = ""

	# NOTE if 与 #option 的先后顺序都接受：
	#   -> 文本 #option:x if 条件
	#   -> 文本 if 条件 #option:x
	var if_pos : int = rest.find(" if ")
	var head : String = rest
	if if_pos >= 0:
		condition = rest.substr(if_pos + 4).strip_edges()
		head = rest.substr(0, if_pos).strip_edges()

	var parsed : Dictionary = _extract_tags(head)
	var tags : Dictionary = parsed["tags"]
	# 条件尾部若还残留标签，一并摘出
	var cond_parsed : Dictionary = _extract_tags(condition)
	for key in cond_parsed["tags"]:
		tags[key] = cond_parsed["tags"][key]
	condition = String(cond_parsed["text"])

	var opt := DialogueOption.new()
	opt.line = no
	opt.text = String(parsed["text"])
	opt.condition = condition

	var id_raw : String = String(tags.get(&"option", ""))
	if id_raw == "":
		opt.id = StringName("%s#opt%d" % [parent.title, parent.options.size()])
		_warn(&"auto_option_id", "选项缺少 #option:<ID>，已自动生成 %s" % opt.id, no)
	else:
		opt.id = StringName(id_raw)

	if body.is_empty():
		opt.target = &""  # 选中即结束
	else:
		_parse_option_body(parent, opt, body)

	parent.options.append(opt)


func _parse_option_body(parent : DialogueNode, opt : DialogueOption, rows : Array) -> void:
	_sub_counter += 1
	var sub := DialogueNode.new()
	sub.title = StringName("%s#%d" % [parent.title, _sub_counter])
	sub.line = int(rows[0]["no"])
	var pending : Array[DialogueCommand] = []

	for r in rows:
		var text : String = r["text"]
		var no : int = int(r["no"])
		if text == SEP_END:
			_error(&"body_sep", "选项分支内不允许出现 '%s'" % SEP_END, no)
			continue
		if text.begins_with("->"):
			_error(&"nested_option", "v0.1 不支持分支内再嵌套选项，请拆成独立节点", no)
			continue
		if text.begins_with("<<"):
			var cmd := _parse_command(text, no)
			if cmd != null:
				pending.append(cmd)
			continue
		var line := _parse_line(text, no)
		line.commands = pending.duplicate()
		pending.clear()
		sub.lines.append(line)

	sub.exit_commands = pending.duplicate()
	if sub.is_empty():
		_error(&"empty_option_body", "选项 %s 的分支正文为空" % opt.id, opt.line)
		return
	_program.nodes[sub.title] = sub
	opt.target = sub.title


# ==================== 台词 / 命令 ====================
func _parse_line(text : String, no : int) -> DialogueLine:
	var parsed : Dictionary = _extract_tags(text)
	var tags : Dictionary = parsed["tags"]
	var body : String = String(parsed["text"])

	var line := DialogueLine.new()
	line.line = no

	var speaker_key : String = String(tags.get(&"speaker", ""))
	var sep : int = _find_speaker_sep(body)
	if sep >= 0:
		if speaker_key == "":
			speaker_key = body.substr(0, sep).strip_edges()
		line.text = body.substr(sep + 1).strip_edges()
	else:
		line.text = body.strip_edges()
	line.speaker = StringName(speaker_key)

	for key in tags:
		if key == &"line":
			continue
		line.tags[key] = String(tags[key])

	var id_raw : String = String(tags.get(&"line", ""))
	if id_raw == "":
		if auto_line_id:
			line.id = StringName("line#%d" % no)
			_warn(&"auto_line_id", "台词缺少 #line:<ID>，已按行号生成 %s（不稳定，建议显式书写）" % line.id, no)
		else:
			_error(&"missing_line_id", "台词缺少 #line:<ID> 标签", no)
	else:
		line.id = StringName(id_raw)
	return line


# NOTE 只在「前缀较短且不含标点」时把冒号当说话人分隔符，避免正文里的冒号被误判
func _find_speaker_sep(body : String) -> int:
	for candidate in [":", "："]:
		var pos : int = body.find(candidate)
		if pos < 0:
			continue
		var head : String = body.substr(0, pos).strip_edges()
		if head == "" or head.length() > MAX_SPEAKER_LEN:
			continue
		if head.contains("。"):
			continue
		return pos
	return -1


func _parse_command(text : String, no : int) -> DialogueCommand:
	if not text.ends_with(">>"):
		_error(&"bad_command", "命令缺少 '>>' 结尾: %s" % text, no)
		return null
	var inner : String = text.substr(2, text.length() - 4).strip_edges()
	var parts : PackedStringArray = _split_args(inner)
	if parts.is_empty():
		_error(&"bad_command", "命令缺少 op", no)
		return null

	var cmd := DialogueCommand.new()
	cmd.op = StringName(parts[0])
	cmd.line = no
	for i in range(1, parts.size()):
		var token : String = parts[i]
		var eq : int = token.find("=")
		if eq > 0:
			cmd.args[StringName(token.substr(0, eq))] = _unquote(token.substr(eq + 1))
		elif eq == 0:
			_error(&"bad_arg", "命令参数缺少键名: %s" % token, no)
		else:
			# NOTE 裸参数统一落到 target，支持 <<jump tavern_order>>
			cmd.args[&"target"] = _unquote(token)
	return cmd


func _split_args(s : String) -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	var cur : String = ""
	var in_quote : bool = false
	for i in s.length():
		var c : String = s[i]
		if c == "\"":
			in_quote = not in_quote
			cur += c
			continue
		if c == " " and not in_quote:
			if cur != "":
				out.append(cur)
				cur = ""
			continue
		cur += c
	if cur != "":
		out.append(cur)
	return out


func _unquote(v : String) -> String:
	var s : String = v.strip_edges()
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		return s.substr(1, s.length() - 2)
	return s


func _extract_tags(text : String) -> Dictionary:
	var tags : Dictionary = {}
	var rest : String = text.strip_edges()
	var re : RegEx = _get_tag_re()
	while true:
		var m : RegExMatch = re.search(rest)
		if m == null:
			break
		tags[StringName(m.get_string(1))] = m.get_string(2)
		rest = rest.substr(0, m.get_start()).strip_edges()
	return {"text": rest, "tags": tags}


static func _get_tag_re() -> RegEx:
	if _tag_re == null:
		_tag_re = RegEx.create_from_string("#([A-Za-z_][A-Za-z0-9_]*):([^\\s#]+)\\s*$")
	return _tag_re


func _coerce(raw : String, type_name : String) -> Variant:
	var s : String = _unquote(raw)
	match type_name:
		"int":
			return s.to_int()
		"float":
			return s.to_float()
		"bool":
			return s.to_lower() == "true"
		_:
			return s


# ==================== 注册与校验 ====================
func _register(node : DialogueNode) -> void:
	if String(node.title) == "":
		_error(&"empty_title", "节点标题为空", node.line)
		return
	if _program.nodes.has(node.title):
		_error(&"duplicate_node", "节点标题重复: %s" % node.title, node.line)
		return
	_program.nodes[node.title] = node


func _validate() -> void:
	if _program.start == &"":
		var titles : Array[StringName] = _program.get_node_titles()
		if not titles.is_empty():
			_program.start = titles[0]
	elif not _program.nodes.has(_program.start):
		_error(&"unknown_start", "起始节点不存在: %s" % _program.start, 1)

	# 行索引
	for title in _program.nodes:
		var node : DialogueNode = _program.nodes[title]
		for idx in node.lines.size():
			var line : DialogueLine = node.lines[idx]
			if line.id == &"":
				continue
			if _program.line_index.has(line.id):
				_error(&"duplicate_line_id", "行 ID 全局重复: %s" % line.id, line.line)
				continue
			_program.line_index[line.id] = {"node": title, "index": idx}

	var seen_option : Dictionary = {}
	for title in _program.nodes:
		var node : DialogueNode = _program.nodes[title]
		for cmd in node.commands:
			_check_command(cmd)
		for line in node.lines:
			for cmd in line.commands:
				_check_command(cmd)
		for cmd in node.exit_commands:
			_check_command(cmd)
		for opt in node.options:
			_check_option(opt, seen_option)
		if node.is_empty():
			_warn(&"empty_node", "节点 %s 没有任何内容" % title, node.line)
		_check_jump_placement(node)


func _check_command(cmd : DialogueCommand) -> void:
	match cmd.op:
		&"jump":
			var target := StringName(String(cmd.args.get(&"target", "")))
			if String(target) == "":
				_error(&"jump_no_target", "<<jump>> 缺少目标节点", cmd.line)
			elif not _program.nodes.has(target):
				_error(&"unknown_jump", "跳转目标不存在: %s" % target, cmd.line)
		&"set":
			var var_name := StringName(String(cmd.args.get(&"var", "")))
			if String(var_name) == "":
				_error(&"set_no_var", "<<set>> 缺少 var 参数", cmd.line)
			elif not _program.vars.has(var_name):
				_error(&"unknown_var", "<<set>> 引用了未声明的变量: %s" % var_name, cmd.line)
			var mode : String = String(cmd.args.get(&"op", "set"))
			if not mode in ["set", "add", "sub", "mul"]:
				_error(&"bad_set_op", "<<set>> 的 op 只能是 set / add / sub / mul", cmd.line)


# NOTE 跳转位置的两条常见误用：中途跳转吞掉后续台词、与选项并存时被选项压制
func _check_jump_placement(node : DialogueNode) -> void:
	for idx in node.lines.size():
		var line : DialogueLine = node.lines[idx]
		for cmd in line.commands:
			if cmd.op == &"jump" and idx < node.lines.size() - 1:
				_warn(&"jump_before_lines_end",
					"该行的 jump 会跳过其后的 %d 行台词" % (node.lines.size() - idx - 1), cmd.line)
	if not node.options.is_empty():
		for cmd in node.exit_commands:
			if cmd.op == &"jump":
				_warn(&"jump_with_options",
					"节点 %s 同时有选项与兜底跳转，跳转会被忽略" % node.title, cmd.line)


func _check_option(opt : DialogueOption, seen : Dictionary) -> void:
	if seen.has(opt.id):
		_error(&"duplicate_option_id", "选项 ID 全局重复: %s" % opt.id, opt.line)
	else:
		seen[opt.id] = true

	if String(opt.target) != "" and not _program.nodes.has(opt.target):
		_error(&"unknown_option_target", "选项 %s 的目标节点不存在: %s" % [opt.id, opt.target], opt.line)

	if opt.condition != "":
		var err : String = DialogueCondition.validate(opt.condition)
		if err != "":
			_error(&"bad_condition", "条件表达式无效 (%s): %s" % [err, opt.condition], opt.line)
		else:
			for var_name in DialogueCondition.identifiers(opt.condition):
				if not _program.vars.has(var_name):
					_error(&"undeclared_var", "条件引用了未声明的变量: %s" % var_name, opt.line)


# ==================== 诊断 ====================
func _error(code : StringName, message : String, line : int) -> void:
	diagnostics.append(DialogueDiagnostic.new(
		DialogueDiagnostic.Severity.ERROR, code, message, line, 1, source_name))


func _warn(code : StringName, message : String, line : int) -> void:
	diagnostics.append(DialogueDiagnostic.new(
		DialogueDiagnostic.Severity.WARNING, code, message, line, 1, source_name))
