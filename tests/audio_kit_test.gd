extends RefCounted
## AudioKit 测试套件（headless / silent 模式）
## 约定：static func run(root: Node) -> Dictionary

const Probe := preload("res://tests/fixtures/audio_test_probe.gd")
const TestAudioArch := preload("res://tests/fixtures/test_audio_arch.gd")


static func run(root : Node) -> Dictionary:
	var cases : Array = []
	_run_bank(cases, root)
	_run_post(cases, root)
	_run_voice_budget(cases, root)
	_run_state_and_mix(cases, root)
	_run_music(cases, root)
	_run_emitter(cases, root)
	_run_listener_and_pause(cases, root)
	_run_selector(cases)
	_run_lifecycle(cases, root)
	AudioServer.set_bus_volume_db(0, 0.0)
	var failed : int = 0
	for c in cases:
		if not c["ok"]:
			failed += 1
	return {"suite": "AudioKit", "total": cases.size(), "failed": failed, "cases": cases}


# ==================== Bank ====================
static func _run_bank(cases : Array, root : Node) -> void:
	var k := _make(root)
	var cue := _cue(&"Cue_Bank", 1, 10.0)
	var bank := _bank(&"Bank_A", [cue])

	_check(cases, "register_bank(null) 返回 ERR_INVALID_PARAMETER", k.register_bank(null) == ERR_INVALID_PARAMETER)
	var empty := AudioBankDef.new()
	_check(cases, "register_bank 空 id 返回 ERR_INVALID_PARAMETER", k.register_bank(empty) == ERR_INVALID_PARAMETER)
	_check(cases, "register_bank 有效返回 OK", k.register_bank(bank) == OK)
	_check(cases, "重复注册返回 ERR_ALREADY_EXISTS", k.register_bank(bank) == ERR_ALREADY_EXISTS)
	_check(cases, "Cue 跨 Bank 重名被拒绝", k.register_bank(_bank(&"Bank_B", [cue])) == ERR_ALREADY_EXISTS)
	_check(cases, "load_bank 未注册返回 ERR_DOES_NOT_EXIST", k.load_bank(&"Bank_Missing") == ERR_DOES_NOT_EXIST)
	_check(cases, "load_bank 返回 OK", k.load_bank(&"Bank_A") == OK)
	_check(cases, "is_bank_loaded 为真", k.is_bank_loaded(&"Bank_A"))
	_check(cases, "首次加载引用计数为 1", k.get_bank_refcount(&"Bank_A") == 1)
	_check(cases, "二次加载返回 OK", k.load_bank(&"Bank_A") == OK)
	_check(cases, "二次加载引用计数为 2", k.get_bank_refcount(&"Bank_A") == 2)
	_check(cases, "加载后 Cue 可用", k.has_cue(&"Cue_Bank"))
	_check(cases, "unload_bank 返回 OK", k.unload_bank(&"Bank_A") == OK)
	_check(cases, "卸载一次后仍为已加载", k.is_bank_loaded(&"Bank_A"))
	_check(cases, "引用计数降为 1", k.get_bank_refcount(&"Bank_A") == 1)
	_check(cases, "再次卸载返回 OK", k.unload_bank(&"Bank_A") == OK)
	_check(cases, "计数归零后 Cue 不可用", not k.has_cue(&"Cue_Bank"))
	_check(cases, "未加载时卸载返回 ERR_DOES_NOT_EXIST", k.unload_bank(&"Bank_A") == ERR_DOES_NOT_EXIST)
	_check(cases, "force 卸载一次清空", _force_unload(k))
	_dispose(root, k)


static func _force_unload(k : AudioKit) -> bool:
	k.load_bank(&"Bank_A")
	k.load_bank(&"Bank_A")
	return k.unload_bank(&"Bank_A", true) == OK and k.get_bank_refcount(&"Bank_A") == 0


# ==================== post / 句柄 / 容器 ====================
static func _run_post(cases : Array, root : Node) -> void:
	var k := _make(root)
	var probe = Probe.new()
	probe.bind(k)
	var single := _cue(&"Cue_Single", 1, 0.1)
	var throttled := _cue(&"Cue_Throttle", 1, 10.0)
	throttled.min_interval = 1.0
	var switched := _cue(&"Cue_Switch", 1, 10.0)
	switched.switch_group = &"Material"
	switched.switch_value = &"Metal"
	var seq := _cue(&"Cue_Seq", 3, 10.0)
	seq.container = AudioCue.ContainerMode.SEQUENCE
	k.register_bank(_bank(&"Bank_Post", [single, throttled, switched, seq]))
	k.load_bank(&"Bank_Post")

	_check(cases, "post 未加载的 Cue 返回 ERR_DOES_NOT_EXIST", k.try_post(&"Cue_Missing") == ERR_DOES_NOT_EXIST)
	_check(cases, "丢弃事件被派发", probe.dropped == 1)
	_check(cases, "丢弃原因为 cue_missing", probe.last_reason == &"cue_missing")
	_check(cases, "空 cue_id 返回 ERR_INVALID_PARAMETER", k.try_post(&"") == ERR_INVALID_PARAMETER)

	_check(cases, "try_post 成功返回 OK", k.try_post(&"Cue_Single") == OK)
	var h := k.get_last_handle()
	_check(cases, "post 返回有效句柄", h != null and h.is_playing())
	_check(cases, "started 事件被派发", probe.started == 1)
	_check(cases, "set_volume_db 返回 OK", h.set_volume_db(-6.0) == OK)
	_check(cases, "set_pitch 返回 OK", h.set_pitch(1.2) == OK)
	_check(cases, "stop_voice 返回 OK", k.stop_voice(h.voice_id, 0.0) == OK)
	_check(cases, "stop 后句柄不再播放", not h.is_playing())
	_check(cases, "ended 事件被派发", probe.ended == 1)
	_check(cases, "重复 stop 返回 ERR_DOES_NOT_EXIST", k.stop_voice(h.voice_id, 0.0) == ERR_DOES_NOT_EXIST)

	# 静音模式：逻辑时长到点自动结束
	k.try_post(&"Cue_Single")
	k.tick(0.2)
	_check(cases, "silent 模式按逻辑时长自动回收", k.get_active_voice_count() == 0)
	_check(cases, "自动回收派发 ended 事件", probe.ended == 2)

	# 节流（min_interval）
	_check(cases, "首次触发不被节流", k.try_post(&"Cue_Throttle") == OK)
	_check(cases, "间隔内触发返回 ERR_BUSY", k.try_post(&"Cue_Throttle") == ERR_BUSY)
	_check(cases, "节流丢弃原因为 throttled", probe.last_reason == &"throttled")
	k.tick(1.1)
	_check(cases, "时钟推进后可再次触发", k.try_post(&"Cue_Throttle") == OK)

	# Switch 门控
	_check(cases, "Switch 不匹配返回 ERR_BUSY", k.try_post(&"Cue_Switch") == ERR_BUSY)
	_check(cases, "Switch 不匹配原因为 switch_mismatch", probe.last_reason == &"switch_mismatch")
	_check(cases, "set_switch 返回 OK", k.set_switch(&"Material", &"Metal") == OK)
	_check(cases, "Switch 匹配后可触发", k.try_post(&"Cue_Switch") == OK)

	# 序列容器：三次 post 依次取不同流
	k.try_post(&"Cue_Seq")
	k.try_post(&"Cue_Seq")
	k.try_post(&"Cue_Seq")
	var m := k.get_model(&"AudioStateModel") as AudioStateModel
	_check(cases, "SEQUENCE 容器推进序号", int(m.seq_index.get(&"Cue_Seq", 0)) == 3)
	_check(cases, "stop_all 停掉全部活跃 voice", k.stop_all(0.0) >= 3)
	_check(cases, "stop_all 后活跃数为 0", k.get_active_voice_count() == 0)
	_dispose(root, k)


# ==================== voice 预算 / 抢占 ====================
static func _run_voice_budget(cases : Array, root : Node) -> void:
	var k := _make(root, 2)
	var probe = Probe.new()
	probe.bind(k)
	var low := _cue(&"Cue_Low", 1, 10.0)
	low.priority = 10
	var high := _cue(&"Cue_High", 1, 10.0)
	high.priority = 90
	var limited := _cue(&"Cue_Limited", 1, 10.0)
	limited.max_instances = 1
	k.register_bank(_bank(&"Bank_Voice", [low, high, limited]))
	k.load_bank(&"Bank_Voice")

	_check(cases, "低优先级第一次触发 OK", k.try_post(&"Cue_Low") == OK)
	_check(cases, "低优先级第二次触发 OK", k.try_post(&"Cue_Low") == OK)
	_check(cases, "达到 voice 上限且同级不可抢占", k.try_post(&"Cue_Low") == ERR_BUSY)
	_check(cases, "丢弃原因为 low_priority", probe.last_reason == &"low_priority")
	_check(cases, "高优先级可抢占最弱 voice", k.try_post(&"Cue_High") == OK)
	_check(cases, "抢占后活跃数仍等于上限", k.get_active_voice_count() == 2)
	_check(cases, "抢占触发 ended 事件", probe.ended == 1)

	k.stop_all(0.0)
	_check(cases, "max_instances 首次触发 OK", k.try_post(&"Cue_Limited") == OK)
	_check(cases, "max_instances 超限返回 ERR_BUSY", k.try_post(&"Cue_Limited") == ERR_BUSY)
	_check(cases, "超限原因为 instance_limit", probe.last_reason == &"instance_limit")
	_check(cases, "stop_cue 返回停止数量", k.stop_cue(&"Cue_Limited", 0.0) == 1)
	_dispose(root, k)


# ==================== State / RTPC / 混音 ====================
static func _run_state_and_mix(cases : Array, root : Node) -> void:
	var k := _make(root)
	var probe = Probe.new()
	probe.bind(k)
	var cue := _cue(&"Cue_Rtpc", 1, 10.0)
	k.register_bank(_bank(&"Bank_Rtpc", [cue]))
	k.load_bank(&"Bank_Rtpc")

	_check(cases, "set_state 返回 OK", k.set_state(&"Music", &"Combat") == OK)
	_check(cases, "get_state 读回状态", k.get_state(&"Music") == &"Combat")
	_check(cases, "空组名返回 ERR_INVALID_PARAMETER", k.set_state(&"", &"X") == ERR_INVALID_PARAMETER)
	_check(cases, "set_switch / get_switch 一致", k.set_switch(&"S", &"V") == OK and k.get_switch(&"S") == &"V")
	_check(cases, "状态事件已派发", probe.state_events >= 2)

	_check(cases, "set_rtpc 返回 OK", k.set_rtpc(&"Intensity", 0.5) == OK)
	_check(cases, "get_rtpc 读回参数", is_equal_approx(k.get_rtpc(&"Intensity"), 0.5))
	_check(cases, "RTPC 值被钳制到 0..1", k.set_rtpc(&"Intensity", 5.0) == OK and is_equal_approx(k.get_rtpc(&"Intensity"), 1.0))

	var binding := AudioRtpcBinding.new()
	binding.parameter = &"Intensity"
	binding.target = AudioRtpcBinding.Target.BUS_VOLUME
	binding.target_name = &"Master"
	binding.value_range = Vector2(0.0, 1.0)
	_check(cases, "bind_rtpc 返回 OK", k.bind_rtpc(binding) == OK)
	_check(cases, "bind_rtpc(null) 返回 ERR_INVALID_PARAMETER", k.bind_rtpc(null) == ERR_INVALID_PARAMETER)
	k.set_rtpc(&"Intensity", 0.25)
	_check(cases, "RTPC 曲线映射到总线目标", is_equal_approx(k.get_bus_volume(&"Master"), 0.25))

	_check(cases, "apply_snapshot 返回 OK", k.apply_snapshot({&"Master": 0.8}, 0.1) == OK)
	_check(cases, "快照写入总线目标", is_equal_approx(k.get_bus_volume(&"Master"), 0.8))
	_check(cases, "不存在的总线返回 ERR_DOES_NOT_EXIST", k.set_bus_volume(&"NoSuchBus", 0.5) == ERR_DOES_NOT_EXIST)
	_check(cases, "duck 返回 OK", k.duck(&"Master", 0.5, 0.2) == OK)
	_check(cases, "duck 压低总线目标", is_equal_approx(k.get_bus_volume(&"Master"), 0.4))
	k.tick(0.3)
	_check(cases, "duck 到期自动恢复", is_equal_approx(k.get_bus_volume(&"Master"), 0.8))

	# 卸载 Bank 时停掉该 Bank 的 voice
	k.try_post(&"Cue_Rtpc")
	_check(cases, "卸载前存在活跃 voice", k.get_active_voice_count() == 1)
	_check(cases, "unload_bank 返回 OK", k.unload_bank(&"Bank_Rtpc") == OK)
	_check(cases, "卸载后活跃 voice 被停掉", k.get_active_voice_count() == 0)
	_dispose(root, k)


# ==================== 交互音乐 ====================
static func _run_music(cases : Array, root : Node) -> void:
	var k := _make(root)
	var music := _cue(&"Music_Combat", 2, 10.0)
	k.register_bank(_bank(&"Bank_Music", [music]))
	k.load_bank(&"Bank_Music")

	_check(cases, "register_music_state 返回 OK", k.register_music_state(&"Combat", &"Music_Combat") == OK)
	_check(cases, "重复注册音乐状态被拒绝", k.register_music_state(&"Combat", &"Music_Combat") == ERR_ALREADY_EXISTS)
	_check(cases, "空状态名返回 ERR_INVALID_PARAMETER", k.register_music_state(&"", &"Music_Combat") == ERR_INVALID_PARAMETER)
	_check(cases, "未注册状态返回 ERR_DOES_NOT_EXIST", k.set_music_state(&"Boss") == ERR_DOES_NOT_EXIST)
	_check(cases, "set_music_state 返回 OK", k.set_music_state(&"Combat") == OK)
	_check(cases, "get_music_state 读回状态", k.get_music_state() == &"Combat")
	_check(cases, "get_music_cue_id 指向音乐 Cue", k.get_music_cue_id() == &"Music_Combat")
	var mix := k.get_system(&"AudioMixMusicSystem") as AudioMixMusicSystem
	_check(cases, "两个 stream 形成两个分层", mix.get_music_layer_count() == 2)
	_check(cases, "set_music_layer 返回 OK", k.set_music_layer(0, 0.3) == OK)
	_check(cases, "越界层返回 ERR_DOES_NOT_EXIST", k.set_music_layer(9, 0.5) == ERR_DOES_NOT_EXIST)
	_check(cases, "stop_music 返回 OK", k.stop_music() == OK)
	_check(cases, "stop_music 后当前 Cue 清空", k.get_music_cue_id() == &"")
	_check(cases, "play_music 不存在的 Cue 返回 ERR_DOES_NOT_EXIST", k.play_music(&"Nope") == ERR_DOES_NOT_EXIST)
	_dispose(root, k)


# ==================== Emitter 桥 ====================
static func _run_emitter(cases : Array, root : Node) -> void:
	var k := _make(root)
	var cue := _cue(&"Cue_3D", 1, 10.0)
	cue.spatial = AudioCue.SpatialMode.POSITIONAL_3D
	k.register_bank(_bank(&"Bank_3D", [cue]))
	k.load_bank(&"Bank_3D")

	var e := AudioEmitter.new()
	root.add_child(e)
	var id : int = k.attach_emitter(e)
	_check(cases, "attach_emitter 分配 id", id > 0)
	_check(cases, "get_emitter_count 为 1", k.get_emitter_count() == 1)
	_check(cases, "重复 attach 返回同一 id", k.attach_emitter(e) == id)
	_check(cases, "3D Cue 可带 emitter 触发", k.post(&"Cue_3D", e) != null)
	_check(cases, "3D voice 已创建", k.get_active_voice_count() == 1)

	root.remove_child(e)
	_check(cases, "emitter 离树自动解绑", not e.is_bound())
	_check(cases, "解绑后计数归零", k.get_emitter_count() == 0)
	_check(cases, "解绑时停掉该 emitter 的 voice", k.get_active_voice_count() == 0)
	_check(cases, "detach 未绑定返回 ERR_DOES_NOT_EXIST", k.detach_emitter(e) == ERR_DOES_NOT_EXIST)
	e.free()
	_dispose(root, k)


# ==================== 监听者 / 暂停 / 空间参数 ====================
static func _run_listener_and_pause(cases : Array, root : Node) -> void:
	var k := _make(root)
	var cue2d := _cue(&"Cue_2D_Att", 1, 10.0)
	cue2d.spatial = AudioCue.SpatialMode.POSITIONAL_2D
	cue2d.attenuation = 2.0
	cue2d.max_distance = 500.0
	var cue3d := _cue(&"Cue_3D_Att", 1, 10.0)
	cue3d.spatial = AudioCue.SpatialMode.POSITIONAL_3D
	cue3d.unit_size = 4.0
	k.register_bank(_bank(&"Bank_Pause", [cue2d, cue3d]))
	k.load_bank(&"Bank_Pause")

	var audio_listener := AudioListener3D.new()
	root.add_child(audio_listener)
	_check(cases, "set_listener(AudioListener3D) 返回 OK", k.set_listener(audio_listener) == OK)
	_check(cases, "get_listener 读回节点", k.get_listener() == audio_listener)
	var plain := Node.new()
	root.add_child(plain)
	_check(cases, "普通 Node 作为监听者被拒绝", k.set_listener(plain) == ERR_INVALID_PARAMETER)
	_check(cases, "set_listener(null) 返回 ERR_INVALID_PARAMETER", k.set_listener(null) == ERR_INVALID_PARAMETER)
	_check(cases, "clear_listener 返回 OK", k.clear_listener() == OK)
	_check(cases, "重复 clear 返回 ERR_DOES_NOT_EXIST", k.clear_listener() == ERR_DOES_NOT_EXIST)

	_check(cases, "set_paused(true) 返回 OK", k.set_paused(true) == OK)
	_check(cases, "is_paused 为真", k.is_paused())
	_check(cases, "暂停状态下仍可 post", k.post(&"Cue_2D_Att") != null)
	_check(cases, "2D 衰减参数不阻断播放", k.get_active_voice_count() == 1)
	_check(cases, "3D unit_size 参数不阻断播放", k.post(&"Cue_3D_Att") != null)
	_check(cases, "set_paused(false) 返回 OK", k.set_paused(false) == OK)
	_check(cases, "is_paused 恢复为假", not k.is_paused())
	root.remove_child(audio_listener)
	audio_listener.free()
	root.remove_child(plain)
	plain.free()
	_dispose(root, k)


# ==================== 纯算法 ====================
static func _run_selector(cases : Array) -> void:
	var sel := AudioSelector.new()
	var cue := _cue(&"Cue_Sel", 3, 1.0)
	cue.container = AudioCue.ContainerMode.SEQUENCE
	_check(cases, "SEQUENCE 按序号取流", sel.pick_index(cue, 0) == 0 and sel.pick_index(cue, 4) == 1)
	cue.container = AudioCue.ContainerMode.RANDOM
	cue.weights = [1.0, 0.0, 0.0]
	var all_zero : bool = true
	for i in range(10):
		if sel.pick_index(cue, i) != 0:
			all_zero = false
	_check(cases, "RANDOM 尊重权重", all_zero)
	cue.container = AudioCue.ContainerMode.SHUFFLE
	var in_range : bool = true
	for i in range(10):
		var idx : int = sel.pick_index(cue, i)
		if idx < 0 or idx > 2:
			in_range = false
	_check(cases, "SHUFFLE 索引不越界", in_range)
	_check(cases, "空 Cue 返回 -1", sel.pick_index(AudioCue.new(), 0) == -1)
	_check(cases, "to_db(0) 收敛到有限值", is_finite(sel.to_db(0.0)))
	var voices : Dictionary = {
		1: {"priority": 10, "start_clock": 100.0},
		2: {"priority": 10, "start_clock": 200.0},
		3: {"priority": 80, "start_clock": 300.0},
	}
	_check(cases, "抢占选最低优先级中最老的一个", sel.find_victim(voices, 90) == 1)
	_check(cases, "同级不可抢占", sel.find_victim(voices, 10) == 0)


# ==================== 生命周期 / 事件转发 / 诊断 ====================
static func _run_lifecycle(cases : Array, root : Node) -> void:
	var k := _make(root)
	var probe = Probe.new()
	probe.bind(k)
	_check(cases, "Model 已注册", k.has_model(&"AudioStateModel"))
	_check(cases, "Utility 已注册", k.has_utility(&"AudioSelector"))
	_check(cases, "四个 System 均已注册", k.has_system(&"AudioBankSystem") and k.has_system(&"AudioVoiceSystem") and k.has_system(&"AudioEventSystem") and k.has_system(&"AudioMixMusicSystem"))

	var arch = TestAudioArch.new()
	root.add_child(arch)
	k.target_architecture = arch
	var forward_probe = Probe.new()
	forward_probe.bind(arch)
	var cue := _cue(&"Cue_Life", 1, 10.0)
	k.register_bank(_bank(&"Bank_Life", [cue]))
	k.load_bank(&"Bank_Life")
	_check(cases, "post 在本作用域派发", k.try_post(&"Cue_Life") == OK and probe.started == 1)
	_check(cases, "回调事件转发到 target_architecture", forward_probe.started == 1)

	var snap : Dictionary = k.get_snapshot()
	_check(cases, "诊断快照含活跃 voice 数", int(snap.get("active_voices", -1)) == 1)
	_check(cases, "诊断快照含已加载 Bank", (snap.get("loaded_banks", []) as Array).has("Bank_Life"))
	_check(cases, "诊断快照含 started 统计", int(snap.get("started_total", 0)) >= 1)
	var diag := k.get_diagnostics()
	_check(cases, "AudioDiagnostic.to_dict 可序列化", not diag.to_dict().is_empty())

	root.remove_child(k)
	_check(cases, "deinit 后 try_post 返回 ERR_UNAVAILABLE", k.try_post(&"Cue_Life") == ERR_UNAVAILABLE)
	_check(cases, "deinit 幂等", _safe_deinit(k))
	root.remove_child(arch)
	arch.free()
	k.free()


static func _safe_deinit(k : AudioKit) -> bool:
	k.deinit()
	k.deinit()
	return true


# ==================== 工具 ====================
static func _make(root : Node, max_voices : int = 8) -> AudioKit:
	var k := AudioKit.new()
	k.silent = true
	k.max_voices = max_voices
	k.default_bus = &"Master"
	root.add_child(k)
	return k


static func _dispose(root : Node, k : AudioKit) -> void:
	if k == null:
		return
	if k.get_parent() != null:
		root.remove_child(k)
	k.free()


static func _cue(id : StringName, count : int, duration : float) -> AudioCue:
	var c := AudioCue.new()
	c.cue_id = id
	for i in range(count):
		c.streams.append(AudioStreamWAV.new())
	c.duration_hint = duration
	return c


static func _bank(id : StringName, cues : Array) -> AudioBankDef:
	var b := AudioBankDef.new()
	b.bank_id = id
	for c in cues:
		b.cues.append(c)
	return b


static func _check(cases : Array, name : String, ok : bool, detail : String = "") -> void:
	cases.append({"name": name, "ok": ok, "detail": detail})
