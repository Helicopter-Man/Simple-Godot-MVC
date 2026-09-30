extends RefCounted
# NOTE 服务中间件：纯静态服务注册表，用于平行 Architecture 之间的解耦通信
# Architecture 通过 ServiceConfig 声明对外接口，初始化时自动注册到此处
# 其他 Architecture 的 System/Model 通过 get_service() 查询，不直接依赖提供方
class_name ServiceMiddleware

static var _services : Dictionary = {}

# NOTE 注册服务：若服务名已存在则 push_warning 提示覆盖
static func register_service(name : StringName, service : Variant) -> void:
	if _services.has(name):
		push_warning("ServiceMiddleware|注册|服务 %s 已存在，覆盖旧值" % name)
	_services[name] = service

# NOTE 查询服务：不存在时返回 null
static func get_service(name : StringName) -> Variant:
	return _services.get(name)

static func has_service(name : StringName) -> bool:
	return _services.has(name)

static func unregister_service(name : StringName) -> void:
	_services.erase(name)

# NOTE 清空所有服务（测试/重置用）
static func clear() -> void:
	_services.clear()
