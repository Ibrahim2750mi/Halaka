extends CharacterBody3D
## Hunts the player by recomputing shortest routes through the maze's walkable cells.

@export var maze_path: NodePath
@export var player_path: NodePath
@export var chase_speed := 2.8
@export var gravity := 18.0
@export var repath_interval := 0.55
var stun_remaining := 0.0
var round_active := false

@onready var maze: Node = get_node(maze_path)

var _path: Array[Vector2i] = []
var _path_index := 0
var _repath_timer := 0.0
var _run_animation: StringName = &""
var _animation_player: AnimationPlayer
var _initialized := false

func _ready() -> void:
	_find_animation_player(self)
	_select_run_animation()

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority() or not round_active:
		return
	if stun_remaining > 0.0:
		stun_remaining = maxf(0.0, stun_remaining - delta)
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= gravity * delta
		move_and_slide()
		return
	var active_players := get_tree().get_nodes_in_group("players")
	active_players = active_players.filter(func(player: Node) -> bool: return player.is_alive)
	if active_players.is_empty():
		return
	if not _initialized:
		var start_cell: Vector2i = maze.world_to_cell(active_players[0].global_position)
		global_position = maze.cell_to_world(maze.find_farthest_cell(start_cell))
		_initialized = true
		_update_path()
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_update_path()
		_repath_timer = repath_interval
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	var move_direction := Vector3.ZERO
	while _path_index < _path.size():
		var waypoint: Vector3 = maze.cell_to_world(_path[_path_index])
		waypoint.y = global_position.y
		var offset := waypoint - global_position
		if offset.length() < 0.48:
			_path_index += 1
			continue
		move_direction = offset.normalized()
		break
	velocity.x = move_direction.x * chase_speed
	velocity.z = move_direction.z * chase_speed
	if move_direction.length_squared() > 0.001:
		look_at(global_position + Vector3(move_direction.x, 0.0, move_direction.z), Vector3.UP)
	move_and_slide()

func start_hunt() -> void:
	if not multiplayer.is_server():
		return
	var active_players := get_tree().get_nodes_in_group("players")
	active_players = active_players.filter(func(player: Node) -> bool: return player.is_alive)
	if active_players.is_empty():
		return
	var start_cell: Vector2i = maze.world_to_cell(active_players[0].global_position)
	global_position = maze.cell_to_world(maze.find_farthest_cell(start_cell))
	velocity = Vector3.ZERO
	_initialized = true
	_repath_timer = 0.0
	_update_path()
	round_active = true
	visible = true

func stop_hunt() -> void:
	round_active = false
	velocity = Vector3.ZERO
	visible = false

func _update_path() -> void:
	var current_cell: Vector2i = maze.world_to_cell(global_position)
	var shortest_path: Array[Vector2i] = []
	for player in get_tree().get_nodes_in_group("players"):
		if not player.is_alive:
			continue
		var target_cell: Vector2i = maze.world_to_cell(player.global_position)
		var candidate: Array[Vector2i] = maze.find_path(current_cell, target_cell)
		if not candidate.is_empty() and (shortest_path.is_empty() or candidate.size() < shortest_path.size()):
			shortest_path = candidate
	_path = shortest_path
	_path_index = 1 if _path.size() > 1 else 0

func _find_animation_player(node: Node) -> void:
	if node is AnimationPlayer:
		_animation_player = node
		return
	for child in node.get_children():
		_find_animation_player(child)
		if _animation_player != null:
			return

func _select_run_animation() -> void:
	if _animation_player == null:
		return
	for animation_name in _animation_player.get_animation_list():
		if "run" in String(animation_name).to_lower():
			_run_animation = animation_name
			var animation := _animation_player.get_animation(animation_name)
			animation.loop_mode = Animation.LOOP_LINEAR
			_animation_player.play(_run_animation)
			return
