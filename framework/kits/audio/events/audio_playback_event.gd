extends Event
## 播放回调：开始 / 结束 / 被丢弃
## 在 AudioKit 作用域内派发；配置了 target_architecture 时由 Kit 转发到业务作用域
class_name AudioPlaybackEvent

const PHASE_STARTED : int = 0
const PHASE_ENDED : int = 1
const PHASE_DROPPED : int = 2

var phase : int = PHASE_STARTED
var cue_id : StringName = &""
var voice_id : int = 0
var emitter_id : int = 0
## 丢弃原因：cue_missing / throttled / instance_limit / voice_limit / low_priority / no_stream
var reason : StringName = &""


static func started(_cue_id : StringName, _voice_id : int, _emitter_id : int) -> AudioPlaybackEvent:
	var e := AudioPlaybackEvent.new()
	e.phase = PHASE_STARTED
	e.cue_id = _cue_id
	e.voice_id = _voice_id
	e.emitter_id = _emitter_id
	return e


static func ended(_cue_id : StringName, _voice_id : int, _emitter_id : int) -> AudioPlaybackEvent:
	var e := AudioPlaybackEvent.new()
	e.phase = PHASE_ENDED
	e.cue_id = _cue_id
	e.voice_id = _voice_id
	e.emitter_id = _emitter_id
	return e


static func dropped(_cue_id : StringName, _reason : StringName, _emitter_id : int = 0) -> AudioPlaybackEvent:
	var e := AudioPlaybackEvent.new()
	e.phase = PHASE_DROPPED
	e.cue_id = _cue_id
	e.reason = _reason
	e.emitter_id = _emitter_id
	return e


func is_started() -> bool:
	return phase == PHASE_STARTED


func is_ended() -> bool:
	return phase == PHASE_ENDED


func is_dropped() -> bool:
	return phase == PHASE_DROPPED
