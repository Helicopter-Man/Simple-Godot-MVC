extends RefCounted
## 一个选项：稳定 ID + 文本 + 条件 + 目标节点
## target 为空表示「选中即结束对话」
class_name DialogueOption

var id : StringName = &""
var text : String = ""
var target : StringName = &""
## 受限条件表达式源码，空串表示无条件
var condition : String = ""
var commands : Array[DialogueCommand] = []
var line : int = 0


func to_dict() -> Dictionary:
	return {
		"id": id,
		"text": text,
		"target": target,
		"condition": condition,
	}
