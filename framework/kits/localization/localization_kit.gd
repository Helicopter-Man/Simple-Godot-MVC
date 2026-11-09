extends Kit
## 容器型扩展：作用域化本地化查表
##
## 自持翻译表实例，不依赖全局 TranslationServer，也不调用 tr()：
## 业务经服务总线取 Kit，用 translate(key, args) 查表；locale 切换发
## LocaleChangedEvent，需要业务作用域收到时配置 target_architecture 转发。
##
## 场景树中与业务 Architecture 平级，赋同一个 shared_registry，
## service_config.self_name = &"LocalizationKit" 即可被业务侧查到。
class_name LocalizationKit

# ==================== 可配置 ====================
## 默认 locale：进入场景树时自动尝试应用；未注册对应翻译表时仅 warning
@export var default_locale : StringName = &"en"
## 回退链：当前 locale 未命中时按序尝试，全部缺失才落到 key 本身
@export var fallback_locales : Array[StringName] = []
## 声明式翻译表：编辑器导入的 .translation，也可在 _init_localization_kit() 里代码注册
@export var translations : Array[Translation] = []
## 事件转发目标：事件总线按 Architecture 隔离，业务作用域需显式指定
@export var target_architecture : Architecture

var _forwarding : bool = false


# ==================== 生命周期 ====================
## 子类重写：在此用代码注册翻译表；此时 LocaleModel 已就绪
func _init_localization_kit() -> void:
	pass


func _init_architecture() -> void:
	var model := LocaleModel.new()
	model.fallback_locales.assign(fallback_locales)
	register_model(model)


# NOTE 配置应用延后到 _ready() 末尾，保证 Model 已完成 _on_init
func _ready() -> void:
	super._ready()
	_bootstrap()


func _bootstrap() -> void:
	register_event(&"LocaleChangedEvent", _on_locale_changed)
	for translation : Translation in translations:
		if translation == null:
			continue
		var result : Error = register_translation(translation)
		if result != OK:
			push_warning("LocalizationKit|声明式注册|locale %s 注册失败，错误码 %d" % [translation.locale, result])
	_init_localization_kit()
	if default_locale != &"" and try_set_locale(default_locale) != OK:
		push_warning("LocalizationKit|默认 locale|%s 未注册翻译表，保持未设置" % default_locale)


# ==================== 内部访问器 ====================
func _model() -> LocaleModel:
	return get_model(&"LocaleModel") as LocaleModel


# ==================== 翻译表注册 ====================
## 注册一个 Translation；locale 取自 translation.locale
func register_translation(translation : Translation) -> Error:
	if _deinited:
		return ERR_UNAVAILABLE
	var model := _model()
	if model == null:
		return ERR_UNAVAILABLE
	if translation == null:
		return ERR_INVALID_PARAMETER
	var locale_name := StringName(translation.locale)
	if locale_name == &"":
		return ERR_INVALID_PARAMETER
	if model.translations.has(locale_name):
		return ERR_ALREADY_EXISTS
	model.translations[locale_name] = translation
	return OK


## 注销某 locale 的翻译表；注销当前 locale 时保留 locale 设置，查表走回退链
func unregister_translation(locale_name : StringName) -> Error:
	if _deinited:
		return ERR_UNAVAILABLE
	var model := _model()
	if model == null:
		return ERR_UNAVAILABLE
	if not model.translations.has(locale_name):
		return ERR_DOES_NOT_EXIST
	model.translations.erase(locale_name)
	return OK


# ==================== locale ====================
## 切换当前 locale：目标 locale 必须已注册翻译表；相同值幂等且不发事件
func try_set_locale(locale_name : StringName) -> Error:
	if _deinited:
		return ERR_UNAVAILABLE
	var model := _model()
	if model == null:
		return ERR_UNAVAILABLE
	if not model.translations.has(locale_name):
		return ERR_DOES_NOT_EXIST
	if model.locale == locale_name:
		return OK
	var old_locale := model.locale
	model.locale = locale_name
	send_event(LocaleChangedEvent.new(old_locale, locale_name))
	return OK


func get_locale() -> StringName:
	var model := _model()
	return &"" if model == null else model.locale


# ==================== 查表 ====================
## 当前 locale → fallback_locales 依次 → key 本身；args 做 {name} 占位符替换
func translate(key : StringName, args : Dictionary = {}) -> String:
	var model := _model()
	if model == null:
		return String(key)
	var text := _find_message(model, key)
	if text.is_empty():
		model.missing_total += 1
		return String(key)
	return _format(text, args)


## 当前 locale 或回退链中任一命中即为真
func has_key(key : StringName) -> bool:
	var model := _model()
	return model != null and not _find_message(model, key).is_empty()


func get_missing_total() -> int:
	var model := _model()
	return 0 if model == null else model.missing_total


# NOTE 空译文等同未命中，与 Godot tr() 的缺省回退语义一致
func _find_message(model : LocaleModel, key : StringName) -> String:
	if model.locale != &"":
		var current := _lookup(model, model.locale, key)
		if not current.is_empty():
			return current
	for fallback : StringName in model.fallback_locales:
		if fallback == model.locale:
			continue
		var message := _lookup(model, fallback, key)
		if not message.is_empty():
			return message
	return ""


func _lookup(model : LocaleModel, locale_name : StringName, key : StringName) -> String:
	var translation := model.get_translation(locale_name)
	if translation == null:
		return ""
	return String(translation.get_message(key))


## 只替换文本中实际出现的占位符：多余 args 忽略，缺值占位符原样保留
func _format(text : String, args : Dictionary) -> String:
	if args.is_empty():
		return text
	var result := text
	for arg_name : Variant in args:
		result = result.replace("{%s}" % str(arg_name), str(args[arg_name]))
	return result


# ==================== 事件转发（事件总线按 Architecture 隔离）====================
func _on_locale_changed(event : LocaleChangedEvent) -> void:
	_forward(event)


func _forward(event : Event) -> void:
	if _forwarding:
		return
	var arch : Architecture = target_architecture
	if arch == null or not is_instance_valid(arch) or arch == self:
		return
	_forwarding = true
	arch.send_event(event)
	_forwarding = false
