extends System
## 混音 + 交互音乐：总线音量插值、Mix Snapshot、Ducking、
## 音乐状态切换（A/B 组交叉淡变）与纵向分层（多 stream 同步播放，逐层调音量）
## 纯 Godot 原生：AudioServer bus + AudioStreamPlayer，无中间件依赖
class_name AudioMixMusicSystem

var silent : bool = false
var paused : bool = false
var default_bus : StringName = &"Master"

var _root : Node = null
var _current_group : Array = []
var _outgoing_group : Array = []
var _layer_gains : Dictionary = {}      # 层索引 -> 线性音量
var _group_fade : float = 0.5
var _group_elapsed : float = 0.0
var _music_cue_id : StringName = &""
var _bus_current : Dictionary = {}      # bus -> 当前线性音量
var _bus_fade : Dictionary = {}         # bus -> 过渡时长（秒）
var _duck : Dictionary = {}             # bus -> {restore:float, until_clock:float}


func _model() -> AudioStateModel:
	return get_model(&"AudioStateModel") as AudioStateModel


func _selector() -> AudioSelector:
	return get_utility(&"AudioSelector") as AudioSelector


func _on_init() -> void:
	_root = Node.new()
	_root.name = "AudioMusicPool"
	var arch := get_architecture()
	if arch != null:
		arch.add_child(_root)


func _on_deinit() -> void:
	shutdown()


func on_process(delta : float) -> void:
	tick(delta)


func tick(delta : float) -> void:
	_tick_buses(delta)
	_tick_music(delta)


# ==================== 混音 ====================
func set_bus_volume(bus : StringName, linear : float, fade : float = 0.08) -> Error:
	if AudioServer.get_bus_index(String(bus)) < 0:
		return ERR_DOES_NOT_EXIST
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	m.bus_targets[bus] = clampf(linear, 0.0, 1.0)
	_bus_fade[bus] = maxf(fade, 0.0001)
	if not _bus_current.has(bus):
		_bus_current[bus] = db_to_linear(AudioServer.get_bus_volume_db(
			AudioServer.get_bus_index(String(bus))))
	return OK


func get_bus_volume(bus : StringName) -> float:
	var m := _model()
	if m != null and m.bus_targets.has(bus):
		return float(m.bus_targets[bus])
	var idx : int = AudioServer.get_bus_index(String(bus))
	if idx < 0:
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(idx))


## snapshot: {bus_name: linear_volume}；fade 为过渡时长
func apply_snapshot(snapshot : Dictionary, fade : float = 0.3) -> Error:
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	var applied : int = 0
	for key : Variant in snapshot:
		var bus : StringName = StringName(key)
		if set_bus_volume(bus, float(snapshot[key]), fade) == OK:
			applied += 1
	if applied == 0:
		return ERR_DOES_NOT_EXIST
	return OK


## 手动 ducking：把总线压低到 base*amount，duration 后自动恢复
func duck(bus : StringName, amount : float = 0.4, duration : float = 0.5) -> Error:
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	if AudioServer.get_bus_index(String(bus)) < 0:
		return ERR_DOES_NOT_EXIST
	var base : float = float(m.bus_targets.get(bus, _bus_current.get(bus, 1.0)))
	if not _duck.has(bus):
		_duck[bus] = {"restore": base}
	_duck[bus]["until_clock"] = m.clock_msec + maxf(duration, 0.0) * 1000.0
	m.bus_targets[bus] = clampf(base * amount, 0.0, 1.0)
	_bus_fade[bus] = 0.08
	return OK


func _tick_buses(delta : float) -> void:
	var m := _model()
	var selector := _selector()
	if m == null or selector == null:
		return
	for bus : StringName in m.bus_targets:
		var idx : int = AudioServer.get_bus_index(String(bus))
		if idx < 0:
			continue
		var current : float = float(_bus_current.get(bus, 1.0))
		var step : float = delta / maxf(float(_bus_fade.get(bus, 0.08)), 0.0001)
		current = move_toward(current, float(m.bus_targets[bus]), step)
		_bus_current[bus] = current
		AudioServer.set_bus_volume_db(idx, selector.to_db(current))
	for bus : StringName in _duck.keys().duplicate():
		if m.clock_msec >= float(_duck[bus]["until_clock"]):
			var restore : float = float(_duck[bus]["restore"])
			_duck.erase(bus)
			set_bus_volume(bus, restore)


# ==================== 状态 / RTPC 应用 ====================
func register_music_state(state : StringName, cue_id : StringName) -> Error:
	if state == &"" or cue_id == &"":
		return ERR_INVALID_PARAMETER
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	if m.music_states.has(state):
		return ERR_ALREADY_EXISTS
	m.music_states[state] = cue_id
	return OK


func set_state(group : StringName, value : StringName) -> Error:
	return _set_value(group, value, AudioStateEvent.KIND_STATE_CHANGED, true)


func set_switch(group : StringName, value : StringName) -> Error:
	return _set_value(group, value, AudioStateEvent.KIND_SWITCH_CHANGED, false)


func _set_value(group : StringName, value : StringName, kind : StringName, is_state : bool) -> Error:
	if group == &"":
		return ERR_INVALID_PARAMETER
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	var table : Dictionary = m.states if is_state else m.switches
	var old : Variant = table.get(group, &"")
	table[group] = value
	send_event(AudioStateEvent.changed(kind, group, value, old))
	return OK


## RTPC 值写入 + 把绑定刷到总线目标 / 活跃 voice
func set_rtpc(parameter : StringName, value : float) -> Error:
	if parameter == &"":
		return ERR_INVALID_PARAMETER
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	var old : float = m.get_rtpc(parameter)
	m.rtpcs[parameter] = clampf(value, 0.0, 1.0)
	for binding : AudioRtpcBinding in m.bindings:
		if binding == null or binding.parameter != parameter:
			continue
		if binding.target == AudioRtpcBinding.Target.BUS_VOLUME:
			var bus : StringName = binding.target_name if binding.target_name != &"" else default_bus
			set_bus_volume(bus, clampf(binding.evaluate(m.rtpcs[parameter]), 0.0, 1.0))
		else:
			var voice : Variant = get_system(&"AudioVoiceSystem")
			if voice != null:
				voice.apply_rtpc(binding, m.rtpcs[parameter])
	send_event(AudioStateEvent.changed(AudioStateEvent.KIND_RTPC_CHANGED, parameter, m.rtpcs[parameter], old))
	return OK


func bind_rtpc(binding : AudioRtpcBinding) -> Error:
	if binding == null or not binding.is_valid():
		return ERR_INVALID_PARAMETER
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	m.bindings.append(binding)
	set_rtpc(binding.parameter, m.get_rtpc(binding.parameter))
	return OK


# ==================== 音乐 ====================
## 播放一组分层流；已有音乐则交叉淡变到新组
func play_music(cue_id : StringName, fade : float = 0.5) -> Error:
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	var cue : AudioCue = m.cues.get(cue_id)
	if cue == null:
		return ERR_DOES_NOT_EXIST
	_free_group(_outgoing_group)
	_outgoing_group = _current_group.duplicate()
	_current_group = []
	_layer_gains.clear()
	var bus : StringName = cue.bus
	if bus == &"" or AudioServer.get_bus_index(String(bus)) < 0:
		bus = default_bus
	for i : int in range(cue.streams.size()):
		var p := AudioStreamPlayer.new()
		if _root != null and is_instance_valid(_root):
			_root.add_child(p)
		p.set("stream", cue.streams[i])
		p.set("bus", String(bus))
		p.set("volume_db", -80.0 if fade > 0.0 else cue.volume_db)
		if not silent:
			p.call("play")
			if paused:
				p.set("stream_paused", true)
		_current_group.append(p)
		_layer_gains[i] = 1.0
	_group_fade = maxf(fade, 0.0)
	_group_elapsed = 0.0
	_music_cue_id = cue_id
	return OK


func stop_music(fade : float = 0.5) -> Error:
	_free_group(_outgoing_group)
	_outgoing_group = _current_group.duplicate()
	_current_group = []
	_layer_gains.clear()
	_group_fade = maxf(fade, 0.0)
	_group_elapsed = 0.0
	_music_cue_id = &""
	return OK


func set_music_state(state : StringName, fade : float = 0.5) -> Error:
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	if not m.music_states.has(state):
		return ERR_DOES_NOT_EXIST
	var cue_id : StringName = m.music_states[state]
	var err : Error = play_music(cue_id, fade)
	if err == OK:
		var old : StringName = m.music_state
		m.music_state = state
		send_event(AudioStateEvent.changed(
			AudioStateEvent.KIND_MUSIC_STATE_CHANGED, state, cue_id, old))
	return err


## index 为分层流索引；linear 0..1
func set_music_layer(index : int, linear : float) -> Error:
	if not _layer_gains.has(index):
		return ERR_DOES_NOT_EXIST
	_layer_gains[index] = clampf(linear, 0.0, 1.0)
	return OK


## 全局暂停 / 恢复：音乐层与 voice 层由 Kit 统一驱动
func set_paused(on : bool) -> void:
	paused = on
	for item : Variant in _current_group:
		_set_stream_paused(item, on)
	for item : Variant in _outgoing_group:
		_set_stream_paused(item, on)


func _set_stream_paused(item : Variant, on : bool) -> void:
	var p : Node = item as Node
	if p != null and is_instance_valid(p):
		p.set("stream_paused", on)


func get_music_cue_id() -> StringName:
	return _music_cue_id


func get_music_layer_count() -> int:
	return _current_group.size()


func _tick_music(delta : float) -> void:
	var selector := _selector()
	if selector == null:
		return
	var fading : bool = _group_fade > 0.0 and (_group_elapsed < _group_fade or not _outgoing_group.is_empty())
	if fading:
		_group_elapsed += delta
		var t : float = clampf(_group_elapsed / maxf(_group_fade, 0.0001), 0.0, 1.0)
		for i : int in range(_current_group.size()):
			var p : Node = _current_group[i] as Node
			if p != null and is_instance_valid(p):
				p.set("volume_db", lerpf(-80.0, selector.to_db(float(_layer_gains.get(i, 1.0))), t))
		for item : Variant in _outgoing_group:
			var op : Node = item as Node
			if op != null and is_instance_valid(op):
				op.set("volume_db", lerpf(0.0, -80.0, t))
		if t >= 1.0:
			_free_group(_outgoing_group)
	else:
		for i : int in range(_current_group.size()):
			var p : Node = _current_group[i] as Node
			if p == null or not is_instance_valid(p):
				continue
			var target : float = selector.to_db(float(_layer_gains.get(i, 1.0)))
			p.set("volume_db", move_toward(float(p.get("volume_db")), target, 60.0 * delta))


func _free_group(group : Array) -> void:
	for item : Variant in group:
		var p : Node = item as Node
		if p != null and is_instance_valid(p):
			p.call("stop")
			p.free()
	group.clear()


func shutdown() -> void:
	paused = false
	_free_group(_outgoing_group)
	_free_group(_current_group)
	_layer_gains.clear()
	_bus_current.clear()
	_bus_fade.clear()
	_duck.clear()
	_music_cue_id = &""
	if _root != null and is_instance_valid(_root):
		_root.free()
		_root = null
