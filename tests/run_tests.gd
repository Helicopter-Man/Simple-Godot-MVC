extends SceneTree
## 测试入口（headless CLI）
##
## 运行：
##   Godot_v4.7-stable_win64_console.exe --headless --path <项目根> --script res://tests/run_tests.gd
##
## 约定：每个测试套件脚本暴露
##   static func run(root: Node) -> Dictionary
##   返回 {"suite": String, "total": int, "failed": int, "cases": Array}
##
## 本入口汇总所有套件，打印 TEST_REPORT 起止标记之间的 JSON，并按失败数设置退出码（0=全通过）。

const SUITES : Array = [
	preload("res://tests/save_kit_test.gd"),
	preload("res://tests/ui_kit_test.gd"),
]


func _initialize() -> void:
	# 在首帧执行：此时 SceneTree 已启动、root 已进树，add_child 才会触发 _ready
	process_frame.connect(_run_all, CONNECT_ONE_SHOT)


func _run_all() -> void:
	var total := 0
	var failed := 0
	var suites : Array = []
	for suite in SUITES:
		var r : Dictionary = suite.run(root)
		total += int(r.get("total", 0))
		failed += int(r.get("failed", 0))
		suites.append(r)

	var report := {
		"total": total,
		"passed": total - failed,
		"failed": failed,
		"suites": suites,
	}
	var text := JSON.stringify(report, "  ")
	print("TEST_REPORT_BEGIN")
	print(text)
	print("TEST_REPORT_END")

	# 落盘一份，便于无控制台时读取
	var f := FileAccess.open("res://tests/_report.json", FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()

	quit(1 if failed > 0 else 0)