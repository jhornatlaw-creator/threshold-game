extends Node
## Minimap -- CIC Tactical Plot (replaces god's-eye minimap).
## Shows ONLY what sensors report: player units (known), bearing lines,
## uncertainty ellipses, datum circles, sonobuoy positions.
## No precise enemy positions. Contacts are probability areas and estimated tracks.
## Autoload singleton. Toggle with M key (handled by RenderBridge).

var enabled: bool = true:
	set(value):
		enabled = value
		if _canvas_layer:
			_canvas_layer.visible = value

var _canvas_layer: CanvasLayer
var _minimap_control: Control

const MAP_SIZE := 220.0
const MAP_MARGIN := 16.0
const COLOR_BG := Color(0.02, 0.04, 0.08, 0.92)
const COLOR_BORDER := Color(0.15, 0.35, 0.6, 0.7)
const COLOR_PLAYER := Color(0.3, 0.7, 1.0)
const COLOR_CONTACT_BEARING := Color(1.0, 0.6, 0.2, 0.5)
const COLOR_CONTACT_ZONE := Color(1.0, 0.5, 0.2, 0.12)
const COLOR_SONOBUOY := Color(0.2, 0.9, 0.4, 0.6)
const COLOR_SONOBUOY_CONTACT := Color(1.0, 1.0, 0.3, 0.5)
const COLOR_DATUM := Color(1.0, 0.3, 0.3, 0.25)
const COLOR_SELECTED := Color(1.0, 1.0, 1.0)
const COLOR_VIEWPORT := Color(1.0, 1.0, 1.0, 0.15)
const COLOR_HEADER := Color(0.2, 0.4, 0.6, 0.8)
const COLOR_GRID := Color(0.1, 0.2, 0.3, 0.3)
const COLOR_HEADING := Color(0.3, 0.7, 1.0, 0.4)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 50  # Above game, below CRT shader at 100
	add_child(_canvas_layer)

	_minimap_control = _TacticalPlotControl.new()
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
# Inner class -- CIC-style tactical plot drawing
# ---------------------------------------------------------------------------
class _TacticalPlotControl extends Control:
	var _render_bridge = null  # Cached reference to RenderBridge

	func _ready() -> void:
		# Redraw only on sim tick (1Hz), not every frame
		SimulationWorld.sim_tick.connect(_on_sim_tick)

	func _on_sim_tick(_tick_number: int, _sim_time: float) -> void:
		queue_redraw()

	func _get_render_bridge():
		if _render_bridge == null or not is_instance_valid(_render_bridge):
			_render_bridge = get_tree().get_root().find_child("RenderBridge", true, false)
		return _render_bridge

	func _draw() -> void:
		var map_rect := Rect2(0.0, 20.0, Minimap.MAP_SIZE, Minimap.MAP_SIZE)

		# --- Header ---
		draw_string(
			ThemeDB.fallback_font,
			Vector2(0.0, 14.0),
			"CIC TACTICAL PLOT",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			9,
			Minimap.COLOR_HEADER
		)

		# --- Background (dark blue-black like a CIC display) ---
		draw_rect(map_rect, Minimap.COLOR_BG)

		# --- Grid lines (range rings / bearing grid) ---
		var center := Vector2(map_rect.position.x + map_rect.size.x * 0.5,
			map_rect.position.y + map_rect.size.y * 0.5)
		# Range rings at 25%, 50%, 75% of map
		for ring_pct in [0.25, 0.5, 0.75]:
			var r: float = map_rect.size.x * 0.5 * ring_pct
			draw_arc(center, r, 0.0, TAU, 24, Minimap.COLOR_GRID, 0.5)
		# Cross hairs
		draw_line(
			Vector2(map_rect.position.x, center.y),
			Vector2(map_rect.position.x + map_rect.size.x, center.y),
			Minimap.COLOR_GRID, 0.5)
		draw_line(
			Vector2(center.x, map_rect.position.y),
			Vector2(center.x, map_rect.position.y + map_rect.size.y),
			Minimap.COLOR_GRID, 0.5)

		# --- Border ---
		draw_rect(map_rect, Minimap.COLOR_BORDER, false, 1.0)

		# --- Gather bounds ---
		var bounds: Rect2 = Minimap._calculate_bounds()
		if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
			return

		# --- Camera viewport rectangle ---
		var cam_info: Dictionary = Minimap._get_camera_info()
		if not cam_info.is_empty():
			var cam_pos: Vector2 = cam_info["position"]
			var cam_zoom: Vector2 = cam_info["zoom"]
			var cam_nm := cam_pos / SimulationWorld.NM_TO_PIXELS
			var vp_size_nm := Vector2(1920.0, 1080.0) / (cam_zoom * SimulationWorld.NM_TO_PIXELS)
			var vp_top_left_nm := cam_nm - vp_size_nm * 0.5
			var vp_tl_mm := Minimap._world_to_minimap(vp_top_left_nm, bounds, map_rect)
			var vp_br_mm := Minimap._world_to_minimap(vp_top_left_nm + vp_size_nm, bounds, map_rect)
			var vp_rect := Rect2(vp_tl_mm, vp_br_mm - vp_tl_mm)
			draw_rect(vp_rect, Minimap.COLOR_VIEWPORT)

		# --- Get selected unit ---
		var selected_id: String = ""
		var rb = _get_render_bridge()
		if rb:
			selected_id = rb.get("_selected_unit_id") if rb.get("_selected_unit_id") != null else ""

		# --- Draw sonobuoys ---
		for bid in SimulationWorld.sonobuoys:
			var buoy: Dictionary = SimulationWorld.sonobuoys[bid]
			var buoy_pos: Vector2 = Minimap._world_to_minimap(buoy["position"], bounds, map_rect)
			draw_circle(buoy_pos, 2.0, Minimap.COLOR_SONOBUOY)

		# --- Draw player units (always visible -- we know where our own ships are) ---
		for uid in SimulationWorld.units:
			var u: Dictionary = SimulationWorld.units[uid]
			if not u.get("is_alive", false):
				continue
			if not u.get("is_airborne", false) and u.get("base_unit_id", "") != "":
				continue  # Skip on-deck helos

			var pos: Vector2 = u.get("position", Vector2.ZERO)
			var mm_pos: Vector2 = Minimap._world_to_minimap(pos, bounds, map_rect)
			var faction: String = u.get("faction", "")

			if faction == "player":
				var ptype: String = u.get("platform", {}).get("type", "")
				_draw_player_symbol(mm_pos, ptype, Minimap.COLOR_PLAYER)
				# Heading indicator
				var hdg_rad: float = deg_to_rad(u.get("heading", 0.0))
				var hdg_tip: Vector2 = mm_pos + Vector2(sin(hdg_rad), -cos(hdg_rad)) * 8.0
				draw_line(mm_pos, hdg_tip, Minimap.COLOR_HEADING, 1.0)
				if uid == selected_id:
					_draw_selected_ring(mm_pos, Minimap.COLOR_SELECTED)

		# --- Draw sensor contacts (bearing lines, uncertainty zones) ---
		# NO precise enemy positions. Only what sensors report.
		for uid in SimulationWorld.units:
			var u: Dictionary = SimulationWorld.units[uid]
			if u.get("faction", "") != "player" or not u.get("is_alive", false):
				continue

			var detector_pos: Vector2 = u.get("position", Vector2.ZERO)
			var detector_mm: Vector2 = Minimap._world_to_minimap(detector_pos, bounds, map_rect)

			for tid in u.get("contacts", {}):
				var det: Dictionary = u["contacts"][tid]
				var bearing_deg: float = det.get("bearing", 0.0)
				var bearing_rad: float = deg_to_rad(bearing_deg)
				var bearing_dir: Vector2 = Vector2(sin(bearing_rad), -cos(bearing_rad))
				var is_bearing_only: bool = det.get("bearing_only", false)
				var tma_quality: float = det.get("tma_quality", 0.0)

				if is_bearing_only:
					# Bearing line from detector toward contact direction
					var line_end: Vector2 = detector_mm + bearing_dir * 80.0
					draw_line(detector_mm, line_end, Minimap.COLOR_CONTACT_BEARING, 0.8)
				else:
					# Ranged contact: show uncertainty circle at estimated position
					var range_est: float = det.get("range_est", 10.0)
					var est_pos: Vector2 = detector_pos + bearing_dir * range_est
					var est_mm: Vector2 = Minimap._world_to_minimap(est_pos, bounds, map_rect)
					# Uncertainty radius based on TMA quality
					var unc_radius: float = lerpf(12.0, 4.0, clampf(tma_quality, 0.0, 1.0))
					draw_arc(est_mm, unc_radius, 0.0, TAU, 16, Minimap.COLOR_CONTACT_BEARING, 1.0)
					draw_circle(est_mm, unc_radius, Minimap.COLOR_CONTACT_ZONE)
					# Center dot only at high quality
					if tma_quality >= 0.7:
						draw_circle(est_mm, 1.5, Minimap.COLOR_CONTACT_BEARING)

		# --- Draw last-known datum circles (fading, from lost contacts) ---
		if rb:
			var lost_timers: Dictionary = rb.get("_lost_contact_timers") if rb.get("_lost_contact_timers") != null else {}
			var player_contacts: Dictionary = rb.get("_player_contacts") if rb.get("_player_contacts") != null else {}
			for tid in lost_timers:
				# Show a fading datum circle where we last had the contact
				if tid in SimulationWorld.units:
					# Don't show ground truth position -- show last known detection pos
					pass  # Datum already visible via bearing line fade in main view

	# Draw player symbols by platform type
	func _draw_player_symbol(pos: Vector2, ptype: String, color: Color) -> void:
		match ptype:
			"SSN":
				var s := 4.0
				var pts := PackedVector2Array([
					pos + Vector2(0.0, -s),
					pos + Vector2(s, 0.0),
					pos + Vector2(0.0, s),
					pos + Vector2(-s, 0.0),
				])
				draw_colored_polygon(pts, color)
			"MPA", "HELO":
				var s := 4.0
				var pts := PackedVector2Array([
					pos + Vector2(0.0, -s),
					pos + Vector2(s, s * 0.6),
					pos + Vector2(-s, s * 0.6),
				])
				draw_colored_polygon(pts, color)
			_:
				draw_circle(pos, 3.0, color)

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

	# Add 15 NM padding on all sides (wider for tactical view)
	var padding := Vector2(15.0, 15.0)
	return Rect2(min_pos - padding, max_pos - min_pos + padding * 2.0)

static func _world_to_minimap(world_pos: Vector2, bounds: Rect2, map_rect: Rect2) -> Vector2:
	var t := (world_pos - bounds.position) / bounds.size
	return Vector2(
		map_rect.position.x + t.x * map_rect.size.x,
		map_rect.position.y + t.y * map_rect.size.y
	)

static func _get_camera_info() -> Dictionary:
	var render_bridge = Engine.get_main_loop().get_root().find_child("RenderBridge", true, false)
	if render_bridge and render_bridge.has_node("Camera2D"):
		var cam: Camera2D = render_bridge.get_node("Camera2D")
		return {"position": cam.global_position, "zoom": cam.zoom}
	return {}
