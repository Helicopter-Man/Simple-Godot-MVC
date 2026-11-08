extends Utility
## 纯算法层：容器取流、优先级抢占、曲线求值、音量换算
## 不持有业务状态、不碰节点，可脱离场景树独立调用与断言
class_name AudioSelector


## 返回本次应播放的 streams 索引；-1 表示没有可用流
func pick_index(cue : AudioCue, seq_index : int) -> int:
	if cue == null or cue.streams.is_empty():
		return -1
	var count : int = cue.streams.size()
	if count == 1:
		return 0
	match cue.container:
		AudioCue.ContainerMode.SINGLE:
			return 0
		AudioCue.ContainerMode.SEQUENCE:
			return seq_index % count
		AudioCue.ContainerMode.SHUFFLE:
			var idx : int = randi_range(0, count - 1)
			if idx == seq_index % count:
				idx = (idx + 1 + randi_range(0, count - 2)) % count
			return idx
		AudioCue.ContainerMode.RANDOM:
			var total : float = 0.0
			for i in range(count):
				total += _weight(cue, i)
			if total <= 0.0:
				return randi_range(0, count - 1)
			var roll : float = randf() * total
			for i in range(count):
				roll -= _weight(cue, i)
				if roll <= 0.0:
					return i
			return count - 1
	return 0


func pick_stream(cue : AudioCue, seq_index : int) -> AudioStream:
	var index : int = pick_index(cue, seq_index)
	if index < 0:
		return null
	return cue.streams[index]


## 从活跃 voice 表中挑出应被抢占者：优先级最低、同级取最老
## 入参 voices: { voice_id: {priority:int, start_clock:float, stopping:bool} }
## 返回 0 表示无可抢占对象（新事件应被丢弃）
func find_victim(voices : Dictionary, incoming_priority : int) -> int:
	var victim : int = 0
	var lowest : int = 101
	var oldest : float = INF
	for voice_id : int in voices:
		var rec : Dictionary = voices[voice_id]
		if bool(rec.get("stopping", false)):
			continue
		var p : int = int(rec.get("priority", 50))
		var started : float = float(rec.get("start_clock", 0.0))
		if p < lowest or (p == lowest and started < oldest):
			lowest = p
			oldest = started
			victim = voice_id
	# NOTE 只有严格更高的优先级才能抢占；同级丢弃新事件（Wwise 默认行为）
	if victim != 0 and lowest < incoming_priority:
		return victim
	return 0


## 线性音量 → dB；0 收敛到 -80dB 而不是 -inf
func to_db(linear : float) -> float:
	return linear_to_db(clampf(linear, 0.0001, 1.0))


func evaluate(binding : AudioRtpcBinding, value : float) -> float:
	if binding == null:
		return 0.0
	return binding.evaluate(value)


func _weight(cue : AudioCue, index : int) -> float:
	if index >= cue.weights.size():
		return 1.0
	return maxf(cue.weights[index], 0.0)
