extends Resource
## RTPC（实时参数控制）绑定：把归一化参数 0..1 映射到目标属性
## 对齐 Wwise Game Parameter + RTPC 曲线；原生后端映射到总线音量 / voice 音量 / voice 音高
class_name AudioRtpcBinding

enum Target { BUS_VOLUME, VOICE_VOLUME, VOICE_PITCH }

@export var parameter : StringName = &""
@export_enum("BUS_VOLUME", "VOICE_VOLUME", "VOICE_PITCH") var target : int = Target.BUS_VOLUME
## BUS_VOLUME 时为目标总线名；VOICE_* 时为目标 cue_id，空表示全部活跃 voice
@export var target_name : StringName = &""
## 可选曲线；为空时线性映射
@export var curve : Curve
## 输出区间：BUS_VOLUME / VOICE_VOLUME 为 dB，VOICE_PITCH 为倍率
@export var value_range : Vector2 = Vector2(-24.0, 0.0)


func is_valid() -> bool:
	return parameter != &""


func evaluate(value : float) -> float:
	var t : float = clampf(value, 0.0, 1.0)
	if curve != null:
		t = clampf(curve.sample(t), 0.0, 1.0)
	return lerpf(value_range.x, value_range.y, t)
