extends RefCounted
## 库型扩展模块：简洁的非分层状态机，与核心零耦合
## 规矩越死，规范越硬
class_name FSMLib

const FSM_FLAG : StringName = &"ISFSM"

# NOTE 简单状态机，不做分层


@abstract
class FSMState extends RefCounted:

	var name : StringName

	var _fsm_ref : WeakRef

	## _name : 状态名; fsm : 状态机对象
	# NOTE 使用 Object 再转换为弱引用，破除状态机与状态之间的循环引用
	func _init(_name : StringName, fsm : Object) -> void:
		# NOTE 先赋值 name，保证即使状态机非法，状态名依然可用
		name = _name
		if !is_instance_valid(fsm):
			push_error("FSMLib|状态初始化|状态机对象不可用")
			return
		if !fsm.get_meta(FSM_FLAG, false):
			push_error("FSMLib|状态初始化|传入的 fsm 对象并非状态机")
			return
		_fsm_ref = weakref(fsm)

	func _change_state(_name : StringName) -> void:
		if !is_instance_valid(_fsm_ref):
			push_error("FSMLib|状态切换|状态机引用失效")
			return
		# NOTE 不写 FSMLib 类名是防止类之间的循环依赖，代价是忽略不计的性能差异
		var fsm : Object = _fsm_ref.get_ref()
		if !is_instance_valid(fsm):
			push_error("FSMLib|状态切换|状态机对象不可用")
			return
		# NOTE _init 时确保了其一定是状态机，直接调用即可
		fsm.change_state(_name)


	@abstract
	func enter() -> void

	@abstract
	func update(delta : float) -> void

	@abstract
	func exit() -> void


var _states : Dictionary[StringName, FSMState] = {}
var _current_state : FSMState = null
var _init_state : StringName
var _active : bool = false


func _init(enums : Array[StringName]) -> void:
	if enums.is_empty():
		push_error("FSMLib|状态机初始化|状态列表为空")
		return
	for state_name : StringName in enums:
		_states[state_name] = null
	_init_state = enums[0]
	set_meta(FSM_FLAG, true)


## 添加状态
## ERR_INVALID_PARAMETER：状态不可用或名称不在构造列表；ERR_ALREADY_EXISTS：该状态已添加
func add_state(state : FSMState) -> Error:
	if !is_instance_valid(state):
		push_error("FSMLib|添加状态|状态不可用")
		return ERR_INVALID_PARAMETER
	var state_name : StringName = state.name
	if !_states.has(state_name):
		push_error("FSMLib|添加状态|不存在状态 %s" % state_name)
		return ERR_INVALID_PARAMETER
	if is_instance_valid(_states[state_name]):
		push_error("FSMLib|添加状态|状态 %s 已存在" % state_name)
		return ERR_ALREADY_EXISTS
	_states[state_name] = state
	return OK


## 启动状态机
## ERR_ALREADY_EXISTS：已激活；ERR_UNAVAILABLE：仍有状态未填充
func start() -> Error:
	if _active:
		push_error("FSMLib|启动|状态机已激活")
		return ERR_ALREADY_EXISTS
	var missing : Array[StringName] = []
	for key in _states.keys():
		if !is_instance_valid(_states[key]):
			missing.append(key)
	if !missing.is_empty():
		push_error("FSMLib|启动|以下状态未填充: %s" % str(missing))
		return ERR_UNAVAILABLE
	_current_state = _states[_init_state]
	_current_state.enter()
	_active = true
	return OK


## 停止状态机；ERR_UNAVAILABLE：未激活
func stop() -> Error:
	if !_active:
		push_error("FSMLib|停止|状态机未激活")
		return ERR_UNAVAILABLE
	_current_state.exit()
	_current_state = null
	_active = false
	return OK


## 切换状态
## ERR_UNAVAILABLE：未激活；ERR_INVALID_PARAMETER：目标状态不存在或为空
func change_state(state_name : StringName) -> Error:
	if !_active:
		push_error("FSMLib|切换|状态机未激活")
		return ERR_UNAVAILABLE
	if !_states.has(state_name):
		push_error("FSMLib|切换|不存在状态 %s" % state_name)
		return ERR_INVALID_PARAMETER
	if !is_instance_valid(_states[state_name]):
		push_error("FSMLib|切换|状态 %s 为空" % state_name)
		return ERR_INVALID_PARAMETER
	# NOTE 状态机一旦激活就必有当前状态，此处直接切换
	_current_state.exit()
	_current_state = _states[state_name]
	_current_state.enter()
	return OK


## 更新当前状态
## 未激活返回 ERR_UNAVAILABLE（预期失败，不写日志，避免逐帧刷屏）
func update(delta : float) -> Error:
	if !_active:
		return ERR_UNAVAILABLE
	if _current_state != null:
		_current_state.update(delta)
	return OK


func clear() -> void:
	if _active:
		stop()
	_states.clear()