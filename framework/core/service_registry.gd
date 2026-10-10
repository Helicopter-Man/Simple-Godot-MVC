extends Resource
## 服务注册表：作用域化的服务容器
## 每个 Architecture 持有自己的实例；多个 Architecture 赋同一个实例（.tres）即可互相查询
## 无任何 static 成员，测试中可自由 new() 并独立起停，互不污染
class_name ServiceRegistry


var _services : Dictionary[StringName, Variant] = {}


# ---- 注册 / 注销 ----
## 注册服务；重名不覆盖，返回 ERR_ALREADY_EXISTS
func register(service_name : StringName, service : Variant) -> Error:
	if service_name == &"":
		push_error("ServiceRegistry|注册|服务名不能为空")
		return ERR_INVALID_PARAMETER
	if service == null:
		push_error("ServiceRegistry|注册|服务 %s 的实例为 null" % service_name)
		return ERR_INVALID_PARAMETER
	if _services.has(service_name):
		push_error("ServiceRegistry|注册|服务 %s 已存在，拒绝覆盖" % service_name)
		return ERR_ALREADY_EXISTS
	_services[service_name] = service
	return OK


# NOTE 未注册过属可探测的预期结果，只用返回码表达，不写日志
func unregister(service_name : StringName) -> Error:
	if not _services.has(service_name):
		return ERR_DOES_NOT_EXIST
	_services.erase(service_name)
	return OK


# ---- 查询 ----
## 查询服务；不存在返回 null
func get_service(service_name : StringName) -> Variant:
	return _services.get(service_name)


func has_service(service_name : StringName) -> bool:
	return _services.has(service_name)


func get_service_names() -> Array[StringName]:
	var names : Array[StringName] = []
	for service_name : StringName in _services:
		names.append(service_name)
	return names


func size() -> int:
	return _services.size()


# ---- 重置 / 快照 ----
func clear() -> void:
	_services.clear()


## 浅快照，供测试回滚
func snapshot() -> Dictionary:
	return _services.duplicate()


func restore(state : Dictionary) -> void:
	_services.clear()
	for service_name : StringName in state:
		_services[service_name] = state[service_name]