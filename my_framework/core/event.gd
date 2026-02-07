extends RefCounted
class_name Event

func get_script_name() -> StringName:
	return (get_script() as GDScript).get_global_name()
