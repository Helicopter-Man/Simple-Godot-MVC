extends Model
class_name LifecycleTestModel
## 测试夹具：用于验证 _on_init 生命周期钩子被框架调用

var was_initialized : bool = false
var value : int = 0

func _on_init() -> void:
	was_initialized = true

func get_data() -> Dictionary:
	return {"value": value}

func set_data(data : Dictionary) -> void:
	value = data.get("value", value)