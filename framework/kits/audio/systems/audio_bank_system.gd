extends System
## 资源组（Bank）：注册、引用计数加载 / 卸载、Cue 查询
## 卸载时先停掉该 Bank 的活跃 voice，再注销 Cue，避免悬挂引用
class_name AudioBankSystem


func _model() -> AudioStateModel:
	return get_model(&"AudioStateModel") as AudioStateModel


## 登记 Bank 定义（不激活 Cue）；重名、Cue 无效、Cue 跨 Bank 重名均拒绝
func register_bank(bank : AudioBankDef) -> Error:
	if bank == null:
		push_error("AudioBankSystem|注册|Bank 实例为 null")
		return ERR_INVALID_PARAMETER
	if not bank.is_valid():
		push_error("AudioBankSystem|注册|bank_id 为空")
		return ERR_INVALID_PARAMETER
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	if m.bank_defs.has(bank.bank_id):
		push_error("AudioBankSystem|注册|%s 已注册，拒绝覆盖" % bank.bank_id)
		return ERR_ALREADY_EXISTS
	var seen : Dictionary = {}
	for cue : AudioCue in bank.cues:
		if cue == null or not cue.is_valid():
			push_error("AudioBankSystem|注册|%s 含无效 Cue" % bank.bank_id)
			return ERR_INVALID_DATA
		if seen.has(cue.cue_id) or _cue_exists(m, cue.cue_id):
			push_error("AudioBankSystem|注册|Cue %s 重复" % cue.cue_id)
			return ERR_ALREADY_EXISTS
		seen[cue.cue_id] = true
	m.bank_defs[bank.bank_id] = bank
	m.bank_refs[bank.bank_id] = 0
	return OK


## 引用计数加载：首次加载时把 Cue 写入可用表，后续只递增计数
func load_bank(bank_id : StringName) -> Error:
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	if not m.bank_defs.has(bank_id):
		return ERR_DOES_NOT_EXIST
	var refs : int = int(m.bank_refs.get(bank_id, 0))
	if refs == 0:
		for cue : AudioCue in m.bank_defs[bank_id].cues:
			m.cues[cue.cue_id] = cue
			m.cue_bank[cue.cue_id] = bank_id
	m.bank_refs[bank_id] = refs + 1
	send_event(AudioStateEvent.changed(
		AudioStateEvent.KIND_BANK_LOADED, bank_id, refs + 1, refs))
	return OK


## 引用计数卸载；force=true 无视计数一次清空
func unload_bank(bank_id : StringName, force : bool = false) -> Error:
	var m := _model()
	if m == null:
		return ERR_UNAVAILABLE
	if not m.bank_defs.has(bank_id):
		return ERR_DOES_NOT_EXIST
	var refs : int = int(m.bank_refs.get(bank_id, 0))
	if refs <= 0:
		return ERR_DOES_NOT_EXIST
	if force:
		refs = 1
	refs -= 1
	m.bank_refs[bank_id] = refs
	if refs == 0:
		# NOTE 顺序要紧：stop_bank_voices 依赖 cue_bank 做归属判定，必须先停再注销
		var voice : Variant = get_system(&"AudioVoiceSystem")
		if voice != null:
			voice.stop_bank_voices(bank_id, 0.0)
		for cue : AudioCue in m.bank_defs[bank_id].cues:
			m.cues.erase(cue.cue_id)
			m.cue_bank.erase(cue.cue_id)
			m.last_post_clock.erase(cue.cue_id)
			m.seq_index.erase(cue.cue_id)
	send_event(AudioStateEvent.changed(
		AudioStateEvent.KIND_BANK_UNLOADED, bank_id, refs, refs + 1))
	return OK


func get_cue(cue_id : StringName) -> AudioCue:
	var m := _model()
	if m == null:
		return null
	return m.cues.get(cue_id)


func get_registered_banks() -> Array[StringName]:
	var m := _model()
	var out : Array[StringName] = []
	if m == null:
		return out
	for bank_id : StringName in m.bank_defs:
		out.append(bank_id)
	return out


func get_bank_refcount(bank_id : StringName) -> int:
	var m := _model()
	if m == null:
		return 0
	return int(m.bank_refs.get(bank_id, 0))


func is_loaded(bank_id : StringName) -> bool:
	return get_bank_refcount(bank_id) > 0


func _cue_exists(m : AudioStateModel, cue_id : StringName) -> bool:
	if m.cues.has(cue_id):
		return true
	for def : AudioBankDef in m.bank_defs.values():
		for cue : AudioCue in def.cues:
			if cue != null and cue.cue_id == cue_id:
				return true
	return false
