extends Kit
## 容器型扩展模块：UI 拔插管理
## 持有 ui_id → PackedScene 注册表；按各 UI 自述的池化策略复用实例
## 拔插：显示时挂入场景树，关闭时离树但不销毁（池上限内回收进池），
## 从而停止绘制 / 布局重算 / 逐帧轮询 / 输入遍历
## 暂停：汇聚所有活动 UI 的暂停请求，供外部查询；UI 与暂停动作解耦
class_name UiKit


# ==================== 可配置 ====================
## 挂载容器：所有 UI 的父节点；留空则在首次使用时自动建一个 CanvasLayer
@export var mount : CanvasLayer
## 数据架构：UI 经总线访问的 Model/System 所属作用域；留空则使用本 Kit 自身
@export var target_architecture : Architecture

# ==================== 内部状态 ====================
var _default_mount : CanvasLayer = null
# NOTE 不能叫 _registry：父类 Architecture 已占用该名
var _scenes : Dictionary[StringName, PackedScene] = {}
var _configs : Dictionary[StringName, Dictionary] = {}
var _idle : Dictionary[StringName, Array] = {}
var _active : Dictionary[StringName, Array] = {}
var _pause_requests : Dictionary = {}
var _last_opened : UiView = null


# ==================== 生命周期 ====================
## 反初始化：先拆掉所有 UI，再走 Architecture 的注销流程
## 重写而非再挂 _exit_tree，避免与基类的 _exit_tree→deinit 二次触发
func deinit() -> void:
	if _deinited:
		return
	_shutdown_views()
	super.deinit()


# ==================== 挂载点 ====================
## 取挂载容器；未配置时自动建一个 CanvasLayer（本 Kit 的子节点）
func get_mount() -> CanvasLayer:
	if mount != null and is_instance_valid(mount):
		return mount
	if _default_mount == null or not is_instance_valid(_default_mount):
		_default_mount = CanvasLayer.new()
		_default_mount.name = "UiMount"
		add_child(_default_mount)
	return _default_mount


## 取 UI 对话的数据架构；未配置则回退为本 Kit 自身
func get_target_architecture() -> Architecture:
	if target_architecture != null and is_instance_valid(target_architecture):
		return target_architecture
	return self


# ==================== 注册表 ====================
## 登记一个可打开的 UI 场景；重名不覆盖
func register(ui_id : StringName, scene : PackedScene) -> Error:
	if ui_id == &"":
		push_error("UiKit|注册|ui_id 不能为空")
		return ERR_INVALID_PARAMETER
	if scene == null:
		push_error("UiKit|注册|%s 的场景为 null" % ui_id)
		return ERR_INVALID_PARAMETER
	if _scenes.has(ui_id):
		push_error("UiKit|注册|%s 已注册，拒绝覆盖" % ui_id)
		return ERR_ALREADY_EXISTS
	_scenes[ui_id] = scene
	return OK


## 注销并释放该 id 的全部实例（活动 + 池中）
func unregister(ui_id : StringName) -> Error:
	if not _scenes.has(ui_id):
		return ERR_DOES_NOT_EXIST
	_drop_instances(ui_id)
	_scenes.erase(ui_id)
	_configs.erase(ui_id)
	return OK


func has_ui(ui_id : StringName) -> bool:
	return _scenes.has(ui_id)


func get_registered_ids() -> Array[StringName]:
	var ids : Array[StringName] = []
	for ui_id : StringName in _scenes:
		ids.append(ui_id)
	return ids


## 预实例化：把该 UI 的空闲池填充到其自述的 pool_initial
func prewarm(ui_id : StringName) -> Error:
	var err : Error = _ensure_config(ui_id)
	if err != OK:
		return err
	var target : int = int(_configs[ui_id]["pool_initial"])
	while _idle_list(ui_id).size() < target:
		var view : UiView = _instantiate(ui_id)
		if view == null:
			return ERR_INVALID_DATA
		_add_idle(ui_id, view)
	return OK


# ==================== 开 / 关 ====================
## 打开 UI（可断言）：优先复用池中实例；singular UI 已打开时返回现有实例
## 成功 OK，实例经 get_last_opened() 取；未注册 ERR_DOES_NOT_EXIST；场景根非 UiView ERR_INVALID_DATA
func try_open(ui_id : StringName, params : Dictionary = {}) -> Error:
	_last_opened = null
	var err : Error = _ensure_config(ui_id)
	if err != OK:
		return err
	if bool(_configs[ui_id]["singular"]) and is_open(ui_id):
		_last_opened = _first_active(ui_id)
		return OK
	var view : UiView = _acquire(ui_id)
	if view == null:
		push_error("UiKit|打开|%s 实例化失败" % ui_id)
		return ERR_INVALID_DATA
	get_mount().add_child(view)
	_push_active(ui_id, view)
	view._on_attached(params)
	_last_opened = view
	return OK


## 便捷包装：失败返回 null；需要错误码请用 try_open()
func open(ui_id : StringName, params : Dictionary = {}) -> UiView:
	if try_open(ui_id, params) != OK:
		return null
	return _last_opened


## 最近一次 try_open 打开的实例；该实例已被释放时返回 null
func get_last_opened() -> UiView:
	if _last_opened == null or not is_instance_valid(_last_opened):
		return null
	return _last_opened


## 关闭 UI：离树但不销毁——池未满则回收进池，否则释放
func close(view : UiView) -> Error:
	if view == null:
		return ERR_INVALID_PARAMETER
	if view._kit != self:
		push_error("UiKit|关闭|该 UiView 不属于本 Kit")
		return ERR_INVALID_PARAMETER
	if not view._is_active():
		return ERR_DOES_NOT_EXIST
	var ui_id : StringName = view.get_ui_id()
	var parent : Node = view.get_parent()
	if parent != null:
		parent.remove_child(view)
	# NOTE 显式兜底：_on_detached 幂等，Kit 不在树中时 remove_child 不会触发 _exit_tree
	view._on_detached()
	_remove_active(ui_id, view)
	if _idle_list(ui_id).size() < _effective_pool_max(ui_id):
		_add_idle(ui_id, view)
	else:
		view.free()   # 已离树，可直接释放
	return OK


## 关闭该 id 的全部活动实例；返回关闭数量
func close_id(ui_id : StringName) -> int:
	var list : Array = _active_list(ui_id).duplicate()
	for view : UiView in list:
		close(view)
	return list.size()


## 关闭所有活动 UI；返回关闭数量
func close_all() -> int:
	var total : int = 0
	var ids : Array = _active.keys().duplicate()
	for ui_id in ids:
		total += close_id(ui_id)
	return total


# ==================== 查询 ====================
func is_open(ui_id : StringName) -> bool:
	return not _active_list(ui_id).is_empty()


## 该 id 当前活动的实例（singular 至多 1 个）
func get_active(ui_id : StringName) -> Array[UiView]:
	var out : Array[UiView] = []
	for view : UiView in _active_list(ui_id):
		out.append(view)
	return out


## 全部活动实例
func get_all_active() -> Array[UiView]:
	var out : Array[UiView] = []
	for ui_id : StringName in _active:
		for view : UiView in _active[ui_id]:
			out.append(view)
	return out


## 该 id 当前空闲（池中、离树保留）的实例数量
func get_pool_size(ui_id : StringName) -> int:
	return _idle_list(ui_id).size()


## 该 UI 是否处于池中（已离树、未销毁）
func is_pooled(view : UiView) -> bool:
	if view == null:
		return false
	return _idle_list(view.get_ui_id()).has(view)


# ==================== 暂停请求聚合 ====================
## 向内入口：由 UiView.set_pause_request 转发写入
func set_pause_request(view : UiView, on : bool) -> void:
	if view == null:
		return
	if on:
		_pause_requests[view] = true
	else:
		_pause_requests.erase(view)


## 向外查询：是否存在任一活动 UI 请求暂停
func is_pause_requested() -> bool:
	return not _pause_requests.is_empty()


## 向外查询：当前所有请求暂停的 UI
func get_pause_requests() -> Array[UiView]:
	var out : Array[UiView] = []
	for view : UiView in _pause_requests.keys():
		out.append(view)
	return out


# ==================== 内部：配置 / 实例 / 池 ====================
# NOTE 探针实例：读取 UI 自述的池化策略，并直接留作首个空闲实例
func _ensure_config(ui_id : StringName) -> Error:
	if _configs.has(ui_id):
		return OK
	if not _scenes.has(ui_id):
		push_error("UiKit|配置|%s 未注册" % ui_id)
		return ERR_DOES_NOT_EXIST
	var probe : UiView = _instantiate(ui_id)
	if probe == null:
		return ERR_INVALID_DATA
	# singular 时池上限收敛为 1；初始量不得超过上限
	var max_raw : int = maxi(probe.pool_max, 0)
	var cap : int = mini(max_raw, 1) if probe.singular else max_raw
	_configs[ui_id] = {
		"singular": probe.singular,
		"pool_initial": mini(maxi(probe.pool_initial, 0), cap),
		"pool_max": cap,
	}
	_add_idle(ui_id, probe)
	return OK


func _instantiate(ui_id : StringName) -> UiView:
	var scene : PackedScene = _scenes.get(ui_id)
	if scene == null:
		return null
	var node : Node = scene.instantiate()
	if not node is UiView:
		push_error("UiKit|实例化|%s 的场景根节点未挂 UiView 脚本" % ui_id)
		node.free()
		return null
	var view : UiView = node as UiView
	view._bind_kit(self, get_target_architecture(), ui_id)
	return view


func _acquire(ui_id : StringName) -> UiView:
	var view : UiView = _take_idle(ui_id)
	if view != null:
		return view
	return _instantiate(ui_id)


func _effective_pool_max(ui_id : StringName) -> int:
	var cfg = _configs.get(ui_id)
	if cfg == null:
		return 0
	return int(cfg["pool_max"])


func _idle_list(ui_id : StringName) -> Array:
	if not _idle.has(ui_id):
		_idle[ui_id] = []
	return _idle[ui_id]


func _add_idle(ui_id : StringName, view : UiView) -> void:
	_idle_list(ui_id).append(view)


func _take_idle(ui_id : StringName) -> UiView:
	var list : Array = _idle_list(ui_id)
	if list.is_empty():
		return null
	return list.pop_back()


func _active_list(ui_id : StringName) -> Array:
	if not _active.has(ui_id):
		_active[ui_id] = []
	return _active[ui_id]


func _push_active(ui_id : StringName, view : UiView) -> void:
	_active_list(ui_id).append(view)


func _remove_active(ui_id : StringName, view : UiView) -> void:
	_active_list(ui_id).erase(view)


func _first_active(ui_id : StringName) -> UiView:
	var list : Array = _active_list(ui_id)
	if list.is_empty():
		return null
	return list[0]


func _drop_instances(ui_id : StringName) -> void:
	for view : UiView in _active_list(ui_id).duplicate():
		if is_instance_valid(view):
			var parent : Node = view.get_parent()
			if parent != null:
				parent.remove_child(view)
			view._on_detached()
			view.free()
	_active.erase(ui_id)
	for view : UiView in _idle_list(ui_id).duplicate():
		if is_instance_valid(view):
			view.free()
	_idle.erase(ui_id)


func _shutdown_views() -> void:
	for ui_id : StringName in _scenes.keys():
		_drop_instances(ui_id)
	_pause_requests.clear()