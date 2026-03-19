@abstract
extends RefCounted
class_name System

func get_script_name() -> StringName:
	return (get_script() as GDScript).get_global_name()

func get_model(model_name : StringName) -> Model:
	return Framework.get_model(model_name)

func get_utility(utility_name : StringName) -> Object:
	return Framework.get_utility(utility_name)

@abstract
func on_process(delta : float) -> void

@abstract
func on_physics_process(delta : float) -> void
