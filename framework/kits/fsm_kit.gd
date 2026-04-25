extends RefCounted
class_name FSM

const FSM_FLAG : StringName = &"ISFSM"

# NOTE 简单状态机，不做分层
# 规矩越死，规范越硬

@abstract
class FSMState extends RefCounted:

	var name : StringName

	var _fsm_ref : WeakRef

	## _name : 状态名; fsm : 状态机对象 NOTE 使用Object再转换为弱引用破除实例的循环引用
	func _init(_name : StringName,fsm : Object) -> void:
		if !is_instance_valid(fsm):
			push_error("FSMKit|状态初始化|状态机对象不可用")
			return

		if !fsm.get_meta(FSM_FLAG,false):
			push_error("FSMKit|状态初始化|传入的fsm对象并非状态机")
			return
		name = _name
		_fsm_ref = weakref(fsm)

	func _change_state(_name : StringName) -> void:
		if !is_instance_valid(_fsm_ref):
			push_error("FSMKit|状态切换|状态机引用失效")
			return
		# NOTE 不写FSM类名是防止类之间的循环依赖，代价是忽略不计的性能差异
		var fsm : Object = _fsm_ref.get_ref()

		if !is_instance_valid(fsm):
			push_error("FSMKit|状态切换|状态机对象不可用")
			return

		# NOTE _init时确保了其一定是状态机，直接调用即可，性能上约等于call，但比确定类型的直接方法调用差
		fsm.change_state(_name)


	@abstract
	func enter() -> void

	@abstract
	func update(delta : float) -> void

	@abstract
	func exit() -> void

var _states : Dictionary[StringName,FSMState] = {}
var _current_state : FSMState = null
var _init_state : StringName
var _active : bool = false

func _init(enums : Array[StringName]) -> void:
	if enums.is_empty():
		push_error("FSMKit|状态机初始化|状态列表为空")
		return
	for name in enums:
		_states[name] = null
	_init_state = enums[0]
	set_meta(FSM_FLAG,true)

func add_state(state : FSMState) -> void:
	if !is_instance_valid(state):
		push_error("FSMKit|状态机添加状态|状态不可用")
		return
	var name : StringName = state.name
	if !_states.has(name):
		push_error("FSMKit|状态机添加状态|不存在状态%s" % name)
		return
	if is_instance_valid(_states[name]):
		push_error("FSMKit|状态机添加状态|已存在状态")
		return
	_states[name] = state

func start() -> void:
	if _active:
		push_error("FSMKit|启动状态机|状态机已激活")
		return
	var null_list : Array[StringName] = []
	for key in _states.keys():
		if !is_instance_valid(_states[key]):
			null_list.append(key)
	if !null_list.is_empty():
		push_error("FSMKit|启动状态机|以下状态不可用:
			%s" % null_list)
		return

	_current_state = _states[_init_state]
	_current_state.enter()
	_active = true

func stop()->void:
	if !_active:
		push_error("FSMKit|停止状态机|状态机未激活")
		return
	_current_state.exit()
	_current_state = null
	_active = false


func change_state(name : StringName) -> void:
	if !_active:
		push_error("FSMKit|状态机切换状态|状态机未激活")
		return

	if !_states.has(name):
		push_error("FSMKit|状态机切换状态|不存在状态索引%s" % name)
		return
	if !_states[name]:
		push_error("FSMKit|状态机切换状态|状态为空")
		return

	# NOTE 因为状态机一旦激活，就一定有当前状态，若是这里都能出问题，应该想想是不是使用错了
	_current_state.exit()
	_current_state = _states[name]
	_current_state.enter()

# 更新当前状态
func update(delta: float) -> void:
	if !_active:
		push_error("FSMKit|状态机更新状态|状态机未激活")
		return

	if _current_state != null:
		_current_state.update(delta)

func clear() -> void:
	if _active:
		stop()
	_states.clear()
