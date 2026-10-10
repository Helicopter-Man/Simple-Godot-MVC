extends Kit
## 容器型扩展模块：版本化整体存档
## 承载实现了 get_data / set_data 接口的 Model；复用 Architecture 的总线、生命周期与服务暴露
class_name SaveKit


# ---- 生命周期：子类重写 _init_save_kit() 注册存档 Model ----
func _init_save_kit() -> void:
	pass


func _init_architecture() -> void:
	_init_save_kit()


# ---- 路径安全校验（本模块内部）----
func _validate_path(path : String) -> Error:
	# 必须以 user:// 开头，防止误写工程目录或绝对路径
	if not path.begins_with("user://"):
		push_error("SaveKit|路径非法，必须以 user:// 开头: %s" % path)
		return ERR_INVALID_PARAMETER
	# 规范化分隔符，防止反斜杠绕过分段校验
	var normalized : String = path.replace("\\", "/")
	for part in normalized.split("/"):
		# 禁止 .. 穿越（如 user://../saves 会越界到工程根目录上层）
		if part == "..":
			push_error("SaveKit|路径非法，禁止使用 .. 进行目录穿越: %s" % path)
			return ERR_INVALID_PARAMETER
	return OK


# ---- 注册 / 注销 ----
## 注册一个可存档 Model（须实现 get_data / set_data）
## ERR_INVALID_PARAMETER：实例为空或接口缺失；其余经 register_model 复用（含键校验、去重、生命周期）
func register_saveable(model : Model) -> Error:
	if model == null:
		push_error("SaveKit|注册|Model 实例为 null")
		return ERR_INVALID_PARAMETER
	if not (model.has_method("get_data") and model.has_method("set_data")):
		push_error("SaveKit|注册|Model %s 未实现 get_data/set_data 接口" % model.get_script_name())
		return ERR_INVALID_PARAMETER
	return register_model(model)


func unregister_saveable(model_name : StringName) -> Error:
	return unregister_model(model_name)


# ---- 保存：将所有存档 Model 数据序列化为存档信封 ----
## 路径非法返回 ERR_INVALID_PARAMETER；文件打开失败返回 ERR_CANT_OPEN；成功返回 OK
func save(path : String) -> Error:
	var err : Error = _validate_path(path)
	if err != OK:
		return err

	# NOTE 信封结构：版本号 + 保存时间 + 各 Model 数据
	var envelope : Dictionary = {
		"save_version": 1,
		"saved_at": Time.get_datetime_string_from_system(),
		"models": {}
	}

	for model_name : StringName in _model_dic:
		var model : Model = _model_dic[model_name]
		# NOTE 本模块只应注册可存档 Model；对经 register_model 混入的对象做防御性跳过
		if not model.has_method("get_data"):
			continue
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
		return ERR_CANT_OPEN
	file.store_buffer(bytes)
	file.close()
	return OK


# ---- 读档：反序列化信封并执行版本迁移链 + 默认值填充 ----
## ERR_FILE_NOT_FOUND：文件不存在（预期失败，不写日志）；ERR_INVALID_DATA：信封格式非法
func load(path : String) -> Error:
	var err : Error = _validate_path(path)
	if err != OK:
		return err

	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND

	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SaveKit|读档|文件打开失败: " + path)
		return ERR_CANT_OPEN
	var bytes : PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	var envelope = bytes_to_var(bytes)

	# 校验信封格式
	if not _validate_envelope(envelope, "读档"):
		return ERR_INVALID_DATA

	var models_dict : Dictionary = envelope["models"]
	for model_name in models_dict:
		var model : Model = _model_dic.get(StringName(model_name))
		if model == null:
			push_warning("SaveKit|读档|Model %s 未注册，跳过" % model_name)
			continue
		if not model.has_method("set_data"):
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

	return OK


# ---- 内部安全调用 ----
# NOTE GDScript 不支持 try/except，统一通过 has_method 做能力探测后再调用
# 包裹 migrate 调用，校验返回值类型
# 返回 null 表示失败；返回 Dictionary 表示成功
func _safe_migrate(model : Model, data : Dictionary, from_version : int, model_name : StringName) -> Variant:
	if not model.has_method("migrate"):
		push_warning("SaveKit|读档|Model %s 未实现 migrate" % model_name)
		return null
	var migrated : Variant = model.migrate(data, from_version)
	if not migrated is Dictionary:
		push_error("SaveKit|读档|Model %s 的 migrate 未返回 Dictionary" % model_name)
		return null
	return migrated

# NOTE 包裹 get_defaults，返回 null 表示失败或未实现
func _safe_get_defaults(model : Model, model_name : StringName) -> Variant:
	if not model.has_method("get_defaults"):
		return null
	var defaults : Variant = model.get_defaults()
	if not defaults is Dictionary:
		push_warning("SaveKit|读档|Model %s 的 get_defaults 未返回 Dictionary" % model_name)
		return null
	return defaults.duplicate(true)

# NOTE 包裹 set_data 调用
# 返回 true 表示成功，false 表示未实现
func _safe_set_data(model : Model, data : Dictionary, model_name : StringName) -> bool:
	if not model.has_method("set_data"):
		push_error("SaveKit|读档|Model %s 未实现 set_data" % model_name)
		return false
	model.set_data(data)
	return true


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
# NOTE 判断指定路径的存档文件是否存在（路径非法时返回 false）
func has_save(path : String) -> bool:
	return _validate_path(path) == OK and FileAccess.file_exists(path)

# NOTE 获取存档元信息，不触发 set_data，适合在选档界面预览；失败返回空字典
func get_save_info(path : String) -> Dictionary:
	if _validate_path(path) != OK:
		return {}

	if not FileAccess.file_exists(path):
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
