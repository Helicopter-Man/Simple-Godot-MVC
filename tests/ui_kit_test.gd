extends RefCounted
## UiKit 测试套件
## 约定：static func run(root: Node) -> Dictionary

const TestUiViewScene := preload("res://tests/fixtures/test_ui_view.gd")
const TestUiEventScene := preload("res://tests/fixtures/test_ui_event.gd")


static func run(root : Node) -> Dictionary:
	var cases : Array = []
	_run_registry(cases, root)
	_run_try_open_errors(cases, root)
	_run_open_close_pool(cases, root)
	_run_no_pool(cases, root)
	_run_multi(cases, root)
	_run_prewarm(cases, root)
	_run_pause(cases, root)
	_run_event_autounbind(cases, root)
	_run_bad_scene(cases, root)
	_run_lifecycle(cases, root)
	var failed := 0
	for c in cases:
		if not c["ok"]:
			failed += 1
	return {"suite": "UiKit", "total": cases.size(), "failed": failed, "cases": cases}


# ---- 用例：注册 / 注销 ----
static func _run_registry(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	_check(cases, "register 有效返回 OK", kit.register(&"A", _make_scene(true, 0, 1)) == OK)
	_check(cases, "register 重名返回 ERR_ALREADY_EXISTS", kit.register(&"A", _make_scene(true, 0, 1)) == ERR_ALREADY_EXISTS)
	_check(cases, "register 场景为 null 返回 ERR_INVALID_PARAMETER", kit.register(&"B", null) == ERR_INVALID_PARAMETER)
	_check(cases, "register 空 id 返回 ERR_INVALID_PARAMETER", kit.register(&"", _make_scene(true, 0, 1)) == ERR_INVALID_PARAMETER)
	_check(cases, "has_ui 已注册为真", kit.has_ui(&"A"))
	_check(cases, "get_registered_ids 含 A", kit.get_registered_ids().has(&"A"))
	_check(cases, "unregister 已存在返回 OK", kit.unregister(&"A") == OK)
	_check(cases, "unregister 不存在返回 ERR_DOES_NOT_EXIST", kit.unregister(&"A") == ERR_DOES_NOT_EXIST)
	_cleanup_kit(root, kit)


# ---- 用例：try_open 可断言错误码 ----
static func _run_try_open_errors(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	_check(cases, "未注册时 try_open 返回 ERR_DOES_NOT_EXIST", kit.try_open(&"Nope") == ERR_DOES_NOT_EXIST)
	_check(cases, "失败后 get_last_opened 为 null", kit.get_last_opened() == null)
	kit.register(&"Ok", _make_scene(true, 0, 1))
	_check(cases, "已注册时 try_open 返回 OK", kit.try_open(&"Ok") == OK)
	_check(cases, "成功后 get_last_opened 非空", kit.get_last_opened() != null)
	_check(cases, "singular 已打开时 try_open 仍返回 OK", kit.try_open(&"Ok") == OK)
	_check(cases, "singular 二次 try_open 复用同一实例", kit.get_last_opened() == kit.get_active(&"Ok")[0])
	_cleanup_kit(root, kit)


# ---- 用例：打开 / 关闭 + singular 池复用 ----
static func _run_open_close_pool(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	kit.register(&"Menu", _make_scene(true, 0, 1))

	var v1 := kit.open(&"Menu")
	_check(cases, "open 返回 UiView", v1 != null)
	_check(cases, "open 后 is_open 为真", kit.is_open(&"Menu"))
	_check(cases, "首次显示调用 _ui_enter", v1 != null and v1.enter_count == 1)
	_check(cases, "singular 重复 open 返回同一实例", kit.open(&"Menu") == v1)

	_check(cases, "close 返回 OK", kit.close(v1) == OK)
	_check(cases, "close 后 is_open 为假", not kit.is_open(&"Menu"))
	_check(cases, "关闭调用 _ui_exit", v1 != null and v1.exit_count == 1)
	_check(cases, "池上限内实例未销毁", is_instance_valid(v1))
	_check(cases, "关闭后实例在池中", kit.is_pooled(v1))
	_check(cases, "关闭后 get_pool_size 为 1", kit.get_pool_size(&"Menu") == 1)

	var v2 := kit.open(&"Menu", {"k": 7})
	_check(cases, "复用池中同一实例", v2 == v1)
	_check(cases, "复用后池为空", kit.get_pool_size(&"Menu") == 0)
	_check(cases, "复用后 _ui_enter 再调一次", v1 != null and v1.enter_count == 2)
	_check(cases, "参数透传到 _ui_enter", v1 != null and v1.last_params.get("k", 0) == 7)
	_cleanup_kit(root, kit)


# ---- 用例：pool_max=0 关闭即释放 ----
static func _run_no_pool(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	kit.register(&"Toast", _make_scene(true, 0, 0))
	var v1 := kit.open(&"Toast")
	kit.close(v1)
	_check(cases, "pool_max=0 关闭后实例被释放", not is_instance_valid(v1))
	_check(cases, "pool_max=0 池保持为空", kit.get_pool_size(&"Toast") == 0)
	var v2 := kit.open(&"Toast")
	_check(cases, "pool_max=0 重新 open 得到可用实例", v2 != null)
	_cleanup_kit(root, kit)


# ---- 用例：复数同时打开与复用 ----
static func _run_multi(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	kit.register(&"Ach", _make_scene(false, 0, 2))
	var a := kit.open(&"Ach")
	var b := kit.open(&"Ach")
	_check(cases, "复数 UI 可同时打开两个", a != null and b != null and a != b)
	_check(cases, "活动实例数为 2", kit.get_active(&"Ach").size() == 2)
	kit.close(a)
	kit.close(b)
	_check(cases, "池上限内两个实例均保留", is_instance_valid(a) and is_instance_valid(b))
	var c := kit.open(&"Ach")
	var d := kit.open(&"Ach")
	_check(cases, "复用池中实例", (c == a and d == b) or (c == b and d == a))
	_check(cases, "close_all 关闭全部", kit.close_all() == 2 and not kit.is_open(&"Ach"))
	_cleanup_kit(root, kit)


# ---- 用例：预实例化 ----
static func _run_prewarm(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	kit.register(&"Item", _make_scene(false, 2, 2))
	_check(cases, "prewarm 返回 OK", kit.prewarm(&"Item") == OK)
	_check(cases, "prewarm 把空闲池填充到 pool_initial", kit.get_pool_size(&"Item") == 2)
	_cleanup_kit(root, kit)


# ---- 用例：暂停请求聚合 ----
static func _run_pause(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	kit.register(&"Pause", _make_scene(true, 0, 1))
	var v := kit.open(&"Pause")
	_check(cases, "初始无暂停请求", not kit.is_pause_requested())
	v.set_pause_request(true)
	_check(cases, "UI 写入请求后聚合为真", kit.is_pause_requested())
	_check(cases, "get_pause_requests 含该 UI", kit.get_pause_requests().has(v))
	kit.close(v)
	_check(cases, "关闭后请求被自动清空", not kit.is_pause_requested())
	_cleanup_kit(root, kit)


# ---- 用例：事件离树自动解绑 ----
static func _run_event_autounbind(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	kit.register(&"Evt", _make_scene(true, 0, 1, true))
	var v := kit.open(&"Evt")
	_check(cases, "显示后事件可被派发到 UI", kit.send_event(TestUiEventScene.new()) == 1)
	_check(cases, "UI 收到事件", v != null and v.received_events == 1)
	kit.close(v)
	_check(cases, "关闭后事件自动解绑", kit.send_event(TestUiEventScene.new()) == 0)
	_cleanup_kit(root, kit)


# ---- 用例：场景根节点不是 UiView ----
static func _run_bad_scene(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	var node := Node.new()
	node.name = "BadRoot"
	var scene := PackedScene.new()
	scene.pack(node)
	node.free()
	kit.register(&"Bad", scene)
	_check(cases, "根节点非 UiView 时 try_open 返回 ERR_INVALID_DATA", kit.try_open(&"Bad") == ERR_INVALID_DATA)
	_check(cases, "失败后 get_last_opened 为 null", kit.get_last_opened() == null)
	_cleanup_kit(root, kit)


# ---- 用例：生命周期（离树 deinit 释放实例）----
static func _run_lifecycle(cases : Array, root : Node) -> void:
	var kit := _new_kit(root)
	kit.register(&"M", _make_scene(true, 0, 1, true))
	var v := kit.open(&"M")
	v.set_pause_request(true)
	root.remove_child(kit)   # _exit_tree → deinit → _shutdown_views
	_check(cases, "deinit 释放活动实例", not is_instance_valid(v))
	_check(cases, "deinit 后暂停聚合为空", not kit.is_pause_requested())
	kit.free()


# ---- 工具 ----
static func _new_kit(root : Node) -> UiKit:
	var kit := UiKit.new()
	if root != null:
		root.add_child(kit)   # 触发 _ready，模拟真实挂载
	return kit


static func _cleanup_kit(root : Node, kit : UiKit) -> void:
	if root != null and kit.get_parent() == root:
		root.remove_child(kit)   # 触发 deinit
	kit.free()


static func _make_scene(singular : bool, initial : int, max_pool : int, bind_event : bool = false) -> PackedScene:
	var v = TestUiViewScene.new()
	v.name = "UiRoot"
	v.singular = singular
	v.pool_initial = initial
	v.pool_max = max_pool
	v.bind_test_event = bind_event
	var scene := PackedScene.new()
	scene.pack(v)
	v.free()
	return scene


static func _check(cases : Array, name : String, ok : bool, detail : String = "") -> void:
	cases.append({"name": name, "ok": ok, "detail": detail})