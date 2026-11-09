extends LocalizationKit
## LocalizationKit 测试夹具：验证 _init_localization_kit 的代码注册路径

var hook_calls : int = 0


func _init_localization_kit() -> void:
	hook_calls += 1
	var ja := Translation.new()
	ja.locale = "ja"
	ja.add_message(&"greet", "こんにちは {name}")
	register_translation(ja)
