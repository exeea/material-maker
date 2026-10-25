extends SubViewport

# A material's exported maps on the ground, seen from above as MegaMek's ground shader samples them, with its hex grid
# (game_view.gdshader). An approximation for scale and repetition: the game's colour grading, parallax and material
# families are not reproduced. The Game View panel shows it, and the MCP's render_preview renders it offscreen.

# The Material node's outputs it reads (those of its Godot 4 Standard export)
const MAPS : Dictionary = { albedo_map=0, orm_map=1, normal_map=3 }
# The default scale: MegaMek's hex (30 m from point to point), the repeat of most of its ground maps
# (materials.json), three hexes across
const HEX_METRES : float = 30.0
const REPEAT_METRES : float = 12.0
const VIEW_METRES : float = 90.0

var ground : ShaderMaterial = ShaderMaterial.new()
var environment : Environment = Environment.new()
var sun : DirectionalLight3D = DirectionalLight3D.new()
var environment_applied : bool = false

func _init() -> void:
	own_world_3d = true
	msaa_3d = Viewport.MSAA_4X
	ground.shader = preload("res://material_maker/panels/game_view/game_view.gdshader")
	var plane : PlaneMesh = PlaneMesh.new()
	# Wider than any view: the camera shows two units of height
	plane.size = Vector2(40, 40)
	var mesh : MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = plane
	mesh.material_override = ground
	add_child(mesh)
	var camera : Camera3D = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2
	camera.transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(0, 4, 0))
	add_child(camera)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var world_environment : WorldEnvironment = WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	add_child(sun)

# The scale: hexes and one repeat of the maps in metres, and the height of the view in metres
func set_view(hex_metres : float, repeat_metres : float, view_metres : float, grid : bool) -> void:
	ground.set_shader_parameter("hex_metres", hex_metres)
	ground.set_shader_parameter("repeat_metres", repeat_metres)
	ground.set_shader_parameter("view_metres", view_metres)
	ground.set_shader_parameter("grid", grid)

# Renders the maps at the material's export size, 8-bit with mipmaps, as the game loads the exported PNGs
func update_maps(material : MMGenMaterial) -> void:
	if not environment_applied:
		environment_applied = true
		var environment_manager = mm_globals.main_window.get_node("EnvironmentManager")
		await environment_manager.apply_environment(mm_globals.get_config("ui_3d_preview_environment"), environment, sun)
	await mm_deps.wait_for_render_queue()
	if not is_instance_valid(material):
		return
	var map_size : int = material.get_image_size()
	for map in MAPS.keys():
		var image : Image = await material.render_output(MAPS[map], Vector2i(map_size, map_size))
		image.convert(Image.FORMAT_RGBA8)
		image.generate_mipmaps()
		ground.set_shader_parameter(map, ImageTexture.create_from_image(image))

func clear_maps() -> void:
	for map in MAPS.keys():
		ground.set_shader_parameter(map, null)
