extends RefCounted
## LocalizationKit 测试套件（headless / 代码构造 Translation）
## 约定：static func run(root: Node) -> Dictionary

const TestLocaleArch := preload("res://tests/fixtures/test_locale_arch.gd")
const TestLocaleKit := preload("res://tests/fixtures/test_locale_kit.gd")
const Probe := preload("res://tests/fixtures/locale_test_probe.gd")


static func run(root : Node) -> Dictionary:
	var cases : Array = []
	_run_registration(cases, root)
	_run_locale(cases, root)
	_run_lookup(cases, root)
	_run_formatting(cases, root)
	_run_forwarding(cases, root)
	_run_hook(cases, root)
	_run_lifecycle(cases, root)
	var failed : int = 0
	for c in cases:
		if not c["ok"]:
			failed += 1
	return {"suite": "LocalizationKit", "total": cases.size(), "failed": failed, "cases": cases}


# ==================== 注册 ====================
static func _run_registration(cases : Array, root : Node) -> void:
	var kit := _make(root)
	_check(cases, "register_translation(null) 返回 ERR_INVALID_PARAMETER", kit.register_translation(null) == ERR_INVALID_PARAMETER)
	var empty := Translation.new()
	empty.locale = ""
	_check(cases, "空 locale 的翻译表被拒绝", kit.register_translation(empty) == ERR_INVALID_PARAMETER)
	var en := _translation("en", {&"hello": "Hello"})
	_check(cases, "有效翻译表注册返回 OK", kit.register_translation(en) == OK)
	_check(cases, "重复 locale 注册返回 ERR_ALREADY_EXISTS", kit.register_translation(_translation("en", {&"x": "X"})) == ERR_ALREADY_EXISTS)
	_check(cases, "unregister_translation 已注册返回 OK", kit.unregister_translation(&"en") == OK)
	_check(cases, "unregister_translation 未注册返回 ERR_DOES_NOT_EXIST", kit.unregister_translation(&"en") == ERR_DOES_NOT_EXIST)
	_check(cases, "注销后可用同一 locale 重新注册", kit.register_translation(en) == OK)
	_dispose(root, kit)


# ==================== locale ====================
static func _run_locale(cases : Array, root : Node) -> void:
	var en := _translation("en", {&"greet": "Hello"})
	var zh := _translation("zh", {&"greet": "你好"})
	var kit := _make(root, [en, zh], &"en")
	var probe := Probe.new()
	probe.bind(kit)
	_check(cases, "默认 locale 在进树时应用", kit.get_locale() == &"en")
	_check(cases, "切换到未注册 locale 返回 ERR_DOES_NOT_EXIST", kit.try_set_locale(&"fr") == ERR_DOES_NOT_EXIST)
	_check(cases, "相同 locale 幂等返回 OK", kit.try_set_locale(&"en") == OK)
	_check(cases, "相同 locale 不派发事件", probe.count == 0)
	_check(cases, "切换已注册 locale 返回 OK", kit.try_set_locale(&"zh") == OK)
	_check(cases, "get_locale 读回新值", kit.get_locale() == &"zh")
	_check(cases, "切换派发一次事件", probe.count == 1)
	_check(cases, "事件 old / new 正确", probe.old_locale == &"en" and probe.new_locale == &"zh")
	_dispose(root, kit)


# ==================== 查表 ====================
static func _run_lookup(cases : Array, root : Node) -> void:
	var en := _translation("en", {&"greet": "Hello", &"only_en": "English only", &"k": "EN"})
	var zh := _translation("zh", {&"greet": "你好", &"only_zh": "仅中文"})
	var kit := _make(root, [en, zh], &"zh", [&"en"])
	_check(cases, "当前 locale 命中", kit.translate(&"greet") == "你好")
	_check(cases, "当前 locale 缺失时回退链命中", kit.translate(&"only_en") == "English only")
	_check(cases, "has_key 覆盖当前 locale", kit.has_key(&"only_zh"))
	_check(cases, "has_key 覆盖回退链", kit.has_key(&"only_en"))
	_check(cases, "has_key 对缺失 key 为假", not kit.has_key(&"missing"))
	_check(cases, "缺失 key 返回 key 本身", kit.translate(&"missing") == "missing")
	_check(cases, "缺失计数递增", kit.get_missing_total() == 1)
	kit.translate(&"missing")
	_check(cases, "再次缺失继续递增", kit.get_missing_total() == 2)

	var fr := _translation("fr", {&"k": "FR"})
	var kit2 := _make(root, [en, fr, zh], &"zh", [&"fr", &"en"])
	_check(cases, "回退链按声明顺序命中", kit2.translate(&"k") == "FR")
	kit2.unregister_translation(&"fr")
	_check(cases, "回退链前一环缺失后继续向后", kit2.translate(&"k") == "EN")

	var kit3 := _make(root, [en, zh], &"zh", [&"en"])
	_check(cases, "注销当前 locale 返回 OK", kit3.unregister_translation(&"zh") == OK)
	_check(cases, "注销后 locale 设置保留", kit3.get_locale() == &"zh")
	_check(cases, "注销后查表走回退链", kit3.translate(&"greet") == "Hello")

	var kit4 := _make(root, [en], &"", [&"en"])
	_check(cases, "未设置 locale 时回退链直接生效", kit4.translate(&"only_en") == "English only")

	_dispose(root, kit)
	_dispose(root, kit2)
	_dispose(root, kit3)
	_dispose(root, kit4)


# ==================== 格式化 ====================
static func _run_formatting(cases : Array, root : Node) -> void:
	var en := _translation("en", {
		&"greet": "Hi {name}, you are {age}",
		&"plain": "No placeholders",
	})
	var kit := _make(root, [en], &"en")
	_check(cases, "占位符按 args 替换且非字符串转 str", kit.translate(&"greet", {"name": "Ada", "age": 30}) == "Hi Ada, you are 30")
	_check(cases, "多余 args 被忽略", kit.translate(&"greet", {"name": "Ada"}) == "Hi Ada, you are {age}")
	_check(cases, "缺值占位符原样保留", kit.translate(&"greet", {"age": 7}) == "Hi {name}, you are 7")
	_check(cases, "无 args 时文本不变", kit.translate(&"plain") == "No placeholders")
	_check(cases, "缺失 key 加 args 仍返回 key", kit.translate(&"absent", {"x": 1}) == "absent")
	_dispose(root, kit)


# ==================== 事件转发 ====================
static func _run_forwarding(cases : Array, root : Node) -> void:
	var en := _translation("en", {&"greet": "Hello"})
	var zh := _translation("zh", {&"greet": "你好"})
	var arch := TestLocaleArch.new()
	root.add_child(arch)
	var kit := _make(root, [en, zh], &"en")
	kit.target_architecture = arch
	var probe := Probe.new()
	probe.bind(arch)
	_check(cases, "切换 locale 转发到 target_architecture", kit.try_set_locale(&"zh") == OK and probe.count == 1)
	_check(cases, "转发事件携带 old / new", probe.old_locale == &"en" and probe.new_locale == &"zh")

	probe.reenter_kit = kit
	_check(cases, "防循环标志阻止重复转发", kit.try_set_locale(&"en") == OK and probe.count == 2)
	probe.reenter_kit = null

	var arch2 := TestLocaleArch.new()
	root.add_child(arch2)
	var kit2 := _make(root, [en, zh], &"en")
	var probe2 := Probe.new()
	probe2.bind(arch2)
	_check(cases, "未配置 target 时不跨作用域转发", kit2.try_set_locale(&"zh") == OK and probe2.count == 0)

	_dispose(root, kit)
	_dispose(root, kit2)
	_free_node(root, arch)
	_free_node(root, arch2)


# ==================== 子类钩子 ====================
static func _run_hook(cases : Array, root : Node) -> void:
	var kit := TestLocaleKit.new()
	kit.default_locale = &"ja"
	root.add_child(kit)
	_check(cases, "_init_localization_kit 被调用一次", kit.hook_calls == 1)
	_check(cases, "hook 注册的翻译表可用于默认 locale", kit.get_locale() == &"ja")
	_check(cases, "hook 注册的翻译表可查表", kit.translate(&"greet", {"name": "Mika"}) == "こんにちは Mika")
	_dispose(root, kit)


# ==================== 生命周期 / 插拔 ====================
static func _run_lifecycle(cases : Array, root : Node) -> void:
	var registry := ServiceRegistry.new()
	var config := ServiceConfig.new()
	config.self_name = &"LocalizationKit"
	var kit := LocalizationKit.new()
	kit.default_locale = &""
	kit.service_config = config
	kit.shared_registry = registry
	root.add_child(kit)

	var arch := TestLocaleArch.new()
	arch.shared_registry = registry
	root.add_child(arch)
	_check(cases, "服务暴露到共享总线", arch.get_service(&"LocalizationKit") == kit)
	_check(cases, "LocalizationKit 自作用域可查 Model", kit.has_model(&"LocaleModel"))

	root.remove_child(kit)
	_check(cases, "deinit 后共享总线服务被注销", arch.get_service(&"LocalizationKit") == null)
	_check(cases, "deinit 后拒绝注册翻译表", kit.register_translation(_translation("en", {&"x": "X"})) == ERR_UNAVAILABLE)
	_check(cases, "deinit 后拒绝注销翻译表", kit.unregister_translation(&"en") == ERR_UNAVAILABLE)
	_check(cases, "deinit 后拒绝切换 locale", kit.try_set_locale(&"en") == ERR_UNAVAILABLE)
	_check(cases, "deinit 后 translate 回落到 key", kit.translate(&"x") == "x")
	_check(cases, "deinit 后 get_locale 为空", kit.get_locale() == &"")
	_check(cases, "deinit 后 missing_total 归零", kit.get_missing_total() == 0)
	_check(cases, "deinit 幂等", _safe_deinit(kit))

	var kit_a := _make(root, [_translation("en", {&"k": "A"})], &"en")
	var kit_b := _make(root, [], &"")
	_check(cases, "不同 Kit 的翻译表互不可见", kit_b.try_set_locale(&"en") == ERR_DOES_NOT_EXIST)
	_check(cases, "两个 Kit 可各自独立起停", kit_a.get_locale() == &"en" and kit_b.get_locale() == &"")

	_dispose(root, kit_a)
	_dispose(root, kit_b)
	kit.free()
	_free_node(root, arch)


# ==================== 工具 ====================
static func _make(root : Node, list : Array = [], default_locale : StringName = &"", fallbacks : Array = []) -> LocalizationKit:
	var kit := LocalizationKit.new()
	kit.default_locale = default_locale
	kit.translations.assign(list)
	kit.fallback_locales.assign(fallbacks)
	root.add_child(kit)
	return kit


static func _translation(locale_name : String, messages : Dictionary) -> Translation:
	var translation := Translation.new()
	translation.locale = locale_name
	for key : Variant in messages:
		translation.add_message(StringName(key), StringName(str(messages[key])))
	return translation


static func _safe_deinit(kit : LocalizationKit) -> bool:
	kit.deinit()
	kit.deinit()
	return true


static func _dispose(root : Node, kit : LocalizationKit) -> void:
	if kit == null:
		return
	if kit.get_parent() != null:
		root.remove_child(kit)
	kit.free()


static func _free_node(root : Node, node : Node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		root.remove_child(node)
	node.free()


static func _check(cases : Array, name : String, ok : bool, detail : String = "") -> void:
	cases.append({"name": name, "ok": ok, "detail": detail})
