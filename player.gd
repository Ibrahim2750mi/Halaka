extends CharacterBody3D

@export var move_speed := 5.0
@export var jump_speed := 4.5
@export var mouse_sensitivity := 0.0025
@export var gravity := 18.0

@onready var camera: Camera3D = $Camera3D
var _camera_pitch := 0.0

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_camera_pitch = clampf(_camera_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-85.0), deg_to_rad(85.0))
		camera.rotation.x = _camera_pitch
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	var move_input := Vector2.ZERO
	if Input.is_key_pressed(KEY_A):
		move_input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		move_input.x += 1.0
	if Input.is_key_pressed(KEY_W):
		move_input.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		move_input.y += 1.0
	move_input = move_input.normalized()
	var move_direction := global_basis.x * move_input.x + global_basis.z * move_input.y
	velocity.x = move_direction.x * move_speed
	velocity.z = move_direction.z * move_speed
	if is_on_floor():
		if Input.is_key_pressed(KEY_SPACE):
			velocity.y = jump_speed
	else:
		velocity.y -= gravity * delta
	move_and_slide()
