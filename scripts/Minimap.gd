extends Node
## Minimap -- Theater-wide tactical overview.
## Autoload singleton. Toggle with M key (handled by RenderBridge).

var enabled: bool = true:
	set(value):
		enabled = value
		if _canvas_layer:
			_canvas_layer.visible = value

var _canvas_layer: CanvasLayer
var _minimap_control: Control

const MAP_SIZE := 200.0
const MAP_MARGIN := 16.0
const COLOR_BG := Color(0.03, 0.05, 0.1, 0.85)
const COLOR_BORDER := Color(0.2, 0.5, 0.8, 0.6)
const COLOR_PLAYER := Color(0.3, 0.7, 1.0)
const COLOR_ENEMY := Color(1.0, 0.3, 0.3)
const COLOR_SELECTED := Color(1.0, 1.0, 1.0)
const COLOR_VIEWPORT := Color(1.0, 1.0, 1.0, 0.2)
const COLOR_HEADER := Color(0.3, 0.5, 0.7, 0.8)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 50  # Above game, below CRT shader at 100
	add_child(_canvas_layer)

	_minimap_control = _MinimapControl.new()
	_minimap_control.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Anchor to bottom-right corner
	_minimap_control.anchor_right = 1.0
	_minimap_control.anchor_bottom = 1.0
	_minimap_control.offset_left = -(MAP_SIZE + MAP_MARGIN)
	_minimap_control.offset_top = -(MAP_SIZE + MAP_MARGIN + 20)  # +20 for header
	_minimap_control.offset_right = -MAP_MARGIN
	_minimap_control.offset_bottom = -MAP_MARGIN

	_canvas_layer.add_child(_minimap_control)
	_canvas_layer.visible = enabled

# ---------------------------------------------------------------------------
# Inner class -- handles all drawing
# ---------------------------------------------------------------------------
class _MinimapControl extends Control:
	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var map_rect := Rect2(0.0, 20.0, Minimap.MAP_SIZE, Minimap.MAP_SIZE)

		# --- Header ---
		draw_string(
			ThemeDB.fallback_font,
			Vector2(0.0, 14.0),
			"TACTICAL",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			10,
			Minimap.COLOR_HEADER
		)

		# --- Background ---
		draw_rect(map_rect, Minimap.COLOR_BG)

		# --- Border ---
		draw_rect(map_rect, Minimap.COLOR_BORDER, false, 1.0)

		# --- Gather live units ---
		var bounds: Rect2 = Minimap._calculate_bounds()
		if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
			return

		# --- Camera viewport rectangle ---
		var cam_info: Dictionary = Minimap._get_camera_info()
		if not cam_info.is_empty():
			var cam_pos: Vector2 = cam_info["position"]
			var cam_zoom: Vector2 = cam_info["zoom"]
			# Camera2D position is in pixels; convert to NM
			var cam_nm := cam_pos / SimulationWorld.NM_TO_PIXELS
			# Viewport size in NM (1920x1080 at given zoom)
			var vp_size_nm := Vector2(1920.0, 1080.0) / (cam_zoom * SimulationWorld.NM_TO_PIXELS)
			var vp_top_left_nm := cam_nm - vp_size_nm * 0.5
			var vp_tl_mm := Minimap._world_to_minimap(vp_top_left_nm, bounds, map_rect)
			var vp_br_mm := Minimap._world_to_minimap(vp_top_left_nm + vp_size_nm, bounds, map_rect)
			var vp_rect := Rect2(vp_tl_mm, vp_br_mm - vp_tl_mm)
			draw_rect(vp_rect, Minimap.COLOR_VIEWPORT)
			draw_rect(vp_rect, Color(1.0, 1.0, 1.0, 0.5), false, 1.0)

		# --- Draw units ---
		var selected_id: String = ""
		# Try to get selected unit from RenderBridge without a direct reference
		var rb = get_tree().get_root().find_child("RenderBridge", true, false)
		if rb:
			selected_id = rb.get("_selected_unit_id") if rb.get("_selected_unit_id") != null else ""

		for uid in SimulationWorld.units:
			var u: Dictionary = SimulationWorld.units[uid]
			if not u.get("is_alive", false):
				continue
			# Skip on-deck helicopters (not visible on map)
			if not u.get("is_airborne", false) and u.get("base_unit_id", "") != "":
				continue

			var pos: Vector2 = u.get("position", Vector2.ZERO)
			var mm_pos: Vector2 = Minimap._world_to_minimap(pos, bounds, map_rect)
			var faction: String = u.get("faction", "")
			var ptype: String = u.get("platform", {}).get("type", "")

			if faction == "player":
				_draw_player_symbol(mm_pos, ptype, Minimap.COLOR_PLAYER)
				if uid == selected_id:
					_draw_selected_ring(mm_pos, Minimap.COLOR_SELECTED)
			elif faction == "enemy":
				if Minimap._is_enemy_detected(uid):
					_draw_enemy_symbol(mm_pos, Minimap.COLOR_ENEMY)
					if uid == selected_id:
						_draw_selected_ring(mm_pos, Minimap.COLOR_SELECTED)

	# Draw player symbols by platform type
	func _draw_player_symbol(pos: Vector2, ptype: String, color: Color) -> void:
		match ptype:
			"SSN":
				# Submarine: filled diamond (rotated square)
				var s := 4.0
				var pts := PackedVector2Array([
					pos + Vector2(0.0, -s),
					pos + Vector2(s, 0.0),
					pos + Vector2(0.0, s),
					pos + Vector2(-s, 0.0),
				])
				draw_colored_polygon(pts, PackedColorArray([color, color, color, color]))
			"MPA", "HELO":
				# Aircraft: small upward triangle
				var s := 4.0
				var pts := PackedVector2Array([
					pos + Vector2(0.0, -s),
					pos + Vector2(s, s * 0.6),
					pos + Vector2(-s, s * 0.6),
				])
				draw_colored_polygon(pts, PackedColorArray([color, color, color]))
			_:
				# Surface ships (DDG, FFG, CGN, etc.): filled circle
				draw_circle(pos, 3.0, color)

	# Draw detected enemy: hollow red circle
	func _draw_enemy_symbol(pos: Vector2, color: Color) -> void:
		draw_arc(pos, 4.0, 0.0, TAU, 12, color, 1.0)

	# Draw selection ring around a unit dot
	func _draw_selected_ring(pos: Vector2, color: Color) -> void:
		draw_arc(pos, 6.0, 0.0, TAU, 16, color, 1.5)

# ---------------------------------------------------------------------------
# Static helpers (called from inner class via Minimap.xxx)
# ---------------------------------------------------------------------------
static func _calculate_bounds() -> Rect2:
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	var found_any: bool = false

	for uid in SimulationWorld.units:
		var u: Dictionary = SimulationWorld.units[uid]
		if not u.get("is_alive", false):
			continue
		var pos: Vector2 = u.get("position", Vector2.ZERO)
		min_pos.x = minf(min_pos.x, pos.x)
		min_pos.y = minf(min_pos.y, pos.y)
		max_pos.x = maxf(max_pos.x, pos.x)
		max_pos.y = maxf(max_pos.y, pos.y)
		found_any = true

	if not found_any:
		return Rect2(Vector2.ZERO, Vector2(100.0, 100.0))

	# Add 10 NM padding on all sides
	var padding := Vector2(10.0, 10.0)
	return Rect2(min_pos - padding, max_pos - min_pos + padding * 2.0)

static func _world_to_minimap(world_pos: Vector2, bounds: Rect2, map_rect: Rect2) -> Vector2:
	# Normalize world_pos into [0,1] within bounds, then scale to map_rect
	var t := (world_pos - bounds.position) / bounds.size
	# Y axis: world Y increases downward on map (naval convention matches screen)
	return Vector2(
		map_rect.position.x + t.x * map_rect.size.x,
		map_rect.position.y + t.y * map_rect.size.y
	)

static func _is_enemy_detected(enemy_id: String) -> bool:
	for uid in SimulationWorld.units:
		var u: Dictionary = SimulationWorld.units[uid]
		if u.get("faction", "") == "player" and u.get("is_alive", false):
			if enemy_id in u.get("contacts", {}):
				return true
	return false

static func _get_camera_info() -> Dictionary:
	# Find the Camera2D parented under RenderBridge in the scene tree
	var render_bridge = Engine.get_main_loop().get_root().find_child("RenderBridge", true, false)
	if render_bridge and render_bridge.has_node("Camera2D"):
		var cam: Camera2D = render_bridge.get_node("Camera2D")
		return {"position": cam.global_position, "zoom": cam.zoom}
	return {}
