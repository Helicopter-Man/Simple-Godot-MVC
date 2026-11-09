extends Event
## 当前 locale 变更通知（1 对多）：UI / 逻辑侧据此刷新文本
class_name LocaleChangedEvent

var old_locale : StringName = &""
var new_locale : StringName = &""


func _init(_old_locale : StringName = &"", _new_locale : StringName = &"") -> void:
	old_locale = _old_locale
	new_locale = _new_locale
