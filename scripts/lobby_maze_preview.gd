extends Control
## Draws the generated maze as a compact top-down lobby map.

var maze: Node

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

func set_maze(source: Node) -> void:
	maze = source
	queue_redraw()

func _draw() -> void:
	var bounds := Rect2(Vector2.ZERO, size)
	draw_rect(bounds, Color("#10191e"), true)
	draw_rect(bounds, Color("#41535a"), false, 2.0)
	if maze == null or maze.size_x <= 0 or maze.size_y <= 0:
		return

	var cell_size := minf(size.x / float(maze.size_x), size.y / float(maze.size_y))
	var map_size := Vector2(cell_size * maze.size_x, cell_size * maze.size_y)
	var origin := (size - map_size) * 0.5
	var padding := maxf(0.5, cell_size * 0.08)
	for x in range(maze.size_x):
		for y in range(maze.size_y):
			var rect := Rect2(
				origin + Vector2(x, y) * cell_size + Vector2.ONE * padding,
				Vector2.ONE * (cell_size - padding * 2.0)
			)
			var floor_color := Color("#28383a") if maze._is_open(x, y) else Color("#121a1e")
			draw_rect(rect, floor_color, true)

			var current := Vector2i(x, y)
			if x + 1 < maze.size_x:
				var right := current + Vector2i.RIGHT
				if maze._is_open(x, y) and maze._is_open(right.x, right.y) and not maze._can_step_between(current, right):
					draw_line(origin + Vector2(x + 1, y) * cell_size, origin + Vector2(x + 1, y + 1) * cell_size, Color("#11191d"), maxf(1.0, cell_size * 0.16))
			if y + 1 < maze.size_y:
				var down := current + Vector2i.DOWN
				if maze._is_open(x, y) and maze._is_open(down.x, down.y) and not maze._can_step_between(current, down):
					draw_line(origin + Vector2(x, y + 1) * cell_size, origin + Vector2(x + 1, y + 1) * cell_size, Color("#11191d"), maxf(1.0, cell_size * 0.16))

	var spawn_cell: Vector2i = maze.world_to_cell(maze.cell_to_world(Vector2i(24, 24)))
	var hunter_cell: Vector2i = maze.find_farthest_cell(spawn_cell)
	var hunter_center := origin + (Vector2(hunter_cell) + Vector2.ONE * 0.5) * cell_size
	draw_circle(hunter_center, maxf(2.0, cell_size * 0.31), Color("#db6c4d"))
	draw_circle(hunter_center, maxf(1.0, cell_size * 0.13), Color("#ffe0c7"))
	for peer_id in range(1, 5):
		var spawn_position: Vector3 = maze.cell_to_world(Vector2i(24, 24) + _spawn_offset(peer_id))
		var cell: Vector2i = maze.world_to_cell(spawn_position)
		var center := origin + (Vector2(cell) + Vector2.ONE * 0.5) * cell_size
		draw_circle(center, maxf(2.0, cell_size * 0.29), Color("#76d8c0"))
		draw_circle(center, maxf(1.0, cell_size * 0.12), Color("#e6fff5"))

func _spawn_offset(peer_id: int) -> Vector2i:
	var offsets: Array[Vector2i] = [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	return offsets[(peer_id - 1) % offsets.size()]
