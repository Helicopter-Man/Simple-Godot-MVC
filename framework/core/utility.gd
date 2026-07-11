extends RefCounted
## 工具层基类：提供基础设施能力（存储、网络、序列化等）
## 由 Architecture 通过 register_utility 注册，经 get_utility 获取
class_name Utility

var _architecture : Architecture

func get_script_name() -> StringName:
	return (get_script() as GDScript).get_global_name()

func get_architecture() -> Architecture:
	return _architecture
