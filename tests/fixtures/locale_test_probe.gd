extends RefCounted
## LocalizationKit 测试夹具：收集 LocaleChangedEvent，验证作用域内派发与跨作用域转发

var count : int = 0
var old_locale : StringName = &""
var new_locale : StringName = &""
## 设置后每次收到事件都把同一事件送回 Kit，用于验证转发防循环标志
var reenter_kit : LocalizationKit = null


func bind(arch : Architecture) -> void:
	arch.register_event(&"LocaleChangedEvent", _on_changed)


func _on_changed(event : LocaleChangedEvent) -> void:
	count += 1
	old_locale = event.old_locale
	new_locale = event.new_locale
	if reenter_kit != null:
		reenter_kit.send_event(event)
