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

# 生命周期：子类重写以注册自身的 Model/System/Utility
func _init_architecture() -> void:
	pass

func _ready() -> void:
	_init_architecture()
	# 初始化已注册的 System / Model
	for system : System in _system_dic.values():
		system._on_init()
	for model : Model in _model_dic.values():
		model._on_init()
	_initialized = true


# ---- 注册 / 注销 / 获取 ----
func register_model(model : Model) -> void:
	var model_name = model.get_script_name()
	if _model_dic.has(model_name):
		push_error("Architecture|Model注册|%s已经注册，请勿重复注册" % model_name)
		return
	model._architecture = self
	_model_dic[model_name] = model
	if _initialized:
		model._on_init()

func register_system(system : System) -> void:
	var system_name = system.get_script_name()
	if _system_dic.has(system_name):
		push_error("Architecture|System注册|%s已经注册，请勿重复注册" % system_name)
		return
	system._architecture = self
	_system_dic[system_name] = system
	# NOTE opt-in：仅当 System 定义了对应方法时才纳入逐帧轮询
	if system.has_method("on_process"):
		_updatable_systems.append(system)
	if system.has_method("on_physics_process"):
		_physics_updatable_systems.append(system)
	if _initialized:
		system._on_init()

func register_utility(utility : Utility) -> void:
	var utility_name = utility.get_script_name()
	if _utility_dic.has(utility_name):
		push_error("Architecture|Utility注册|%s已经注册，请勿重复注册" % utility_name)
		return
	utility._architecture = self
	_utility_dic[utility_name] = utility


func unregister_model(model_name : StringName) -> void:
	_model_dic.erase(model_name)

func unregister_system(system_name : StringName) -> void:
	var system : System = _system_dic.get(system_name)
	if system:
		_updatable_systems.erase(system)
		_physics_updatable_systems.erase(system)
	_system_dic.erase(system_name)

func unregister_utility(utility_name : StringName) -> void:
	_utility_dic.erase(utility_name)


func get_model(model_name : StringName) -> Model:
	return _model_dic.get(model_name)

func get_system(system_name : StringName) -> System:
	return _system_dic.get(system_name)

func get_utility(utility_name : StringName) -> Utility:
	return _utility_dic.get(utility_name)


# ---- 按需逐帧更新（只 tick opt-in 的 System）----
func _process(delta: float) -> void:
	for system : System in _updatable_systems:
		system.on_process(delta)

func _physics_process(delta: float) -> void:
	for system : System in _physics_updatable_systems:
		system.on_physics_process(delta)


# ---- 事件总线 ----
func register_event(event_name: StringName, callback: Callable) -> void:
	_event_mutex.lock()
	if !_event_callback.has(event_name):
		_event_callback[event_name] = []
	# 避免重复注册
	if not _event_callback[event_name].has(callback):
		_event_callback[event_name].append(callback)
	else:
		push_error("Architecture|事件注册|%s回调已存在，请勿重复注册" % event_name)
	_event_mutex.unlock()

func unregister_event(event_name: StringName, callback: Callable) -> void:
	_event_mutex.lock()
	if _event_callback.has(event_name):
		_event_callback[event_name].erase(callback)
		if _event_callback[event_name].is_empty():
			_event_callback.erase(event_name)
	else:
		push_error("Architecture|事件注销|事件%s不存在" % event_name)
	_event_mutex.unlock()

func send_event(event: Event) -> void:
	var event_type: StringName = event.get_script_name()

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
	for callback in valid_callbacks:
		if callback.is_valid():  # 再次检查，确保安全
			callback.call(event)


# ---- 反初始化 ----
func deinit() -> void:
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
