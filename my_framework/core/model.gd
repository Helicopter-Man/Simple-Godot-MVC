extends Resource
## 用于存储简单数据，对于需要保存的数据，可以通过@export导出，用ResourceSaver来写入到文件
class_name Model

func get_script_name()->StringName:
	return (get_script() as GDScript).get_global_name()

func get_utility(utility_name : StringName)->Object:
	return Framework.get_utility(utility_name)
