extends UiView
## UiKit 测试夹具：记录生命周期调用、可选绑定事件
class_name TestUiView

var enter_count : int = 0
var exit_count : int = 0
var received_events : int = 0
var last_params : Dictionary = {}

## 为真时在 _ui_enter 中绑定 TestUiEvent（用于验证离树自动解绑）
@export var bind_test_event : bool = false


func _ui_enter(params : Dictionary) -> void:
	enter_count += 1
	last_params = params
	if bind_test_event:
		bind_event(&"TestUiEvent", _on_test_event)


func _ui_exit() -> void:
	exit_count += 1


func _on_test_event(_event : Event) -> void:
	received_events += 1