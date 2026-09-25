// 把一张贴图裁成圆角矩形。
//
// 开屏页的头像框要用：`TextureRect` 能按"填满裁切"缩放图片，但裁出来是直角，
// 头像的四角会顶到圆角边框外面。`clip_contents` 也救不了——它只裁子节点，
// 不裁控件自己画的内容。
//
// 做法是圆角矩形的有向距离场：把 UV 映射到以中心为原点、半长为 1 的方框里，
// 算每个像素到这个圆角框边界的距离，正数在框外，直接抹掉。

shader_type canvas_item;

// 圆角半径，单位是"方框半长"的倍数：0.34 大约等于方形边长 17% 的圆角。
uniform float radius : hint_range(0.0, 1.0) = 0.34;
// 边缘柔化宽度，避免圆角处出现锯齿
uniform float softness : hint_range(0.0, 0.05) = 0.006;

void fragment() {
	vec2 q = abs(UV * 2.0 - 1.0);
	vec2 inner = vec2(1.0 - radius);
	float d = length(max(q - inner, vec2(0.0))) - radius;
	float alpha = 1.0 - smoothstep(-softness, softness, d);
	vec4 tex = texture(TEXTURE, UV);
	COLOR = vec4(tex.rgb, tex.a * alpha);
}
