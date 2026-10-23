extends RefCounted
## 一个节点：剧本的原子单位
## 推进顺序固定：commands（进入时）→ lines（逐行，行前置命令随行）→ exit_commands → options
class_name DialogueNode

var title : StringName = &""
## 进入节点时立即执行的命令（如切背景、摆立绘）
var commands : Array[DialogueCommand] = []
var lines : Array[DialogueLine] = []
## 台词走完后、选项之前执行的命令（如 <<jump>>）
var exit_commands : Array[DialogueCommand] = []
var options : Array[DialogueOption] = []
var line : int = 0


func is_empty() -> bool:
	return lines.is_empty() and options.is_empty() and commands.is_empty() and exit_commands.is_empty()


func to_dict() -> Dictionary:
	var opts : Array = []
	for opt in options:
		opts.append(opt.to_dict())
	var line_dicts : Array = []
	for l in lines:
		line_dicts.append(l.to_dict())
	return {
		"title": title,
		"line_count": lines.size(),
		"lines": line_dicts,
		"options": opts,
	}
