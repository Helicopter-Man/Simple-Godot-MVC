extends Kit
## 容器型扩展：Godot 原生音频引擎
##
## 把 Wwise / FMOD 那套「Event 驱动 + 资源组 + State/Switch/RTPC + 混音快照 +
## voice 预算 + 交互音乐」的工作流落进本框架的 Model / System / Utility 分层。
## 业务只发语义事件，不接触 AudioStreamPlayer；无 Autoload、无第三方依赖。
##
## 场景树中与业务 Architecture 平级，赋同一个 shared_registry，
## service_config.self_name = &"AudioKit" 即可被业务侧查到。
class_name AudioKit

# ==================== 可配置 ====================
## 回调事件转发目标：事件总线按 Architecture 隔离，业务作用域需显式指定
@export var target_architecture : Architecture
@export_range(1, 256, 1) var max_voices : int = 32
## 静音模式：不调用 play()，用逻辑时长推进；headless 测试与无声设备可确定性断言
@export var silent : bool = false
@export var default_bus : StringName = &"Master"
## 声明式配置：资源组 / RTPC 绑定 / 音乐状态（也可在 _init_audio_kit() 里代码注册）
@export var banks : Array[AudioBankDef] = []
@export var rtpc_bindings : Array[AudioRtpcBinding] = []
@export var music_states : Dictionary = {}
## 监听者：AudioListener2D / AudioListener3D / 当前 Camera；留空则用引擎默认
@export var listener : Node

var _forwarding : bool = false
var _listener : Node = null


# ==================== 生命周期 ====================
## 子类重写：在此注册 Bank / RTPC / 音乐状态；此时各 System 已初始化完毕
func _init_audio_kit() -> void:
	pass


# NOTE 组件注册放在 _init_architecture()：Architecture._ready() 会统一调用各 System._on_init()
func _init_architecture() -> void:
	register_model(AudioStateModel.new())
	register_utility(AudioSelector.new())
	var voice_sys := AudioVoiceSystem.new()
	voice_sys.max_voices = max_voices
	voice_sys.silent = silent
	voice_sys.default_bus = default_bus
	var mix_sys := AudioMixMusicSystem.new()
	mix_sys.silent = silent
	mix_sys.default_bus = default_bus
	# NOTE 顺序：Bank → Voice → Event → MixMusic；跨 System 调用统一用 get_system() 动态查找
	register_system(AudioBankSystem.new())
	register_system(voice_sys)
	register_system(AudioEventSystem.new())
	register_system(mix_sys)


# NOTE 配置应用延后到 _ready() 末尾：此时 pool_root / music_root 均已由 _on_init 建好
func _ready() -> void:
	super._ready()
	_bootstrap()


func _bootstrap() -> void:
	register_event(&"AudioPlaybackEvent", _on_playback_event)
	register_event(&"AudioStateEvent", _on_state_event)
	for bank : AudioBankDef in banks:
		if bank != null and not is_bank_registered(bank.bank_id):
			register_bank(bank)
	for binding : AudioRtpcBinding in rtpc_bindings:
		if binding != null:
			bind_rtpc(binding)
	for state : Variant in music_states:
		register_music_state(StringName(state), StringName(music_states[state]))
	_init_audio_kit()
	for bank : AudioBankDef in banks:
		if bank != null and bank.auto_load and not is_bank_loaded(bank.bank_id):
			load_bank(bank.bank_id)
	if listener != null:
		set_listener(listener)


## 重写而非再挂 _exit_tree：先停播与拆音乐，再走 Architecture 的注销流程
func deinit() -> void:
	if _deinited:
		return
	stop_all(0.0)
	stop_music(0.0)
	super.deinit()


# ==================== 内部访问器 ====================
func _model() -> AudioStateModel:
	return get_model(&"AudioStateModel") as AudioStateModel


func _bank_sys() -> AudioBankSystem:
	return get_system(&"AudioBankSystem") as AudioBankSystem


func _voice_sys() -> AudioVoiceSystem:
	return get_system(&"AudioVoiceSystem") as AudioVoiceSystem


func _event_sys() -> AudioEventSystem:
	return get_system(&"AudioEventSystem") as AudioEventSystem


func _mix_sys() -> AudioMixMusicSystem:
	return get_system(&"AudioMixMusicSystem") as AudioMixMusicSystem


# ==================== 资源组 ====================
func register_bank(bank : AudioBankDef) -> Error:
	var sys := _bank_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.register_bank(bank)


func load_bank(bank_id : StringName) -> Error:
	var sys := _bank_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.load_bank(bank_id)


func unload_bank(bank_id : StringName, force : bool = false) -> Error:
	var sys := _bank_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.unload_bank(bank_id, force)


func is_bank_registered(bank_id : StringName) -> bool:
	var sys := _bank_sys()
	return sys != null and sys.get_registered_banks().has(bank_id)


func is_bank_loaded(bank_id : StringName) -> bool:
	var sys := _bank_sys()
	return sys != null and sys.is_loaded(bank_id)


func get_bank_refcount(bank_id : StringName) -> int:
	var sys := _bank_sys()
	return 0 if sys == null else sys.get_bank_refcount(bank_id)


func get_registered_banks() -> Array[StringName]:
	var sys := _bank_sys()
	return [] if sys == null else sys.get_registered_banks()


func has_cue(cue_id : StringName) -> bool:
	var sys := _bank_sys()
	return sys != null and sys.get_cue(cue_id) != null


# ==================== 事件 / 播放 ====================
## 可断言入口：成功 OK，句柄经 get_last_handle() 取
func try_post(cue_id : StringName, emitter_id : int = 0, params : Dictionary = {}) -> Error:
	var sys := _event_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.try_post(cue_id, emitter_id, params)


## 便捷入口：失败返回 null。emitter 可传 emitter_id(int) 或 AudioEmitter 实例（自动绑定）
func post(cue_id : StringName, emitter : Variant = null, params : Dictionary = {}) -> AudioHandle:
	var emitter_id : int = 0
	if emitter is int:
		emitter_id = int(emitter)
	elif emitter is AudioEmitter:
		var e : AudioEmitter = emitter as AudioEmitter
		emitter_id = e.get_emitter_id()
		if emitter_id == 0:
			emitter_id = attach_emitter(e)
	if try_post(cue_id, emitter_id, params) != OK:
		return null
	return get_last_handle()


func get_last_handle() -> AudioHandle:
	var sys := _event_sys()
	return null if sys == null else sys.get_last_handle()


func stop_voice(voice_id : int, fade : float = -1.0) -> Error:
	var sys := _voice_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.stop_voice(voice_id, fade)


func stop_cue(cue_id : StringName, fade : float = -1.0) -> int:
	var sys := _voice_sys()
	return 0 if sys == null else sys.stop_cue(cue_id, fade)


func stop_all(fade : float = -1.0) -> int:
	var sys := _voice_sys()
	return 0 if sys == null else sys.stop_all(fade)


func is_voice_active(voice_id : int) -> bool:
	var sys := _voice_sys()
	return sys != null and sys.is_voice_active(voice_id)


func set_voice_volume_db(voice_id : int, db : float) -> Error:
	var sys := _voice_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.set_voice_volume_db(voice_id, db)


func set_voice_pitch(voice_id : int, value : float) -> Error:
	var sys := _voice_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.set_voice_pitch(voice_id, value)


func get_active_voice_count() -> int:
	var sys := _voice_sys()
	return 0 if sys == null else sys.get_active_count()


# ==================== State / Switch / RTPC ====================
func set_state(group : StringName, value : StringName) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.set_state(group, value)


func get_state(group : StringName) -> StringName:
	var m := _model()
	return &"" if m == null else m.get_state(group)


func set_switch(group : StringName, value : StringName) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.set_switch(group, value)


func get_switch(group : StringName) -> StringName:
	var m := _model()
	return &"" if m == null else m.get_switch(group)


func set_rtpc(parameter : StringName, value : float) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.set_rtpc(parameter, value)


func get_rtpc(parameter : StringName) -> float:
	var m := _model()
	return 0.0 if m == null else m.get_rtpc(parameter)


func bind_rtpc(binding : AudioRtpcBinding) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.bind_rtpc(binding)


# ==================== 混音 ====================
func set_bus_volume(bus : StringName, linear : float, fade : float = 0.08) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.set_bus_volume(bus, linear, fade)


func get_bus_volume(bus : StringName) -> float:
	var sys := _mix_sys()
	return 0.0 if sys == null else sys.get_bus_volume(bus)


func apply_snapshot(snapshot : Dictionary, fade : float = 0.3) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.apply_snapshot(snapshot, fade)


func duck(bus : StringName, amount : float = 0.4, duration : float = 0.5) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.duck(bus, amount, duration)


# ==================== 交互音乐 ====================
func register_music_state(state : StringName, cue_id : StringName) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.register_music_state(state, cue_id)


func set_music_state(state : StringName, fade : float = 0.5) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.set_music_state(state, fade)


func get_music_state() -> StringName:
	var m := _model()
	return &"" if m == null else m.music_state


func play_music(cue_id : StringName, fade : float = 0.5) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.play_music(cue_id, fade)


func stop_music(fade : float = 0.5) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.stop_music(fade)


func set_music_layer(index : int, linear : float) -> Error:
	var sys := _mix_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.set_music_layer(index, linear)


func get_music_cue_id() -> StringName:
	var sys := _mix_sys()
	return &"" if sys == null else sys.get_music_cue_id()


# ==================== 发声体桥 ====================
func attach_emitter(emitter : AudioEmitter) -> int:
	var sys := _voice_sys()
	return 0 if sys == null else sys.attach_emitter(emitter)


func detach_emitter(emitter : AudioEmitter) -> Error:
	var sys := _voice_sys()
	if sys == null:
		return ERR_UNAVAILABLE
	return sys.detach_emitter(emitter)


func get_emitter_count() -> int:
	var sys := _voice_sys()
	return 0 if sys == null else sys.get_emitter_count()


# ==================== 监听者 / 全局暂停 ====================
## 切换监听者：AudioListener* 会立即 make_current()；Camera 由引擎自动作为监听者
func set_listener(node : Node) -> Error:
	if node == null:
		return ERR_INVALID_PARAMETER
	if node is AudioListener3D:
		if not node.is_inside_tree():
			return ERR_UNAVAILABLE
		(node as AudioListener3D).make_current()
	elif node is AudioListener2D:
		if not node.is_inside_tree():
			return ERR_UNAVAILABLE
		(node as AudioListener2D).make_current()
	elif node is Camera3D or node is Camera2D:
		pass
	else:
		return ERR_INVALID_PARAMETER
	_listener = node
	return OK


func get_listener() -> Node:
	return _listener


func clear_listener() -> Error:
	if _listener == null:
		return ERR_DOES_NOT_EXIST
	_listener = null
	return OK


## 全局暂停 / 恢复：已播放的 voice 与音乐层保持实例，仅置 stream_paused
func set_paused(on : bool) -> Error:
	var voice := _voice_sys()
	var mix := _mix_sys()
	if voice == null or mix == null:
		return ERR_UNAVAILABLE
	voice.set_paused(on)
	mix.set_paused(on)
	return OK


func is_paused() -> bool:
	var voice := _voice_sys()
	return voice != null and voice.paused


# ==================== 诊断 ====================
func get_diagnostics() -> AudioDiagnostic:
	var d := AudioDiagnostic.new()
	var m := _model()
	var voice := _voice_sys()
	var mix := _mix_sys()
	if voice != null:
		d.active_voices = voice.get_active_count()
		d.max_voices = voice.max_voices
		d.emitters = voice.get_emitter_count()
	if mix != null:
		d.music_state = get_music_state()
	if m != null:
		d.dropped_total = m.dropped_total
		d.started_total = m.started_total
		d.ended_total = m.ended_total
		d.registered_cues = m.cues.size()
		d.loaded_banks = m.get_loaded_banks()
		d.states = m.states.duplicate(true)
		d.switches = m.switches.duplicate(true)
		d.rtpcs = m.rtpcs.duplicate(true)
		for bus : StringName in m.bus_targets:
			d.bus_volumes[String(bus)] = m.bus_targets[bus]
	return d


func get_snapshot() -> Dictionary:
	return get_diagnostics().to_dict()


## 手动推进音频逻辑时钟；自动化测试用，运行期由 Architecture 的按需 tick 驱动
func tick(delta : float) -> void:
	var voice := _voice_sys()
	if voice != null:
		voice.tick(delta)
	var mix := _mix_sys()
	if mix != null:
		mix.tick(delta)


# ==================== 事件转发（事件总线按 Architecture 隔离）====================
func _on_playback_event(event : AudioPlaybackEvent) -> void:
	_forward(event)


func _on_state_event(event : AudioStateEvent) -> void:
	_forward(event)


func _forward(event : Event) -> void:
	if _forwarding:
		return
	var arch : Architecture = target_architecture
	if arch == null or not is_instance_valid(arch) or arch == self:
		return
	_forwarding = true
	arch.send_event(event)
	_forwarding = false
