extends Resource
# NOTE 服务配置：声明式定义 Architecture 的对外接口
# 在编辑器中创建 .tres 资源，填入要暴露的 Model/System/Utility 名称
# 赋值给 Architecture 的 service_config 属性即可
class_name ServiceConfig

# 暴露为服务的 Model 名称列表（服务名 = Model 名）
@export var models : Array[StringName] = []

# 暴露为服务的 System 名称列表
@export var systems : Array[StringName] = []

# 暴露为服务的 Utility 名称列表
@export var utilities : Array[StringName] = []

# 将 Architecture 自身作为服务暴露的名称（空则不暴露自身）
@export var self_name : StringName = &""
