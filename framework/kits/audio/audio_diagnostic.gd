extends RefCounted
## 音频诊断快照：纯数据，供测试、编辑器面板与运行期 profiler 使用
## 与 DialogueDiagnostic 同风格：定位 / 计数字段 + to_dict()
class_name AudioDiagnostic

var active_voices : int = 0
var max_voices : int = 0
var dropped_total : int = 0
var started_total : int = 0
var ended_total : int = 0
var registered_cues : int = 0
var loaded_banks : Array[StringName] = []
var emitters : int = 0
var states : Dictionary = {}
var switches : Dictionary = {}
var rtpcs : Dictionary = {}
var bus_volumes : Dictionary = {}
var music_state : StringName = &""


func to_dict() -> Dictionary:
	var banks : Array[String] = []
	for bank_id : StringName in loaded_banks:
		banks.append(String(bank_id))
	return {
		"active_voices": active_voices,
		"max_voices": max_voices,
		"dropped_total": dropped_total,
		"started_total": started_total,
		"ended_total": ended_total,
		"registered_cues": registered_cues,
		"loaded_banks": banks,
		"emitters": emitters,
		"states": states.duplicate(true),
		"switches": switches.duplicate(true),
		"rtpcs": rtpcs.duplicate(true),
		"bus_volumes": bus_volumes.duplicate(true),
		"music_state": String(music_state),
	}


func _to_string() -> String:
	return "AudioDiagnostic(%s)" % JSON.stringify(to_dict())
