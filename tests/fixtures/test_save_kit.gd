extends SaveKit
## 测试夹具：在 _init_save_kit 中注册两个存档 Model，用于验证生命周期闭环

const _TestSaveModel := preload("res://tests/fixtures/test_save_model.gd")
const _LifecycleTestModel := preload("res://tests/fixtures/lifecycle_test_model.gd")

func _init_save_kit() -> void:
	register_saveable(_TestSaveModel.new())
	register_saveable(_LifecycleTestModel.new())