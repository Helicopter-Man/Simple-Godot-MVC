@abstract
extends Node
# NOTE 作用域 IOC 容器：替代原先全局 Framework 自动加载
# 游戏应继承本类，在 _init_architecture() 中注册自身的 Model/System/Utility
class_name Architecture

var _model_dic : Dictionary[StringName,Model] = {}
var _system_dic : Dictionary[StringName,System] = {}
var _utility_dic : Dictionary[StringName,Utility] = {}

# NOTE 按需 tick：只有定义了 on_process / on_physics_process 的 System 才会被加入
var _updatable_systems : Array[System] = []
var _physics_updatable_systems : Array[System] = []

# NOTE 内置事件总线（吸收原 EventKit），事件为架构作用域内
var _event_callback : Dictionary[StringName,Array] = {}
var _event_mutex = Mutex.new()

var _initialized : bool = false
# NOTE 幂等键：独立于 _initialized——若节点从未 _ready 但已注册组件，
# 复用 _initialized 会提前 return 导致 _on_deinit 丢失
var _deinited : bool = false

# NOTE 服务配置：声明本 Architecture 对外暴露的接口，赋值后在 _ready 时自动注册到总线
@export var service_config : ServiceConfig
# NOTE 共享总线：多个 Architecture 赋同一个 ServiceRegistry 实例（.tres）即可互相查询
# 留空则本节点自建私有实例，不与其他 Architecture 互通
@export var shared_registry : ServiceRegistry

var _registry : ServiceRegistry
# NOTE 区分自有 / 共享：仅自有实例才在 deinit 时整体 clear，避免误清别人的注册
var _owns_registry : bool = false
# NOTE 跟踪本 Architecture 成功注册的服务名，用于 deinit 时按名注销
var _registered_services : Array[StringName] = []


# 生命周期：子类重写以注册自身的 Model/System/Utility
func _init_architecture() -> void:
	pass

func _ready() -> void:
	_setup_registry()
	_init_architecture()
	# 初始化已注册的 System / Model
	for system : System in _system_dic.values():
		system._on_init()
	for model : Model in _model_dic.values():
		model._on_init()
	_initialized = true
	_register_services()
	_sync_tick_flags()

func _exit_tree() -> void:
	# NOTE 主动反初始化，避免悬挂服务与回调
	deinit()


# ---- 服务总线 ----
func _setup_registry() -> void:
	if shared_registry != null:
		_registry = shared_registry
		_owns_registry = false
	else:
		_registry = ServiceRegistry.new()
		_owns_registry = true

# NOTE 读取本作用域总线；_ready 之前返回 null。跨 Architecture 查询请用 get_service()
func get_registry() -> ServiceRegistry:
	return _registry

# NOTE 查询本作用域服务；不存在返回 null
func get_service(service_name : StringName) -> Variant:
	if _registry == null:
		return null
	return _registry.get_service(service_name)


func _register_services() -> void:
	if service_config == null:
		return
	# 暴露 Architecture 自身
	if service_config.self_name != &"":
		_expose(service_config.self_name, self)
	# 暴露 Model
	for model_name : StringName in service_config.models:
		var model : Model = get_model(model_name)
		if model == null:
			push_warning("Architecture|服务声明|Model %s 未注册，跳过" % model_name)
			continue
		_expose(model_name, model)
	# 暴露 System
	for system_name : StringName in service_config.systems:
		var system : System = get_system(system_name)
		if system == null:
			push_warning("Architecture|服务声明|System %s 未注册，跳过" % system_name)
			continue
		_expose(system_name, system)
	# 暴露 Utility
	for utility_name : StringName in service_config.utilities:
		var utility : Utility = get_utility(utility_name)
		if utility == null:
			push_warning("Architecture|服务声明|Utility %s 未注册，跳过" % utility_name)
			continue
		_expose(utility_name, utility)

# NOTE 写入总线：只把自己成功注册的名字记入 _registered_services，
# 共享总线上属于其他 Architecture 的服务不归本节点注销
func _expose(service_name : StringName, service : Variant) -> void:
	var result : Error = _registry.register(service_name, service)
	if result == OK:
		_registered_services.append(service_name)
	else:
		push_warning("Architecture|服务声明|服务 %s 注册失败，错误码 %d" % [service_name, result])

func _unregister_services() -> void:
	if _registry == null:
		return
	for service_name : StringName in _registered_services:
		_registry.unregister(service_name)
	_registered_services.clear()
	# NOTE 自有总线随本节点生命周期结束，整体清空；共享总线只注销自己的名字
	if _owns_registry:
		_registry.clear()


# ---- 注册 / 注销 / 获取 ----
# NOTE 注册键规则：优先使用显式名；未显式传入时回退到脚本的 class_name（global_name）；
# 两者皆空则 fail-fast，避免静默落到 &"" 造成碰撞
func _resolve_key(script_name : StringName, explicit_name : StringName, action : String) -> StringName:
	if explicit_name != &"":
		return explicit_name
	if script_name == &"":
		push_error("Architecture|%s|脚本缺少 class_name，无法生成注册键；请显式传入名称" % action)
		return &""
	return script_name

func register_model(model : Model, model_name : StringName = &"") -> Error:
	if _deinited:
		push_error("Architecture|Model注册|已 deinit，拒绝注册")
		return ERR_UNAVAILABLE
	if model == null:
		push_error("Architecture|Model注册|实例为 null")
		return ERR_INVALID_PARAMETER
	var key : StringName = _resolve_key(model.get_script_name(), model_name, "Model注册")
	if key == &"":
		return ERR_INVALID_PARAMETER
	if _model_dic.has(key):
		push_error("Architecture|Model注册|%s已经注册，请勿重复注册" % key)
		return ERR_ALREADY_EXISTS
	model._architecture = self
	_model_dic[key] = model
	if _initialized:
		model._on_init()
	return OK

func register_system(system : System, system_name : StringName = &"") -> Error:
	if _deinited:
		push_error("Architecture|System注册|已 deinit，拒绝注册")
		return ERR_UNAVAILABLE
	if system == null:
		push_error("Architecture|System注册|实例为 null")
		return ERR_INVALID_PARAMETER
	var key : StringName = _resolve_key(system.get_script_name(), system_name, "System注册")
	if key == &"":
		return ERR_INVALID_PARAMETER
	if _system_dic.has(key):
		push_error("Architecture|System注册|%s已经注册，请勿重复注册" % key)
		return ERR_ALREADY_EXISTS
	system._architecture = self
	_system_dic[key] = system
	# NOTE opt-in：仅当 System 定义了对应方法时才纳入逐帧轮询
	if system.has_method("on_process"):
		_updatable_systems.append(system)
	if system.has_method("on_physics_process"):
		_physics_updatable_systems.append(system)
	if _initialized:
		system._on_init()
	_sync_tick_flags()
	return OK

func register_utility(utility : Utility, utility_name : StringName = &"") -> Error:
	if _deinited:
		push_error("Architecture|Utility注册|已 deinit，拒绝注册")
		return ERR_UNAVAILABLE
	if utility == null:
		push_error("Architecture|Utility注册|实例为 null")
		return ERR_INVALID_PARAMETER
	var key : StringName = _resolve_key(utility.get_script_name(), utility_name, "Utility注册")
	if key == &"":
		return ERR_INVALID_PARAMETER
	if _utility_dic.has(key):
		push_error("Architecture|Utility注册|%s已经注册，请勿重复注册" % key)
		return ERR_ALREADY_EXISTS
	utility._architecture = self
	_utility_dic[key] = utility
	return OK


func unregister_model(model_name : StringName) -> Error:
	if not _model_dic.has(model_name):
		return ERR_DOES_NOT_EXIST
	_model_dic.erase(model_name)
	return OK

func unregister_system(system_name : StringName) -> Error:
	var system : System = _system_dic.get(system_name)
	if system == null:
		return ERR_DOES_NOT_EXIST
	_updatable_systems.erase(system)
	_physics_updatable_systems.erase(system)
	_system_dic.erase(system_name)
	_sync_tick_flags()
	return OK

func unregister_utility(utility_name : StringName) -> Error:
	if not _utility_dic.has(utility_name):
		return ERR_DOES_NOT_EXIST
	_utility_dic.erase(utility_name)
	return OK


func get_model(model_name : StringName) -> Model:
	return _model_dic.get(model_name)

func get_system(system_name : StringName) -> System:
	return _system_dic.get(system_name)

func get_utility(utility_name : StringName) -> Utility:
	return _utility_dic.get(utility_name)

func has_model(model_name : StringName) -> bool:
	return _model_dic.has(model_name)

func has_system(system_name : StringName) -> bool:
	return _system_dic.has(system_name)

func has_utility(utility_name : StringName) -> bool:
	return _utility_dic.has(utility_name)


# ---- 按需逐帧更新（只 tick opt-in 的 System）----
# NOTE 没有需要轮询的 System 时关闭 _process / _physics_process，避免空转
func _sync_tick_flags() -> void:
	set_process(not _updatable_systems.is_empty())
	set_physics_process(not _physics_updatable_systems.is_empty())

func _process(delta: float) -> void:
	for system : System in _updatable_systems:
		system.on_process(delta)

func _physics_process(delta: float) -> void:
	for system : System in _physics_updatable_systems:
		system.on_physics_process(delta)


# ---- 事件总线 ----
func register_event(event_name: StringName, callback: Callable) -> Error:
	if event_name == &"":
		push_error("Architecture|事件注册|事件名不能为空")
		return ERR_INVALID_PARAMETER
	if not callback.is_valid():
		push_error("Architecture|事件注册|%s 的回调无效" % event_name)
		return ERR_INVALID_PARAMETER
	# NOTE 持锁期间不做日志与返回，先把结果存起来，unlock 后再处理
	var result : Error = OK
	_event_mutex.lock()
	if !_event_callback.has(event_name):
		_event_callback[event_name] = []
	if _event_callback[event_name].has(callback):
		result = ERR_ALREADY_EXISTS
	else:
		_event_callback[event_name].append(callback)
	_event_mutex.unlock()
	if result != OK:
		push_error("Architecture|事件注册|%s回调已存在，请勿重复注册" % event_name)
	return result

func unregister_event(event_name: StringName, callback: Callable) -> Error:
	# NOTE 未注册过属可探测的预期结果，只用返回码表达，不写日志
	var result : Error = OK
	_event_mutex.lock()
	if not _event_callback.has(event_name):
		result = ERR_DOES_NOT_EXIST
	else:
		_event_callback[event_name].erase(callback)
		if _event_callback[event_name].is_empty():
			_event_callback.erase(event_name)
	_event_mutex.unlock()
	return result

# NOTE 返回实际执行的回调数量，便于断言事件确实被消费
func send_event(event: Event) -> int:
	var event_type: StringName = event.get_script_name()
	if event_type == &"":
		push_error("Architecture|事件派发|Event 脚本缺少 class_name，无法确定事件类型")
		return 0

	_event_mutex.lock()
	var callbacks = _event_callback.get(event_type, []).duplicate()  # 复制一份避免修改
	_event_mutex.unlock()

	# 先过滤有效回调
	var valid_callbacks: Array[Callable] = []
	for callback in callbacks:
		if callback.is_valid():
			valid_callbacks.append(callback)

	# 更新存储的列表
	_event_mutex.lock()
	_event_callback[event_type] = valid_callbacks
	_event_mutex.unlock()

	# 执行所有有效回调
	var executed : int = 0
	for callback in valid_callbacks:
		if callback.is_valid():  # 再次检查，确保安全
			callback.call(event)
			executed += 1
	return executed


# ---- 反初始化 ----
# NOTE 幂等：可被 _exit_tree 自动调用，也可被业务手动调用
func deinit() -> void:
	if _deinited:
		return
	_deinited = true
	_unregister_services()
	for system : System in _system_dic.values():
		system._on_deinit()
	for model : Model in _model_dic.values():
		model._on_deinit()
	_system_dic.clear()
	_model_dic.clear()
	_utility_dic.clear()
	_updatable_systems.clear()
	_physics_updatable_systems.clear()
	_event_callback.clear()
	_initialized = false