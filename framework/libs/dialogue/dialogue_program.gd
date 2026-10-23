extends RefCounted
## 编译产物：纯数据，不含 Node / Texture / Callable 引用
## 可被缓存复用，被多个 DialogueLib 实例共享（实例自身不修改本对象）
class_name DialogueProgram

const FORMAT_VERSION : int = 1

var version : int = FORMAT_VERSION
var nodes : Dictionary[StringName, DialogueNode] = {}
## 变量声明：name -> {type: String, default: Variant}
var vars : Dictionary[StringName, Dictionary] = {}
var start : StringName = &""
## 行索引：line_id -> {node: StringName, index: int}
var line_index : Dictionary[StringName, Dictionary] = {}
var diagnostics : Array[DialogueDiagnostic] = []
var source_name : String = ""


func has_errors() -> bool:
	for d in diagnostics:
		if d.is_error():
			return true
	return false


func get_node(title : StringName) -> DialogueNode:
	return nodes.get(title)


func get_line(line_id : StringName) -> DialogueLine:
	var entry : Dictionary = line_index.get(line_id, {})
	if entry.is_empty():
		return null
	var node : DialogueNode = nodes.get(entry["node"])
	if node == null:
		return null
	var idx : int = int(entry["index"])
	if idx < 0 or idx >= node.lines.size():
		return null
	return node.lines[idx]


func get_node_titles() -> Array[StringName]:
	var out : Array[StringName] = []
	for key in nodes:
		out.append(key)
	return out


## 供 AI 工作流注入上下文：已有节点标题 + 已声明变量
func describe() -> Dictionary:
	var var_names : Array[StringName] = []
	for key in vars:
		var_names.append(key)
	return {
		"version": version,
		"start": start,
		"nodes": get_node_titles(),
		"vars": var_names,
	}
