extends RefCounted
## 一次播放的句柄（对齐 Wwise PlayingID）
## 只持有 Kit 的弱引用，Kit 释放后所有操作安全降级为 ERR_UNAVAILABLE
class_name AudioHandle

var voice_id : int = 0
var cue_id : StringName = &""
var _kit_ref : WeakRef = null


func _init(_kit : Object = null, _voice_id : int = 0, _cue_id : StringName = &"") -> void:
	voice_id = _voice_id
	cue_id = _cue_id
	if _kit != null:
		_kit_ref = weakref(_kit)


func _kit() -> Object:
	if _kit_ref == null:
		return null
	var k : Variant = _kit_ref.get_ref()
	if k == null or not is_instance_valid(k):
		return null
	return k


func is_playing() -> bool:
	var k := _kit()
	if k == null:
		return false
	return bool(k.call("is_voice_active", voice_id))


## fade < 0 时用 cue.fade_out
func stop(fade : float = -1.0) -> Error:
	var k := _kit()
	if k == null:
		return ERR_UNAVAILABLE
	return k.call("stop_voice", voice_id, fade) as Error


func set_volume_db(db : float) -> Error:
	var k := _kit()
	if k == null:
		return ERR_UNAVAILABLE
	return k.call("set_voice_volume_db", voice_id, db) as Error


func set_pitch(value : float) -> Error:
	var k := _kit()
	if k == null:
		return ERR_UNAVAILABLE
	return k.call("set_voice_pitch", voice_id, value) as Error


func get_cue_id() -> StringName:
	return cue_id
