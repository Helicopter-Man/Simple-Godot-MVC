extends System
## 事件编排层：post 的门控、容器取流、voice 抢占与回调派发
## 业务侧只调用 try_post / post，所有播放细节由 VoiceSystem 承接
class_name AudioEventSystem

var _last_handle : AudioHandle = null


func _model() -> AudioStateModel:
	return get_model(&"AudioStateModel") as AudioStateModel


func _selector() -> AudioSelector:
	return get_utility(&"AudioSelector") as AudioSelector


## 可断言的 post；成功时句柄经 get_last_handle() 取
## ERR_BUSY：被节流 / 实例上限 / voice 上限 / Switch 不匹配 / 优先级不足
func try_post(cue_id : StringName, emitter_id : int = 0, params : Dictionary = {}) -> Error:
	_last_handle = null
	if cue_id == &"":
		push_error("AudioEventSystem|post|cue_id 不能为空")
		return ERR_INVALID_PARAMETER
	var m := _model()
	var voice : Variant = get_system(&"AudioVoiceSystem")
	var selector := _selector()
	if m == null or voice == null or selector == null:
		return ERR_UNAVAILABLE

	var cue : AudioCue = m.cues.get(cue_id)
	if cue == null:
		return _drop(m, cue_id, &"cue_missing", emitter_id, ERR_DOES_NOT_EXIST)
	if cue.switch_group != &"" and m.get_switch(cue.switch_group) != cue.switch_value:
		return _drop(m, cue_id, &"switch_mismatch", emitter_id, ERR_BUSY)
	if cue.min_interval > 0.0:
		var last : float = float(m.last_post_clock.get(cue_id, -1.0e20))
		if m.clock_msec - last < cue.min_interval * 1000.0:
			return _drop(m, cue_id, &"throttled", emitter_id, ERR_BUSY)
	if cue.max_instances > 0 and m.get_active_cue_count(cue_id) >= cue.max_instances:
		return _drop(m, cue_id, &"instance_limit", emitter_id, ERR_BUSY)

	# NOTE 全局 voice 预算：优先级不高于最弱 voice 时直接丢弃，否则抢占最弱 / 最老
	if int(voice.get_active_count()) >= int(voice.max_voices):
		var victim : int = int(voice.find_victim(cue.priority))
		if victim == 0:
			return _drop(m, cue_id, &"low_priority", emitter_id, ERR_BUSY)
		voice.stop_voice(victim, 0.0)

	var seq : int = int(m.seq_index.get(cue_id, 0))
	var index : int = selector.pick_index(cue, seq)
	if index < 0:
		return _drop(m, cue_id, &"no_stream", emitter_id, ERR_INVALID_DATA)
	var stream : AudioStream = cue.streams[index]
	# NOTE SHUFFLE 用「上次索引」去重，SEQUENCE 用递增序号
	m.seq_index[cue_id] = index + 1

	var voice_id : int = int(voice.spawn(cue, stream, emitter_id, params))
	if voice_id <= 0:
		return _drop(m, cue_id, &"spawn_failed", emitter_id, ERR_CANT_CREATE)

	m.voice_cue[voice_id] = cue_id
	m.last_post_clock[cue_id] = m.clock_msec
	m.started_total += 1
	_last_handle = AudioHandle.new(get_architecture(), voice_id, cue_id)
	send_event(AudioPlaybackEvent.started(cue_id, voice_id, emitter_id))
	return OK


func get_last_handle() -> AudioHandle:
	return _last_handle


func _drop(m : AudioStateModel, cue_id : StringName, reason : StringName, emitter_id : int, code : Error) -> Error:
	m.dropped_total += 1
	send_event(AudioPlaybackEvent.dropped(cue_id, reason, emitter_id))
	return code
