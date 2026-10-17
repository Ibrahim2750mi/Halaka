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

@onready var maze: Node = $Maze
@onready var players: Node3D = $Players
@onready var player_spawner: MultiplayerSpawner = $Players/MultiplayerSpawner
@onready var pickups: Node3D = $Pickups
@onready var pickup_spawner: MultiplayerSpawner = $Pickups/MultiplayerSpawner
@onready var barricade_spawner: MultiplayerSpawner = $Barricades/MultiplayerSpawner

var _lobby_panel: PanelContainer
var _lobby_controls: VBoxContainer
var _info_layout: VBoxContainer
var _address_input: LineEdit
var _status_label: Label
var _player_list_label: Label
var _status_message := "Waiting for a host."
var _round_active := false
var _round_finished := false
var _round_time_left := ROUND_LENGTH
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
	_build_lobby_ui()
	_build_round_hud()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _process(delta: float) -> void:
	_update_round_hud()
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

func _build_round_hud() -> void:
	if _info_layout == null:
		return
	_info_layout.add_child(HSeparator.new())
	_hud_label = Label.new()
	_hud_label.name = "RoundStatus"
	_hud_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.72))
	_info_layout.add_child(_hud_label)
	_update_round_hud()

func _update_round_hud() -> void:
	if _hud_label == null:
		return
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
	_update_round_hud()

func _build_lobby_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "LobbyUI"
	add_child(canvas)
	_lobby_panel = PanelContainer.new()
	_lobby_panel.name = "GameInfoPanel"
	_lobby_panel.position = Vector2(28, 28)
	_lobby_panel.custom_minimum_size = Vector2(340, 0)
	canvas.add_child(_lobby_panel)
	_info_layout = VBoxContainer.new()
	_lobby_panel.add_child(_info_layout)
	_lobby_controls = VBoxContainer.new()
	_info_layout.add_child(_lobby_controls)
	var title := Label.new()
	title.text = "HALAKA  |  2–4 PLAYERS"
	_lobby_controls.add_child(title)
	var instructions := Label.new()
	instructions.text = "Host a game or enter the host's LAN address."
	instructions.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lobby_controls.add_child(instructions)
	_address_input = LineEdit.new()
	_address_input.placeholder_text = "Host IP address"
	_address_input.text = "127.0.0.1"
	_lobby_controls.add_child(_address_input)
	var buttons := HBoxContainer.new()
	_lobby_controls.add_child(buttons)
	var host_button := Button.new()
	host_button.text = "Host Game"
	host_button.pressed.connect(_host_game)
	buttons.add_child(host_button)
	var join_button := Button.new()
	join_button.text = "Join Game"
	join_button.pressed.connect(_join_game)
	buttons.add_child(join_button)
	_info_layout.add_child(HSeparator.new())
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_layout.add_child(_status_label)
	_player_list_label = Label.new()
	_info_layout.add_child(_player_list_label)
	_refresh_player_list()

func _host_game() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(GAME_PORT, MAX_REMOTE_PLAYERS)
	if error != OK:
		_set_status("Couldn't host: %s" % error_string(error))
		return
	multiplayer.multiplayer_peer = peer
	_spawn_peer(1)
	_lobby_controls.hide()
	_refresh_status("Hosting on port %d" % GAME_PORT)

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
	for index in range(4):
		if not used_character_indices.has(index):
			return index
	return -1

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
		_refresh_player_list.call_deferred()

func _on_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server():
		var player := players.get_node_or_null("Player_%d" % peer_id)
		if player != null:
			player_spawner.despawn(player)
			_refresh_status.call_deferred("Player %d left" % peer_id)
	else:
		_refresh_player_list.call_deferred()

func _on_player_spawned(_player: Node) -> void:
	_refresh_player_list.call_deferred()
	_maybe_start_round.call_deferred()

func _on_player_despawned(_player: Node) -> void:
	_refresh_player_list.call_deferred()
	_update_round_hud.call_deferred()

func _on_connected_to_server() -> void:
	_lobby_controls.hide()
	_refresh_status("Connected to host")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_round_hud()

func _on_connection_failed() -> void:
	_set_status("Connection failed. Check the host IP and port %d." % GAME_PORT)
	multiplayer.multiplayer_peer = null
	_lobby_controls.show()

func _on_server_disconnected() -> void:
	_set_status("Host disconnected.")
	_lobby_controls.show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _refresh_status(message: String) -> void:
	_status_message = message
	_refresh_player_list()

func _refresh_player_list() -> void:
	if _player_list_label == null:
		return
	var active_players := get_tree().get_nodes_in_group("players")
	active_players.sort_custom(func(a: Node, b: Node) -> bool: return a.owner_peer_id < b.owner_peer_id)
	var lines: PackedStringArray = ["Players (%d/4):" % active_players.size()]
	for player in active_players:
		var entry := "Player %d" % player.owner_peer_id
		if _network_is_active() and player.owner_peer_id == multiplayer.get_unique_id():
			entry += " (you)"
		lines.append(entry)
	if active_players.is_empty():
		lines.append("Waiting for players...")
	_player_list_label.text = "\n".join(lines)
	_render_status()

func _set_status(message: String) -> void:
	_status_message = message
	_render_status()

func _render_status() -> void:
	if _status_label != null:
		var player_count := get_tree().get_nodes_in_group("players").size()
		_status_label.text = "%s  |  Players: %d/4" % [_status_message, player_count]
