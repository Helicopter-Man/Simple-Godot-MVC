extends RefCounted
## 编译诊断：一条可定位的问题记录
## 定位信息统一为 file / line / column / code / message，便于编辑器跳转与 AI 回环修复
class_name DialogueDiagnostic

enum Severity { ERROR, WARNING }

const SEVERITY_NAME : Dictionary = {
	Severity.ERROR: "error",
	Severity.WARNING: "warning",
}

var severity : Severity = Severity.ERROR
var code : StringName = &""
var message : String = ""
var source : String = ""
var line : int = 0
var column : int = 0


func _init(
	_severity : Severity = Severity.ERROR,
	_code : StringName = &"",
	_message : String = "",
	_line : int = 0,
	_column : int = 1,
	_source : String = ""
) -> void:
	severity = _severity
	code = _code
	message = _message
	line = _line
	column = _column
	source = _source


func is_error() -> bool:
	return severity == Severity.ERROR


func to_dict() -> Dictionary:
	return {
		"severity": SEVERITY_NAME[severity],
		"code": String(code),
		"message": message,
		"source": source,
		"line": line,
		"column": column,
	}


func _to_string() -> String:
	return "%s:%d:%d: %s [%s] %s" % [
		source if source != "" else "<source>", line, column,
		SEVERITY_NAME[severity], code, message,
	]
