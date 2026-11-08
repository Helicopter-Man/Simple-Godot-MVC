extends System
## Voice 运行时：播放器池、位置跟随、淡变、优先级抢占、结束回收
## silent=true 时不调用 play()，用逻辑时长推进，供 headless 测试与无声设备使用
class_name AudioVoiceSystem

var max_voices : int = 32
var silent : bool = false
var paused : bool = false
var default_bus : StringName = &"Master"

var _pool_root : Node = null
var _pool : Dictionary = {}       # spatial(int) -> Array[Node]
var _voices : Dictionary = {}     # voice_id -> 运行记录
var _emitters : Dictionary = {}   # emitter_id -> AudioEmitter
var _next_voice_id : int = 0
var _next_emitter_id : int = 0


func _model() -> AudioStateModel:
	return get_model(&"AudioStateModel") as AudioStateModel


func _selector() -> AudioSelector:
	return get_utility(&"AudioSelector") as AudioSelector


func _on_init() -> void:
	_pool_root = Node.new()
	_pool_root.name = "AudioVoicePool"
	var arch := get_architecture()
	if arch != null:
		arch.add_child(_pool_root)


func _on_deinit() -> void:
	shutdown()


# ==================== 生命周期：tick ====================
func on_process(delta : float) -> void:
	tick(delta)


## 也可由测试手动推进；clock_msec 无论有无 voice 都会前进
func tick(delta : float) -> void:
	var m := _model()
	if m != null:
		m.clock_msec += maxf(delta, 0.0) * 1000.0
	if _voices.is_empty():
		return
	var finished : Array[int] = []
	for voice_id : int in _voices.keys():
		var rec : Dictionary = _voices[voice_id]
		rec["elapsed"] = float(rec["elapsed"]) + delta
		var elapsed : float = float(rec["elapsed"])
		var p : Node = rec["player"] as Node
		var current : float = float(rec["current_db"])

		if bool(rec["stopping"]):
			rec["stop_elapsed"] = float(rec["stop_elapsed"]) + delta
			var sf : float = maxf(float(rec["stop_fade"]), 0.0001)
			var t : float = clampf(float(rec["stop_elapsed"]) / sf, 0.0, 1.0)
			current = lerpf(float(rec["stop_start_db"]), -80.0, t)
			if t >= 1.0:
				finished.append(voice_id)
		else:
			var fade_in : float = float(rec["fade_in"])
			if fade_in > 0.0 and elapsed < fade_in:
				current = lerpf(float(rec["base_db"]) - 60.0, float(rec["target_db"]),
					clampf(elapsed / fade_in, 0.0, 1.0))
			else:
				current = move_toward(current, float(rec["target_db"]), 60.0 * delta)
		rec["current_db"] = current
		if p != null and is_instance_valid(p):
			p.set("volume_db", current)

		# 3D / 2D 位置跟随：由 Kit 的 tick 驱动，业务无需逐帧上报
		if int(rec["spatial"]) != AudioCue.SpatialMode.NON_POSITIONAL:
			var emitter : AudioEmitter = _emitters.get(int(rec["emitter_id"])) as AudioEmitter
			if emitter != null and is_instance_valid(emitter):
				var pos : Variant = emitter.get_world_position()
				if pos != null and p != null and is_instance_valid(p):
					p.set("global_position", pos)

		if not bool(rec["stopping"]):
			if not silent:
				if p == null or not is_instance_valid(p) or not bool(p.get("playing")):
					finished.append(voice_id)
			else:
				var duration : float = float(rec["duration"])
				if duration > 0.0 and elapsed >= duration:
					finished.append(voice_id)
	for id : int in finished:
		_finish(id, true)


# ==================== 播放 ====================
## 返回 voice_id；0 表示创建失败
func spawn(cue : AudioCue, stream : AudioStream, emitter_id : int, params : Dictionary) -> int:
	if cue == null or stream == null:
		return 0
	var m := _model()
	if m == null:
		return 0
	var p : Node = _acquire_player(cue.spatial)
	if p == null or not is_instance_valid(p):
		return 0

	var bus : StringName = StringName(params.get("bus", cue.bus))
	if bus == &"" or AudioServer.get_bus_index(String(bus)) < 0:
		bus = default_bus
	var base_db : float = float(params.get("volume_db", cue.volume_db))
	if cue.volume_jitter_db > 0.0:
		base_db += randf_range(-cue.volume_jitter_db, cue.volume_jitter_db)
	var pitch : float = float(params.get("pitch", cue.pitch))
	if cue.pitch_jitter > 0.0:
		pitch += randf_range(-cue.pitch_jitter, cue.pitch_jitter)

	p.set("stream", stream)
	p.set("bus", String(bus))
	p.set("pitch_scale", maxf(pitch, 0.01))
	var fade_in : float = maxf(cue.fade_in, 0.0)
	var start_db : float = base_db - 60.0 if fade_in > 0.0 else base_db
	p.set("volume_db", start_db)

	if cue.spatial != AudioCue.SpatialMode.NON_POSITIONAL:
		if cue.max_distance > 0.0:
			p.set("max_distance", cue.max_distance)
		if cue.spatial == AudioCue.SpatialMode.POSITIONAL_2D and cue.attenuation > 0.0:
			p.set("attenuation", cue.attenuation)
		elif cue.spatial == AudioCue.SpatialMode.POSITIONAL_3D and cue.unit_size > 0.0:
			p.set("unit_size", cue.unit_size)
		var emitter : AudioEmitter = _emitters.get(emitter_id) as AudioEmitter
		if emitter != null and is_instance_valid(emitter):
			var pos : Variant = emitter.get_world_position()
			if pos != null:
				p.set("global_position", pos)
	if not silent:
		p.call("play")
		if paused:
			p.set("stream_paused", true)

	_next_voice_id += 1
	var id : int = _next_voice_id
	_voices[id] = {
		"player": p,
		"cue_id": cue.cue_id,
		"emitter_id": emitter_id,
		"priority": cue.priority,
		"start_clock": m.clock_msec,
		"duration": cue.get_duration(stream),
		"elapsed": 0.0,
		"base_db": base_db,
		"target_db": base_db,
		"current_db": start_db,
		"fade_in": fade_in,
		"spatial": cue.spatial,
		"stopping": false,
		"stop_fade": 0.0,
		"stop_elapsed": 0.0,
		"stop_start_db": start_db,
	}
	m.voice_cue[id] = cue.cue_id
	return id


## fade < 0 时用 cue.fade_out；fade <= 0 立即结束
func stop_voice(voice_id : int, fade : float = -1.0) -> Error:
	if not _voices.has(voice_id):
		return ERR_DOES_NOT_EXIST
	var rec : Dictionary = _voices[voice_id]
	if bool(rec["stopping"]):
		return OK
	if fade < 0.0:
		var m := _model()
		var cue : Variant = null
		if m != null:
			cue = m.cues.get(rec["cue_id"])
		fade = float(cue.fade_out) if cue != null else 0.0
	if fade <= 0.0:
		_finish(voice_id, true)
		return OK
	rec["stopping"] = true
	rec["stop_fade"] = fade
	rec["stop_elapsed"] = 0.0
	rec["stop_start_db"] = float(rec["current_db"])
	return OK


func stop_cue(cue_id : StringName, fade : float = -1.0) -> int:
	var total : int = 0
	for voice_id : int in _voices.keys().duplicate():
		if StringName(_voices[voice_id]["cue_id"]) == cue_id:
			if stop_voice(voice_id, fade) == OK:
				total += 1
	return total


func stop_all(fade : float = -1.0) -> int:
	var total : int = _voices.size()
	for voice_id : int in _voices.keys().duplicate():
		stop_voice(voice_id, fade)
	return total


func stop_bank_voices(bank_id : StringName, fade : float = -1.0) -> int:
	var m := _model()
	if m == null:
		return 0
	var total : int = 0
	for voice_id : int in _voices.keys().duplicate():
		var cue_id : StringName = StringName(_voices[voice_id]["cue_id"])
		if StringName(m.cue_bank.get(cue_id, &"")) == bank_id:
			if stop_voice(voice_id, fade) == OK:
				total += 1
	return total


func stop_emitter_voices(emitter_id : int, fade : float = -1.0) -> int:
	var total : int = 0
	for voice_id : int in _voices.keys().duplicate():
		if int(_voices[voice_id]["emitter_id"]) == emitter_id:
			if stop_voice(voice_id, fade) == OK:
				total += 1
	return total


# ==================== 查询 / 控制 ====================
func get_active_count() -> int:
	return _voices.size()


## 全局暂停 / 恢复：对齐 Wwise Suspend / Resume；暂停期间 voice 不释放
func set_paused(on : bool) -> void:
	paused = on
	for voice_id : int in _voices:
		var p : Node = _voices[voice_id]["player"] as Node
		if p != null and is_instance_valid(p):
			p.set("stream_paused", on)


func get_active_count_for_cue(cue_id : StringName) -> int:
	var m := _model()
	if m == null:
		return 0
	return m.get_active_cue_count(cue_id)


func is_voice_active(voice_id : int) -> bool:
	return _voices.has(voice_id)


func find_victim(incoming_priority : int) -> int:
	var selector := _selector()
	if selector == null:
		return 0
	return selector.find_victim(_voices, incoming_priority)


func set_voice_volume_db(voice_id : int, db : float) -> Error:
	if not _voices.has(voice_id):
		return ERR_DOES_NOT_EXIST
	var rec : Dictionary = _voices[voice_id]
	rec["base_db"] = db
	rec["target_db"] = db
	return OK


func set_voice_pitch(voice_id : int, value : float) -> Error:
	if not _voices.has(voice_id):
		return ERR_DOES_NOT_EXIST
	var p : Node = _voices[voice_id]["player"] as Node
	if p == null or not is_instance_valid(p):
		return ERR_UNAVAILABLE
	p.set("pitch_scale", clampf(value, 0.01, 4.0))
	return OK


## RTPC 变更时把新值刷到活跃 voice（BUS_VOLUME 由 MixMusicSystem 处理）
func apply_rtpc(binding : AudioRtpcBinding, value : float) -> void:
	if binding == null or _voices.is_empty():
		return
	var out : float = binding.evaluate(value)
	for voice_id : int in _voices:
		var rec : Dictionary = _voices[voice_id]
		if binding.target_name != &"" and StringName(rec["cue_id"]) != binding.target_name:
			continue
		if binding.target == AudioRtpcBinding.Target.VOICE_VOLUME:
			rec["target_db"] = float(rec["base_db"]) + out
		elif binding.target == AudioRtpcBinding.Target.VOICE_PITCH:
			var p : Node = rec["player"] as Node
			if p != null and is_instance_valid(p):
				p.set("pitch_scale", clampf(out, 0.01, 4.0))


# ==================== Emitter 桥 ====================
func attach_emitter(emitter : AudioEmitter) -> int:
	if emitter == null or not is_instance_valid(emitter):
		return 0
	if emitter.is_bound():
		return emitter.get_emitter_id()
	_next_emitter_id += 1
	_emitters[_next_emitter_id] = emitter
	emitter._bind_kit(get_architecture(), _next_emitter_id)
	return _next_emitter_id


func detach_emitter(emitter : AudioEmitter) -> Error:
	if emitter == null:
		return ERR_INVALID_PARAMETER
	var id : int = emitter.get_emitter_id()
	if not _emitters.has(id):
		return ERR_DOES_NOT_EXIST
	_emitters.erase(id)
	emitter._unbind()
	stop_emitter_voices(id, 0.0)
	return OK


func get_emitter_count() -> int:
	return _emitters.size()


# ==================== 内部 ====================
func _finish(voice_id : int, notify : bool) -> void:
	if not _voices.has(voice_id):
		return
	var rec : Dictionary = _voices[voice_id]
	var p : Node = rec["player"] as Node
	if p != null and is_instance_valid(p):
		p.call("stop")
	_release_player(int(rec["spatial"]), p)
	_voices.erase(voice_id)
	var m := _model()
	if m != null:
		m.voice_cue.erase(voice_id)
		m.ended_total += 1
	if notify:
		send_event(AudioPlaybackEvent.ended(
			StringName(rec["cue_id"]), voice_id, int(rec["emitter_id"])))


func _create_player(spatial : int) -> Node:
	var p : Node
	match spatial:
		AudioCue.SpatialMode.POSITIONAL_2D:
			p = AudioStreamPlayer2D.new()
		AudioCue.SpatialMode.POSITIONAL_3D:
			p = AudioStreamPlayer3D.new()
		_:
			p = AudioStreamPlayer.new()
	if _pool_root != null and is_instance_valid(_pool_root):
		_pool_root.add_child(p)
	return p


func _acquire_player(spatial : int) -> Node:
	var key : int = int(spatial)
	var list : Array = _pool.get(key, [])
	var p : Node = null
	if not list.is_empty():
		p = list.pop_back() as Node
	if p == null or not is_instance_valid(p):
		p = _create_player(spatial)
	_pool[key] = list
	return p


func _release_player(spatial : int, p : Node) -> void:
	if p == null or not is_instance_valid(p):
		return
	p.call("stop")
	var key : int = int(spatial)
	var list : Array = _pool.get(key, [])
	list.append(p)
	_pool[key] = list


func shutdown() -> void:
	paused = false
	for voice_id : int in _voices.keys().duplicate():
		_finish(voice_id, false)
	for key : int in _pool.keys():
		for item : Variant in _pool[key]:
			if item is Node and is_instance_valid(item):
				(item as Node).free()
	_pool.clear()
	for emitter : Variant in _emitters.values():
		if emitter is AudioEmitter and is_instance_valid(emitter):
			(emitter as AudioEmitter)._unbind()
	_emitters.clear()
	if _pool_root != null and is_instance_valid(_pool_root):
		_pool_root.free()
		_pool_root = null
