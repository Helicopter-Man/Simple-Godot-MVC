extends Node
## 存档套件：独立于 Architecture 的存档作用域容器
## 仅承载实现了 get_data / set_data 接口的 saveable Model
## 通过 ServiceConfig 暴露 saveable Model 与自身实例给其他 Architecture
class_name SaveKit


# ---- 服务配置（与 Architecture 对齐）----
@export var service_config : ServiceConfig
var _registered_services : Array[StringName] = []

# ---- saveable Model 容器 ----
var _saveable_models : Dictionary[StringName, Model] = {}

# 生命周期：子类重写以注册自身的 saveable Model
func _init_save_kit() -> void:
	pass

func _ready() -> void:
	_init_save_kit()
	# 触发 saveable Model 的初始化钩子
	for model : Model in _saveable_models.values():
		if model.has_method("_on_init"):
			model._on_init()
	_register_services()

func _exit_tree() -> void:
	# NOTE 主动反初始化，避免悬挂服务与回调
	_unregister_services()
	for model : Model in _saveable_models.values():
		if model.has_method("_on_deinit"):
			model._on_deinit()
	_saveable_models.clear()


# ---- 服务声明 ----
func _register_services() -> void:
	if service_config == null:
		return
	# 暴露 SaveKit 自身
	if service_config.self_name != &"":
		ServiceMiddleware.register_service(service_config.self_name, self)
		_registered_services.append(service_config.self_name)
	# 暴露 saveable Model
	for model_name : StringName in service_config.models:
		var model : Model = get_model(model_name)
		if model != null:
			ServiceMiddleware.register_service(model_name, model)
			_registered_services.append(model_name)
		else:
			push_warning("SaveKit|服务声明|Model %s 未注册，跳过" % model_name)
	# NOTE SaveKit 不暴露 System / Utility，明确警告以避免配置错误
	for system_name : StringName in service_config.systems:
		push_warning("SaveKit|服务声明|SaveKit 不支持暴露 System，跳过 %s" % system_name)
	for utility_name : StringName in service_config.utilities:
		push_warning("SaveKit|服务声明|SaveKit 不支持暴露 Utility，跳过 %s" % utility_name)

func _unregister_services() -> void:
	for service_name : StringName in _registered_services:
		ServiceMiddleware.unregister_service(service_name)
	_registered_services.clear()

# NOTE 查询其他 Architecture 暴露的服务
func get_service(name : StringName) -> Variant:
	return ServiceMiddleware.get_service(name)


# ---- 注册 / 注销 / 获取 saveable Model ----
func register_saveable(model : Model) -> void:
	if not (model.has_method("get_data") and model.has_method("set_data")):
		push_error("SaveKit|注册|Model %s 未实现 get_data/set_data 接口" % model.get_script_name())
		return
	var model_name = model.get_script_name()
	if _saveable_models.has(model_name):
		push_error("SaveKit|注册|Model %s 已经注册，请勿重复注册" % model_name)
		return
	_saveable_models[model_name] = model

func unregister_saveable(model_name : StringName) -> void:
	_saveable_models.erase(model_name)

func get_model(model_name : StringName) -> Model:
	return _saveable_models.get(model_name)

func has_model(model_name : StringName) -> bool:
	return _saveable_models.has(model_name)


# ---- 路径安全校验 ----
func _validate_path(path : String, action : String) -> bool:
	# 必须以 user:// 开头，防止误写工程目录或绝对路径
	if not path.begins_with("user://"):
		push_error("SaveKit|%s|路径非法，必须以 user:// 开头" % action)
		return false
	# 规范化分隔符，防止反斜杠绕过分段校验
	var normalized := path.replace("\\", "/")
	var parts := normalized.split("/")
	for part in parts:
		# 禁止 .. 穿越（如 user://../saves 会越界到工程根目录上层）
		if part == "..":
			push_error("SaveKit|%s|路径非法，禁止使用 .. 进行目录穿越" % action)
			return false
	return true


# ---- 保存：将所有 saveable Model 的数据序列化为存档信封 ----
func save(path : String) -> void:
	if not _validate_path(path, "保存"):
		return

	# NOTE 信封结构：版本号 + 保存时间 + 各 Model 数据
	var envelope : Dictionary = {
		"save_version": 1,
		"saved_at": Time.get_datetime_string_from_system(),
		"models": {}
	}

	for model_name : StringName in _saveable_models:
		var model : Model = _saveable_models[model_name]
		# NOTE get_data 必须返回 Dictionary，否则跳过该 Model 并报错
		var data = model.get_data()
		if not data is Dictionary:
			push_error("SaveKit|保存|Model %s 的 get_data 未返回 Dictionary，跳过" % model_name)
			continue
		# NOTE get_version 可选，未实现默认 1；返回类型异常则降级
		var version : int = 1
		if model.has_method("get_version"):
			var v = model.get_version()
			if v is int:
				version = v
			else:
				push_warning("SaveKit|保存|Model %s 的 get_version 未返回 int，使用默认值 1" % model_name)
		# 键转为 String，便于反序列化后按字符串遍历再转 StringName 查找
		envelope["models"][String(model_name)] = {
			"version": version,
			"data": data
		}

	# 序列化为字节流并写入文件
	var bytes : PackedByteArray = var_to_bytes(envelope)
	var file : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("SaveKit|保存|文件打开失败: " + path)
		return
	file.store_buffer(bytes)
	file.close()


# ---- 读档：反序列化信封并执行版本迁移链 + 默认值填充 ----
func load(path : String) -> void:
	if not _validate_path(path, "读档"):
		return

	if not FileAccess.file_exists(path):
		push_warning("SaveKit|读档|文件不存在: " + path)
		return

	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SaveKit|读档|文件打开失败: " + path)
		return
	var bytes : PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	var envelope = bytes_to_var(bytes)

	# 校验信封格式
	if not _validate_envelope(envelope, "读档"):
		return

	var models_dict : Dictionary = envelope["models"]
	for model_name in models_dict:
		var model : Model = _saveable_models.get(StringName(model_name))
		if model == null:
			push_warning("SaveKit|读档|Model %s 未注册，跳过" % model_name)
			continue

		var entry = models_dict[model_name]
		# 校验条目结构（version / data 类型完整）
		if not _validate_entry(entry, model_name):
			continue

		var saved_version : int = entry["version"]
		var data : Dictionary = entry["data"]

		# 当前 Model 的版本号
		var current_version : int = 1
		if model.has_method("get_version"):
			var cv = model.get_version()
			if cv is int:
				current_version = cv

		# NOTE 迁移链：逐版本向上迁移；失败时隔离错误，回退默认值
		var migration_ok := true
		while saved_version < current_version:
			if model.has_method("migrate"):
				var migrated = _safe_migrate(model, data, saved_version, model_name)
				if migrated == null:
					# migrate 抛错或返回类型错误，终止迁移
					migration_ok = false
					break
				data = migrated
				saved_version += 1
			else:
				push_warning("SaveKit|读档|Model %s 需要迁移但未实现 migrate" % model_name)
				break

		if not migration_ok:
			# 迁移失败：尝试用默认值回退，保证 Model 可用
			var defaults = _safe_get_defaults(model, model_name)
			if defaults == null:
				push_error("SaveKit|读档|Model %s 迁移失败且无默认值，跳过 set_data" % model_name)
				continue
			data = defaults
			saved_version = current_version

		# NOTE 版本超前：存档版本高于当前代码版本，原样使用
		if saved_version > current_version:
			push_warning("SaveKit|读档|Model %s 存档版本超前（%d > %d），原样使用" % [model_name, saved_version, current_version])

		# 默认值填充：补齐新增字段，避免老存档缺键
		if model.has_method("get_defaults"):
			var defaults = _safe_get_defaults(model, model_name)
			if defaults != null:
				for key in defaults:
					if not data.has(key):
						data[key] = defaults[key]

		# 调用 set_data：错误隔离，单个 Model 失败不影响其他 Model
		if not _safe_set_data(model, data, model_name):
			continue


# ---- 内部安全调用 ----
# NOTE 包裹 migrate 调用，捕获运行时异常与返回值类型错误
# 返回 null 表示失败；返回 Dictionary 表示成功
func _safe_migrate(model : Model, data : Dictionary, from_version : int, model_name : StringName) -> Variant:
	var migrated
	try:
		migrated = model.migrate(data, from_version)
	except e:
		push_error("SaveKit|读档|Model %s 的 migrate 抛出异常：%s" % [model_name, str(e)])
		return null
	if not migrated is Dictionary:
		push_error("SaveKit|读档|Model %s 的 migrate 未返回 Dictionary" % model_name)
		return null
	return migrated

# NOTE 包裹 get_defaults，返回 null 表示失败或未实现
func _safe_get_defaults(model : Model, model_name : StringName) -> Variant:
	if not model.has_method("get_defaults"):
		return null
	var defaults
	try:
		defaults = model.get_defaults()
	except e:
		push_error("SaveKit|读档|Model %s 的 get_defaults 抛出异常：%s" % [model_name, str(e)])
		return null
	if not defaults is Dictionary:
		push_warning("SaveKit|读档|Model %s 的 get_defaults 未返回 Dictionary" % model_name)
		return null
	return defaults.duplicate(true)

# NOTE 包裹 set_data 调用，捕获业务侧运行时异常
# 返回 true 表示成功，false 表示失败
func _safe_set_data(model : Model, data : Dictionary, model_name : StringName) -> bool:
	try:
		model.set_data(data)
		return true
	except e:
		push_error("SaveKit|读档|Model %s 的 set_data 抛出异常：%s" % [model_name, str(e)])
		return false


# ---- 校验工具 ----
func _validate_envelope(envelope : Variant, action : String) -> bool:
	if not envelope is Dictionary:
		push_error("SaveKit|%s|存档格式错误：根不是 Dictionary" % action)
		return false
	if not envelope.has("models"):
		push_error("SaveKit|%s|存档格式错误：缺少 models 字段" % action)
		return false
	if not envelope["models"] is Dictionary:
		push_error("SaveKit|%s|存档格式错误：models 不是 Dictionary" % action)
		return false
	return true

func _validate_entry(entry : Variant, model_name : StringName) -> bool:
	if not entry is Dictionary:
		push_error("SaveKit|读档|Model %s 的条目不是 Dictionary，跳过" % model_name)
		return false
	if not entry.has("version") or not entry.has("data"):
		push_error("SaveKit|读档|Model %s 的条目缺少 version 或 data 字段，跳过" % model_name)
		return false
	# NOTE 容忍 float → int（var_to_bytes 在某些情况下会恢复为 float）
	if entry["version"] is float:
		entry["version"] = int(entry["version"])
	elif not entry["version"] is int:
		push_error("SaveKit|读档|Model %s 的 version 不是 int，跳过" % model_name)
		return false
	if not entry["data"] is Dictionary:
		push_error("SaveKit|读档|Model %s 的 data 不是 Dictionary，跳过" % model_name)
		return false
	return true


# ---- 辅助方法 ----
# NOTE 判断指定路径的存档文件是否存在
func has_save(path : String) -> bool:
	if not _validate_path(path, "查询"):
		return false
	return FileAccess.file_exists(path)

# NOTE 获取存档元信息，不触发 set_data，适合在选档界面预览
func get_save_info(path : String) -> Dictionary:
	if not _validate_path(path, "查询"):
		return {}

	if not FileAccess.file_exists(path):
		push_warning("SaveKit|查询|文件不存在: " + path)
		return {}

	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SaveKit|查询|文件打开失败: " + path)
		return {}
	var bytes : PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	var envelope = bytes_to_var(bytes)

	if not _validate_envelope(envelope, "查询"):
		return {}

	return {
		"save_version": envelope.get("save_version", 1),
		"saved_at": envelope.get("saved_at", ""),
		"models": envelope["models"].keys()
	}
