extends RefCounted
## 受限条件表达式：字面量 / 变量 / 比较 / and or not / 括号
## 只做白名单求值，不支持函数调用、下标、算术与赋值——剧本条件必须可静态校验
class_name DialogueCondition

const ALLOWED_OPS : Array[String] = ["==", "!=", ">", ">=", "<", "<="]
const _DIGITS : String = "0123456789"
const _ALPHA : String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"


## 编译为 AST；ok 为 false 时 error 有效
static func compile(source : String) -> Dictionary:
	var tokens : Array = _tokenize(source)
	for t in tokens:
		if t["t"] == "err":
			return {"ok": false, "error": t["v"], "pos": t["p"]}
	var ctx := {"tokens": tokens, "i": 0, "error": ""}
	var ast = _parse_or(ctx)
	if ctx["error"] != "":
		return {"ok": false, "error": ctx["error"], "pos": 0}
	if ctx["i"] < tokens.size():
		return {"ok": false, "error": "多余的内容 '%s'" % str(tokens[ctx["i"]]["v"]), "pos": 0}
	if ast == null:
		return {"ok": false, "error": "表达式为空", "pos": 0}
	return {"ok": true, "ast": ast, "error": ""}


## 校验表达式是否合法；返回空串表示通过
static func validate(source : String) -> String:
	var r : Dictionary = compile(source)
	return "" if r["ok"] else String(r["error"])


## 求值；表达式非法或变量缺失一律按 false 处理，并给出警告
static func evaluate(source : String, vars : Dictionary) -> bool:
	var r : Dictionary = compile(source)
	if not r["ok"]:
		push_warning("DialogueCondition|求值|表达式无效: %s (%s)" % [source, r["error"]])
		return false
	return _truthy(_eval(r["ast"], vars))


## 提取表达式中引用的变量名，供编译器校验「变量已声明」
static func identifiers(source : String) -> Array[StringName]:
	var out : Array[StringName] = []
	var r : Dictionary = compile(source)
	if not r["ok"]:
		return out
	_collect(r["ast"], out)
	return out


# ---- 词法 ----
static func _tokenize(source : String) -> Array:
	var out : Array = []
	var i : int = 0
	var n : int = source.length()
	while i < n:
		var c : String = source[i]
		if c == " " or c == "\t":
			i += 1
			continue
		if c == "(" or c == ")":
			out.append({"t": c, "v": c, "p": i})
			i += 1
			continue
		if c == "=" or c == "!" or c == "<" or c == ">":
			var op : String = c
			if i + 1 < n and source[i + 1] == "=":
				op += "="
				i += 1
			if op == "=":
				out.append({"t": "err", "v": "比较应写作 '=='", "p": i})
				return out
			out.append({"t": "op", "v": op, "p": i})
			i += 1
			continue
		if c == "\"":
			var j : int = i + 1
			var buf : String = ""
			while j < n and source[j] != "\"":
				buf += source[j]
				j += 1
			if j >= n:
				out.append({"t": "err", "v": "字符串未闭合", "p": i})
				return out
			out.append({"t": "lit", "v": buf, "p": i})
			i = j + 1
			continue
		if _DIGITS.contains(c):
			var j2 : int = i
			var num : String = ""
			var is_float : bool = false
			while j2 < n and (_DIGITS.contains(source[j2]) or source[j2] == "."):
				if source[j2] == ".":
					is_float = true
				num += source[j2]
				j2 += 1
			out.append({"t": "lit", "v": num.to_float() if is_float else num.to_int(), "p": i})
			i = j2
			continue
		if _ALPHA.contains(c):
			var j3 : int = i
			var ident : String = ""
			while j3 < n and (_ALPHA.contains(source[j3]) or _DIGITS.contains(source[j3])):
				ident += source[j3]
				j3 += 1
			if ident == "and" or ident == "or" or ident == "not":
				out.append({"t": "kw", "v": ident, "p": i})
			elif ident == "true" or ident == "false":
				out.append({"t": "lit", "v": ident == "true", "p": i})
			else:
				out.append({"t": "var", "v": ident, "p": i})
			i = j3
			continue
		out.append({"t": "err", "v": "无法识别的字符 '%s'" % c, "p": i})
		return out
	return out


# ---- 语法（递归下降，Dictionary 引用传递以便 index 可写）----
static func _peek(ctx : Dictionary) -> Variant:
	var tokens : Array = ctx["tokens"]
	var idx : int = ctx["i"]
	if idx >= tokens.size():
		return null
	return tokens[idx]


static func _next(ctx : Dictionary) -> Variant:
	var tok = _peek(ctx)
	if tok != null:
		ctx["i"] = int(ctx["i"]) + 1
	return tok


static func _peek_is(ctx : Dictionary, type : String, value : String) -> bool:
	var tok = _peek(ctx)
	if tok == null:
		return false
	if tok["t"] != type:
		return false
	return value == "" or String(tok["v"]) == value


static func _parse_or(ctx : Dictionary) -> Variant:
	var left = _parse_and(ctx)
	if ctx["error"] != "":
		return null
	while _peek_is(ctx, "kw", "or"):
		_next(ctx)
		var right = _parse_and(ctx)
		if ctx["error"] != "":
			return null
		left = {"t": "bin", "op": "or", "l": left, "r": right}
	return left


static func _parse_and(ctx : Dictionary) -> Variant:
	var left = _parse_not(ctx)
	if ctx["error"] != "":
		return null
	while _peek_is(ctx, "kw", "and"):
		_next(ctx)
		var right = _parse_not(ctx)
		if ctx["error"] != "":
			return null
		left = {"t": "bin", "op": "and", "l": left, "r": right}
	return left


static func _parse_not(ctx : Dictionary) -> Variant:
	if _peek_is(ctx, "kw", "not"):
		_next(ctx)
		var inner = _parse_not(ctx)
		if ctx["error"] != "":
			return null
		return {"t": "not", "a": inner}
	return _parse_cmp(ctx)


static func _parse_cmp(ctx : Dictionary) -> Variant:
	var left = _parse_primary(ctx)
	if ctx["error"] != "":
		return null
	if _peek_is(ctx, "op", ""):
		var op : String = String(_peek(ctx)["v"])
		_next(ctx)
		var right = _parse_primary(ctx)
		if ctx["error"] != "":
			return null
		return {"t": "bin", "op": op, "l": left, "r": right}
	return left


static func _parse_primary(ctx : Dictionary) -> Variant:
	var tok = _peek(ctx)
	if tok == null:
		ctx["error"] = "表达式意外结束"
		return null
	if tok["t"] == "(":
		_next(ctx)
		var inner = _parse_or(ctx)
		if ctx["error"] != "":
			return null
		if not _peek_is(ctx, ")", ""):
			ctx["error"] = "缺少右括号"
			return null
		_next(ctx)
		return inner
	if tok["t"] == "lit":
		_next(ctx)
		return {"t": "lit", "v": tok["v"]}
	if tok["t"] == "var":
		_next(ctx)
		return {"t": "var", "n": String(tok["v"])}
	ctx["error"] = "无法识别的记号 '%s'" % str(tok["v"])
	return null


# ---- 求值 ----
static func _eval(node : Variant, vars : Dictionary) -> Variant:
	if not node is Dictionary:
		return null
	match String(node.get("t", "")):
		"lit":
			return node["v"]
		"var":
			var name : String = node["n"]
			return vars.get(StringName(name), null)
		"not":
			return not _truthy(_eval(node["a"], vars))
		"bin":
			var op : String = node["op"]
			if op == "and":
				return _truthy(_eval(node["l"], vars)) and _truthy(_eval(node["r"], vars))
			if op == "or":
				return _truthy(_eval(node["l"], vars)) or _truthy(_eval(node["r"], vars))
			return _compare(op, _eval(node["l"], vars), _eval(node["r"], vars))
	return null


static func _compare(op : String, a : Variant, b : Variant) -> bool:
	if a == null or b == null:
		return op == "!="
	match op:
		"==":
			return a == b
		"!=":
			return a != b
		">":
			return _gt(a, b)
		"<":
			return _gt(b, a)
		">=":
			return _gt(a, b) or _eq_numeric(a, b)
		"<=":
			return _gt(b, a) or _eq_numeric(a, b)
	return false


static func _gt(a : Variant, b : Variant) -> bool:
	if _is_num(a) and _is_num(b):
		return float(a) > float(b)
	if a is String and b is String:
		return a > b
	return false


static func _eq_numeric(a : Variant, b : Variant) -> bool:
	if _is_num(a) and _is_num(b):
		return is_equal_approx(float(a), float(b))
	return a == b


static func _is_num(v : Variant) -> bool:
	return v is int or v is float


static func _truthy(v : Variant) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if _is_num(v):
		return float(v) != 0.0
	if v is String:
		return v != ""
	return true


static func _collect(node : Variant, out : Array[StringName]) -> void:
	if not node is Dictionary:
		return
	match String(node.get("t", "")):
		"var":
			var name := StringName(node["n"])
			if not out.has(name):
				out.append(name)
		"not":
			_collect(node["a"], out)
		"bin":
			_collect(node["l"], out)
			_collect(node["r"], out)
