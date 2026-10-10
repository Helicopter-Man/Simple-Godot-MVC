@abstract
extends Control
## UI 视图基类：挂在 UiKit 挂载点下的可拔插界面
## 生命周期由 UiKit 驱动：显示时调 _ui_enter，隐藏/离树时调 _ui_exit
## 子类请重写 _ui_enter / _ui_exit，不要重写 _exit_tree（框架在此兜底清理）
class_name UiView

# ---- 池化自述：由 UI 自身声明，UiKit 在首次实例化时读取 ----
## 同一时刻是否只允许一个实例处于活动状态
@export var singular : bool = true
## 池初始大小：预实例化的空闲实例数量
@export var pool_initial : int = 0
## 池上限：关闭后保留在池中的空闲实例数量，超出立即释放；0 表示不保留
@export var pool_max : int = 1

# ---- 框架内部状态 ----
var _ui_id : StringName = &""
var _kit : UiKit = null
var _arch : Architecture = null
var _active : bool = false
var _pause_request : bool = false
var _bound_events : Array[Dictionary] = []


# ==================== 生命周期钩子（子类重写）====================
## 每次显示时调用（首次显示与池中复用都会调用）；params 为 open() 透传的参数
func _ui_enter(params : Dictionary) -> void:
	pass

## 每次隐藏/离树时调用；在此重置界面自身的可变状态（事件由框架兜底解绑）
func _ui_exit() -> void:
	pass


# ==================== 框架内部（由 UiKit 调用）====================
func _bind_kit(kit : UiKit, arch : Architecture, ui_id : StringName) -> void:
	_kit = kit
	_arch = arch
	_ui_id = ui_id

## 离树兜底：子类不要重写本方法，改用 _ui_exit
func _exit_tree() -> void:
	_on_detached()

func _on_attached(params : Dictionary) -> void:
	_active = true
	visible = true
	_ui_enter(params)

func _on_detached() -> void:
	# NOTE 幂等：池化实例会反复进出场景树，重复触发不得二次清理
	if not _active:
		return
	_active = false
	_ui_exit()
	# 框架兜底：无论如何都解绑事件、清空暂停请求，避免脏状态泄漏给下一位使用者
	_unbind_all_events()
	_clear_pause_request()

func _is_active() -> bool:
	return _active

func get_ui_id() -> StringName:
	return _ui_id


# ==================== 与数据架构的桥（MSC 的 C+V ↔ Model/System）====================
func get_arch() -> Architecture:
	return _arch

func get_system(system_name : StringName) -> System:
	if _arch == null:
		return null
	return _arch.get_system(system_name)

func get_model(model_name : StringName) -> Model:
	if _arch == null:
		return null
	return _arch.get_model(model_name)

func get_utility(utility_name : StringName) -> Utility:
	if _arch == null:
		return null
	return _arch.get_utility(utility_name)

## 绑定事件；离树时框架自动解绑，避免池化复用累积重复回调
func bind_event(event_name : StringName, callback : Callable) -> Error:
	if _arch == null:
		push_error("UiView|事件绑定|未绑定数据架构，无法注册 %s" % event_name)
		return ERR_UNAVAILABLE
	var err : Error = _arch.register_event(event_name, callback)
	if err == OK:
		_bound_events.append({"name": event_name, "callback": callback})
	return err

func unbind_event(event_name : StringName, callback : Callable) -> Error:
	if _arch == null:
		return ERR_UNAVAILABLE
	var err : Error = _arch.unregister_event(event_name, callback)
	for i in range(_bound_events.size() - 1, -1, -1):
		var rec : Dictionary = _bound_events[i]
		if rec["name"] == event_name and rec["callback"] == callback:
			_bound_events.remove_at(i)
	return err

## 发送事件；返回实际执行的回调数量
func send_event(event : Event) -> int:
	if _arch == null:
		return 0
	return _arch.send_event(event)

func _unbind_all_events() -> void:
	var records : Array[Dictionary] = _bound_events.duplicate()
	_bound_events.clear()
	if _arch == null or not is_instance_valid(_arch):
		return
	for rec in records:
		_arch.unregister_event(rec["name"], rec["callback"])


# ==================== 暂停请求（向内写入，与暂停动作解耦）====================
## 写入本 UI 的暂停请求；UiKit 汇总后可被外部暂停逻辑查询
func set_pause_request(on : bool) -> void:
	if _pause_request == on:
		return
	_pause_request = on
	if _kit != null and is_instance_valid(_kit):
		_kit.set_pause_request(self, on)

func is_pause_requested() -> bool:
	return _pause_request

# 离树时清空，避免隐藏中的 UI 永久按住暂停
func _clear_pause_request() -> void:
	if not _pause_request:
		return
	_pause_request = false
	if _kit != null and is_instance_valid(_kit):
		_kit.set_pause_request(self, false)