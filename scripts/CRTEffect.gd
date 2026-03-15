extends Node
## CRTEffect -- Full-screen CRT post-processing overlay.
## Autoload singleton. Toggle with CRTEffect.enabled = true/false or V key.

var enabled: bool = false:
	set(value):
		enabled = value
		if _overlay:
			_overlay.visible = value

var _canvas_layer: CanvasLayer
var _overlay: ColorRect

func _ready() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 100
	add_child(_canvas_layer)

	_overlay = ColorRect.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var shader := Shader.new()
	shader.code = _get_shader_code()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_overlay.material = mat
	_canvas_layer.add_child(_overlay)
	_overlay.visible = enabled

func _get_shader_code() -> String:
	return """
shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

void fragment() {
	vec2 uv = SCREEN_UV;

	// Barrel distortion (subtle CRT curvature)
	vec2 center = uv - 0.5;
	float dist = dot(center, center);
	uv = uv + center * dist * 0.04;

	// Clamp UV to avoid sampling outside screen after distortion
	vec2 uv_clamped = clamp(uv, 0.0, 1.0);

	// Chromatic aberration -- slight RGB offset
	float aberration = 0.001;
	float r = texture(screen_texture, clamp(uv + vec2(aberration, 0.0), 0.0, 1.0)).r;
	float g = texture(screen_texture, uv_clamped).g;
	float b = texture(screen_texture, clamp(uv - vec2(aberration, 0.0), 0.0, 1.0)).b;
	vec3 color = vec3(r, g, b);

	// Black out pixels outside the distorted screen boundary
	float edge_x = step(0.0, uv.x) * step(uv.x, 1.0);
	float edge_y = step(0.0, uv.y) * step(uv.y, 1.0);
	float in_bounds = edge_x * edge_y;
	color *= in_bounds;

	// Scanlines -- every ~2px at 1080p (800 * PI gives fine lines)
	float scanline = sin(uv_clamped.y * 800.0) * 0.04 + 0.96;
	color *= scanline;

	// Vignette -- darken edges
	float vignette = 1.0 - dist * 1.5;
	vignette = clamp(vignette, 0.0, 1.0);
	color *= vignette;

	// Phosphor tint -- Cold War radar: slight green/teal shift
	color *= vec3(0.95, 1.02, 1.01);

	// Subtle flicker -- barely perceptible brightness oscillation
	float flicker = 0.995 + 0.005 * sin(TIME * 8.0);
	color *= flicker;

	// Slight brightness boost to compensate for scanline darkening
	color *= 1.05;

	COLOR = vec4(color, 1.0);
}
"""
