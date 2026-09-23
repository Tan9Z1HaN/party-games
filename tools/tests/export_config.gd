extends SceneTree

## 构建配置检查。
##
## 这类问题有个共同点：**在编辑器里跑一切正常，装到手机上才炸**。
## 它们必须在这里被拦下来，而不是等导出安装之后靠肉眼发现。
##
##   godot --headless --path . --script res://tools/tests/export_config.gd

var _passed := 0
var _failed := 0


func _initialize() -> void:
	print("=== 导出配置检查 ===")
	_test_export_preset()
	_test_word_file()
	_finish()


func _test_export_preset() -> void:
	print("\n-- 导出预设 --")
	var config_path := "res://export_presets.cfg"
	_check("预设文件存在", FileAccess.file_exists(config_path), config_path)

	var config := ConfigFile.new()
	if config.load(config_path) != OK:
		_check("预设能解析", false)
		return
	_check("预设能解析", true)

	var found := false
	for section in config.get_sections():
		if not section.begins_with("preset.") or section.ends_with(".options"):
			continue
		if String(config.get_value(section, "platform", "")) != "Android":
			continue

		found = true

		# 这条是**功能性**的，不是可选项：
		# 词库是 .txt，Godot 不把它当资源，只有匹配 include_filter 才会被打进包。
		# 少了它，编辑器里一切正常，装到手机上一点「开始游戏」就直接结束。
		#
		# 注意 include_filter 在**预设级**（[preset.N]），不在 [preset.N.options] 里。
		var filter := String(config.get_value(section, "include_filter", ""))
		_check("include_filter 含 *.txt", filter.contains("*.txt"), "当前值：\"%s\"" % filter)

		var options := section + ".options"
		_check("含 x86_64 架构（模拟器要用）",
			bool(config.get_value(options, "architectures/x86_64", false)))
		_check("含 arm64-v8a 架构（真机要用）",
			bool(config.get_value(options, "architectures/arm64-v8a", false)))
		break

	_check("存在 Android 预设", found)


func _test_word_file() -> void:
	print("\n-- 词库 --")
	_check("词库文件存在", FileAccess.file_exists(WordBank.DEFAULT_PATH), WordBank.DEFAULT_PATH)

	var bank := WordBank.load_default()
	_check("词库能加载", bank.total() > 0, "%d 条" % bank.total())
	_check("至少 200 条", bank.total() >= 200, "%d 条" % bank.total())
	for difficulty in [1, 2, 3]:
		_check("难度 %d 有词条" % difficulty, bank.count_of(difficulty) > 0,
			"%d 条" % bank.count_of(difficulty))


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [OK]   ", label)
	else:
		_failed += 1
		print("  [FAIL] ", label, "   ", detail)


func _finish() -> void:
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
