class_name UnoCard2D
extends Node2D

## 一张 UNO 牌。
##
## 牌面是 UnoCardPainter 画的、被 UnoCardArt 烘成的贴图；
## 伪 3D 是 fake3d.gdshader 在 canvas_item 里做的真透视投影。
##
## 三张贴图（正面 / 牌背 / 阴影）共用同一个 shader，只是 y_rot 差 180 度、
## tint 不一样。阴影就是「同一张牌面涂黑」——形状天然吻合，不用另画一张。
##
## 对外只暴露三件事：显示哪张牌、在扇形里的姿态、有没有被选中。
## 具体位置由牌桌算好传进来，牌自己不猜上下文。
##
## **y_rot 不要超过 ±70 度**：这个 shader 在接近侧对镜头时 z 趋近 0，
## 透视除法会把牌拉成一条巨大的竖条。实测 70 度以内都好看，
## 90 度直接消失，135 度会炸开。

const SIZE := Vector2(148, 216)
const SHADER: Shader = preload("res://games/uno/ui/fake3d.gdshader")

## 选中时抬起来的高度和放大倍率。
const LIFT_HEIGHT := 56.0
const LIFT_SCALE := 1.14

## 阴影的偏移量和浓度。偏移在牌的本地坐标里，会跟着牌一起转。
const SHADOW_OFFSET := Vector2(5, 8)
const SHADOW_ALPHA := 0.20

var card := -1
var face_up := true
var lifted := false

## 绕横轴（上下仰合）。给牌堆一点"躺在桌上"的斜度。
var perspective_x := 0.0: set = set_perspective_x
## 绕竖轴（左右转）。扇形的每张牌靠这个错开。
var perspective_y := 0.0: set = set_perspective_y

var _shadow: Sprite2D
var _back: Sprite2D
var _front: Sprite2D

## 扇形基准姿态，set_fan_pose 只改这几个；选中时在它们之上叠加位移。
var _base_position := Vector2.ZERO
var _base_rotation := 0.0
var _base_scale := Vector2.ONE
var _base_px := 0.0
var _base_py := 0.0
var _base_z := 60


func _init() -> void:
	_shadow = _make_sprite(Color(0, 0, 0, SHADOW_ALPHA))
	_shadow.position = SHADOW_OFFSET
	add_child(_shadow)
	_back = _make_sprite(Color(1, 1, 1, 1))
	add_child(_back)
	_front = _make_sprite(Color(1, 1, 1, 1))
	add_child(_front)
	_refresh_textures()


func _make_sprite(tint_color: Color) -> Sprite2D:
	var node := Sprite2D.new()
	node.centered = true
	# 牌在小屏上会被缩着画，不开 mipmap 的话边缘会闪
	node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("tint", tint_color)
	# 关掉背面剔除。默认开着时，牌背那一张（y_rot 被减了 180 度）永远
	# 处于背面，整张牌会只剩阴影——牌背之前就是一块灰方块。
	# 反正摆牌的角度都控制在安全范围内，见文件头的说明。
	material.set_shader_parameter("cull_back", false)
	node.material = material
	return node


# ---------------------------------------------------------------- 牌面

func set_card(value: int, revealed := true) -> void:
	card = value
	face_up = revealed
	_refresh_textures()


## 三张精灵是不是都拿到贴图了。测试用来挡住「牌画成一块灰方块」这类回归。
func texture_ready() -> bool:
	return _front.texture != null and _back.texture != null and _shadow.texture != null


func _refresh_textures() -> void:
	var front_tex := UnoCardArt.texture_of(card, true)
	var back_tex := UnoCardArt.texture_of(-1, false)
	_front.texture = front_tex
	_back.texture = back_tex
	_shadow.texture = front_tex if face_up else back_tex
	_front.visible = face_up
	_back.visible = not face_up


func set_perspective_x(value: float) -> void:
	perspective_x = value
	_push_perspective()


func set_perspective_y(value: float) -> void:
	perspective_y = value
	_push_perspective()


## 三张精灵共用同一个姿态。哪一张显示由 _refresh_textures 决定，
## 所以这里不给牌背额外转 180 度——那样它会翻到背面被剔除掉。
func _push_perspective() -> void:
	for sprite in [_shadow, _back, _front]:
		sprite.material.set_shader_parameter("x_rot", perspective_x)
		sprite.material.set_shader_parameter("y_rot", perspective_y)


# ---------------------------------------------------------------- 姿态

## 直接摆到一个绝对姿态。牌堆、牌背这种"一张牌自己待着"的地方用它。
func place_at(pos: Vector2, rot_z: float, x_rot: float, y_rot: float,
		size_scale := 1.0, z := 5) -> void:
	_base_position = pos
	_base_rotation = rot_z
	_base_scale = Vector2(size_scale, size_scale)
	_base_px = x_rot
	_base_py = y_rot
	_base_z = z
	snap_to_pose()


## 摆成手牌扇形的第 offset 格。offset 为 0 是正中那张。
##
## 参数集中在一个字典里，方便对着参考项目调手感：
##   origin   扇形中心点的绝对位置
##   spacing  每格横向间距
##   spread   每格绕 Z 轴转多少弧度
##   arc      越靠边往下掉多少（做成一个微微上拱的扇面）
##   turn     每格绕竖轴转多少度，伪 3D 的"越靠边越转过去"
##   tilt     整把牌绕横轴的仰角
##   scale    牌的整体缩放
func set_fan_pose(offset: float, cfg: Dictionary = {}) -> void:
	var origin: Vector2 = cfg.get("origin", Vector2.ZERO)
	var spacing: float = cfg.get("spacing", 92.0)
	var spread: float = cfg.get("spread", 0.052)
	var arc: float = cfg.get("arc", 12.0)
	var turn: float = cfg.get("turn", 8.0)
	var tilt: float = cfg.get("tilt", 0.0)
	var size_scale: float = cfg.get("scale", 1.0)

	_base_position = origin + Vector2(offset * spacing, absf(offset) * arc)
	_base_rotation = offset * spread
	_base_scale = Vector2(size_scale, size_scale)
	_base_px = tilt
	# 右边的牌右边缘往里收，左边的牌左边缘往里收 —— 扇形才是"放射"出去的
	_base_py = offset * turn
	# 中间的牌压在两边的上面，扇形才立得住
	_base_z = int(60 - absf(offset) * 6.0)
	snap_to_pose()


## 选中时抬起来：整体上移 + 放大 + 摆正，让玩家一眼看出选的是哪张。
func set_lifted(value: bool, animate := true) -> void:
	if lifted == value:
		return
	lifted = value
	if not animate:
		snap_to_pose()
		return

	var target := _lifted_pose()
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.set_parallel(true)
	tween.tween_property(self, "position", target["position"], 0.16)
	tween.tween_property(self, "rotation", target["rotation"], 0.16)
	tween.tween_property(self, "scale", target["scale"], 0.16)
	tween.tween_property(self, "perspective_x", target["px"], 0.16)
	tween.tween_property(self, "perspective_y", target["py"], 0.16)
	z_index = target["z"]


## 立刻套上姿态，不走动画。布局重排时用（比如刚发完牌）。
func snap_to_pose() -> void:
	var target := _lifted_pose()
	position = target["position"]
	rotation = target["rotation"]
	scale = target["scale"]
	perspective_x = target["px"]
	perspective_y = target["py"]
	z_index = target["z"]


func _lifted_pose() -> Dictionary:
	if lifted:
		return {
			"position": _base_position + Vector2(0, -LIFT_HEIGHT),
			"rotation": 0.0,
			"scale": _base_scale * LIFT_SCALE,
			"px": 0.0,
			"py": 0.0,
			"z": 90,
		}
	return {
		"position": _base_position,
		"rotation": _base_rotation,
		"scale": _base_scale,
		"px": _base_px,
		"py": _base_py,
		"z": _base_z,
	}
