extends Node
# NOTE 作为全局单例挂在场景中

var _model_dic : Dictionary[StringName,Model] = {}
var _utility_dic : Dictionary[StringName,Object] = {}
var _system_dic : Dictionary[StringName,System] = {}

func register_model(model : Model) -> void:
	var model_name = model.get_script_name()
	if _model_dic.has(model_name):
		push_error("Framework|Model注册|%s已经注册，请勿重复注册" % model_name)
		return
	_model_dic[model_name] = model

func register_utility(utility : Object) -> void:
	if !utility.has_method("get_script_name"):
		push_error("Framework|Utility注册|注册对象缺少方法：get_script_name")
		return
	var utility_name = utility.get_script_name()
	if _utility_dic.has(utility_name):
		push_error("Framework|Utility注册|%s已经注册，请勿重复注册" % utility_name)
		return
	_utility_dic[utility_name] = utility

func register_system(system : System) -> void:
	var system_name = system.get_script_name()
	if _system_dic.has(system_name):
		push_error("Framework|System注册|%s已经注册，请勿重复注册" % system_name)
		return
	_system_dic[system_name] = system
	

func unregister_model(model_name : StringName) -> void:
	_model_dic.erase(model_name)

func unregister_utility(utility_name : StringName) -> void:
	_utility_dic.erase(utility_name)

func unregister_system(system_name : StringName) -> void:
	_model_dic.erase(system_name)

func get_model(model_name : StringName) -> Model:
	return _model_dic.get(model_name)

func get_utility(utility_name : StringName) -> Object:
	return _utility_dic.get(utility_name)

func get_system(system_name : StringName) -> System:
	return _system_dic.get(system_name)


func _process(delta: float) -> void:
	for system : System in _system_dic.values():
		system.on_process(delta)

func _physics_process(delta: float) -> void:
	for system : System in _system_dic.values():
		system.on_physics_process(delta)
