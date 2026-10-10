extends Model
class_name VersionedTestModel
## 测试夹具：带版本迁移与默认值的可存档 Model

var hp : int = 100
var level : int = 1

func get_data() -> Dictionary:
	return {"hp": hp, "level": level}

func set_data(data : Dictionary) -> void:
	hp = data.get("hp", hp)
	level = data.get("level", level)

func get_version() -> int:
	return 2

func migrate(data : Dictionary, from_version : int) -> Dictionary:
	if from_version == 1:
		data["level"] = data.get("exp", 1)
		data.erase("exp")
	return data

func get_defaults() -> Dictionary:
	return {"hp": 100, "level": 1}