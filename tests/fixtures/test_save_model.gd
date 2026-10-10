extends Model
class_name TestSaveModel
## 测试夹具：可存档 Model（未实现 get_version，存档版本按默认 1）

var hp : int = 100
var level : int = 1

func get_data() -> Dictionary:
	return {"hp": hp, "level": level}

func set_data(data : Dictionary) -> void:
	hp = data.get("hp", hp)
	level = data.get("level", level)