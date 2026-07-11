@abstract
extends RefCounted
class_name System

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
func get_system(system_name : StringName) -> System:
	return _architecture.get_system(system_name)

func get_model(model_name : StringName) -> Model:
	return _architecture.get_model(model_name)

func get_utility(utility_name : StringName) -> Utility:
	return _architecture.get_utility(utility_name)

# 事件：委托给所属 Architecture
func register_event(event_name : StringName, callback: Callable) -> void:
	_architecture.register_event(event_name, callback)

func unregister_event(event_name : StringName, callback: Callable) -> void:
	_architecture.unregister_event(event_name, callback)

func send_event(event : Event) -> void:
	_architecture.send_event(event)

# NOTE 逐帧更新改为 opt-in：子类按需定义 func on_process(delta) / func on_physics_process(delta)
# 定义了对应方法的 System 才会被 Architecture 纳入 _process / _physics_process 轮询
