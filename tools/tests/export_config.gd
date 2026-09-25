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
	_test_boot_splash()
	_test_back_button()
	_test_word_file()
	_test_build_scripts_ascii()
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

		# 同样只在真机上才暴露的一类问题：没有 INTERNET 权限就创建不了任何
		# socket，联网功能全线失败。Godot 新建预设时把所有权限都默认填 false。
		_check("开了 INTERNET 权限（联机必需）",
			bool(config.get_value(options, "permissions/internet", false)),
			"权限为 false 时，安卓上建房/加入都会失败")
		_check("开了网络状态权限",
			bool(config.get_value(options, "permissions/access_network_state", false)))

		# 启动时不该先闪一下 Godot 的引擎 logo。装到手机上尤其明显：
		# 先是引擎 logo，再是应用自己的浅色底，中间那一下很出戏。
		_check("安卓导出关掉了 Godot 启动图",
			bool(config.get_value(options, "splash_screen/disable_godot_boot_splash", false)),
			"关掉它，手机启动时才不会先闪引擎 logo")
		break

	_check("存在 Android 预设", found)


## 启动画面。项目里没配的话用的是 Godot 默认那张引擎 logo，
## 而应用的底是浅蓝紫——中间那一下非常突兀。
##
## 这里的断言是防回退：Godot 编辑器改 project.godot 时会整段重写，
## 手改的配置很容易被它悄悄抹掉。
func _test_boot_splash() -> void:
	print("\n-- 启动画面 --")
	_check("关掉了启动图（不显示 Godot logo）",
		not bool(ProjectSettings.get_setting("application/boot_splash/show_image", true)),
		"application/boot_splash/show_image")

	# 底色跟 app 里 LightTheme 的渐变起点一致，加载完接上去看不出接缝
	var bg: Color = ProjectSettings.get_setting("application/boot_splash/bg_color",
		Color.BLACK)
	_check("启动底色是浅色（不是默认的黑）",
		bg.r > 0.6 and bg.g > 0.6 and bg.b > 0.6, str(bg))


## Android 的返回键。默认行为是**按一下直接退出应用**，误触一下整个房间
## 就没了——这是只有装到手机上才会发现的一类问题，所以在构建配置里钉死。
##
## 关掉自动退出之后，返回键走的是 Window 的 go_back_requested 信号，
## 由 app.gd 沿界面栈往回走一层；那条链路的走法在 app_shell.gd 里测。
func _test_back_button() -> void:
	print("\n-- 返回键 --")
	_check("关掉了「按返回直接退出应用」",
		not bool(ProjectSettings.get_setting("application/config/quit_on_go_back", true)),
		"application/config/quit_on_go_back")


func _test_word_file() -> void:
	print("\n-- 词库 --")
	_check("词库文件存在", FileAccess.file_exists(WordBank.DEFAULT_PATH), WordBank.DEFAULT_PATH)

	var bank := WordBank.load_default()
	_check("词库能加载", bank.total() > 0, "%d 条" % bank.total())
	_check("至少 200 条", bank.total() >= 200, "%d 条" % bank.total())
	for difficulty in [1, 2, 3]:
		_check("难度 %d 有词条" % difficulty, bank.count_of(difficulty) > 0,
			"%d 条" % bank.count_of(difficulty))


## 构建脚本必须是纯 ASCII。
##
## Windows PowerShell 5.1 读 .ps1 时按系统 ANSI 代码页解码（无 BOM 的 UTF-8
## 也不例外），中文会变成乱码；更糟的是那种代码页是双字节的，
## 注释末尾半个汉字会把**换行符吞掉**，下一行代码直接进了注释，整个函数断掉。
##
## 这个坑我踩过三次，每次都是「知道规则但还是随手写了中文」，
## 所以改成机器盯着。
func _test_build_scripts_ascii() -> void:
	print("\n-- 构建脚本编码 --")
	var files := _find_files("res://tools", ".ps1")
	_check("找到了构建脚本", files.size() > 0, "%d 个" % files.size())

	var offenders := PackedStringArray()
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		for i in text.length():
			if text.unicode_at(i) > 127:
				offenders.append(path.get_file())
				break
	_check("所有 .ps1 都是纯 ASCII", offenders.is_empty(),
		"含非 ASCII 字符：" + ", ".join(offenders))


func _find_files(root: String, suffix: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full := root.path_join(entry)
			if dir.current_is_dir():
				out.append_array(_find_files(full, suffix))
			elif entry.ends_with(suffix):
				out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


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
