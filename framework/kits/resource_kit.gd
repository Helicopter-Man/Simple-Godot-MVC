extends Resource
## 一个简单的存储特定的Resource到特定位置的工具
class_name ResourceKit

static func resource_save(resource : Resource,save_path : String) -> void:
	# 确保路径使用 user:// 目录
	if not save_path.begins_with("user://"):
		push_error("ResourceKit|资源保存|路径非法，确保路径使用 user:// 目录")
		return
	# 确保路径末尾有文件名 .tres
	if not save_path.ends_with(".tres"):
		push_error("ResourceKit|资源保存|路径非法，确保文件后缀使用 .tres")
		return

	# 确保路径存在
	var dir = DirAccess.open("user://")
	var dir_path = save_path.get_base_dir().replace("user://", "")
	for part in dir_path.split("/"):
		if part != "":
			if not dir.dir_exists(part):
				if dir.make_dir(part) != OK:
					return
			dir = DirAccess.open(dir.get_current_dir().path_join(part))

	ResourceSaver.save(resource,save_path)

static func resource_load(save_path : String) -> Resource:
	# 确保路径使用 user:// 目录
	if not save_path.begins_with("user://"):
		push_error("ResourceKit|资源读取|路径非法，确保路径使用 user:// 目录")
		return null
	# 确保路径末尾有文件名 .tres
	if not save_path.ends_with(".tres"):
		push_error("ResourceKit|资源读取|路径非法，确保文件后缀使用 .tres")
		return null

	# 检查文件是否存在
	if not FileAccess.file_exists(save_path):
		push_warning("ResourceKit|资源读取|文件不存在" + save_path)
		return null

	# NOTE 深拷贝，防止直接使用资源文件
	var resource: Resource = load(save_path)

	if resource:
		resource = resource.duplicate(true)

	return resource
