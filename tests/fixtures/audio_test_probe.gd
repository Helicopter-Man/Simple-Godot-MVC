extends RefCounted
## AudioKit 测试夹具：收集播放 / 状态事件，验证作用域内派发与转发

var started : int = 0
var ended : int = 0
var dropped : int = 0
var state_events : int = 0
var last_reason : StringName = &""
var phases : Array[int] = []


func bind(arch : Node) -> void:
	arch.register_event(&"AudioPlaybackEvent", _on_playback)
	arch.register_event(&"AudioStateEvent", _on_state)


func _on_playback(e : AudioPlaybackEvent) -> void:
	phases.append(e.phase)
	if e.is_started():
		started += 1
	elif e.is_ended():
		ended += 1
	elif e.is_dropped():
		dropped += 1
		last_reason = e.reason


func _on_state(_e : AudioStateEvent) -> void:
	state_events += 1
