extends Resource
## 用于存储简单数据，对于需要保存的数据，可以通过@export导出，用ResourceSaver来写入到文件
class_name Model

var _architecture : Architecture

func get_script_name() -> StringName:
	return (get_script() as GDScript).get_global_name()

func get_architecture() -> Architecture:
	return _architecture

# 生命周期：由所属 Architecture 调用
func _on_init() -> void:
	pass

func _on_deinit() -> void:
	pass

# 同层访问器：经由所属 Architecture 路由
func get_utility(utility_name : StringName) -> Utility:
	return _architecture.get_utility(utility_name)

# 事件：委托给所属 Architecture
func register_event(event_name : StringName, callback: Callable) -> void:
	_architecture.register_event(event_name, callback)

func unregister_event(event_name : StringName, callback: Callable) -> void:
	_architecture.unregister_event(event_name, callback)

func send_event(event : Event) -> void:
	_architecture.send_event(event)
