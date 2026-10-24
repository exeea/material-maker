extends Node

## The MCP tools. They work through Material Maker's own loader, node library,
## graph editor (so edits show live and can be undone) and exporter.

const ExportCommand = preload("res://parse_args.gd")

const NO_WINDOW : String = "The Material Maker window is not ready"
const NO_GRAPH : String = "No graph is open in Material Maker"

const INSTRUCTIONS : String = """Material Maker builds procedural PBR materials from node graphs.
These tools work on a Material Maker tab, live: the user sees every edit and can undo it. load_graph, new_graph and get_graph return the tab's handle; pass it as tab to stay on that tab when the user or another agent switches tabs. Graphs can hold subgraphs (get_graph counts their nodes): pass subgraph, the node names from the top level joined by '/', to read, edit or render inside one, "" for the top level. By default tools use the current tab and the graph it shows.
Find nodes with list_nodes, read their parameters and ports with describe_node, then build with apply_edits (or add_node, connect_nodes and set_parameters), or load a whole graph (the .ptex JSON format) with load_graph. Close tabs you no longer need with close_graph.
Check outputs with render_node, judge the material lit and tiled with render_preview, compare parameter values with render_sweep, and write texture maps with export_material. Node names are the names used in graph JSON, ports count from 0.
Examples, including a cookbook of finished materials, are listed by list_examples."""

const GRAPH_ARGUMENTS : Dictionary = {
	"graph": { "type": "object", "description": "A graph in Material Maker's .ptex JSON format" },
	"path": { "type": "string", "description": "Path of a .ptex file (used instead of graph)" }
}
const TAB_ARGUMENT : Dictionary = { "type": "integer", "description": "Handle of the tab to work on, from load_graph, new_graph or get_graph; default the current tab" }
const SUBGRAPH_ARGUMENT : Dictionary = { "type": "string", "description": "Subgraph to work in: node names from the top level joined by '/', \"\" for the top level; default the graph the tab shows" }

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
		"description": "Opens a graph in Material Maker, in a new tab unless replace is true, and returns the tab's handle.",
		"inputSchema": { "type": "object", "properties": {
			"graph": GRAPH_ARGUMENTS.graph,
			"path": GRAPH_ARGUMENTS.path,
			"replace": { "type": "boolean", "description": "Replace the graph of a tab once it has finished rendering (refused when it has unsaved changes)" },
			"tab": TAB_ARGUMENT } }
	},
	{
		"name": "new_graph",
		"description": "Opens a new tab with an empty material and returns the tab's handle.",
		"inputSchema": { "type": "object", "properties": {} }
	},
	{
		"name": "get_graph",
		"description": "A tab's graph, or one of its subgraphs: each node's type, its parameters that differ from their defaults and its comments, and the connections, with the tab's handle, the subgraph path, the file path and the material's export targets. full returns the .ptex JSON instead.",
		"inputSchema": { "type": "object", "properties": {
			"full": { "type": "boolean", "description": "Return the whole graph in .ptex JSON format" },
			"tab": TAB_ARGUMENT,
			"subgraph": SUBGRAPH_ARGUMENT } }
	},
	{
		"name": "save_graph",
		"description": "Saves a tab's project as a .ptex file.",
		"inputSchema": { "type": "object", "properties": {
			"path": { "type": "string", "description": "File to save to; defaults to the tab's current file" },
			"tab": TAB_ARGUMENT } }
	},
	{
		"name": "close_graph",
		"description": "Closes a tab, once its renders are done. Refused when it has unsaved changes, unless discard is true.",
		"inputSchema": { "type": "object", "properties": {
			"discard": { "type": "boolean", "description": "Close even with unsaved changes" },
			"tab": TAB_ARGUMENT } }
	},
	{
		"name": "apply_edits",
		"description": "Applies several edits to a graph in order, as one undo step, and stops at the first that fails. Each edit has an op: add (node, name, parameters, x, y), connect or disconnect (from, from_port, to, to_port), remove (node) or set (node, parameters), with the arguments of add_node, connect_nodes, disconnect_nodes, remove_node and set_parameters. Later edits can use the names earlier add edits asked for. The tab shows the graph edited.",
		"inputSchema": { "type": "object", "required": [ "edits" ], "properties": {
			"edits": { "type": "array", "items": { "type": "object" } },
			"tab": TAB_ARGUMENT,
			"subgraph": SUBGRAPH_ARGUMENT } }
	},
	{
		"name": "add_node",
		"description": "Adds a node to a graph and returns its name.",
		"inputSchema": { "type": "object", "required": [ "node" ], "properties": {
			"node": { "type": "string", "description": "A node type or a library item" },
			"name": { "type": "string", "description": "Name for the new node; Material Maker adds a number if it is taken" },
			"parameters": { "type": "object", "description": "Parameter values, see describe_node" },
			"x": { "type": "number" },
			"y": { "type": "number" },
			"tab": TAB_ARGUMENT,
			"subgraph": SUBGRAPH_ARGUMENT } }
	},
	{
		"name": "connect_nodes",
		"description": "Connects an output of a node to an input of another, replacing what was connected to that input.",
		"inputSchema": { "type": "object", "required": [ "from", "from_port", "to", "to_port" ], "properties": {
			"from": { "type": "string" }, "from_port": { "type": "integer" },
			"to": { "type": "string" }, "to_port": { "type": "integer" },
			"tab": TAB_ARGUMENT,
			"subgraph": SUBGRAPH_ARGUMENT } }
	},
	{
		"name": "disconnect_nodes",
		"description": "Removes a connection.",
		"inputSchema": { "type": "object", "required": [ "from", "from_port", "to", "to_port" ], "properties": {
			"from": { "type": "string" }, "from_port": { "type": "integer" },
			"to": { "type": "string" }, "to_port": { "type": "integer" },
			"tab": TAB_ARGUMENT,
			"subgraph": SUBGRAPH_ARGUMENT } }
	},
	{
		"name": "remove_node",
		"description": "Deletes a node and its connections.",
		"inputSchema": { "type": "object", "required": [ "node" ], "properties": {
			"node": { "type": "string" },
			"tab": TAB_ARGUMENT,
			"subgraph": SUBGRAPH_ARGUMENT } }
	},
	{
		"name": "set_parameters",
		"description": "Sets parameters of a node. Colors are {\"type\": \"Color\", \"r\": 1, \"g\": 0, \"b\": 0, \"a\": 1}; enums take the index of the value.",
		"inputSchema": { "type": "object", "required": [ "node", "parameters" ], "properties": {
			"node": { "type": "string" },
			"parameters": { "type": "object" },
			"tab": TAB_ARGUMENT,
			"subgraph": SUBGRAPH_ARGUMENT } }
	},
	{
		"name": "render_node",
		"description": "Renders an output of a node once all buffers are up to date; for the Material node the outputs are its maps (see describe_node). Returns the image (up to 1024 pixels) and can save it as PNG.",
		"inputSchema": { "type": "object", "required": [ "node" ], "properties": {
			"node": { "type": "string" },
			"port": { "type": "integer", "description": "Output index, default 0" },
			"size": { "type": "integer", "description": "Edge length in pixels, default 512" },
			"path": { "type": "string", "description": "PNG file to save the render to" },
			"tab": TAB_ARGUMENT,
			"subgraph": SUBGRAPH_ARGUMENT } }
	},
	{
		"name": "render_preview",
		"description": "Renders a tab's material lit like the 3D preview: on a sphere, on a square seen at an angle (one repeat), or tiled 3x3 seen from above to check seams and repetition. Returns the image (up to 1024 pixels) and can save it as PNG.",
		"inputSchema": { "type": "object", "properties": {
			"view": { "type": "string", "enum": [ "sphere", "plane", "tiled" ], "description": "Default sphere" },
			"size": { "type": "integer", "description": "Edge length in pixels, default 512" },
			"path": { "type": "string", "description": "PNG file to save the render to" },
			"tab": TAB_ARGUMENT } }
	},
	{
		"name": "render_sweep",
		"description": "Renders a node output, or a material preview, once for each value of one parameter, as one contact sheet read left to right then top to bottom. The parameter is restored afterwards.",
		"inputSchema": { "type": "object", "required": [ "node", "parameter", "values" ], "properties": {
			"node": { "type": "string" },
			"parameter": { "type": "string" },
			"values": { "type": "array", "description": "1 to 16 values, in the format of set_parameters" },
			"view": { "type": "string", "enum": [ "output", "sphere", "plane", "tiled" ], "description": "What each cell shows, default output (the node's output)" },
			"port": { "type": "integer", "description": "Output index for the output view, default 0" },
			"size": { "type": "integer", "description": "Edge length of each cell in pixels, default 256" },
			"path": { "type": "string", "description": "PNG file to save the sheet to" },
			"tab": TAB_ARGUMENT,
			"subgraph": SUBGRAPH_ARGUMENT } }
	},
	{
		"name": "export_material",
		"description": "Exports the texture maps of a tab's project, or of a .ptex file, like File > Export. Returns the files written.",
		"inputSchema": { "type": "object", "required": [ "path" ], "properties": {
			"path": { "type": "string", "description": "Path prefix of the files, e.g. C:/out/rock writes rock_albedo.png and so on" },
			"target": { "type": "string", "description": "Export target, default 'Godot/Godot 4 Standard' (see get_graph)" },
			"size": { "type": "integer", "description": "Edge length in pixels; default is the material's Size" },
			"graph_path": { "type": "string", "description": "Export this .ptex file instead of a tab's project" },
			"tab": TAB_ARGUMENT } }
	},
	{
		"name": "list_examples",
		"description": "Example projects shipped with Material Maker, including a cookbook of finished materials with recipe notes, and the project graphs of folders given with --mcp-examples. Open one with load_graph.",
		"inputSchema": { "type": "object", "properties": {
			"filter": { "type": "string", "description": "Only examples whose name, category or description contains this text" } } }
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

var next_tab : int = 1

# The graph editor of the tab a tool works on: the tab with the handle given as "tab", else the
# current tab; or an error message
func target_graph_edit(args : Dictionary):
	if mm_globals.main_window == null:
		return NO_WINDOW
	if args.get("tab") == null:
		var graph_edit : MMGraphEdit = mm_globals.main_window.get_current_graph_edit()
		return graph_edit if graph_edit != null and graph_edit.top_generator != null else NO_GRAPH
	var projects = mm_globals.main_window.projects_panel.get_projects()
	for i in projects.get_tab_count():
		var graph_edit : MMGraphEdit = tab_graph_edit(projects, i)
		if graph_edit != null and graph_edit.get_meta("mcp_tab", 0) == int(args.tab):
			return graph_edit
	return "No open tab has the handle %d" % int(args.tab)

static func tab_graph_edit(projects, index : int) -> MMGraphEdit:
	var control : Control = projects.get_tab(index)
	return control.get_graph_edit() if control.has_method("get_graph_edit") else null

# A tab's handle: a number that stays the same while the tab is open
func tab_handle(graph_edit : MMGraphEdit) -> int:
	if not graph_edit.has_meta("mcp_tab"):
		graph_edit.set_meta("mcp_tab", next_tab)
		next_tab += 1
	return graph_edit.get_meta("mcp_tab")

# The graph a tool works on in a tab: the subgraph path given as "subgraph" (node names from the
# top level joined by "/", "" for the top level), else the graph the tab shows; or an error message
static func target_graph(graph_edit : MMGraphEdit, args : Dictionary):
	if args.get("subgraph") == null:
		return graph_edit.generator
	var graph = graph_edit.get_node_from_hier_name(str(args.subgraph))
	if graph is MMGenGraph and (graph == graph_edit.top_generator or graph_edit.top_generator.is_ancestor_of(graph)):
		return graph
	return "No subgraph '%s'" % args.subgraph

# The node named "node" in the graph a tool works on, or an error message
static func target_node(graph_edit : MMGraphEdit, args : Dictionary):
	var graph = target_graph(graph_edit, args)
	if graph is String:
		return graph
	var generator = graph.get_node_or_null(NodePath(str(args.get("node", ""))))
	return generator if generator is MMGenBase else "No node named '%s'" % args.get("node", "")

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
	var replace : bool = args.get("replace", false)
	var graph_edit = target_graph_edit(args) if replace else null
	if graph_edit is String:
		return graph_edit
	if replace and graph_edit.need_save:
		return "The tab has unsaved changes: save it, or load the graph without replace"
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
	if graph_edit == main_window.get_current_graph_edit():
		main_window.hierarchy.update_from_graph_edit(graph_edit)
	if main_window.current_mesh != null:
		built.generator.set_current_mesh(main_window.current_mesh)
	var nodes : Array = []
	for n in built.generator.get_children():
		nodes.append(n.name)
	return { tab=tab_handle(graph_edit), loaded=graph_edit.save_path if graph_edit.save_path != "" else "graph", nodes=nodes, problems=graph_problems(built.data, built.generator) }

func tool_new_graph(_args : Dictionary):
	if mm_globals.main_window == null:
		return NO_WINDOW
	mm_globals.main_window.new_material()
	await get_tree().process_frame
	return { created=true, tab=tab_handle(mm_globals.main_window.get_current_graph_edit()) }

func tool_get_graph(args : Dictionary):
	var graph_edit = target_graph_edit(args)
	if graph_edit is String:
		return graph_edit
	var graph = target_graph(graph_edit, args)
	if graph is String:
		return graph
	var result : Dictionary = { tab=tab_handle(graph_edit), subgraph=graph.get_hier_name(), path=graph_edit.save_path, unsaved=graph_edit.need_save }
	if args.get("full", false):
		result.graph = graph.serialize()
	else:
		result.nodes = compact_nodes(graph)
		var connections : PackedStringArray = []
		for c in graph.connections:
			connections.append("%s:%d -> %s:%d" % [ c.from, c.from_port, c.to, c.to_port ])
		result.connections = connections
	var material : MMGenMaterial = graph_edit.get_material_node()
	if material != null:
		result.export_targets = material.get_export_profiles()
	return result

# Each node's type and the parameters that differ from their defaults; comments with their text
static func compact_nodes(graph : MMGenGraph) -> Array:
	var nodes : Array = []
	for generator in graph.get_children():
		if not generator is MMGenBase:
			continue
		var node : Dictionary = { name=generator.name, type=generator.model if generator.model != null else generator.get_type() }
		if generator is MMGenComment:
			node.text = generator.text
		var parameters : Dictionary = {}
		for definition in generator.get_parameter_defs():
			var value = MMType.serialize_value(generator.get_parameter(definition.name))
			if not definition.has("default") or differs(value, MMType.serialize_value(MMType.deserialize_value(definition.default))):
				parameters[definition.name] = value
		if not parameters.is_empty():
			node.parameters = parameters
		if generator is MMGenGraph:
			node.label = generator.label
			node.nodes = generator.get_child_count()
		nodes.append(node)
	return nodes

# != fails on values of different types, e.g. a float parameter that holds an expression string
static func differs(a, b) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return a != b
	return typeof(a) != typeof(b) or a != b

func tool_save_graph(args : Dictionary):
	var graph_edit = target_graph_edit(args)
	if graph_edit is String:
		return graph_edit
	var path : String = str(args.get("path", graph_edit.save_path))
	if path == "":
		return "This project has no file yet: pass a path"
	if not DirAccess.dir_exists_absolute(path.get_base_dir()):
		return "Folder %s does not exist" % path.get_base_dir()
	if not await graph_edit.save_file(path):
		return "Could not save "+path
	return { saved=path }

func tool_close_graph(args : Dictionary):
	var graph_edit = target_graph_edit(args)
	if graph_edit is String:
		return graph_edit
	if graph_edit.need_save and not args.get("discard", false):
		return "The tab has unsaved changes: save it, or pass discard"
	# Closing frees the graph: none of its renders may still be running
	await mm_deps.wait_for_render_queue()
	await wait_for_render_thread_idle()
	if graph_edit.need_save:
		graph_edit.remove_crash_recovery_file()
	var closed : String = graph_edit.save_path
	var projects = mm_globals.main_window.projects_panel.get_projects()
	var current : Control = projects.get_current_tab_control()
	for i in projects.get_tab_count():
		if tab_graph_edit(projects, i) == graph_edit:
			projects.do_close_tab(i)
			break
	# Closing a tab shows the first one: keep showing the tab that was shown
	if is_instance_valid(current):
		projects.current_tab = current.get_index()
	return { closed=closed if closed != "" else "graph", open_tabs=projects.get_tab_count() }

func tool_apply_edits(args : Dictionary):
	if not args.get("edits") is Array or args.edits.is_empty():
		return "Pass a list of edits"
	return await run_edits(args, args.edits)

func tool_add_node(args : Dictionary):
	return await run_edit(args.merged({ op="add" }))

func tool_connect_nodes(args : Dictionary):
	return await run_edit(args.merged({ op="connect" }))

func tool_disconnect_nodes(args : Dictionary):
	return await run_edit(args.merged({ op="disconnect" }))

func tool_remove_node(args : Dictionary):
	return await run_edit(args.merged({ op="remove" }))

func tool_set_parameters(args : Dictionary):
	return await run_edit(args.merged({ op="set" }))

func run_edit(edit : Dictionary):
	var result = await run_edits(edit, [ edit ])
	return result if result is String else result.results[0]

# Applies edits to the graph the tool works on (see target_graph) as one undo step, stopping at the first that fails
func run_edits(args : Dictionary, edits : Array):
	var graph_edit = target_graph_edit(args)
	if graph_edit is String:
		return graph_edit
	var graph = target_graph(graph_edit, args)
	if graph is String:
		return graph
	# The editor edits the graph it shows: show that one, like the hierarchy panel does
	if graph != graph_edit.generator:
		graph_edit.edit_subgraph(graph)
	var before : Dictionary = graph.serialize().duplicate(true)
	var names : Dictionary = {}
	var results : Array = []
	var failure : String = ""
	for i in edits.size():
		var edit : Dictionary = edits[i] if edits[i] is Dictionary else {}
		var result = await apply_edit(graph_edit, edit, names)
		if result is String:
			failure = result if edits.size() == 1 else "Edit %d (%s) failed: %s" % [ i, edit.get("op", ""), result ]
			if i > 0:
				failure += ". The %d edits before it were applied, as one undo step." % i
			break
		results.append(result)
	if not results.is_empty():
		graph_edit.undoredo_create_step("MCP edits", graph.get_hier_name(), before, graph.serialize())
	return failure if failure != "" else { applied=results.size(), results=results }

# One edit, without an undo step of its own. names maps the names add edits asked for to the names
# Material Maker gave them, so the edits that follow can use the names they asked for.
func apply_edit(graph_edit : MMGraphEdit, edit : Dictionary, names : Dictionary):
	var graph : MMGenGraph = graph_edit.generator
	var node : String = names.get(str(edit.get("node", "")), str(edit.get("node", "")))
	var from : String = names.get(str(edit.get("from", "")), str(edit.get("from", "")))
	var to : String = names.get(str(edit.get("to", "")), str(edit.get("to", "")))
	var from_port : int = int(edit.get("from_port", 0))
	var to_port : int = int(edit.get("to_port", 0))
	var connection : String = "%s:%d -> %s:%d" % [ from, from_port, to, to_port ]
	match edit.get("op"):
		"add":
			var data : Dictionary = node_data(str(edit.get("node", "")))
			if edit.get("name") is String:
				data.name = edit.name
			if edit.get("parameters") is Dictionary:
				var parameters : Dictionary = data.get("parameters", {})
				parameters.merge(edit.parameters, true)
				data.parameters = parameters
			var nodes : Array = await graph_edit.do_create_nodes(data, Vector2(float(edit.get("x", 0)), float(edit.get("y", 0))))
			if nodes.is_empty():
				return "Material Maker cannot create a node from '%s'" % edit.get("node", "")
			if edit.get("name") is String:
				names[edit.name] = nodes[0].generator.name
			return { created=nodes[0].generator.name }
		"connect":
			var problem : String = connection_problem(graph, from, from_port, to, to_port)
			if problem != "":
				return problem
			var replaced : Dictionary = graph_edit.get_source("node_"+to, to_port)
			if not graph_edit.do_connect_node("node_"+from, from_port, "node_"+to, to_port):
				return "Material Maker refused the connection (it would create a loop)"
			# Like the editor, the new connection replaces the one into that input
			if not replaced.is_empty():
				graph_edit.disconnect_node(replaced.node, replaced.slot, "node_"+to, to_port)
			return { connected=connection }
		"disconnect":
			if not has_connection(graph, from, from_port, to, to_port):
				return "There is no connection "+connection
			graph_edit.do_disconnect_node("node_"+from, from_port, "node_"+to, to_port)
			return { disconnected=connection }
		"remove":
			var graph_node = graph_edit.get_node_or_null(NodePath("node_"+node))
			if graph_node == null:
				return "No node named '%s'" % node
			if not graph_node.generator.can_be_deleted():
				return "'%s' cannot be deleted" % node
			graph_edit.do_remove_node(graph_node)
			return { removed=node }
		"set":
			var generator : MMGenBase = graph.get_node_or_null(NodePath(node))
			if generator == null:
				return "No node named '%s'" % node
			if not edit.get("parameters") is Dictionary:
				return "Pass the parameters as an object"
			for p in edit.parameters.keys():
				if generator.get_parameter_def(p).is_empty():
					var parameter_names : PackedStringArray = []
					for d in generator.get_parameter_defs():
						parameter_names.append(d.name)
					return "%s has no parameter '%s' (it has: %s)" % [ node, p, ", ".join(parameter_names) ]
			var values : Dictionary = {}
			for p in edit.parameters.keys():
				generator.set_parameter(p, MMType.deserialize_value(edit.parameters[p]))
				values[p] = MMType.serialize_value(generator.get_parameter(p))
			return { node=node, parameters=values }
	return "Unknown op '%s': use add, connect, disconnect, remove or set" % edit.get("op", "")

func tool_render_node(args : Dictionary):
	var graph_edit = target_graph_edit(args)
	if graph_edit is String:
		return graph_edit
	var generator = target_node(graph_edit, args)
	if generator is String:
		return generator
	var port : int = int(args.get("port", 0))
	var problem : String = output_problem(generator, port)
	if problem != "":
		return problem
	var size : int = clampi(int(args.get("size", 512)), 16, 8192)
	var image : Image = await render_output_image(generator, port, size)
	return image_result(image, args, { node=args.node, port=port, size=size })

func tool_render_preview(args : Dictionary):
	var graph_edit = target_graph_edit(args)
	if graph_edit is String:
		return graph_edit
	var material : MMGenMaterial = graph_edit.get_material_node()
	if material == null:
		return "The graph has no material"
	var view : String = str(args.get("view", "sphere"))
	if not view in PREVIEW_VIEWS:
		return "view must be one of: "+", ".join(PackedStringArray(PREVIEW_VIEWS))
	var size : int = clampi(int(args.get("size", 512)), 64, 2048)
	var image : Image = await render_preview_image(material, view, size)
	return image_result(image, args, { view=view, size=size })

func tool_render_sweep(args : Dictionary):
	var graph_edit = target_graph_edit(args)
	if graph_edit is String:
		return graph_edit
	var generator = target_node(graph_edit, args)
	if generator is String:
		return generator
	var parameter : String = str(args.get("parameter", ""))
	if generator.get_parameter_def(parameter).is_empty():
		return "%s has no parameter '%s'" % [ args.node, parameter ]
	var values = args.get("values")
	if not values is Array or values.is_empty() or values.size() > 16:
		return "Pass 1 to 16 values"
	var view : String = str(args.get("view", "output"))
	var port : int = int(args.get("port", 0))
	var material : MMGenMaterial = graph_edit.get_material_node()
	if view == "output":
		var problem : String = output_problem(generator, port)
		if problem != "":
			return problem
	elif not view in PREVIEW_VIEWS:
		return "view must be output or one of: "+", ".join(PackedStringArray(PREVIEW_VIEWS))
	elif material == null:
		return "The graph has no material"
	var size : int = clampi(int(args.get("size", 256)), 16, 1024)
	var original = MMType.serialize_value(generator.get_parameter(parameter))
	var images : Array[Image] = []
	for value in values:
		generator.set_parameter(parameter, MMType.deserialize_value(value))
		if view == "output":
			images.append(await render_output_image(generator, port, size))
		else:
			images.append(await render_preview_image(material, view, size))
	generator.set_parameter(parameter, MMType.deserialize_value(original))
	const GAP : int = 4
	var columns : int = ceili(sqrt(images.size()))
	var rows : int = ceili(float(images.size())/columns)
	var sheet : Image = Image.create(columns*(size+GAP)-GAP, rows*(size+GAP)-GAP, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.25, 0.25, 0.25))
	var cells : Array = []
	for i in images.size():
		images[i].convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(images[i], Rect2i(Vector2i.ZERO, images[i].get_size()), Vector2i(i%columns, i/columns)*(size+GAP))
		cells.append({ row=i/columns, column=i%columns, value=values[i] })
	return image_result(sheet, args, { node=args.node, parameter=parameter, view=view, cell_size=size, gap=GAP, cells=cells })

func output_problem(generator : MMGenBase, port : int) -> String:
	# Hidden outputs include the maps of Material nodes
	var output_count : int = generator.get_output_defs(true).size()
	if port < 0 or port >= output_count:
		return "%s has %d outputs" % [ generator.name, output_count ]
	return ""

func render_output_image(generator : MMGenBase, port : int, size : int) -> Image:
	await mm_deps.wait_for_render_queue()
	return await generator.render_output(port, Vector2i(size, size))

# A render tool's result: the image is saved when a path is given and returned when it is small enough
func image_result(image : Image, args : Dictionary, result : Dictionary):
	image.convert(Image.FORMAT_RGBA8)
	if args.get("path") is String:
		var error : Error = image.save_png(args.path)
		if error != OK:
			return "Cannot save %s: %s" % [ args.path, error_string(error) ]
		result.saved = args.path
	if image.get_width() <= 1024 and image.get_height() <= 1024:
		result.image = image.save_png_to_buffer()
	return result

# 3D previews: the material on a sphere, on a square seen at an angle, or tiled 3x3 seen from above.
# Their own scene, lit like the 3D preview panel, so the panel and its settings stay untouched.

const PREVIEW_VIEWS : Array[String] = [ "sphere", "plane", "tiled" ]

var preview_viewport : SubViewport
var preview_material : ShaderMaterial
var preview_camera : Camera3D
var preview_sphere : MeshInstance3D
var preview_plane : MeshInstance3D

func create_preview_scene() -> void:
	preview_viewport = SubViewport.new()
	preview_viewport.own_world_3d = true
	preview_viewport.msaa_3d = Viewport.MSAA_4X
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(preview_viewport)
	var environment : Environment = Environment.new()
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var world_environment : WorldEnvironment = WorldEnvironment.new()
	world_environment.environment = environment
	preview_viewport.add_child(world_environment)
	var sun : DirectionalLight3D = DirectionalLight3D.new()
	sun.shadow_enabled = true
	preview_viewport.add_child(sun)
	preview_camera = Camera3D.new()
	preview_viewport.add_child(preview_camera)
	preview_material = ShaderMaterial.new()
	var sphere_mesh : SphereMesh = SphereMesh.new()
	sphere_mesh.radius = 1.0
	sphere_mesh.height = 2.0
	sphere_mesh.radial_segments = 128
	sphere_mesh.rings = 64
	preview_sphere = MeshInstance3D.new()
	preview_sphere.mesh = sphere_mesh
	preview_sphere.material_override = preview_material
	preview_viewport.add_child(preview_sphere)
	var plane_mesh : PlaneMesh = PlaneMesh.new()
	plane_mesh.size = Vector2(2, 2)
	preview_plane = MeshInstance3D.new()
	preview_plane.mesh = plane_mesh
	preview_plane.material_override = preview_material
	preview_viewport.add_child(preview_plane)
	var environment_manager = mm_globals.main_window.get_node("EnvironmentManager")
	await environment_manager.apply_environment(mm_globals.get_config("ui_3d_preview_environment"), environment, sun)

func render_preview_image(material : MMGenMaterial, view : String, size : int) -> Image:
	if preview_viewport == null:
		await create_preview_scene()
	await mm_deps.wait_for_render_queue()
	await material.update_material(preview_material)
	preview_sphere.visible = view == "sphere"
	preview_plane.visible = view != "sphere"
	match view:
		"sphere":
			preview_material.set_shader_parameter("uv1_scale", Vector3(4, 2, 1))
			preview_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			preview_camera.fov = 45
			preview_camera.look_at_from_position(Vector3(0, 1.5, 2.6), Vector3.ZERO)
		"plane":
			preview_material.set_shader_parameter("uv1_scale", Vector3(1, 1, 1))
			preview_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			preview_camera.fov = 45
			preview_camera.look_at_from_position(Vector3(0, 2.0, 2.8), Vector3(0, 0, 0.1))
		"tiled":
			preview_material.set_shader_parameter("uv1_scale", Vector3(3, 3, 1))
			preview_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			preview_camera.size = 2
			preview_camera.look_at_from_position(Vector3(0, 4, 0), Vector3.ZERO, Vector3.FORWARD)
	preview_viewport.size = Vector2i(size, size)
	# Render until two frames match: the first ones can miss shaders that are still compiling
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var image : Image
	var previous : PackedByteArray = PackedByteArray()
	for frame in 40:
		await RenderingServer.frame_post_draw
		if frame < 2:
			continue
		image = preview_viewport.get_texture().get_image()
		if image.get_data() == previous:
			break
		previous = image.get_data()
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return image

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
		var graph_edit = target_graph_edit(args)
		if graph_edit is String:
			return graph_edit
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

func tool_list_examples(args : Dictionary):
	var directories : PackedStringArray = [ MMPaths.get_examples_dir() ]
	directories.append_array(project_example_dirs())
	var examples : Array = []
	for directory in directories:
		collect_examples(directory, "" if directory == directories[0] else directory.get_file(), examples)
	var filter : String = str(args.get("filter", "")).to_lower()
	if filter != "":
		examples = examples.filter(func(e): return filter in ("%s %s %s" % [ e.name, e.get("category", ""), e.get("description", "") ]).to_lower())
	return { directories=directories, examples=examples }

# Folders of project graphs listed beside the shipped examples: --mcp-examples <folder>, repeatable
static func project_example_dirs() -> PackedStringArray:
	var args : PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var directories : PackedStringArray = []
	for i in args.size()-1:
		if args[i] == "--mcp-examples":
			directories.append(args[i+1].replace("\\", "/"))
	return directories

func collect_examples(directory : String, category : String, examples : Array) -> void:
	for f in DirAccess.get_files_at(directory):
		if f.get_extension() != "ptex":
			continue
		var example : Dictionary = { name=f.get_basename(), path=directory.path_join(f) }
		if category != "":
			example.category = category
		var description : String = example_description(example.path)
		if description != "":
			example.description = description
		var card : String = example.path.get_basename()+".md"
		if FileAccess.file_exists(card):
			example.recipe = card
		examples.append(example)
	for d in DirAccess.get_directories_at(directory):
		collect_examples(directory.path_join(d), category.path_join(d) if category != "" else d, examples)

# The title of a cookbook recipe card ("# <name> - <description>"), else the start of the graph's first comment
static func example_description(path : String) -> String:
	var card : String = path.get_basename()+".md"
	if FileAccess.file_exists(card):
		var title : String = FileAccess.get_file_as_string(card).get_slice("\n", 0).trim_prefix("# ").strip_edges()
		return title.get_slice(" - ", 1) if title.contains(" - ") else title
	var graph : Dictionary = MMLoader.string_to_dict_tree(FileAccess.get_file_as_string(path))
	for node in graph.get("nodes", []):
		if node is Dictionary and node.get("type") == "comment" and node.get("text", "") != "":
			var text : String = node.text.get_slice("\n", 0).strip_edges()
			return text.left(240)+"..." if text.length() > 240 else text
	return ""
