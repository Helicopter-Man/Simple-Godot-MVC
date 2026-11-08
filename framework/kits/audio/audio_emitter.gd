extends Node
## 发声体桥（对齐 Wwise Game Object）：挂到 2D/3D 节点下，由 Kit 显式绑定
## 位置从父节点推断，业务无需逐帧上报；离树时自动解绑并停掉自己的 voice
class_name AudioEmitter

@export var label : String = ""

var _assigned_id : int = 0
var _kit_ref : WeakRef = null
var _bound : bool = false


func _bind_kit(kit : Node, id : int) -> void:
	_kit_ref = weakref(kit)
	_assigned_id = id
	_bound = true


func _unbind() -> void:
	_bound = false
	_kit_ref = null
	_assigned_id = 0


func get_emitter_id() -> int:
	return _assigned_id


func is_bound() -> bool:
	return _bound


## 返回 Vector3 / Vector2 / null；null 表示非空间播放
func get_world_position() -> Variant:
	var parent : Node = get_parent()
	if parent is Node3D:
		return (parent as Node3D).global_position
	if parent is Node2D:
		return (parent as Node2D).global_position
	return null


func _exit_tree() -> void:
	if not _bound:
		return
	_bound = false
	var k : Variant = null
	if _kit_ref != null:
		k = _kit_ref.get_ref()
	if k != null and is_instance_valid(k):
		k.call("detach_emitter", self)
