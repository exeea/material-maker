extends SubViewport

# A material's exported maps on the ground, seen from above as MegaMek's ground shader samples them, with its hex grid
# (game_view.gdshader). An approximation for scale and repetition, seen by an orthographic camera: the game's colour
# grading, material families and lava shaders are not reproduced. The Game View panel shows it, and the MCP's
# render_preview renders it offscreen.

# The Material node's outputs it reads (those of its Godot 4 Standard export)
const MAPS : Dictionary = { albedo_map=0, orm_map=1, emission_map=2, normal_map=3, height_map=8 }
# Maps the export writes, and the game reads, only when an input of the Material node is connected (emission_tex,
# depth_tex)
const OPTIONAL_MAPS : Dictionary = { emission_map=3, height_map=6 }
# The default scale: MegaMek's hex (30 m from point to point), the repeat of most of its ground maps
# (materials.json), three hexes across
const HEX_METRES : float = 30.0
const REPEAT_METRES : float = 12.0
const VIEW_METRES : float = 90.0
# The Material node's settings for the shader's factors (their .tres names: normal_scale, roughness, metallic)
const SETTINGS : Dictionary = { normal_scale="normal", roughness_factor="roughness", metallic_factor="metallic" }

var ground : ShaderMaterial = ShaderMaterial.new()
var environment : Environment = Environment.new()
var sun : DirectionalLight3D = DirectionalLight3D.new()
var camera : Camera3D = Camera3D.new()
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
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2
	add_child(camera)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var world_environment : WorldEnvironment = WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	add_child(sun)

# The scale: hexes and one repeat of the maps in metres, and the height of the view in metres; and the camera's
# angle from straight down in degrees, which shows the parallax
func set_view(hex_metres : float, repeat_metres : float, view_metres : float, grid : bool, tilt : float) -> void:
	ground.set_shader_parameter("hex_metres", hex_metres)
	ground.set_shader_parameter("repeat_metres", repeat_metres)
	ground.set_shader_parameter("view_metres", view_metres)
	ground.set_shader_parameter("grid", grid)
	var direction : Vector3 = Vector3(0, -cos(deg_to_rad(tilt)), -sin(deg_to_rad(tilt)))
	camera.transform = Transform3D(Basis.looking_at(direction, Vector3.FORWARD), -4.0*direction)

# The settings the export writes into the .tres and the game applies: albedo_color, normal_scale, roughness, metallic,
# heightmap_scale (25 times depth_scale) and emission_energy, the last two only with their maps
func update_settings(material : MMGenMaterial) -> void:
	var tint = material.get_parameter("albedo_color")
	ground.set_shader_parameter("albedo_tint", Color(tint.r, tint.g, tint.b, tint.a))
	for uniform in SETTINGS.keys():
		ground.set_shader_parameter(uniform, material.calculate_float_parameter(SETTINGS[uniform]).get("value", 1.0))
	var depth : float = .25*material.calculate_float_parameter("depth_scale").get("value", 0.0)
	ground.set_shader_parameter("heightmap_depth", depth if reads_map(material, "height_map") else 0.0)
	var energy : float = material.calculate_float_parameter("emission_energy").get("value", 1.0)
	ground.set_shader_parameter("emission_energy", energy if reads_map(material, "emission_map") else 0.0)

# Whether the game applies an optional map: the export writes it when its input is connected, and the game applies it
# to projects exported as a StandardMaterial3D; those exported as their own ShaderMaterial (lava) have shaders of
# their own in the game
func reads_map(material : MMGenMaterial, map : String) -> bool:
	return material.get_source(OPTIONAL_MAPS[map]) != null and not material.shader_model.get("exports", {}).has("Godot/Godot 4 ShaderMaterial")

# Renders the maps at the material's export size, 8-bit with mipmaps, as the game loads the exported PNGs
func update_maps(material : MMGenMaterial) -> void:
	if not environment_applied:
		environment_applied = true
		var environment_manager = mm_globals.main_window.get_node("EnvironmentManager")
		await environment_manager.apply_environment(mm_globals.get_config("ui_3d_preview_environment"), environment, sun)
	await mm_deps.wait_for_render_queue()
	if not is_instance_valid(material):
		return
	update_settings(material)
	var map_size : int = material.get_image_size()
	for map in MAPS.keys():
		if OPTIONAL_MAPS.has(map) and not reads_map(material, map):
			continue
		var image : Image = await material.render_output(MAPS[map], Vector2i(map_size, map_size))
		image.convert(Image.FORMAT_RGBA8)
		image.generate_mipmaps()
		ground.set_shader_parameter(map, ImageTexture.create_from_image(image))

func clear_maps() -> void:
	for map in MAPS.keys():
		ground.set_shader_parameter(map, null)
