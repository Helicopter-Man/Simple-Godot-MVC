extends Resource
## 资源组（Bank）：把一组 Cue 当作可加载 / 卸载的单元
## Godot 原生实现不生成二进制 SoundBank：加载 = 注册 Cue + 引用计数，
## 卸载 = 注销 Cue + 停掉仍在播放的 voice。语义与 Wwise LoadBank 对齐。
class_name AudioBankDef

@export var bank_id : StringName = &""
@export var cues : Array[AudioCue] = []
## Kit 完成初始化后自动 load_bank()
@export var auto_load : bool = false


func is_valid() -> bool:
	return bank_id != &""


## 返回不合法的 cue 名；空数组表示全部可用
func invalid_cue_ids() -> Array[StringName]:
	var out : Array[StringName] = []
	for cue : AudioCue in cues:
		if cue == null or not cue.is_valid():
			out.append(&"<null_or_invalid>")
	return out
