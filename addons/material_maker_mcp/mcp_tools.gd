extends Node

## The MCP tools. They work through Material Maker's own loader, node library,
## graph editor (so edits show live and can be undone) and exporter.

const ExportCommand = preload("res://parse_args.gd")

const NO_WINDOW : String = "The Material Maker window is not ready"
const NO_GRAPH : String = "No graph is open in Material Maker"

const INSTRUCTIONS : String = """Material Maker builds procedural PBR materials from node graphs.
These tools work on the graph shown in the current Material Maker tab: the user sees every edit live and can undo it.
Find nodes with list_nodes, read their parameters and ports with describe_node, then build with add_node, connect_nodes and set_parameters, or load a whole graph (the .ptex JSON format) with load_graph.
Check outputs with render_node and write texture maps with export_material. Node names are the names used in graph JSON, ports count from 0.
Examples, including a cookbook of finished materials, are listed by list_examples."""

const GRAPH_ARGUMENTS : Dictionary = {
	"graph": { "type": "object", "description": "A graph in Material Maker's .ptex JSON format" },
	"path": { "type": "string", "description": "Path of a .ptex file (used instead of graph)" }
}

const TOOLS : Array = [
	{
		"name": "list_nodes",
		"description": "Search Material Maker's node library, like the Add Node popup. Returns library items (e.g. 'Simple/Shape/Circle') with their node type.",
		"inputSchema": { "type": "object", "properties": {
			"filter": { "type": "string", "description": "Words to search for; empty lists every item" } } }
	},
	{
		"name": "describe_node",
		"description": "Parameters (with ranges and enum values), inputs and outputs of a node type or library item.",
		"inputSchema": { "type": "object", "required": [ "node" ], "properties": {
			"node": { "type": "string", "description": "A node type (e.g. 'shape') or a library item (e.g. 'Simple/Shape/Circle')" } } }
	},
	{
		"name": "validate_graph",
		"description": "Builds a graph with Material Maker's loader without opening it, and reports nodes it cannot create and connections it cannot make.",
		"inputSchema": { "type": "object", "properties": GRAPH_ARGUMENTS }
	},
	{
		"name": "load_graph",
		"description": "Opens a graph in Material Maker, in a new tab unless replace is true.",
		"inputSchema": { "type": "object", "properties": {
			"graph": GRAPH_ARGUMENTS.graph,
			"path": GRAPH_ARGUMENTS.path,
			"replace": { "type": "boolean", "description": "Replace the graph of the current tab once it has finished rendering (refused when it has unsaved changes)" } } }
	},
	{
		"name": "new_graph",
		"description": "Opens a new tab with an empty material.",
		"inputSchema": { "type": "object", "properties": {} }
	},
	{
		"name": "get_graph",
		"description": "The graph shown in the current tab, in .ptex JSON format, with its file path and the material's export targets.",
		"inputSchema": { "type": "object", "properties": {} }
	},
	{
		"name": "save_graph",
		"description": "Saves the current tab's project as a .ptex file.",
		"inputSchema": { "type": "object", "properties": {
			"path": { "type": "string", "description": "File to save to; defaults to the tab's current file" } } }
	},
	{
		"name": "add_node",
		"description": "Adds a node to the current graph and returns its name.",
		"inputSchema": { "type": "object", "required": [ "node" ], "properties": {
			"node": { "type": "string", "description": "A node type or a library item" },
			"name": { "type": "string", "description": "Name for the new node; Material Maker adds a number if it is taken" },
			"parameters": { "type": "object", "description": "Parameter values, see describe_node" },
			"x": { "type": "number" },
			"y": { "type": "number" } } }
	},
	{
		"name": "connect_nodes",
		"description": "Connects an output of a node to an input of another, replacing what was connected to that input.",
		"inputSchema": { "type": "object", "required": [ "from", "from_port", "to", "to_port" ], "properties": {
			"from": { "type": "string" }, "from_port": { "type": "integer" },
			"to": { "type": "string" }, "to_port": { "type": "integer" } } }
	},
	{
		"name": "disconnect_nodes",
		"description": "Removes a connection.",
		"inputSchema": { "type": "object", "required": [ "from", "from_port", "to", "to_port" ], "properties": {
			"from": { "type": "string" }, "from_port": { "type": "integer" },
			"to": { "type": "string" }, "to_port": { "type": "integer" } } }
	},
	{
		"name": "remove_node",
		"description": "Deletes a node and its connections.",
		"inputSchema": { "type": "object", "required": [ "node" ], "properties": {
			"node": { "type": "string" } } }
	},
	{
		"name": "set_parameters",
		"description": "Sets parameters of a node. Colors are {\"type\": \"Color\", \"r\": 1, \"g\": 0, \"b\": 0, \"a\": 1}; enums take the index of the value.",
		"inputSchema": { "type": "object", "required": [ "node", "parameters" ], "properties": {
			"node": { "type": "string" },
			"parameters": { "type": "object" } } }
	},
	{
		"name": "render_node",
		"description": "Renders an output of a node once all buffers are up to date; for the Material node the outputs are its maps (see describe_node). Returns the image (up to 1024 pixels) and can save it as PNG.",
		"inputSchema": { "type": "object", "required": [ "node" ], "properties": {
			"node": { "type": "string" },
			"port": { "type": "integer", "description": "Output index, default 0" },
			"size": { "type": "integer", "description": "Edge length in pixels, default 512" },
			"path": { "type": "string", "description": "PNG file to save the render to" } } }
	},
	{
		"name": "export_material",
		"description": "Exports the texture maps of the current project, or of a .ptex file, like File > Export. Returns the files written.",
		"inputSchema": { "type": "object", "required": [ "path" ], "properties": {
			"path": { "type": "string", "description": "Path prefix of the files, e.g. C:/out/rock writes rock_albedo.png and so on" },
			"target": { "type": "string", "description": "Export target, default 'Godot/Godot 4 Standard' (see get_graph)" },
			"size": { "type": "integer", "description": "Edge length in pixels; default is the material's Size" },
			"graph_path": { "type": "string", "description": "Export this .ptex file instead of the current project" } } }
	},
	{
		"name": "list_examples",
		"description": "Example projects shipped with Material Maker, including a cookbook of finished materials with recipe notes. Open one with load_graph.",
		"inputSchema": { "type": "object", "properties": {} }
	}
]


func call_tool(tool_name : String, args : Dictionary) -> Dictionary:
	if not has_method("tool_"+tool_name):
		return error_result("Unknown tool: "+tool_name)
	var result = await Callable(self, "tool_"+tool_name).call(args)
	if result is String:
		return error_result(result)
	var content : Array = []
	if result.has("image"):
		content.append({ type="image", data=Marshalls.raw_to_base64(result.image), mimeType="image/png" })
		result.erase("image")
	content.push_front({ type="text", text=JSON.stringify(result, "  ") })
	return { content=content, isError=false }

static func error_result(message : String) -> Dictionary:
	return { content=[ { type="text", text=message } ], isError=true }

# Helpers

func get_graph_edit() -> MMGraphEdit:
	if mm_globals.main_window == null:
		return null
	return mm_globals.main_window.get_current_graph_edit()

func find_node(graph_edit : MMGraphEdit, node_name) -> MMGenBase:
	return graph_edit.generator.get_node_or_null(NodePath(str(node_name)))

# Generator data for a node type or a library item
func node_data(node : String) -> Dictionary:
	if mm_globals.main_window != null:
		var library_item = mm_globals.main_window.node_library_manager.get_item(node)
		if library_item != null:
			return library_item.item.duplicate(true)
	return { type=node }

# The generator data of a "graph" (JSON object) or "path" (.ptex file) argument, or an error message
func read_graph_argument(args : Dictionary):
	if args.get("graph") is Dictionary:
		return MMLoader.replace_arrays_with_multiline_strings(args.graph.duplicate(true))
	if args.get("path") is String:
		var file : FileAccess = FileAccess.open(args.path, FileAccess.READ)
		if file == null:
			return "Cannot read %s: %s" % [ args.path, error_string(FileAccess.get_open_error()) ]
		var data : Dictionary = MMLoader.string_to_dict_tree(file.get_as_text())
		if data.is_empty():
			return "%s is not a Material Maker graph" % args.path
		return data
	return "Pass a graph (JSON object) or the path of a .ptex file"

# Builds generators (not added to the scene) from a graph argument: { generator, data } or an error message
func build_graph(args : Dictionary):
	var data = read_graph_argument(args)
	if data is String:
		return data
	var path : String = args.path if args.get("path") is String else ""
	mm_loader.current_project_path = path.get_base_dir()
	var generator : MMGenBase = await mm_loader.create_gen(data)
	mm_loader.current_project_path = ""
	if generator == null:
		return "Material Maker cannot build a graph from this data"
	if path != "":
		generator.set_meta("file_path", path)
	return { generator=generator, data=data }

# Freeing a graph while the render thread still works for it (e.g. preview readbacks, which the
# render queue does not track) froze Material Maker in tests. Waits until the thread has been idle
# for 60 frames, or 20 seconds at most.
func wait_for_render_thread_idle() -> void:
	var deadline : int = Time.get_ticks_msec()+20000
	var idle_frames : int = 0
	while idle_frames < 60 and Time.get_ticks_msec() < deadline:
		idle_frames = 0 if mm_renderer.rendering_thread_working else idle_frames+1
		await get_tree().process_frame

# Frees generators that never entered the scene tree, with their render buffers
func free_detached(generator : MMGenBase) -> void:
	var stack : Array[Node] = [ generator ]
	while not stack.is_empty():
		var node : Node = stack.pop_back()
		stack.append_array(node.get_children())
		mm_deps.delete_buffers_from_object(node)
	generator.free()

# What Material Maker could not build from graph data: unknown node types, invalid or refused connections
func graph_problems(data : Dictionary, graph : MMGenBase, prefix : String = "") -> PackedStringArray:
	var problems : PackedStringArray = []
	if not graph is MMGenGraph:
		return problems
	for n in data.get("nodes", []):
		if not n is Dictionary or not n.has("name"):
			continue
		var node : MMGenBase = graph.get_node_or_null(NodePath(n.name))
		if node == null:
			problems.append("%s%s: cannot create a node of type '%s'" % [ prefix, n.name, n.get("type", "") ])
		elif n.has("nodes"):
			problems.append_array(graph_problems(n, node, prefix+n.name+"/"))
	var connections = data.get("connections", [])
	if connections is Dictionary:
		connections = graph.connections_from_compact(connections)
	for c in connections:
		var description : String = "%s%s:%d -> %s:%d" % [ prefix, c.from, int(c.from_port), c.to, int(c.to_port) ]
		var problem : String = connection_problem(graph, c.from, int(c.from_port), c.to, int(c.to_port))
		if problem == "" and not has_connection(graph, c.from, int(c.from_port), c.to, int(c.to_port)):
			problem = "refused (it would create a loop)"
		if problem != "":
			problems.append(description+": "+problem)
	return problems

func connection_problem(graph : MMGenBase, from, from_port : int, to, to_port : int) -> String:
	var from_node : MMGenBase = graph.get_node_or_null(NodePath(str(from)))
	var to_node : MMGenBase = graph.get_node_or_null(NodePath(str(to)))
	if from_node == null or to_node == null:
		return "no node named '%s'" % (from if from_node == null else to)
	if from_port < 0 or from_port >= from_node.get_output_defs().size():
		return "%s has %d outputs" % [ from, from_node.get_output_defs().size() ]
	if to_port < 0 or to_port >= to_node.get_input_defs().size():
		return "%s has %d inputs" % [ to, to_node.get_input_defs().size() ]
	return ""

static func has_connection(graph : MMGenBase, from, from_port : int, to, to_port : int) -> bool:
	for c in graph.connections:
		if str(c.from) == str(from) and c.from_port == from_port and str(c.to) == str(to) and c.to_port == to_port:
			return true
	return false

static func port_definitions(definitions : Array) -> Array:
	var ports : Array = []
	for i in definitions.size():
		var port : Dictionary = { index=i, type=definitions[i].get("type", "") }
		for key in [ "name", "label", "shortdesc" ]:
			if definitions[i].has(key):
				port[key] = definitions[i][key]
		ports.append(port)
	return ports

# Tools

func tool_list_nodes(args : Dictionary):
	if mm_globals.main_window == null:
		return NO_WINDOW
	var nodes : Array = []
	for i in mm_globals.main_window.node_library_manager.get_items(str(args.get("filter", ""))):
		nodes.append({ item=i.name, name=i.item.get("display_name", i.name), type=i.item.get("type", "graph") })
	return { nodes=nodes }

func tool_describe_node(args : Dictionary):
	var node : String = str(args.get("node", ""))
	var generator : MMGenBase = await mm_loader.create_gen(node_data(node))
	if generator == null:
		return "Unknown node type or library item: "+node
	var parameters : Array = []
	for p in generator.get_parameter_defs():
		var parameter : Dictionary = { value=MMType.serialize_value(generator.get_parameter(p.name)) }
		for key in [ "name", "label", "type", "min", "max", "step", "values", "shortdesc", "longdesc" ]:
			if p.has(key):
				parameter[key] = p[key]
		parameters.append(parameter)
	var description : Dictionary = {
		node=node,
		name=generator.get_type_name(),
		description=generator.get_description(),
		parameters=parameters,
		inputs=port_definitions(generator.get_input_defs()),
		outputs=port_definitions(generator.get_output_defs(true))
	}
	free_detached(generator)
	return description

func tool_validate_graph(args : Dictionary):
	var built = await build_graph(args)
	if built is String:
		return built
	var problems : PackedStringArray = graph_problems(built.data, built.generator)
	var node_count : int = built.generator.get_child_count()
	free_detached(built.generator)
	return { valid=problems.is_empty(), nodes=node_count, problems=problems }

func tool_load_graph(args : Dictionary):
	var main_window = mm_globals.main_window
	if main_window == null:
		return NO_WINDOW
	var graph_edit : MMGraphEdit = get_graph_edit()
	var replace : bool = args.get("replace", false) and graph_edit != null
	if replace and graph_edit.need_save:
		return "The current tab has unsaved changes: save it, or load the graph without replace"
	# Wait before building the new graph, whose buffers only render once it is attached
	if replace:
		await mm_deps.wait_for_render_queue()
	var built = await build_graph(args)
	if built is String:
		return built
	if replace:
		await wait_for_render_thread_idle()
	else:
		graph_edit = main_window.new_graph_panel()
	graph_edit.set_save_path(args.path if args.get("path") is String else "")
	graph_edit.set_new_generator(built.generator)
	main_window.hierarchy.update_from_graph_edit(graph_edit)
	if main_window.current_mesh != null:
		built.generator.set_current_mesh(main_window.current_mesh)
	var nodes : Array = []
	for n in built.generator.get_children():
		nodes.append(n.name)
	return { loaded=graph_edit.save_path if graph_edit.save_path != "" else "graph", nodes=nodes, problems=graph_problems(built.data, built.generator) }

func tool_new_graph(_args : Dictionary):
	if mm_globals.main_window == null:
		return NO_WINDOW
	mm_globals.main_window.new_material()
	await get_tree().process_frame
	return { created=true }

func tool_get_graph(_args : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null or graph_edit.generator == null:
		return NO_GRAPH
	var result : Dictionary = { graph=graph_edit.generator.serialize(), path=graph_edit.save_path, unsaved=graph_edit.need_save }
	if graph_edit.generator != graph_edit.top_generator:
		result.subgraph = graph_edit.generator.get_hier_name()
	var material : MMGenMaterial = graph_edit.get_material_node()
	if material != null:
		result.export_targets = material.get_export_profiles()
	return result

func tool_save_graph(args : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null or graph_edit.top_generator == null:
		return NO_GRAPH
	var path : String = str(args.get("path", graph_edit.save_path))
	if path == "":
		return "This project has no file yet: pass a path"
	if not DirAccess.dir_exists_absolute(path.get_base_dir()):
		return "Folder %s does not exist" % path.get_base_dir()
	if not await graph_edit.save_file(path):
		return "Could not save "+path
	return { saved=path }

func tool_add_node(args : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null or graph_edit.generator == null:
		return NO_GRAPH
	var data : Dictionary = node_data(str(args.get("node", "")))
	if args.get("name") is String:
		data.name = args.name
	if args.get("parameters") is Dictionary:
		var parameters : Dictionary = data.get("parameters", {})
		parameters.merge(args.parameters, true)
		data.parameters = parameters
	var nodes : Array = await graph_edit.create_nodes(data, Vector2(float(args.get("x", 0)), float(args.get("y", 0))))
	if nodes.is_empty():
		return "Material Maker cannot create a node from '%s'" % args.get("node", "")
	var names : Array = []
	for n in nodes:
		names.append(n.generator.name)
	return { created=names }

func tool_connect_nodes(args : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null or graph_edit.generator == null:
		return NO_GRAPH
	var from_port : int = int(args.get("from_port", 0))
	var to_port : int = int(args.get("to_port", 0))
	var problem : String = connection_problem(graph_edit.generator, args.get("from"), from_port, args.get("to"), to_port)
	if problem != "":
		return problem
	graph_edit.on_connect_node("node_"+str(args.from), from_port, "node_"+str(args.to), to_port)
	if not has_connection(graph_edit.generator, args.from, from_port, args.to, to_port):
		return "Material Maker refused the connection (it would create a loop)"
	return { connected=true }

func tool_disconnect_nodes(args : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null or graph_edit.generator == null:
		return NO_GRAPH
	var from_port : int = int(args.get("from_port", 0))
	var to_port : int = int(args.get("to_port", 0))
	if not has_connection(graph_edit.generator, args.get("from"), from_port, args.get("to"), to_port):
		return "There is no such connection"
	graph_edit.on_disconnect_node("node_"+str(args.from), from_port, "node_"+str(args.to), to_port)
	return { disconnected=true }

func tool_remove_node(args : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null or graph_edit.generator == null:
		return NO_GRAPH
	var graph_node = graph_edit.get_node_or_null(NodePath("node_"+str(args.get("node", ""))))
	if graph_node == null:
		return "No node named '%s'" % args.get("node", "")
	if not graph_node.generator.can_be_deleted():
		return "'%s' cannot be deleted" % args.node
	graph_edit.remove_node(graph_node)
	return { removed=args.node }

func tool_set_parameters(args : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null or graph_edit.generator == null:
		return NO_GRAPH
	var generator : MMGenBase = find_node(graph_edit, args.get("node", ""))
	if generator == null:
		return "No node named '%s'" % args.get("node", "")
	if not args.get("parameters") is Dictionary:
		return "Pass the parameters as an object"
	for p in args.parameters.keys():
		if generator.get_parameter_def(p).is_empty():
			var names : PackedStringArray = []
			for d in generator.get_parameter_defs():
				names.append(d.name)
			return "%s has no parameter '%s' (it has: %s)" % [ args.node, p, ", ".join(names) ]
	graph_edit.set_node_parameters(generator, args.parameters)
	var values : Dictionary = {}
	for p in args.parameters.keys():
		values[p] = MMType.serialize_value(generator.get_parameter(p))
	return { node=args.node, parameters=values }

func tool_render_node(args : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null or graph_edit.generator == null:
		return NO_GRAPH
	var generator : MMGenBase = find_node(graph_edit, args.get("node", ""))
	if generator == null:
		return "No node named '%s'" % args.get("node", "")
	var port : int = int(args.get("port", 0))
	# Hidden outputs include the maps of Material nodes
	var output_count : int = generator.get_output_defs(true).size()
	if port < 0 or port >= output_count:
		return "%s has %d outputs" % [ args.node, output_count ]
	var size : int = clampi(int(args.get("size", 512)), 16, 8192)
	await mm_deps.wait_for_render_queue()
	var image : Image = await generator.render_output(port, Vector2i(size, size))
	image.convert(Image.FORMAT_RGBA8)
	var result : Dictionary = { node=args.node, port=port, size=size }
	if args.get("path") is String:
		var error : Error = image.save_png(args.path)
		if error != OK:
			return "Cannot save %s: %s" % [ args.path, error_string(error) ]
		result.saved = args.path
	if size <= 1024:
		result.image = image.save_png_to_buffer()
	return result

func tool_export_material(args : Dictionary):
	var prefix : String = str(args.get("path", "")).replace("\\", "/")
	if prefix == "":
		return "Pass a path prefix for the exported files"
	var target : String = str(args.get("target", "Godot/Godot 4 Standard"))
	var size : int = int(args.get("size", 0))
	var generator : MMGenBase
	if args.get("graph_path") is String:
		generator = await mm_loader.load_gen(args.graph_path)
		if generator == null:
			return "Cannot load "+args.graph_path
		add_child(generator)
	else:
		var graph_edit : MMGraphEdit = get_graph_edit()
		if graph_edit == null or graph_edit.top_generator == null:
			return NO_GRAPH
		generator = graph_edit.top_generator
	DirAccess.make_dir_recursive_absolute(prefix.get_base_dir())
	var start : int = int(Time.get_unix_time_from_system())
	var exported : int = await ExportCommand.export_generator(generator, prefix, target, size)
	if generator.get_parent() == self:
		await wait_for_render_thread_idle()
		generator.queue_free()
	if exported == 0:
		return "Nothing to export: the graph has no material or Export node"
	var files : Array = []
	var directory : String = prefix.get_base_dir()
	for f in DirAccess.get_files_at(directory):
		if FileAccess.get_modified_time(directory.path_join(f)) >= start:
			files.append(directory.path_join(f))
	return { exported=exported, files=files }

func tool_list_examples(_args : Dictionary):
	var directory : String = MMPaths.get_examples_dir()
	var examples : Array = []
	collect_examples(directory, "", examples)
	return { directory=directory, examples=examples }

func collect_examples(directory : String, category : String, examples : Array) -> void:
	for f in DirAccess.get_files_at(directory):
		if f.get_extension() != "ptex":
			continue
		var example : Dictionary = { name=f.get_basename(), path=directory.path_join(f) }
		if category != "":
			example.category = category
		# Cookbook materials come with a recipe card titled "# <name> - <description>"
		var card : String = directory.path_join(f.get_basename()+".md")
		if FileAccess.file_exists(card):
			example.recipe = card
			var title : String = FileAccess.get_file_as_string(card).get_slice("\n", 0).trim_prefix("# ").strip_edges()
			example.description = title.get_slice(" - ", 1) if title.contains(" - ") else title
		examples.append(example)
	for d in DirAccess.get_directories_at(directory):
		collect_examples(directory.path_join(d), category.path_join(d) if category != "" else d, examples)
