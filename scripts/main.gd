extends Node3D
## Small LAN lobby and server-side player spawning for the maze prototype.

const GAME_PORT := 2456
const MAX_REMOTE_PLAYERS := 3
const ROUND_LENGTH := 180.0
const RESPAWN_DELAY := 15.0
const POWERUP_STUN_TIME := 5.0
const POWERUP_BLIND_TIME := 2.5
const POWERUP_BARRICADE_TIME := 10.0
const POWERUP_WALL_TRAVEL_TIME := 3.0
const POWERUP_HIT_BONUS := 25.0
const POWERUP_PICKUP_COUNT := 8
const POWERUP_RESPAWN_INTERVAL := 4.0
const POWERUP_PICKUP_LIFETIME_MIN := 25.0
const POWERUP_PICKUP_LIFETIME_MAX := 40.0
const POWERUP_RANGE := 60.0
const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const POWERUP_SCENE: PackedScene = preload("res://scenes/powerup_pickup.tscn")
const BARRICADE_SCENE: PackedScene = preload("res://scenes/barricade.tscn")
const CHARACTER_CATALOG = preload("res://scripts/character_catalog.gd")
const MAZE_PREVIEW_SCRIPT = preload("res://scripts/lobby_maze_preview.gd")
const CHARACTER_PREVIEW_SCRIPT = preload("res://scripts/lobby_character_preview.gd")
const LOBBY_TIPS: Array[Dictionary] = [
	{"title": "STUN SHOT", "body": "Collect the blue charge, aim at the hunter, and left-click to freeze it for 5 seconds. A direct hit earns 25 points."},
	{"title": "BLIND FLASH", "body": "The violet charge blinds another player for 2.5 seconds. It cannot affect the hunter."},
	{"title": "BARRICADE", "body": "Drop a temporary wall across a passage to block pursuit for 10 seconds."},
	{"title": "WALL TRAVEL", "body": "Use the green charge to pass through cave walls for 3 seconds. Keep moving."},
]

@onready var maze: Node = $Maze
@onready var players: Node3D = $Players
@onready var player_spawner: MultiplayerSpawner = $Players/MultiplayerSpawner
@onready var pickups: Node3D = $Pickups
@onready var pickup_spawner: MultiplayerSpawner = $Pickups/MultiplayerSpawner
@onready var barricade_spawner: MultiplayerSpawner = $Barricades/MultiplayerSpawner

var _start_layer: CanvasLayer
var _start_status_label: Label
var _lobby_layer: CanvasLayer
var _lobby_panel: PanelContainer
var _address_input: LineEdit
var _lobby_status_label: Label
var _roster_container: VBoxContainer
var _maze_preview: Control
var _tip_title: Label
var _tip_body: Label
var _roster_signature := ""
var _tip_index := 0
var _tip_timer := 9.0
var _roster_refresh_timer := 0.0
var _menu_camera: Camera3D
var _menu_camera_angle := 0.0
var _status_message := "Waiting for a host."
var _round_active := false
var _round_finished := false
var _round_time_left := ROUND_LENGTH
var _round_hud_layer: CanvasLayer
var _hud_label: Label
var _round_sync_timer := 0.0
var _powerup_spawn_timer := 0.0
var _next_pickup_id := 0

func _ready() -> void:
	_separate_maze_wall_colliders()
	player_spawner.spawn_function = _spawn_player
	pickup_spawner.spawn_function = _spawn_powerup
	barricade_spawner.spawn_function = _spawn_barricade
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	player_spawner.spawned.connect(_on_player_spawned)
	player_spawner.despawned.connect(_on_player_despawned)
	_setup_menu_camera()
	_build_lobby_ui()
	_build_start_ui()
	_build_round_hud()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _process(delta: float) -> void:
	_update_round_hud()
	if _menu_camera != null and not _round_active and not _round_finished:
		_update_menu_camera(delta)
	if _lobby_layer != null and _lobby_layer.visible:
		_tip_timer -= delta
		if _tip_timer <= 0.0:
			_tip_index = (_tip_index + 1) % LOBBY_TIPS.size()
			_tip_timer = 9.0
			_update_lobby_tip()
		_roster_refresh_timer -= delta
		if _roster_refresh_timer <= 0.0:
			_roster_refresh_timer = 0.35
			_refresh_lobby_roster()
	if not _network_is_active() or not multiplayer.is_server():
		return
	if not _round_active:
		return
	_round_time_left = maxf(0.0, _round_time_left - delta)
	_update_players(delta)
	_update_powerup_spawning(delta)
	_round_sync_timer -= delta
	if _round_sync_timer <= 0.0:
		_round_sync_timer = 1.0
		_sync_round_state.rpc(_round_active, _round_time_left, _round_finished)
	if _round_time_left <= 0.0:
		_round_active = false
		_round_finished = true
		for player in get_tree().get_nodes_in_group("players"):
			player.round_active = false
		_sync_round_state.rpc(_round_active, _round_time_left, _round_finished)
		_refresh_status("Round over")
	_update_round_hud()

func _network_is_active() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func _setup_menu_camera() -> void:
	_menu_camera = Camera3D.new()
	_menu_camera.name = "LobbyOrbitCamera"
	_menu_camera.fov = 62.0
	_menu_camera.far = 180.0
	add_child(_menu_camera)
	_menu_camera.current = true
	_update_menu_camera(0.0)

func _update_menu_camera(delta: float) -> void:
	_menu_camera_angle += delta * 0.1
	var focus: Vector3 = maze.cell_to_world(Vector2i(24, 24)) + Vector3.UP * 1.3
	var orbit_radius := 31.0
	_menu_camera.global_position = focus + Vector3(cos(_menu_camera_angle) * orbit_radius, 18.0, sin(_menu_camera_angle) * orbit_radius)
	_menu_camera.look_at(focus, Vector3.UP)

func _build_round_hud() -> void:
	_round_hud_layer = CanvasLayer.new()
	_round_hud_layer.name = "RoundHUD"
	_round_hud_layer.visible = false
	add_child(_round_hud_layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(22, 22)
	panel.custom_minimum_size = Vector2(300, 0)
	_apply_panel_style(panel, Color(0.035, 0.055, 0.065, 0.92), Color(0.29, 0.43, 0.45, 0.9))
	_round_hud_layer.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 5)
	margin.add_child(layout)
	_hud_label = Label.new()
	_hud_label.name = "RoundStatus"
	_hud_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.72))
	layout.add_child(_hud_label)
	_update_round_hud()

func _update_round_hud() -> void:
	if _hud_label == null:
		return
	_round_hud_layer.visible = _round_active or _round_finished
	var heading := "Waiting for another player..."
	if _round_active:
		heading = "Round: %d:%02d" % [int(_round_time_left) / 60, int(_round_time_left) % 60]
	elif _round_finished:
		heading = "ROUND OVER"
	var lines: PackedStringArray = [heading, ""]
	var active_players := get_tree().get_nodes_in_group("players")
	active_players.sort_custom(func(a: Node, b: Node) -> bool: return a.owner_peer_id < b.owner_peer_id)
	for player in active_players:
		var state := "Alive"
		if not player.is_alive:
			state = "Respawning: %d" % ceili(player.respawn_remaining)
		lines.append("P%d  %s  |  %d pts  |  %ds alive" % [player.owner_peer_id, state, int(player.score), int(player.total_alive_time)])
	_hud_label.text = "\n".join(lines)

func _update_players(delta: float) -> void:
	for player in get_tree().get_nodes_in_group("players"):
		player.stun_remaining = maxf(0.0, player.stun_remaining - delta)
		player.blind_remaining = maxf(0.0, player.blind_remaining - delta)
		player.wall_travel_remaining = maxf(0.0, player.wall_travel_remaining - delta)
		if player.is_alive and maze.to_local(player.global_position).y < -1.0:
			player.is_alive = false
			player.respawn_remaining = RESPAWN_DELAY
			player.wall_travel_remaining = 0.0
			player.velocity = Vector3.ZERO
		if player.is_alive:
			player.total_alive_time += delta
			# The point rate rises with this player's own accumulated survival time.
			player.score += delta * (1.0 + player.total_alive_time / 60.0)
			_try_collect_powerup(player)
			if _is_caught_by_monster(player):
				player.is_alive = false
				player.respawn_remaining = RESPAWN_DELAY
				player.wall_travel_remaining = 0.0
				player.velocity = Vector3.ZERO
		else:
			player.respawn_remaining = maxf(0.0, player.respawn_remaining - delta)
			if player.respawn_remaining <= 0.0:
				_respawn_player(player)

func _is_caught_by_monster(player: Node3D) -> bool:
	var monster := get_node_or_null("Monster") as CharacterBody3D
	return monster != null and monster.global_position.distance_to(player.global_position) <= 1.35

func _respawn_player(player: Node) -> void:
	player.global_position = _get_spawn_position(player.owner_peer_id)
	player.velocity = Vector3.ZERO
	player.respawn_remaining = 0.0
	player.is_alive = true

func _get_spawn_position(peer_id: int) -> Vector3:
	var spawn_offsets := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	var offset: Vector2i = spawn_offsets[(peer_id - 1) % spawn_offsets.size()]
	return maze.cell_to_world(Vector2i(24, 24) + offset) + Vector3(0, 0.1, 0)

func _separate_maze_wall_colliders() -> void:
	var wall_body := StaticBody3D.new()
	wall_body.name = "WallColliders"
	wall_body.collision_layer = 2
	wall_body.collision_mask = 1
	maze.add_child(wall_body)
	for child in maze.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null:
			continue
		var box_shape := shape_node.shape as BoxShape3D
		if box_shape != null and box_shape.size.y > 1.0:
			shape_node.reparent(wall_body, true)

func _maybe_start_round() -> void:
	if not multiplayer.is_server() or _round_active or _round_finished:
		return
	if get_tree().get_nodes_in_group("players").size() < 2:
		return
	_round_active = true
	_round_time_left = ROUND_LENGTH
	_round_sync_timer = 0.0
	_powerup_spawn_timer = POWERUP_RESPAWN_INTERVAL
	for player in get_tree().get_nodes_in_group("players"):
		player.round_active = true
	_spawn_round_powerups()
	_sync_round_state.rpc(_round_active, _round_time_left, _round_finished)
	_refresh_status("Round started")

func _spawn_round_powerups() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var start_cell: Vector2i = maze.world_to_cell(_get_spawn_position(1))
	var used_cells: Dictionary = {}
	var powerup_types := ["stun", "stun", "blind", "blind", "barricade", "barricade", "wall_travel", "wall_travel"]
	powerup_types.shuffle()
	var spawned := 0
	for attempt in range(160):
		if spawned >= POWERUP_PICKUP_COUNT:
			break
		var cell := Vector2i(rng.randi_range(2, maze.size_x - 3), rng.randi_range(2, maze.size_y - 3))
		if used_cells.has(cell) or not maze._is_open(cell.x, cell.y):
			continue
		if cell.distance_to(start_cell) < 7.0 or maze.find_path(start_cell, cell).is_empty():
			continue
		used_cells[cell] = true
		var pickup_position: Vector3 = maze.cell_to_world(cell) + Vector3.UP * 0.65
		pickup_spawner.spawn({
			"pickup_id": spawned,
			"powerup_type": powerup_types[spawned],
			"position": pickup_position,
			"lifetime": rng.randf_range(POWERUP_PICKUP_LIFETIME_MIN, POWERUP_PICKUP_LIFETIME_MAX)
		})
		spawned += 1
	_next_pickup_id = spawned

func _update_powerup_spawning(delta: float) -> void:
	_powerup_spawn_timer -= delta
	if _powerup_spawn_timer > 0.0:
		return
	if _get_active_powerup_count() >= POWERUP_PICKUP_COUNT:
		_powerup_spawn_timer = POWERUP_RESPAWN_INTERVAL
		return
	if _spawn_replacement_powerup():
		_powerup_spawn_timer = POWERUP_RESPAWN_INTERVAL
	else:
		_powerup_spawn_timer = 1.0

func _spawn_replacement_powerup() -> bool:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var start_cell: Vector2i = maze.world_to_cell(_get_spawn_position(1))
	var powerup_types := ["stun", "stun", "blind", "blind", "barricade", "barricade", "wall_travel", "wall_travel"]
	for attempt in range(160):
		var cell := Vector2i(rng.randi_range(2, maze.size_x - 3), rng.randi_range(2, maze.size_y - 3))
		if not maze._is_open(cell.x, cell.y) or cell.distance_to(start_cell) < 7.0:
			continue
		if maze.find_path(start_cell, cell).is_empty():
			continue
		var pickup_position: Vector3 = maze.cell_to_world(cell) + Vector3.UP * 0.65
		var too_close := false
		for pickup in pickups.get_children():
			if not pickup.has_method("get_powerup_type") or pickup.is_queued_for_deletion():
				continue
			if pickup.global_position.distance_to(pickup_position) < 5.0:
				too_close = true
				break
		if too_close:
			continue
		for player in get_tree().get_nodes_in_group("players"):
			if player.global_position.distance_to(pickup_position) < 5.0:
				too_close = true
				break
		if too_close:
			continue
		var type_index := rng.randi_range(0, powerup_types.size() - 1)
		pickup_spawner.spawn({
			"pickup_id": _next_pickup_id,
			"powerup_type": powerup_types[type_index],
			"position": pickup_position,
			"lifetime": rng.randf_range(POWERUP_PICKUP_LIFETIME_MIN, POWERUP_PICKUP_LIFETIME_MAX)
		})
		_next_pickup_id += 1
		return true
	return false

func _get_active_powerup_count() -> int:
	var count := 0
	for pickup in pickups.get_children():
		if pickup.has_method("get_powerup_type") and not pickup.is_queued_for_deletion():
			count += 1
	return count

func _spawn_powerup(data: Variant) -> Node:
	var pickup := POWERUP_SCENE.instantiate()
	pickup.name = "Pickup_%d" % int(data.get("pickup_id", 0))
	pickup.powerup_type = String(data.get("powerup_type", "stun"))
	pickup.position = data.get("position", Vector3.ZERO)
	pickup.lifetime = float(data.get("lifetime", POWERUP_PICKUP_LIFETIME_MIN))
	return pickup

func _spawn_barricade(data: Variant) -> Node:
	var barricade := BARRICADE_SCENE.instantiate()
	barricade.position = data.get("position", Vector3.ZERO)
	barricade.rotation = data.get("rotation", Vector3.ZERO)
	barricade.lifetime = POWERUP_BARRICADE_TIME
	return barricade

func _try_collect_powerup(player: Node) -> void:
	if not player.held_powerup.is_empty():
		return
	for pickup in pickups.get_children():
		if pickup.has_method("get_powerup_type") and player.global_position.distance_to(pickup.global_position) <= 1.35:
			player.held_powerup = pickup.powerup_type
			pickup.queue_free()
			return

func use_powerup_for_player(player: Node) -> void:
	if not multiplayer.is_server() or not _round_active or not player.is_alive or player.held_powerup.is_empty():
		return
	var used_powerup: String = player.held_powerup
	player.held_powerup = ""
	if used_powerup == "barricade":
		var barricade_position: Vector3 = player.global_position - player.global_basis.z * 2.4 + Vector3.UP * 1.4
		var barricade_rotation: Vector3 = Vector3(0.0, player.rotation.y, 0.0)
		if _can_place_barricade(player, barricade_position, barricade_rotation):
			barricade_spawner.spawn({"position": barricade_position, "rotation": barricade_rotation})
			_send_powerup_beam(player, barricade_position, Color(1.0, 0.62, 0.2))
			_send_powerup_feedback(player, "BARRICADE DEPLOYED — lasts 10 seconds")
		else:
			_send_powerup_feedback(player, "BLOCKED — no room to place barricade")
		return
	if used_powerup == "wall_travel":
		player.wall_travel_remaining = POWERUP_WALL_TRAVEL_TIME
		_send_powerup_feedback(player, "WALL TRAVEL — 3 seconds")
		return
	if used_powerup != "stun" and used_powerup != "blind":
		return
	var origin: Vector3 = player.camera.global_position
	var direction: Vector3 = -player.camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * POWERUP_RANGE)
	query.exclude = [player.get_rid()]
	query.collide_with_areas = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var beam_end: Vector3 = hit.get("position", origin + direction * POWERUP_RANGE)
	var beam_color := Color(0.22, 0.86, 1.0) if used_powerup == "stun" else Color(0.82, 0.3, 1.0)
	_send_powerup_beam(player, beam_end, beam_color)
	var target: Object = hit.get("collider") if not hit.is_empty() else null
	var monster := get_node_or_null("Monster")
	if used_powerup == "stun" and monster != null and (target == monster or target == monster.get_node_or_null("StunAimHitbox")):
		monster.stun_remaining = POWERUP_STUN_TIME
		player.score += POWERUP_HIT_BONUS
		_send_powerup_feedback(player, "HIT — monster stunned")
	elif target is Node and target.is_in_group("players") and target != player:
		if used_powerup == "stun":
			target.stun_remaining = POWERUP_STUN_TIME
		else:
			target.blind_remaining = POWERUP_BLIND_TIME
		player.score += POWERUP_HIT_BONUS
		_send_powerup_feedback(player, "HIT — player stunned" if used_powerup == "stun" else "HIT — player blinded")
	elif target == monster or (monster != null and target == monster.get_node_or_null("StunAimHitbox")):
		_send_powerup_feedback(player, "MISS — blind gun only affects players")
	elif target != null:
		_send_powerup_feedback(player, "BLOCKED — clear line of sight")
	else:
		_send_powerup_feedback(player, "MISS — no target in range")

func _can_place_barricade(player: Node, wall_position: Vector3, wall_rotation: Vector3) -> bool:
	var right := Basis.from_euler(wall_rotation).x
	var ray_start: Vector3 = player.global_position + Vector3.UP * 1.4
	for side_offset in [-0.85, 0.0, 0.85]:
		var offset: Vector3 = right * side_offset
		var query := PhysicsRayQueryParameters3D.create(ray_start + offset, wall_position + offset)
		query.collision_mask = 3
		query.exclude = [player.get_rid()]
		if not get_world_3d().direct_space_state.intersect_ray(query).is_empty():
			return false
	return true

func _send_powerup_feedback(player: Node, message: String) -> void:
	if player.owner_peer_id == 1:
		player._show_powerup_feedback(message)
	else:
		player._show_powerup_feedback.rpc_id(player.owner_peer_id, message)

func _send_powerup_beam(player: Node, beam_end: Vector3, beam_color: Color) -> void:
	if player.owner_peer_id == 1:
		player._show_powerup_beam(beam_end, beam_color)
	else:
		player._show_powerup_beam.rpc_id(player.owner_peer_id, beam_end, beam_color)

@rpc("authority", "call_local", "reliable")
func _sync_round_state(active: bool, time_left: float, finished: bool) -> void:
	_round_active = active
	_round_time_left = time_left
	_round_finished = finished
	_lobby_layer.visible = not active and not finished
	_round_hud_layer.visible = active or finished
	_menu_camera.current = not active
	if active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		var local_player := players.get_node_or_null("Player_%d" % multiplayer.get_unique_id())
		if local_player != null:
			var local_camera := local_player.get_node_or_null("Camera3D") as Camera3D
			if local_camera != null:
				local_camera.make_current()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_update_round_hud()

func _build_lobby_ui() -> void:
	_lobby_layer = CanvasLayer.new()
	_lobby_layer.name = "LobbyUI"
	_lobby_layer.layer = 5
	add_child(_lobby_layer)
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.015, 0.025, 0.03, 0.26)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lobby_layer.add_child(backdrop)
	_lobby_panel = PanelContainer.new()
	_lobby_panel.name = "LobbyPanel"
	_lobby_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lobby_panel.offset_left = 26
	_lobby_panel.offset_top = 22
	_lobby_panel.offset_right = -26
	_lobby_panel.offset_bottom = -22
	_apply_panel_style(_lobby_panel, Color(0.045, 0.065, 0.075, 0.78), Color(0.27, 0.42, 0.43, 1.0))
	_lobby_layer.add_child(_lobby_panel)
	var outer_margin := MarginContainer.new()
	outer_margin.add_theme_constant_override("margin_left", 22)
	outer_margin.add_theme_constant_override("margin_right", 22)
	outer_margin.add_theme_constant_override("margin_top", 17)
	outer_margin.add_theme_constant_override("margin_bottom", 17)
	_lobby_panel.add_child(outer_margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 14)
	outer_margin.add_child(layout)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 18)
	layout.add_child(header)
	var title := Label.new()
	title.text = "HALAKA"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.91, 0.96, 0.91))
	header.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "A CAVE RUN FOR 2–4 SURVIVORS"
	subtitle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", Color(0.54, 0.73, 0.70))
	header.add_child(subtitle)
	layout.add_child(HSeparator.new())

	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 18)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(content)
	var map_panel := PanelContainer.new()
	map_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_apply_panel_style(map_panel, Color(0.025, 0.04, 0.047, 0.76), Color(0.16, 0.27, 0.29, 1.0))
	content.add_child(map_panel)
	var map_margin := MarginContainer.new()
	map_margin.add_theme_constant_override("margin_left", 12)
	map_margin.add_theme_constant_override("margin_right", 12)
	map_margin.add_theme_constant_override("margin_top", 10)
	map_margin.add_theme_constant_override("margin_bottom", 10)
	map_panel.add_child(map_margin)
	var map_layout := VBoxContainer.new()
	map_layout.add_theme_constant_override("separation", 7)
	map_margin.add_child(map_layout)
	var map_title := Label.new()
	map_title.text = "THE CINDER MAZE"
	map_title.add_theme_font_size_override("font_size", 17)
	map_title.add_theme_color_override("font_color", Color(0.87, 0.91, 0.84))
	map_layout.add_child(map_title)
	var map_caption := Label.new()
	map_caption.text = "TOP-DOWN FIELD MAP  ·  KNOW YOUR STARTING POINT"
	map_caption.add_theme_font_size_override("font_size", 10)
	map_caption.add_theme_color_override("font_color", Color(0.5, 0.63, 0.63))
	map_layout.add_child(map_caption)
	_maze_preview = Control.new()
	_maze_preview.name = "MazePreview"
	_maze_preview.set_script(MAZE_PREVIEW_SCRIPT)
	_maze_preview.custom_minimum_size = Vector2(350, 280)
	_maze_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_maze_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_layout.add_child(_maze_preview)
	_maze_preview.call("set_maze", maze)
	var legend := HBoxContainer.new()
	legend.add_theme_constant_override("separation", 15)
	map_layout.add_child(legend)
	_add_map_legend_item(legend, Color("#76d8c0"), "SURVIVOR SPAWN")
	_add_map_legend_item(legend, Color("#db6c4d"), "HUNTER START")

	var side_column := VBoxContainer.new()
	side_column.custom_minimum_size.x = 330
	side_column.size_flags_horizontal = Control.SIZE_FILL
	side_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_column.add_theme_constant_override("separation", 10)
	content.add_child(side_column)
	var roster_heading := HBoxContainer.new()
	side_column.add_child(roster_heading)
	var roster_title := Label.new()
	roster_title.text = "RUNNERS"
	roster_title.add_theme_font_size_override("font_size", 16)
	roster_title.add_theme_color_override("font_color", Color(0.87, 0.91, 0.84))
	roster_heading.add_child(roster_title)
	var roster_spacer := Control.new()
	roster_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_heading.add_child(roster_spacer)
	var count_label := Label.new()
	count_label.name = "RunnerCount"
	count_label.add_theme_color_override("font_color", Color(0.56, 0.71, 0.68))
	roster_heading.add_child(count_label)
	_roster_container = VBoxContainer.new()
	_roster_container.add_theme_constant_override("separation", 6)
	side_column.add_child(_roster_container)
	var roster_footer := Label.new()
	roster_footer.text = "Characters are assigned at random when players join."
	roster_footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	roster_footer.add_theme_font_size_override("font_size", 11)
	roster_footer.add_theme_color_override("font_color", Color(0.5, 0.62, 0.63))
	side_column.add_child(roster_footer)
	var tip_panel := PanelContainer.new()
	tip_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_apply_panel_style(tip_panel, Color(0.11, 0.14, 0.13, 0.88), Color(0.48, 0.5, 0.3, 0.85))
	side_column.add_child(tip_panel)
	var tip_margin := MarginContainer.new()
	tip_margin.add_theme_constant_override("margin_left", 13)
	tip_margin.add_theme_constant_override("margin_right", 13)
	tip_margin.add_theme_constant_override("margin_top", 10)
	tip_margin.add_theme_constant_override("margin_bottom", 10)
	tip_panel.add_child(tip_margin)
	var tip_layout := VBoxContainer.new()
	tip_layout.add_theme_constant_override("separation", 5)
	tip_margin.add_child(tip_layout)
	var tip_kicker := Label.new()
	tip_kicker.text = "FIELD NOTE  ·  POWERUP GUIDE"
	tip_kicker.add_theme_font_size_override("font_size", 10)
	tip_kicker.add_theme_color_override("font_color", Color(0.73, 0.7, 0.44))
	tip_layout.add_child(tip_kicker)
	_tip_title = Label.new()
	_tip_title.add_theme_font_size_override("font_size", 15)
	_tip_title.add_theme_color_override("font_color", Color(0.95, 0.9, 0.72))
	tip_layout.add_child(_tip_title)
	_tip_body = Label.new()
	_tip_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_body.add_theme_font_size_override("font_size", 12)
	_tip_body.add_theme_color_override("font_color", Color(0.78, 0.81, 0.73))
	tip_layout.add_child(_tip_body)
	_update_lobby_tip()

	var controls_hint := Label.new()
	controls_hint.text = "WASD MOVE  ·  SPACE JUMP  ·  MOUSE LOOK  ·  LEFT CLICK USES YOUR POWERUP  ·  ESC RELEASES MOUSE"
	controls_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls_hint.add_theme_font_size_override("font_size", 10)
	controls_hint.add_theme_color_override("font_color", Color(0.55, 0.68, 0.66))
	layout.add_child(controls_hint)
	layout.add_child(HSeparator.new())
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	layout.add_child(footer)
	_lobby_status_label = Label.new()
	_lobby_status_label.text = _status_message
	_lobby_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lobby_status_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_lobby_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lobby_status_label.add_theme_color_override("font_color", Color(0.67, 0.79, 0.76))
	footer.add_child(_lobby_status_label)
	_refresh_lobby_roster(true)
	_render_status()
	_lobby_layer.hide()

func _build_start_ui() -> void:
	_start_layer = CanvasLayer.new()
	_start_layer.name = "StartScreen"
	_start_layer.layer = 6
	add_child(_start_layer)
	var shade := ColorRect.new()
	shade.color = Color(0.01, 0.02, 0.025, 0.32)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_start_layer.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_start_layer.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(480, 0)
	_apply_panel_style(panel, Color(0.025, 0.04, 0.048, 0.86), Color(0.3, 0.47, 0.46, 1.0))
	center.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 34)
	margin.add_theme_constant_override("margin_right", 34)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 28)
	panel.add_child(margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 14)
	margin.add_child(layout)
	var title := Label.new()
	title.text = "HALAKA"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(0.91, 0.96, 0.91))
	layout.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "A CAVE RUN FOR 2–4 SURVIVORS"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", Color(0.57, 0.76, 0.71))
	layout.add_child(subtitle)
	var description := Label.new()
	description.text = "Outrun the hunter. Master the maze. Get your crew out alive."
	description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_color_override("font_color", Color(0.76, 0.81, 0.77))
	layout.add_child(description)
	var divider := HSeparator.new()
	divider.add_theme_constant_override("separation", 8)
	layout.add_child(divider)
	var host_button := Button.new()
	host_button.text = "HOST A GAME"
	host_button.custom_minimum_size.y = 46
	host_button.pressed.connect(_host_game)
	layout.add_child(host_button)
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	layout.add_child(join_row)
	_address_input = LineEdit.new()
	_address_input.placeholder_text = "Host IP address"
	_address_input.text = "127.0.0.1"
	_address_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address_input.custom_minimum_size.y = 42
	_address_input.tooltip_text = "Enter the host computer's local network IP address."
	join_row.add_child(_address_input)
	var join_button := Button.new()
	join_button.text = "JOIN"
	join_button.custom_minimum_size = Vector2(102, 42)
	join_button.pressed.connect(_join_game)
	join_row.add_child(join_button)
	_start_status_label = Label.new()
	_start_status_label.text = _status_message
	_start_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_start_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_start_status_label.add_theme_color_override("font_color", Color(0.66, 0.79, 0.75))
	layout.add_child(_start_status_label)
	var hint := Label.new()
	hint.text = "WASD MOVE  ·  MOUSE LOOK  ·  ESC RELEASES MOUSE"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.48, 0.62, 0.61))
	layout.add_child(hint)
	_start_layer.show()

func _show_lobby() -> void:
	_start_layer.hide()
	_lobby_layer.show()
	_roster_signature = ""
	_refresh_lobby_roster(true)

func _show_start() -> void:
	_lobby_layer.hide()
	_start_layer.show()

func _apply_panel_style(panel: Control, background: Color, border: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 1
	style.content_margin_right = 1
	style.content_margin_top = 1
	style.content_margin_bottom = 1
	panel.add_theme_stylebox_override("panel", style)

func _add_map_legend_item(parent: HBoxContainer, color: Color, text: String) -> void:
	var item := HBoxContainer.new()
	item.add_theme_constant_override("separation", 5)
	parent.add_child(item)
	var swatch := ColorRect.new()
	swatch.color = color
	swatch.custom_minimum_size = Vector2(8, 8)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	item.add_child(swatch)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color(0.61, 0.72, 0.69))
	item.add_child(label)

func _update_lobby_tip() -> void:
	if _tip_title == null or _tip_body == null:
		return
	var tip: Dictionary = LOBBY_TIPS[_tip_index]
	_tip_title.text = String(tip["title"])
	_tip_body.text = String(tip["body"])

func _refresh_lobby_roster(force := false) -> void:
	if _roster_container == null:
		return
	var active_players := get_tree().get_nodes_in_group("players")
	active_players.sort_custom(func(a: Node, b: Node) -> bool: return a.owner_peer_id < b.owner_peer_id)
	var signature := ""
	for player in active_players:
		signature += "%d:%d;" % [player.owner_peer_id, player.character_index]
	for seat in range(active_players.size(), 4):
		signature += "open:%d;" % seat
	if not force and signature == _roster_signature:
		return
	_roster_signature = signature
	for child in _roster_container.get_children():
		child.queue_free()
	var count_label := _lobby_panel.find_child("RunnerCount", true, false) as Label
	if count_label != null:
		count_label.text = "%d / 4" % active_players.size()
	for slot_index in range(4):
		var card := PanelContainer.new()
		card.custom_minimum_size.y = 74
		_apply_panel_style(card, Color(0.07, 0.095, 0.1, 0.92), Color(0.18, 0.29, 0.3, 1.0))
		_roster_container.add_child(card)
		var card_margin := MarginContainer.new()
		card_margin.add_theme_constant_override("margin_left", 6)
		card_margin.add_theme_constant_override("margin_right", 6)
		card_margin.add_theme_constant_override("margin_top", 2)
		card_margin.add_theme_constant_override("margin_bottom", 2)
		card.add_child(card_margin)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		card_margin.add_child(row)
		if slot_index < active_players.size():
			var player: Node = active_players[slot_index]
			var character_index := clampi(player.character_index, 0, CHARACTER_CATALOG.MODELS.size() - 1)
			row.add_child(_create_character_preview(character_index))
			var detail := VBoxContainer.new()
			detail.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			detail.add_theme_constant_override("separation", 2)
			row.add_child(detail)
			var identity := Label.new()
			var player_tag := "HOST" if player.owner_peer_id == 1 else "RUNNER"
			if _network_is_active() and player.owner_peer_id == multiplayer.get_unique_id():
				player_tag += "  ·  YOU"
			identity.text = "P%d  ·  %s" % [player.owner_peer_id, player_tag]
			identity.add_theme_font_size_override("font_size", 10)
			identity.add_theme_color_override("font_color", Color(0.54, 0.73, 0.68))
			detail.add_child(identity)
			var character_name := Label.new()
			character_name.text = CHARACTER_CATALOG.NAMES[character_index]
			character_name.add_theme_font_size_override("font_size", 14)
			character_name.add_theme_color_override("font_color", CHARACTER_CATALOG.COLORS[character_index])
			detail.add_child(character_name)
		else:
			var placeholder := ColorRect.new()
			placeholder.custom_minimum_size = Vector2(64, 64)
			placeholder.color = Color(0.1, 0.14, 0.15, 1.0)
			row.add_child(placeholder)
			var open_label := Label.new()
			open_label.text = "OPEN SLOT\nWaiting for a runner…"
			open_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			open_label.add_theme_font_size_override("font_size", 11)
			open_label.add_theme_color_override("font_color", Color(0.49, 0.59, 0.6))
			row.add_child(open_label)

func _create_character_preview(character_index: int) -> SubViewportContainer:
	var container := SubViewportContainer.new()
	container.custom_minimum_size = Vector2(64, 70)
	container.stretch = true
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 140)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	container.add_child(viewport)
	var stage := Node3D.new()
	stage.name = "PreviewStage"
	stage.set_script(CHARACTER_PREVIEW_SCRIPT)
	viewport.add_child(stage)
	var character := CHARACTER_CATALOG.MODELS[character_index].instantiate() as Node3D
	character.name = "Character"
	character.rotation.y = PI
	character.scale = Vector3.ONE * 0.92
	stage.add_child(character)
	stage.set("preview_model", character)
	_apply_preview_textures(character, character_index)
	_play_preview_idle(character)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 1.0, 3.6)
	camera.rotation.x = -0.02
	camera.fov = 30.0
	camera.current = true
	stage.add_child(camera)
	var key_light := OmniLight3D.new()
	key_light.position = Vector3(-1.2, 2.4, 2.0)
	key_light.light_color = Color(0.76, 0.9, 0.88)
	key_light.light_energy = 2.2
	key_light.omni_range = 8.0
	stage.add_child(key_light)
	var fill_light := OmniLight3D.new()
	fill_light.position = Vector3(1.4, 1.5, -1.4)
	fill_light.light_color = CHARACTER_CATALOG.COLORS[character_index]
	fill_light.light_energy = 1.0
	fill_light.omni_range = 6.0
	stage.add_child(fill_light)
	return container

func _apply_preview_textures(character: Node3D, character_index: int) -> void:
	for node in character.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface_index in range(mesh_instance.mesh.get_surface_count()):
			var source_material: Material = mesh_instance.get_active_material(surface_index)
			var material := StandardMaterial3D.new()
			if source_material is StandardMaterial3D:
				material = (source_material as StandardMaterial3D).duplicate() as StandardMaterial3D
			material.albedo_texture = CHARACTER_CATALOG.ALBEDO_TEXTURES[character_index]
			material.ao_enabled = true
			material.ao_texture = CHARACTER_CATALOG.AO_TEXTURES[character_index]
			material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			mesh_instance.set_surface_override_material(surface_index, material)

func _play_preview_idle(character: Node3D) -> void:
	for node in character.find_children("*", "AnimationPlayer", true, false):
		var animation_player := node as AnimationPlayer
		for animation_name in animation_player.get_animation_list():
			if "idle" in String(animation_name).to_lower():
				animation_player.call_deferred("play", animation_name)
				return

func _host_game() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(GAME_PORT, MAX_REMOTE_PLAYERS)
	if error != OK:
		_set_status("Couldn't host: %s" % error_string(error))
		return
	multiplayer.multiplayer_peer = peer
	_spawn_peer(1)
	_show_lobby()
	_refresh_status("Lobby open on this network · Port %d · Waiting for another runner" % GAME_PORT)

func _join_game() -> void:
	var address := _address_input.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, GAME_PORT)
	if error != OK:
		_set_status("Couldn't connect: %s" % error_string(error))
		return
	multiplayer.multiplayer_peer = peer
	_show_lobby()
	_set_status("Connecting to %s:%d..." % [address, GAME_PORT])

func _spawn_peer(peer_id: int) -> void:
	if not multiplayer.is_server() or players.has_node("Player_%d" % peer_id):
		return
	var character_index: int = _get_available_character_index()
	if character_index < 0:
		return
	player_spawner.spawn({"peer_id": peer_id, "character_index": character_index})

func _get_available_character_index() -> int:
	var used_character_indices: Dictionary = {}
	for player in get_tree().get_nodes_in_group("players"):
		var assigned_index: Variant = player.get("character_index")
		if assigned_index != null:
			used_character_indices[int(assigned_index)] = true
	var available_indices: Array[int] = []
	for index in range(CHARACTER_CATALOG.MODELS.size()):
		if not used_character_indices.has(index):
			available_indices.append(index)
	available_indices.shuffle()
	return available_indices[0] if not available_indices.is_empty() else -1

func _spawn_player(data: Variant) -> Node:
	var peer_id := int(data.get("peer_id", 1))
	var character_index := clampi(int(data.get("character_index", 0)), 0, 3)
	var player := PLAYER_SCENE.instantiate()
	player.name = "Player_%d" % peer_id
	player.owner_peer_id = peer_id
	player.character_index = character_index
	player.round_active = _round_active
	player.set_multiplayer_authority(1, true)
	player.position = _get_spawn_position(peer_id)
	return player

func _on_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		_spawn_peer(peer_id)
		_refresh_status("Player %d joined" % peer_id)
		_maybe_start_round.call_deferred()
	else:
		_refresh_lobby_roster.call_deferred(true)

func _on_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server():
		var player := players.get_node_or_null("Player_%d" % peer_id)
		if player != null:
			player_spawner.despawn(player)
			_refresh_status.call_deferred("Player %d left" % peer_id)
	else:
		_refresh_lobby_roster.call_deferred(true)

func _on_player_spawned(_player: Node) -> void:
	_refresh_lobby_roster.call_deferred(true)
	_maybe_start_round.call_deferred()

func _on_player_despawned(_player: Node) -> void:
	_refresh_lobby_roster.call_deferred(true)
	_update_round_hud.call_deferred()

func _on_connected_to_server() -> void:
	_show_lobby()
	_refresh_status("Connected to host · Waiting for the round to begin")
	_update_round_hud()

func _on_connection_failed() -> void:
	_set_status("Connection failed. Check the host IP and port %d." % GAME_PORT)
	multiplayer.multiplayer_peer = null
	_show_start()

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	_set_status("Host disconnected.")
	_show_start()
	_round_active = false
	_round_finished = false
	_menu_camera.current = true
	_round_hud_layer.hide()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_roster_signature = ""
	_refresh_lobby_roster.call_deferred(true)

func _refresh_status(message: String) -> void:
	_status_message = message
	_render_status()
	_refresh_lobby_roster()

func _set_status(message: String) -> void:
	_status_message = message
	_render_status()

func _render_status() -> void:
	if _lobby_status_label != null:
		_lobby_status_label.text = _status_message
	if _start_status_label != null:
		_start_status_label.text = _status_message
