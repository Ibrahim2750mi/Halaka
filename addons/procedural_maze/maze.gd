@tool
extends StaticBody3D
## Builds connected cave chambers and winding passages from the cave kit.

@export_range(16, 100, 1) var size_x := 48:
	set(value):
		size_x = value
		if is_inside_tree():
			generate()
@export_range(16, 100, 1) var size_y := 48:
	set(value):
		size_y = value
		if is_inside_tree():
			generate()
@export_range(1.0, 4.0, 0.1) var corridor_width := 2.0:
	set(value):
		corridor_width = value
		if is_inside_tree():
			generate()
@export_range(0.1, 2.0, 0.05) var wall_width := 0.8:
	set(value):
		wall_width = value
		if is_inside_tree():
			generate()
@export_range(1.0, 10.0, 0.1) var height := 4.05:
	set(value):
		height = value
		if is_inside_tree():
			generate()
@export var random_seed := 23:
	set(value):
		random_seed = value
		if is_inside_tree():
			generate()

const FLOOR_ASSET: PackedScene = preload("res://kenney_modular-cave-kit_1.0/Models/GLB format/template-floor.glb")
const WALL_ASSET: PackedScene = preload("res://kenney_modular-cave-kit_1.0/Models/GLB format/template-wall.glb")
var _open_cells: Array[PackedByteArray] = []
var _chamber_baffles: Array[Dictionary] = []

func _ready() -> void:
	# The editor saves generated maze geometry into the scene. At runtime, rebuild
	# the navigation data but keep those saved nodes instead of duplicating them.
	var rebuild_geometry := Engine.is_editor_hint() or get_child_count() == 0
	generate(rebuild_geometry)

func generate(rebuild_geometry := true) -> void:
	if rebuild_geometry:
		for child in get_children():
			remove_child(child)
			child.queue_free()
	_open_cells.clear()
	_chamber_baffles.clear()
	for x in range(size_x):
		var column := PackedByteArray()
		column.resize(size_y)
		_open_cells.append(column)

	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var start := Vector2i(size_x / 2, size_y / 2)
	var chambers: Array[Vector2i] = [start]
	_carve_chamber(start, 5.5, 5.0, rng)
	_add_chamber_baffles(start, 5.5, 5.0, true, true)
	for room_index in range(7):
		var center := _pick_chamber_center(chambers, rng)
		var nearest := chambers[0]
		for existing in chambers:
			if existing.distance_squared_to(center) < nearest.distance_squared_to(center):
				nearest = existing
		_carve_passage(nearest, center, rng)
		var radius_x := rng.randf_range(4.0, 6.5)
		var radius_y := rng.randf_range(4.0, 6.5)
		_carve_chamber(center, radius_x, radius_y, rng)
		if room_index > 0:
			_add_chamber_baffles(center, radius_x, radius_y, room_index in [2, 4, 6])
		chambers.append(center)

	# A few broad connecting passages make the cave feel open and give alternate routes.
	for _loop in range(2):
		var first := rng.randi_range(0, chambers.size() - 1)
		var second := rng.randi_range(0, chambers.size() - 1)
		while second == first:
			second = rng.randi_range(0, chambers.size() - 1)
		_carve_passage(chambers[first], chambers[second], rng)
	if rebuild_geometry:
		_build_geometry()

func _add_chamber_baffles(center: Vector2i, radius_x: float, radius_y: float, add_cross_walls: bool, protect_spawn := false) -> void:
	var row_offsets: Array[int] = [-4, -2, 0, 2, 4]
	var baffle_index := 0
	for row_offset in row_offsets:
		if abs(float(row_offset)) >= radius_y - 1.0:
			continue
		var row: int = center.y + row_offset
		var row_fraction := float(row_offset) / radius_y
		var half_width := max(2, int(floor(radius_x * sqrt(1.0 - row_fraction * row_fraction))) - 1)
		var min_x := max(1, center.x - half_width)
		var max_x := min(size_x - 2, center.x + half_width)
		var gap_width := 2 if protect_spawn and row_offset == 0 else 1
		var gap_start: int
		if protect_spawn and row_offset == 0:
			gap_start = center.x - int(floor(float(gap_width) * 0.5))
		else:
			gap_start = center.x + half_width - gap_width if baffle_index % 2 == 0 else center.x - half_width
		_chamber_baffles.append({
			"axis": "horizontal",
			"line": row,
			"start": min_x,
			"end": max_x,
			"gap_start": gap_start,
			"gap_end": gap_start + gap_width - 1,
		})
		baffle_index += 1
	if not add_cross_walls:
		return
	var column_offsets: Array[int] = [-3, 0, 3]
	baffle_index = 0
	for column_offset in column_offsets:
		if abs(float(column_offset)) >= radius_x - 1.0:
			continue
		var column: int = center.x + column_offset
		var column_fraction := float(column_offset) / radius_x
		var half_height := max(2, int(floor(radius_y * sqrt(1.0 - column_fraction * column_fraction))) - 1)
		var min_y := max(1, center.y - half_height)
		var max_y := min(size_y - 2, center.y + half_height)
		var gap_width := 2
		var gap_start: int
		if protect_spawn and column_offset == 0:
			gap_start = center.y - int(floor(float(gap_width) * 0.5))
		else:
			gap_start = center.y + half_height - gap_width if baffle_index % 2 == 0 else center.y - half_height
		_chamber_baffles.append({
			"axis": "vertical",
			"line": column,
			"start": min_y,
			"end": max_y,
			"gap_start": gap_start,
			"gap_end": gap_start + gap_width - 1,
		})
		baffle_index += 1

func _pick_chamber_center(chambers: Array[Vector2i], rng: RandomNumberGenerator) -> Vector2i:
	var margin := 9
	var candidate := Vector2i(size_x / 2, size_y / 2)
	for attempt in range(120):
		candidate = Vector2i(rng.randi_range(margin, size_x - margin - 1), rng.randi_range(margin, size_y - margin - 1))
		var spaced := true
		for existing in chambers:
			if existing.distance_to(candidate) < 12.0:
				spaced = false
				break
		if spaced:
			return candidate
	return candidate

func _carve_chamber(center: Vector2i, radius_x: float, radius_y: float, rng: RandomNumberGenerator) -> void:
	var min_x := max(1, int(center.x - radius_x - 1.0))
	var max_x := min(size_x - 2, int(center.x + radius_x + 1.0))
	var min_y := max(1, int(center.y - radius_y - 1.0))
	var max_y := min(size_y - 2, int(center.y + radius_y + 1.0))
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var dx := float(x - center.x) / radius_x
			var dy := float(y - center.y) / radius_y
			var rough_edge := rng.randf_range(0.88, 1.12)
			if dx * dx + dy * dy <= rough_edge:
				_set_open(x, y)

func _carve_passage(from: Vector2i, to: Vector2i, rng: RandomNumberGenerator) -> void:
	var delta := Vector2(to - from)
	var distance := delta.length()
	var steps := max(1, int(ceil(distance * 1.5)))
	var perpendicular := Vector2(-delta.y, delta.x).normalized()
	var curve_amount := rng.randf_range(1.0, 3.5)
	var phase := rng.randf_range(0.0, TAU)
	for step in range(steps + 1):
		var t := float(step) / float(steps)
		var curve := sin(t * PI) * sin(t * PI * 2.0 + phase) * curve_amount
		var point := Vector2(from).lerp(Vector2(to), t) + perpendicular * curve
		var center := Vector2i(roundi(point.x), roundi(point.y))
		_carve_tunnel_disc(center, rng.randf_range(1.8, 2.7), rng)

func _carve_tunnel_disc(center: Vector2i, radius: float, rng: RandomNumberGenerator) -> void:
	var reach := int(ceil(radius))
	for x in range(center.x - reach, center.x + reach + 1):
		for y in range(center.y - reach, center.y + reach + 1):
			var dx := float(x - center.x)
			var dy := float(y - center.y)
			if dx * dx + dy * dy <= radius * radius * rng.randf_range(0.88, 1.12):
				_set_open(x, y)

func _set_open(x: int, y: int) -> void:
	if x > 0 and x < size_x - 1 and y > 0 and y < size_y - 1:
		_open_cells[x][y] = 1

func _is_open(x: int, y: int) -> bool:
	return x >= 0 and x < size_x and y >= 0 and y < size_y and _open_cells[x][y] == 1

## Converts a world position to the nearest maze cell.
func world_to_cell(world_position: Vector3) -> Vector2i:
	var local_position := to_local(world_position)
	var origin_x := -0.5 * size_x * corridor_width + 0.5 * corridor_width
	var origin_y := -0.5 * size_y * corridor_width + 0.5 * corridor_width
	return Vector2i(
		clampi(roundi((local_position.x - origin_x) / corridor_width), 0, size_x - 1),
		clampi(roundi((local_position.z - origin_y) / corridor_width), 0, size_y - 1)
	)

func cell_to_world(cell: Vector2i) -> Vector3:
	var origin_x := -0.5 * size_x * corridor_width + 0.5 * corridor_width
	var origin_y := -0.5 * size_y * corridor_width + 0.5 * corridor_width
	return to_global(Vector3(origin_x + cell.x * corridor_width, 0.0, origin_y + cell.y * corridor_width))

## Breadth-first search over open cells, respecting the maze's interior baffle walls.
func find_path(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var empty_path: Array[Vector2i] = []
	if not _is_open(start.x, start.y) or not _is_open(goal.x, goal.y):
		return empty_path
	var queue: Array[Vector2i] = [start]
	var head := 0
	var parents: Dictionary = {start: start}
	var directions: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		if current == goal:
			break
		for direction in directions:
			var next := current + direction
			if parents.has(next) or not _is_open(next.x, next.y) or not _can_step_between(current, next):
				continue
			parents[next] = current
			queue.append(next)
	if not parents.has(goal):
		return empty_path
	var path: Array[Vector2i] = []
	var cursor := goal
	while cursor != start:
		path.push_front(cursor)
		cursor = parents[cursor]
	path.push_front(start)
	return path

## Returns the most distant reachable open cell, used to place the monster away from spawn.
func find_farthest_cell(start: Vector2i) -> Vector2i:
	var queue: Array[Vector2i] = [start]
	var head := 0
	var distances: Dictionary = {start: 0}
	var farthest := start
	var directions: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		if distances[current] > distances[farthest]:
			farthest = current
		for direction in directions:
			var next := current + direction
			if distances.has(next) or not _is_open(next.x, next.y) or not _can_step_between(current, next):
				continue
			distances[next] = distances[current] + 1
			queue.append(next)
	return farthest

func _can_step_between(from: Vector2i, to: Vector2i) -> bool:
	for baffle in _chamber_baffles:
		if baffle.axis == "horizontal" and from.x == to.x and mini(from.y, to.y) == baffle.line:
			if from.x >= baffle.start and from.x <= baffle.end and (from.x < baffle.gap_start or from.x > baffle.gap_end):
				return false
		if baffle.axis == "vertical" and from.y == to.y and mini(from.x, to.x) == baffle.line:
			if from.y >= baffle.start and from.y <= baffle.end and (from.y < baffle.gap_start or from.y > baffle.gap_end):
				return false
	return true

func _build_geometry() -> void:
	var cell_size := corridor_width
	var origin := Vector3(-0.5 * size_x * cell_size + 0.5 * cell_size, 0.0, -0.5 * size_y * cell_size + 0.5 * cell_size)
	_add_floor_visuals(origin, cell_size)
	_add_floor_collision(origin, cell_size)
	for x in range(size_x):
		for y in range(size_y):
			if not _is_open(x, y):
				continue
			var center := origin + Vector3(x * cell_size, 0.0, y * cell_size)
			if not _is_open(x - 1, y):
				_add_cave_wall("CaveWall_Left", center + Vector3(-cell_size * 0.5, 0.0, 0.0), false, cell_size)
			if not _is_open(x + 1, y):
				_add_cave_wall("CaveWall_Right", center + Vector3(cell_size * 0.5, 0.0, 0.0), false, cell_size)
			if not _is_open(x, y - 1):
				_add_cave_wall("CaveWall_Top", center + Vector3(0.0, 0.0, -cell_size * 0.5), true, cell_size)
			if not _is_open(x, y + 1):
				_add_cave_wall("CaveWall_Bottom", center + Vector3(0.0, 0.0, cell_size * 0.5), true, cell_size)
	for baffle in _chamber_baffles:
		var line: int = baffle.line
		for index in range(baffle.start, baffle.end + 1):
			if index >= baffle.gap_start and index <= baffle.gap_end:
				continue
			if baffle.axis == "horizontal":
				if _is_open(index, line) and _is_open(index, line + 1):
					var wall_center := origin + Vector3(index * cell_size, 0.0, (line + 0.5) * cell_size)
					_add_cave_wall("ChamberBaffle", wall_center, true, cell_size)
			else:
				if _is_open(line, index) and _is_open(line + 1, index):
					var wall_center := origin + Vector3((line + 0.5) * cell_size, 0.0, index * cell_size)
					_add_cave_wall("ChamberBaffle", wall_center, false, cell_size)

func _add_floor_visuals(origin: Vector3, cell_size: float) -> void:
	var floor_root := FLOOR_ASSET.instantiate()
	var floor_mesh_info := _find_mesh(floor_root, Transform3D.IDENTITY)
	if floor_mesh_info.is_empty():
		floor_root.free()
		return
	var mesh: Mesh = floor_mesh_info.mesh
	var local_transform: Transform3D = floor_mesh_info.transform
	floor_root.free()
	var transforms: Array[Transform3D] = []
	var floor_scale := cell_size / 4.0
	for x in range(size_x):
		for y in range(size_y):
			if _is_open(x, y):
				var position := origin + Vector3(x * cell_size, -0.03, y * cell_size)
				var tile_transform := Transform3D(Basis.from_scale(Vector3(floor_scale, 1.0, floor_scale)), position)
				transforms.append(tile_transform * local_transform)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in range(transforms.size()):
		multimesh.set_instance_transform(index, transforms[index])
	var floor_instance := MultiMeshInstance3D.new()
	floor_instance.name = "CaveFloor"
	floor_instance.multimesh = multimesh
	add_child(floor_instance)
	floor_instance.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null

func _add_floor_collision(origin: Vector3, cell_size: float) -> void:
	# Merge adjacent walkable cells into a smaller set of solid floor hitboxes.
	for y in range(size_y):
		var x := 0
		while x < size_x:
			while x < size_x and not _is_open(x, y):
				x += 1
			if x >= size_x:
				break
			var start_x := x
			while x < size_x and _is_open(x, y):
				x += 1
			var run_length := x - start_x
			var center_x := origin.x + (start_x + 0.5 * run_length - 0.5) * cell_size
			_add_box_collision(
				"CaveFloorCollision",
				Vector3(run_length * cell_size, 0.2, cell_size),
				Vector3(center_x, -0.1, origin.z + y * cell_size)
			)

func _add_cave_wall(node_name: String, edge_center: Vector3, along_x: bool, cell_size: float) -> void:
	var cave_wall: Node3D = WALL_ASSET.instantiate()
	cave_wall.name = node_name
	cave_wall.position = edge_center
	cave_wall.scale = Vector3((cell_size + wall_width) / 4.0, height / 4.05, wall_width / 2.0)
	if along_x:
		cave_wall.position.z += cave_wall.scale.z
	else:
		cave_wall.rotation.y = PI * 0.5
		cave_wall.position.x += cave_wall.scale.z
	add_child(cave_wall)
	cave_wall.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null
	var wall_length := cell_size + wall_width
	var collision_size := Vector3(wall_length, height, wall_width) if along_x else Vector3(wall_width, height, wall_length)
	_add_box_collision("CaveWallCollision", collision_size, edge_center + Vector3(0.0, height * 0.5, 0.0))

func _add_box_collision(node_name: String, box_size: Vector3, position: Vector3) -> void:
	var collision := CollisionShape3D.new()
	collision.name = node_name
	var shape := BoxShape3D.new()
	shape.size = box_size
	collision.shape = shape
	collision.position = position
	add_child(collision)
	collision.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null

func _find_mesh(node: Node, parent_transform: Transform3D) -> Dictionary:
	if node is MeshInstance3D and node.mesh != null:
		return {"mesh": node.mesh, "transform": parent_transform * node.transform}
	for child in node.get_children():
		var result := _find_mesh(child, parent_transform * child.transform)
		if not result.is_empty():
			return result
	return {}

