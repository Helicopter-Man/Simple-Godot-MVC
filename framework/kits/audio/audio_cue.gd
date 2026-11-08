extends Resource
## 音频事件（Cue）：业务只与 cue_id 打交道，不接触任何 AudioStreamPlayer
## 对齐 Wwise Event / Random-Sequence Container：一个 cue 可携带多个变体流
class_name AudioCue

enum ContainerMode { SINGLE, RANDOM, SEQUENCE, SHUFFLE }
enum SpatialMode { NON_POSITIONAL, POSITIONAL_2D, POSITIONAL_3D }

## 事件名；为空时由 AudioBankDef 在注册阶段拒绝
@export var cue_id : StringName = &""
## 变体流；SINGLE 取第 0 个
@export var streams : Array[AudioStream] = []
## RANDOM 模式权重，与 streams 一一对应；长度不足按 1.0 处理
@export var weights : Array[float] = []
@export_enum("SINGLE", "RANDOM", "SEQUENCE", "SHUFFLE") var container : int = ContainerMode.SINGLE
@export_enum("NON_POSITIONAL", "POSITIONAL_2D", "POSITIONAL_3D") var spatial : int = SpatialMode.NON_POSITIONAL
@export var bus : StringName = &"Master"
## 0..100；voice 上限裁剪与抢占时越大越重要
@export_range(0, 100, 1) var priority : int = 50
## 同一 cue 的最大同时实例数；0 = 不限
@export_range(0, 64, 1) var max_instances : int = 0
## 同一 cue 两次触发的最小间隔（秒）；0 = 不限
@export var min_interval : float = 0.0
@export var volume_db : float = 0.0
@export var volume_jitter_db : float = 0.0
@export var pitch : float = 1.0
@export var pitch_jitter : float = 0.0
@export var fade_in : float = 0.0
@export var fade_out : float = 0.0
## 2D/3D 最大距离；<= 0 时用引擎默认
@export var max_distance : float = 0.0
## 2D 衰减系数（POSITIONAL_2D）；<= 0 时用引擎默认
@export var attenuation : float = 0.0
## 3D 单位尺寸（POSITIONAL_3D）；<= 0 时用引擎默认
@export var unit_size : float = 0.0
## 静音模式下的逻辑时长；<= 0 时用 stream.get_length()
@export var duration_hint : float = 0.0
## 可选 Switch 组：非空时，仅当该组当前值等于 switch_value 才允许触发
@export var switch_group : StringName = &""
@export var switch_value : StringName = &""


func is_valid() -> bool:
	return cue_id != &"" and not streams.is_empty()


func get_stream_count() -> int:
	return streams.size()


## 逻辑时长：静音模式与诊断用；未知长度返回 0（表示不自动结束）
func get_duration(stream : AudioStream) -> float:
	if duration_hint > 0.0:
		return duration_hint
	if stream != null:
		var length : float = stream.get_length()
		if length > 0.0:
			return length
	return 0.0
