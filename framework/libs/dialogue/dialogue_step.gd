extends RefCounted
## 单次推进的产物：下一帧的默认编排形式
## 只有纯数据：不含 Node / Texture / Callable，调用方可放心缓存、比较、序列化
class_name DialogueStep

enum Kind {
	NONE,
	LINE,      ## 呈现一句台词（可能同时带 ops）
	CHOICES,   ## 等待选择，choices 非空
	ENDED,     ## 对话结束
	ERROR,     ## 推进失败，error_code / message 有效
}

var kind : Kind = Kind.NONE
var node : StringName = &""
var line_id : StringName = &""
var speaker : StringName = &""
var text : String = ""
var tags : Dictionary[StringName, String] = {}
## 声明式副作用：[{op: StringName, args: Dictionary}]，语义由调用方解释
var ops : Array[Dictionary] = []
## 可选项：[{id: StringName, text: String, target: StringName}]
var choices : Array[Dictionary] = []
## 本次推进产生的变量变更
var var_changes : Dictionary[StringName, Variant] = {}
var error_code : int = OK
var message : String = ""


static func make_error(code : int, msg : String) -> DialogueStep:
	var step := DialogueStep.new()
	step.kind = Kind.ERROR
	step.error_code = code
	step.message = msg
	return step


func is_error() -> bool:
	return kind == Kind.ERROR


func is_ended() -> bool:
	return kind == Kind.ENDED


func has_choices() -> bool:
	return kind == Kind.CHOICES and not choices.is_empty()


func find_choice(choice_id : StringName) -> Dictionary:
	for c in choices:
		if StringName(c["id"]) == choice_id:
			return c
	return {}


func _to_string() -> String:
	match kind:
		Kind.LINE:
			return "LINE %s %s: %s" % [node, speaker, text]
		Kind.CHOICES:
			return "CHOICES %s (%d)" % [node, choices.size()]
		Kind.ENDED:
			return "ENDED"
		Kind.ERROR:
			return "ERROR %d: %s" % [error_code, message]
		_:
			return "NONE"
