extends RefCounted
## 一行台词：稳定 ID + 说话人 + 正文 + 标签
## 文本保持原文，本地化由调用方按 id 另行查表
class_name DialogueLine

var id : StringName = &""
var speaker : StringName = &""
var text : String = ""
var tags : Dictionary[StringName, String] = {}
## 本行呈现前执行的命令（随该行一起产出 ops）
var commands : Array[DialogueCommand] = []
var line : int = 0


func to_dict() -> Dictionary:
	return {
		"id": id,
		"speaker": speaker,
		"text": text,
		"tags": tags.duplicate(),
	}
