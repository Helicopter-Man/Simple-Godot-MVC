extends RefCounted
## SaveKit 测试套件
## 约定：static func run(root: Node) -> Dictionary

const TestSaveModel := preload("res://tests/fixtures/test_save_model.gd")
const PlainTestModel := preload("res://tests/fixtures/plain_test_model.gd")
const VersionedTestModel := preload("res://tests/fixtures/versioned_test_model.gd")
const LifecycleTestModel := preload("res://tests/fixtures/lifecycle_test_model.gd")
const TestSaveKit := preload("res://tests/fixtures/test_save_kit.gd")

const TMP_DIR := "user://__savekit_tests__"


static func run(root: Node) -> Dictionary:
	var cases : Array = []
	_reset_dir()
	_run_registration(cases)
	_run_save(cases)
	_run_load(cases)
	_run_migration(cases)
	_run_lifecycle(cases, root)
	_reset_dir()
	var failed := 0
	for c in cases:
		if not c["ok"]:
			failed += 1
	return {"suite": "SaveKit", "total": cases.size(), "failed": failed, "cases": cases}


# ---- 用例：注册 / 注销 ----
static func _run_registration(cases : Array) -> void:
	var kit = SaveKit.new()
	var model = TestSaveModel.new()

	_check(cases, "register_saveable 有效 Model 返回 OK", kit.register_saveable(model) == OK)
	_check(cases, "注册后 has_model 为真", kit.has_model(&"TestSaveModel"))
	_check(cases, "注册后 get_model 返回同一实例", kit.get_model(&"TestSaveModel") == model)
	_check(cases, "重复注册返回 ERR_ALREADY_EXISTS", kit.register_saveable(TestSaveModel.new()) == ERR_ALREADY_EXISTS)
	_check(cases, "注册 null 返回 ERR_INVALID_PARAMETER", kit.register_saveable(null) == ERR_INVALID_PARAMETER)
	_check(cases, "缺少接口的 Model 返回 ERR_INVALID_PARAMETER", kit.register_saveable(PlainTestModel.new()) == ERR_INVALID_PARAMETER)
	_check(cases, "unregister_saveable 已存在返回 OK", kit.unregister_saveable(&"TestSaveModel") == OK)
	_check(cases, "unregister_saveable 不存在返回 ERR_DOES_NOT_EXIST", kit.unregister_saveable(&"TestSaveModel") == ERR_DOES_NOT_EXIST)

	kit.free()


# ---- 用例：保存 ----
static func _run_save(cases : Array) -> void:
	var kit = SaveKit.new()
	var model = TestSaveModel.new()
	model.hp = 42
	model.level = 7
	kit.register_saveable(model)

	var path : String = TMP_DIR + "/save1.save"
	_check(cases, "save 有效路径返回 OK", kit.save(path) == OK)
	_check(cases, "save 后文件存在", FileAccess.file_exists(path))
	_check(cases, "save 非 user:// 路径返回 ERR_INVALID_PARAMETER", kit.save("res://x.save") == ERR_INVALID_PARAMETER)
	_check(cases, "save 目录穿越返回 ERR_INVALID_PARAMETER", kit.save("user://../evil.save") == ERR_INVALID_PARAMETER)

	var env = _read_envelope(path)
	var env_ok : bool = env is Dictionary and env.has("models") and env["models"].has("TestSaveModel")
	_check(cases, "信封含 models 且含 TestSaveModel", env_ok)
	if env_ok:
		var entry : Dictionary = env["models"]["TestSaveModel"]
		_check(cases, "信封数据 hp == 42", entry["data"]["hp"] == 42)
		_check(cases, "无 get_version 的 Model 版本为 1", entry["version"] == 1)

	_check(cases, "has_save 已存在为真", kit.has_save(path))
	_check(cases, "has_save 不存在为假", not kit.has_save(TMP_DIR + "/none.save"))
	var info : Dictionary = kit.get_save_info(path)
	_check(cases, "get_save_info 返回 models 列表", info.has("models") and info["models"].has("TestSaveModel"))

	kit.free()


# ---- 用例：读档 ----
static func _run_load(cases : Array) -> void:
	var kit = SaveKit.new()
	var model = TestSaveModel.new()
	model.hp = 10
	model.level = 3
	kit.register_saveable(model)

	var path : String = TMP_DIR + "/roundtrip.save"
	kit.save(path)
	model.hp = 999
	model.level = 999

	_check(cases, "load 返回 OK", kit.load(path) == OK)
	_check(cases, "load 恢复 hp", model.hp == 10)
	_check(cases, "load 恢复 level", model.level == 3)
	_check(cases, "load 文件不存在返回 ERR_FILE_NOT_FOUND", kit.load(TMP_DIR + "/missing.save") == ERR_FILE_NOT_FOUND)
	_check(cases, "load 非法路径返回 ERR_INVALID_PARAMETER", kit.load("res://x.save") == ERR_INVALID_PARAMETER)

	kit.free()


# ---- 用例：版本迁移 / 默认值 / 版本超前 ----
static func _run_migration(cases : Array) -> void:
	# 旧版本（v1，含 exp）→ 迁移到当前 v2
	var kit = SaveKit.new()
	var model = VersionedTestModel.new()
	kit.register_saveable(model)
	var p1 : String = TMP_DIR + "/old.save"
	_write_envelope(p1, {"save_version": 1, "saved_at": "", "models": {"VersionedTestModel": {"version": 1, "data": {"hp": 55, "exp": 9}}}})
	_check(cases, "旧版本 load 返回 OK", kit.load(p1) == OK)
	_check(cases, "migrate 把 exp 迁移为 level", model.level == 9)
	_check(cases, "migrate 保留 hp", model.hp == 55)

	# 存档版本超前（5 > 当前 2）→ 原样使用
	var kit2 = SaveKit.new()
	var model2 = VersionedTestModel.new()
	kit2.register_saveable(model2)
	var p2 : String = TMP_DIR + "/ahead.save"
	_write_envelope(p2, {"save_version": 1, "saved_at": "", "models": {"VersionedTestModel": {"version": 5, "data": {"hp": 1, "level": 2}}}})
	_check(cases, "版本超前 load 返回 OK", kit2.load(p2) == OK)
	_check(cases, "版本超前原样使用 hp", model2.hp == 1)

	# 缺字段 → get_defaults 补齐
	var kit3 = SaveKit.new()
	var model3 = VersionedTestModel.new()
	model3.level = 999
	kit3.register_saveable(model3)
	var p3 : String = TMP_DIR + "/sparse.save"
	_write_envelope(p3, {"save_version": 1, "saved_at": "", "models": {"VersionedTestModel": {"version": 2, "data": {"hp": 77}}}})
	_check(cases, "缺字段 load 返回 OK", kit3.load(p3) == OK)
	_check(cases, "缺字段由 get_defaults 补 level=1", model3.level == 1)
	_check(cases, "已有字段 hp 保持 77", model3.hp == 77)

	kit.free()
	kit2.free()
	kit3.free()


# ---- 用例：生命周期闭环（需要场景树）----
static func _run_lifecycle(cases : Array, root : Node) -> void:
	var kit = TestSaveKit.new()
	var cfg := ServiceConfig.new()
	var names : Array[StringName] = [&"TestSaveModel"]
	cfg.models = names
	kit.service_config = cfg

	if root == null:
		_check(cases, "生命周期用例需要有场景树 root", false, "root 为 null")
		return

	root.add_child(kit)   # 触发 _ready
	_check(cases, "_init_save_kit 注册的 Model 可用", kit.has_model(&"TestSaveModel") and kit.has_model(&"LifecycleTestModel"))
	var lc = kit.get_model(&"LifecycleTestModel")
	_check(cases, "Model 的 _on_init 被框架调用", lc != null and lc.was_initialized)
	_check(cases, "service_config 把 Model 暴露到总线", kit.get_service(&"TestSaveModel") != null)

	root.remove_child(kit)   # 触发 _exit_tree → deinit
	_check(cases, "deinit 后 register_saveable 返回 ERR_UNAVAILABLE", kit.register_saveable(TestSaveModel.new()) == ERR_UNAVAILABLE)
	_check(cases, "deinit 后 get_service 返回 null", kit.get_service(&"TestSaveModel") == null)

	kit.free()


# ---- 工具 ----
static func _check(cases : Array, name : String, ok : bool, detail : String = "") -> void:
	cases.append({"name": name, "ok": ok, "detail": detail})


static func _reset_dir() -> void:
	var base := DirAccess.open("user://")
	if base == null:
		return
	if not base.dir_exists("__savekit_tests__"):
		base.make_dir("__savekit_tests__")
	var d := DirAccess.open(TMP_DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)


static func _write_envelope(path : String, env : Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(var_to_bytes(env))
	f.close()


static func _read_envelope(path : String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes : PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	return bytes_to_var(bytes)