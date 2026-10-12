extends CharacterBody3D
## Each player controls only their own avatar. MultiplayerSynchronizer shares its transform.

@export var move_speed := 5.0
@export var jump_speed := 4.5
@export var mouse_sensitivity := 0.0025
@export var gravity := 18.0

@onready var camera: Camera3D = $Camera3D
@onready var visual: MeshInstance3D = $Visual
@onready var flashlight: SpotLight3D = $Camera3D/Flashlight
@onready var local_beam: MeshInstance3D = $Camera3D/LocalBeam
var owner_peer_id := 1
var _camera_pitch := 0.0
var _remote_input := Vector2.ZERO
var _remote_yaw := 0.0
var _remote_pitch := 0.0
var _remote_jump := false
var _input_send_timer := 0.0

func _ready() -> void:
	var is_local := multiplayer.get_unique_id() == owner_peer_id
	camera.current = is_local
	if is_local:
		camera.make_current()
	flashlight.visible = true
	flashlight.position = Vector3(0.0, -0.05, -0.2)
	flashlight.light_energy = 5.0
	flashlight.spot_range = 20.0
	flashlight.spot_angle = 42.0
	flashlight.light_volumetric_fog_energy = 0.0
	flashlight.shadow_enabled = false
	local_beam.visible = is_local
	visual.visible = not is_local
	var player_colors: Array[Color] = [Color(0.22, 0.75, 0.95), Color(0.96, 0.42, 0.24), Color(0.56, 0.9, 0.38), Color(0.86, 0.55, 0.96)]
	var player_material := StandardMaterial3D.new()
	player_material.albedo_color = player_colors[(owner_peer_id - 1) % player_colors.size()]
	visual.material_override = player_material
	if is_local and multiplayer.has_multiplayer_peer():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	add_to_group("players")

func _unhandled_input(event: InputEvent) -> void:
	if multiplayer.get_unique_id() != owner_peer_id:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_camera_pitch = clampf(_camera_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-85.0), deg_to_rad(85.0))
		camera.rotation.x = _camera_pitch
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if multiplayer.is_server():
		var server_input := _read_move_input() if owner_peer_id == 1 else _remote_input
		if owner_peer_id != 1:
			rotation.y = _remote_yaw
			camera.rotation.x = _remote_pitch
		var server_jump := Input.is_key_pressed(KEY_SPACE) if owner_peer_id == 1 else _remote_jump
		_simulate_movement(delta, server_input, server_jump)
	elif multiplayer.get_unique_id() == owner_peer_id:
		var predicted_input := _read_move_input()
		var jump_pressed := Input.is_key_pressed(KEY_SPACE)
		_simulate_movement(delta, predicted_input, jump_pressed)
		_input_send_timer -= delta
		if _input_send_timer <= 0.0:
			_submit_input.rpc_id(1, predicted_input, rotation.y, _camera_pitch, jump_pressed)
			_input_send_timer = 1.0 / 30.0

func _simulate_movement(delta: float, move_input: Vector2, jump_pressed: bool) -> void:
	move_input = move_input.normalized()
	var move_direction := global_basis.x * move_input.x + global_basis.z * move_input.y
	velocity.x = move_direction.x * move_speed
	velocity.z = move_direction.z * move_speed
	if is_on_floor():
		if jump_pressed:
			velocity.y = jump_speed
	else:
		velocity.y -= gravity * delta
	move_and_slide()

func _read_move_input() -> Vector2:
	var move_input := Vector2.ZERO
	if Input.is_key_pressed(KEY_A):
		move_input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		move_input.x += 1.0
	if Input.is_key_pressed(KEY_W):
		move_input.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		move_input.y += 1.0
	return move_input.normalized()

@rpc("any_peer", "unreliable")
func _submit_input(move_input: Vector2, body_yaw: float, camera_pitch: float, jump_pressed: bool) -> void:
	if not multiplayer.is_server() or multiplayer.get_remote_sender_id() != owner_peer_id:
		return
	_remote_input = move_input
	_remote_yaw = body_yaw
	_remote_pitch = camera_pitch
	_remote_jump = jump_pressed
