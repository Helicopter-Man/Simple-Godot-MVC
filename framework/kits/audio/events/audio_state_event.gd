extends Event
## 状态变更回调：资源组、State / Switch / RTPC、音乐状态
class_name AudioStateEvent

const KIND_BANK_LOADED : StringName = &"bank_loaded"
const KIND_BANK_UNLOADED : StringName = &"bank_unloaded"
const KIND_STATE_CHANGED : StringName = &"state_changed"
const KIND_SWITCH_CHANGED : StringName = &"switch_changed"
const KIND_RTPC_CHANGED : StringName = &"rtpc_changed"
const KIND_MUSIC_STATE_CHANGED : StringName = &"music_state_changed"

var kind : StringName = &""
var key : StringName = &""
var value : Variant = null
var old_value : Variant = null


static func changed(_kind : StringName, _key : StringName, _value : Variant, _old_value : Variant = null) -> AudioStateEvent:
	var e := AudioStateEvent.new()
	e.kind = _kind
	e.key = _key
	e.value = _value
	e.old_value = _old_value
	return e
