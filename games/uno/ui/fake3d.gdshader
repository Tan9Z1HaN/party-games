// 伪 3D 牌面：在 canvas_item 的 vertex/fragment 里自己做一遍透视投影，
// 让一张平面贴图看起来是绕竖轴/横轴转过去、带近大远小的。
//
// 做法来源：Hei 的 Godot4-Fake3D-Card-Game-UI-Demo（MIT 许可）。
//   原版：https://github.com/Fulafu-ai/Godot4-Fake3D-Card-Game-UI-Demo
// 相对原版改了两处：
//   1. 去掉「绿幕去背」。我们的牌面贴图本身带 alpha，不需要按颜色抠。
//   2. 用 tint 代替 modulate。canvas_item 的 fragment 里 COLOR 一开始是
//      「顶点色 × 贴图」，只要自己写 COLOR 就会把 modulate 丢掉；用一个显式的
//      tint 反而更好控制——投影/阴影就是靠同一个贴图配不同 tint 画出来的。
//
// 原理：顶点阶段把矩形撑大 2 倍（补偿下面的放大），同时算出每个顶点在
// 「虚拟相机」里的位置 p；片元阶段做透视除法 (p.xy / p.z)，把结果当成 UV
// 去采样贴图。z <= 0 说明这个面转到背面了，直接 discard。
//
// 注意 VERTEX 撑大后几何体是可见区域的 2 倍，超出的部分靠
// `step(max(abs(uv.x), abs(uv.y)), 0.5)` 把 alpha 抹成 0。

shader_type canvas_item;

// 虚拟相机的视场角。越小越"长焦"，透视压缩越弱
uniform float fov : hint_range(1, 179) = 90.0;
// 绕竖轴（左右转），-180~180
uniform float y_rot : hint_range(-180, 180) = 0.0;
// 绕横轴（上下仰合），-180~180
uniform float x_rot : hint_range(-180, 180) = 0.0;
// 转到背面时是否丢弃。牌背是靠另一张贴图 + y_rot-180 画的，所以开着
uniform bool cull_back = true;
// 0 时看起来尺寸不变；1 时把贴图缩进矩形内，留出全角度旋转的空间
uniform float inset : hint_range(0, 1) = 0.0;
// 颜色倍率。画阴影就是同一个贴图配 (0,0,0,0.2)
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

varying flat vec2 o;
varying vec3 p;


void vertex() {
	float sin_b = sin(y_rot / 180.0 * PI);
	float cos_b = cos(y_rot / 180.0 * PI);
	float sin_c = sin(x_rot / 180.0 * PI);
	float cos_c = cos(x_rot / 180.0 * PI);

	mat3 inv_rot_mat;
	inv_rot_mat[0][0] = cos_b;
	inv_rot_mat[0][1] = 0.0;
	inv_rot_mat[0][2] = -sin_b;
	inv_rot_mat[1][0] = sin_b * sin_c;
	inv_rot_mat[1][1] = cos_c;
	inv_rot_mat[1][2] = cos_b * sin_c;
	inv_rot_mat[2][0] = sin_b * cos_c;
	inv_rot_mat[2][1] = -sin_c;
	inv_rot_mat[2][2] = cos_b * cos_c;

	float t = tan(fov / 360.0 * PI);
	p = inv_rot_mat * vec3((UV - 0.5), 0.5 / t);
	float v = (0.5 / t) + 0.5;
	p.xy *= v * inv_rot_mat[2].z;
	o = v * inv_rot_mat[2].xy;

	VERTEX += (UV - 0.5) / TEXTURE_PIXEL_SIZE * t * (1.0 - inset);
}


void fragment() {
	if (cull_back && p.z <= 0.0) {
		discard;
	}
	vec2 uv = p.xy / p.z - o;
	vec4 tex = texture(TEXTURE, uv + 0.5);
	tex.a *= step(max(abs(uv.x), abs(uv.y)), 0.5);
	COLOR = tex * tint;
}
