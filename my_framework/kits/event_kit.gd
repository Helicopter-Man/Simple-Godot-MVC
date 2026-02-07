extends RefCounted
class_name EventKit

static var _event_callback : Dictionary[StringName, Array] = {}
static var _mutex = Mutex.new()

static func register_event(event_name: StringName, callback: Callable) -> void:
	_mutex.lock()
	if !_event_callback.has(event_name):
		_event_callback[event_name] = []
	
	# 避免重复注册
	if not _event_callback[event_name].has(callback):
		_event_callback[event_name].append(callback)
	else:
		push_error("EventKit|注册事件|事件已存在，请勿重复注册")
	_mutex.unlock()

static func unregister_event(event_name: StringName, callback: Callable) -> void:
	_mutex.lock()
	if _event_callback.has(event_name):
		_event_callback[event_name].erase(callback)
		if _event_callback[event_name].is_empty():
			_event_callback.erase(event_name)
	else:
		push_error("EventKit|注销事件|事件不存在")
	_mutex.unlock()

static func send_event(event: Event) -> void:
	var event_type: StringName = event.get_script_name()
	
	_mutex.lock()
	var callbacks = _event_callback.get(event_type, []).duplicate()  # 复制一份避免修改
	_mutex.unlock()
	
	# 先过滤有效回调
	var valid_callbacks: Array[Callable] = []
	for callback in callbacks:
		if callback.is_valid():
			valid_callbacks.append(callback)
	
	# 更新存储的列表
	_mutex.lock()
	_event_callback[event_type] = valid_callbacks
	_mutex.unlock()
	
	# 执行所有有效回调
	for callback in valid_callbacks:
		if callback.is_valid():  # 再次检查，确保安全
			callback.call(event)
