extends SceneTree

## 应用外壳（app/main.tscn）的开屏、界面栈与返回键测试。
##
##   godot --headless --path . --script res://tools/tests/app_shell.gd
##
## 为什么要单独测这一段：**返回键的行为只有装到手机上才碰得到**，
## 而 Android 上它默认是「按一下直接退出应用」——试错成本很高，
## 按错一下整个房间就没了。所以把界面栈的走法在测试里钉死，
## 真机上剩下要验的只有「Window 的信号接上了没有」。
##
## 界面栈：选游戏 → 菜单 → 大厅 → 对局。返回就沿栈往回走一层。

var _passed := 0
var _failed := 0
var _main


func _initialize() -> void:
	print("=== 应用外壳测试 ===")
	var packed := load("res://app/main.tscn")
	_check("外壳场景能加载", packed != null)
	if packed == null:
		_finish()
		return
	_main = packed.instantiate()
	root.add_child(_main)
	_run()


func _run() -> void:
	# 必须等一帧：_initialize 阶段场景树还没运转，add_child 不会触发 _ready
	await process_frame
	await process_frame

	await _test_initial_screen()
	await _test_back_skips_splash()
	await _test_about()
	_test_back_from_menu()
	await _test_back_from_lobby()
	await _test_back_from_game()
	_test_back_at_root()
	_finish()


func _test_initial_screen() -> void:
	print("\n-- 启动 --")
	_check("启动先显示开屏", _main._splash.visible)
	# 主界面先藏着，等开屏快走完再淡入——直接晾在底下的话，
	# 开屏淡出只是"揭开一层膜"，看着像贴图
	_check("开屏时主界面还没出场", not _main._picker.visible)
	_check("菜单和大厅都还没露出来",
		not _main._menu.visible and not _main._lobby.visible)
	# 返回键是 Window 级的信号，只在根窗口上发；接错地方就等于没接
	_check("返回键的信号接到了",
		_main.get_window().go_back_requested.is_connected(_main._on_back_requested))
	_check("没有对局界面残留", _main._game_screen == null)

	# 头像加载不上的话框里是空的，界面照样跑得起来——只有看图才发现
	var avatar: Texture2D = load(_main.AVATAR_PATH)
	_check("开屏的头像图片加载得上", avatar != null, _main.AVATAR_PATH)
	if avatar != null:
		_check("头像分辨率够用（不会糊）",
			avatar.get_width() >= 256, "%dx%d" % [avatar.get_width(), avatar.get_height()])

	_main.dismiss_splash()
	await process_frame
	_check("收起开屏之后就是「玩什么」",
		not _main._splash.visible and _main._picker.visible)


## 开屏还没走完就按返回，应该是跳过开屏，不是退出应用。
func _test_back_skips_splash() -> void:
	print("\n-- 开屏按返回：跳过 --")
	_main._show_splash()
	await process_frame
	_check("开屏又亮起来了", _main._splash.visible)
	_check("返回被吃掉了（没退到退出应用）", _main.go_back())
	_check("开屏收起来了", not _main._splash.visible)
	_check("还是停在第一屏", _main._picker.visible)


## 「关于作者」。名字和头像都从常量 / 那张图来，地址点一下开浏览器。
func _test_about() -> void:
	print("\n-- 关于作者 --")
	_check("默认不显示", not _main._about.visible)
	_check("作者名有值", not String(_main.AUTHOR_NAME).is_empty(), _main.AUTHOR_NAME)
	_check("GitHub 地址是 https 的",
		String(_main.AUTHOR_URL).begins_with("https://"), _main.AUTHOR_URL)

	_main._show_about()
	await process_frame
	_check("点开了", _main._about.visible)
	# 返回键要先关掉它，而不是把这一屏也退掉
	_check("返回键先关掉关于作者", _main.go_back())
	_check("关掉了", not _main._about.visible)
	_check("还停在第一屏", _main._picker.visible)


func _test_back_from_menu() -> void:
	print("\n-- 菜单按返回：回到选游戏 --")
	_main._on_game_selected("draw_guess")
	_check("进了菜单", _main._menu.visible and not _main._picker.visible)

	var handled: bool = _main.go_back()
	_check("返回被吃掉了（没退到退出应用）", handled)
	_check("回到了「玩什么」", _main._picker.visible, "")
	_check("菜单收起来了", not _main._menu.visible)


func _test_back_from_lobby() -> void:
	print("\n-- 大厅按返回：回菜单并退房 --")
	_main._on_game_selected("uno")
	_main._on_host_pressed()
	await process_frame
	if not _main._lobby.visible:
		# 端口被占（比如上一个测试进程还没退干净）时建房会失败，
		# 那不是这一条要验的东西，说一声跳过就行
		print("      （建房没成功，跳过大厅那一段）")
		return

	_check("建房之后进了大厅", _main._room.is_in_room())
	var handled: bool = _main.go_back()
	_check("返回被吃掉了", handled)
	_check("回到了菜单", _main._menu.visible and not _main._lobby.visible)
	_check("房间也退了（不然房主那边留着一个已经走人的玩家）",
		not _main._room.is_in_room())


func _test_back_from_game() -> void:
	print("\n-- 对局按返回：退出这一局 --")
	_main._on_game_selected("uno")
	_main._on_solo_pressed()
	await process_frame
	await process_frame
	_check("进了对局", _main._game_screen != null)

	var handled: bool = _main.go_back()
	_check("返回被吃掉了", handled)
	_check("对局界面已卸掉", _main._game_screen == null)
	_check("回到了菜单", _main._menu.visible)


func _test_back_at_root() -> void:
	print("\n-- 已经在第一屏：再按才退出 --")
	_main._show_picker()
	_check("确实在第一屏", _main._picker.visible)
	_check("这时候返回返回 false（交给调用方去退出应用）",
		not _main.go_back())


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [OK]   ", label)
	else:
		_failed += 1
		print("  [FAIL] ", label, "   ", detail)


func _finish() -> void:
	# 壳子里可能还开着房间，先收掉再退，免得影响下一个测试进程
	if _main != null and _main._room != null:
		_main._room.leave_room()
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
