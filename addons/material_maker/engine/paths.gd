@tool
class_name MMPaths

const WEBSITE_ADDRESS : String = "https://www.materialmaker.org"
#const WEBSITE_ADDRESS : String = "http://localhost:3000"

const STD_GENDEF_PATH = "res://addons/material_maker/nodes"

static func get_resource_dir() -> String:
	if Engine.is_editor_hint():
		return ProjectSettings.globalize_path("res://material_maker")
	return OS.get_executable_path().get_base_dir()

# Examples ship next to the executable; from a source checkout they are in the project
static func get_examples_dir() -> String:
	var release_examples_path : String = get_resource_dir().replace("\\", "/").path_join("examples")
	if DirAccess.dir_exists_absolute(release_examples_path):
		return release_examples_path
	return ProjectSettings.globalize_path("res://material_maker/examples")

static func get_nodes_paths() -> Array:
	return [ STD_GENDEF_PATH, get_resource_dir()+"/nodes", "user://shared_nodes" ]
