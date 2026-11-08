extends Model
## AudioKit 的数据层：资源组 / Cue / 状态 / 参数 / voice 索引 / 统计
## 纯数据，不持有节点、不发事件；所有变更由 System 驱动
class_name AudioStateModel

var bank_defs : Dictionary[StringName, AudioBankDef] = {}
var bank_refs : Dictionary[StringName, int] = {}
var cues : Dictionary[StringName, AudioCue] = {}
var cue_bank : Dictionary[StringName, StringName] = {}

var states : Dictionary[StringName, StringName] = {}
var switches : Dictionary[StringName, StringName] = {}
var rtpcs : Dictionary[StringName, float] = {}
var bindings : Array[AudioRtpcBinding] = []
var music_states : Dictionary[StringName, StringName] = {}
var music_state : StringName = &""

## voice_id -> cue_id（voice 实体本身由 AudioVoiceSystem 持有）
var voice_cue : Dictionary[int, StringName] = {}
var last_post_clock : Dictionary[StringName, float] = {}
var seq_index : Dictionary[StringName, int] = {}
## 总线 -> 线性音量目标（0..1），由 AudioMixMusicSystem 插值逼近
var bus_targets : Dictionary[StringName, float] = {}

## 逻辑时钟（毫秒）：由 AudioVoiceSystem.tick 推进，测试可确定性断言 min_interval
var clock_msec : float = 0.0
var dropped_total : int = 0
var started_total : int = 0
var ended_total : int = 0


func get_rtpc(name : StringName) -> float:
	return rtpcs.get(name, 0.0)


func get_state(group : StringName) -> StringName:
	return states.get(group, &"")


func get_switch(group : StringName) -> StringName:
	return switches.get(group, &"")


func get_loaded_banks() -> Array[StringName]:
	var out : Array[StringName] = []
	for bank_id : StringName in bank_refs:
		if int(bank_refs[bank_id]) > 0:
			out.append(bank_id)
	return out


func get_cue_ids() -> Array[StringName]:
	var out : Array[StringName] = []
	for cue_id : StringName in cues:
		out.append(cue_id)
	return out


func get_active_cue_count(cue_id : StringName) -> int:
	var total : int = 0
	for active_cue : StringName in voice_cue.values():
		if active_cue == cue_id:
			total += 1
	return total


func reset() -> void:
	bank_defs.clear()
	bank_refs.clear()
	cues.clear()
	cue_bank.clear()
	states.clear()
	switches.clear()
	rtpcs.clear()
	bindings.clear()
	music_states.clear()
	music_state = &""
	voice_cue.clear()
	last_post_clock.clear()
	seq_index.clear()
	bus_targets.clear()
	clock_msec = 0.0
	dropped_total = 0
	started_total = 0
	ended_total = 0
