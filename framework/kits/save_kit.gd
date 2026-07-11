extends Architecture
# NOTE 存档套件：基于 Architecture 的 IoC 容器，只接受实现了 get_data/set_data 的 Model
# 负责 序列化/反序列化 存档信封，支持版本迁移链与默认值填充
class_name SaveKit


# ---- 注册覆写：限制可注册类型 ----
# NOTE SaveKit 只接受 Model，且 Model 必须实现 get_data / set_data 接口
func register_model(model : Model) -> void:
	if not (model.has_method("get_data") and model.has_method("set_data")):
		push_error("SaveKit|注册|Model %s 未实现 get_data/set_data 接口" % model.get_script_name())
		return
	super.register_model(model)

# NOTE SaveKit 不接受 System / Utility，直接拒绝
func register_system(_system : System) -> void:
	push_error("SaveKit|注册|SaveKit 不接受 System")
	return

func register_utility(_utility : Utility) -> void:
	push_error("SaveKit|注册|SaveKit 不接受 Utility")
	return


# ---- 保存：将所有 Model 的数据序列化为存档信封 ----
func save(path: String) -> void:
	# 校验路径合法性
	if not path.begins_with("user://"):
		push_error("SaveKit|保存|路径非法，确保路径使用 user:// 目录")
		return

	# NOTE 信封结构：版本号 + 保存时间 + 各 Model 数据
	var envelope : Dictionary = {
		"save_version": 1,
		"saved_at": Time.get_datetime_string_from_system(),
		"models": {}
	}

	for model_name : StringName in _model_dic:
		var model : Model = _model_dic[model_name]
		var data = model.get_data()
		# NOTE 若 Model 实现 get_version 则采用其返回值，否则默认 1
		var version : int = 1
		if model.has_method("get_version"):
			version = model.get_version()
		# NOTE 键转为 String，便于反序列化后按字符串遍历再转 StringName 查找
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
func load(path: String) -> void:
	# 校验路径合法性
	if not path.begins_with("user://"):
		push_error("SaveKit|读档|路径非法，确保路径使用 user:// 目录")
		return

	# 校验文件存在
	if not FileAccess.file_exists(path):
		push_warning("SaveKit|读档|文件不存在: " + path)
		return

	# 读取字节流并反序列化
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SaveKit|读档|文件打开失败: " + path)
		return
	var bytes : PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	var envelope = bytes_to_var(bytes)

	# 校验信封格式
	if not envelope is Dictionary or not envelope.has("models"):
		push_error("SaveKit|读档|存档格式错误")
		return

	# NOTE 遍历信封中的每个 Model 条目，按需迁移并填充默认值
	for model_name in envelope["models"]:
		var model : Model = _model_dic.get(StringName(model_name))
		if model == null:
			push_warning("SaveKit|读档|Model %s 未注册，跳过" % model_name)
			continue

		var entry : Dictionary = envelope["models"][model_name]
		var saved_version : int = entry["version"]
		var data = entry["data"]

		# 当前 Model 的版本号
		var current_version : int = 1
		if model.has_method("get_version"):
			current_version = model.get_version()

		# NOTE 迁移链：逐版本向上迁移，直到追上当前版本
		while saved_version < current_version:
			if model.has_method("migrate"):
				data = model.migrate(data, saved_version)
				saved_version += 1
			else:
				push_warning("SaveKit|读档|Model %s 需要迁移但未实现 migrate" % model_name)
				break

		# NOTE 版本超前：存档版本高于当前代码版本，原样使用
		if saved_version > current_version:
			push_warning("SaveKit|读档|Model %s 存档版本超前（%d > %d），原样使用" % [model_name, saved_version, current_version])

		# NOTE 默认值填充：补齐新增字段，避免老存档缺键
		if model.has_method("get_defaults"):
			var defaults = model.get_defaults()
			for key in defaults:
				if not data.has(key):
					data[key] = defaults[key]

		model.set_data(data)


# ---- 辅助方法 ----
# NOTE 判断指定路径的存档文件是否存在
func has_save(path: String) -> bool:
	if not path.begins_with("user://"):
		push_error("SaveKit|查询|路径非法，确保路径使用 user:// 目录")
		return false
	return FileAccess.file_exists(path)

# NOTE 获取存档元信息，不触发 set_data，适合在选档界面预览
func get_save_info(path: String) -> Dictionary:
	if not path.begins_with("user://"):
		push_error("SaveKit|查询|路径非法，确保路径使用 user:// 目录")
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

	if not envelope is Dictionary or not envelope.has("models"):
		push_warning("SaveKit|查询|存档格式错误: " + path)
		return {}

	return {
		"save_version": envelope["save_version"],
		"saved_at": envelope["saved_at"],
		"models": envelope["models"].keys()
	}
