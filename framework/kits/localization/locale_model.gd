extends Model
## LocalizationKit 的数据层：当前 locale / 已注册翻译表 / 回退链 / 缺失计数
## 纯数据，不持有节点、不发事件；查表与格式化由 Kit 门面驱动
class_name LocaleModel

var locale : StringName = &""
## locale -> Translation（locale 比较严格区分大小写，不做前缀匹配）
var translations : Dictionary[StringName, Translation] = {}
## 回退顺序：由 Kit 在进入场景树时从导出配置同步
var fallback_locales : Array[StringName] = []
## translate 未命中的累计次数，供诊断与测试断言
var missing_total : int = 0


func get_translation(locale_name : StringName) -> Translation:
	return translations.get(locale_name)


func has_translation(locale_name : StringName) -> bool:
	return translations.has(locale_name)
