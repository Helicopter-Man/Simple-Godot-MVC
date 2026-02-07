extends RefCounted
class_name FSM

# NOTE 简单状态机，不做分层
# 仅支持枚举，规矩越死，规范越硬

@abstract
class FSMState:
	
	@abstract
	func enter()
	
	@abstract
	func update(delta : float)
	
	@abstract
	func eixt()

var _states : Dictionary[int,FSMState] = {}
var _current_state : FSMState = null

func _init(enums : Array[int]) -> void:
	for index in enums:
		_states[index] = null

func add_state(index : int, state : FSMState) -> void:
	if !_states.has(index):
		push_error("FSMKit|添加状态|不存在状态索引%s" % index)
		return
	if _states[index]:
		push_error("FSMKit|添加状态|已存在状态")
		return
	_states[index] = state

func start(index : int = 0) -> void:
	change_state(index)
	
func change_state(index : int) -> void:
	if !_states.has(index):
		push_error("FSMKit|切换状态|不存在状态索引%s" % index)
		return
	if !_states[index]:
		push_error("FSMKit|切换状态|状态为空")
		return
	
	if _current_state != null:
		_current_state.eixt()
	
	_current_state = _states[index]
	_current_state.enter()

# 更新当前状态
func update(delta: float) -> void:
	if _current_state != null:
		_current_state.update(delta)

func stop() -> void:
	if _current_state:
		_current_state.exit()
		_current_state = null

func clear() -> void:
	if _current_state:
		_current_state.exit()
	_states.clear()
	_current_state = null
