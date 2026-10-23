extends RefCounted
## 声明式指令：op 与参数原样保存
## 本模块不认识任何 op 的语义（jump / set 除外，它们直接影响流程与变量）
class_name DialogueCommand

var op : StringName = &""
var args : Dictionary[StringName, Variant] = {}
var line : int = 0


func _init(_op : StringName = &"", _args : Dictionary = {}, _line : int = 0) -> void:
	op = _op
	line = _line
	for key in _args:
		args[StringName(key)] = _args[key]


## 转为调用方消费的纯数据形式，不暴露本类实例
func to_dict() -> Dictionary:
	return {"op": op, "args": args.duplicate()}
