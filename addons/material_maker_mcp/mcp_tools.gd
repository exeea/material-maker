extends Node

## The MCP tools. They work through Material Maker's own loader, node library,
## graph editor (so edits show live and can be undone) and exporter.

const ExportCommand = preload("res://parse_args.gd")
const PtexFile = preload("res://addons/material_maker_mcp/ptex_file.gd")

const NO_WINDOW : String = "The Material Maker window is not ready"
const NO_GRAPH : String = "No graph is open in Material Maker"

const INSTRUCTIONS : String = """Material Maker builds procedural PBR materials from node graphs.
These tools work on a Material Maker tab, live: the user sees every edit and can undo it. load_graph, new_graph and get_graph return the tab's handle; pass it as tab to stay on that tab when the user or another agent switches tabs. Graphs can hold subgraphs (get_graph counts their nodes): pass subgraph, the node names from the top level joined by '/', to read, edit or render inside one, "" for the top level. By default tools use the current tab and the graph it shows.
Find nodes with list_nodes, read their parameters and ports with describe_node, then build with apply_edits (or add_node, connect_nodes and set_parameters), or load a whole graph (the .ptex JSON format) with load_graph. Close tabs you no longer need with close_graph.
Check outputs with render_node, judge the material lit and tiled with render_preview, compare parameter values with render_sweep, and write texture maps with export_material. Node names are the names used in graph JSON, ports count from 0.
To change .ptex files without opening them, e.g. the same change across many projects, use edit_files.
Examples, including a cookbook of finished materials, are listed by list_examples."""

const GRAPH_ARGUMENTS : Dictionary = {
	"graph": { "type": "object", "description": "A graph in Material Maker's .ptex JSON format" },
	"path": { "type": "string", "description": "Path of a .ptex file (used instead of graph)" }
}
const TAB_ARGUMENT : Dictionary = { "type": "integer", "description": "Handle of the tab to work on, from load_graph, new_graph or get_graph; default the current tab" }
const COMMENT_TITLE_ARGUMENT : Dictionary = { "type": "string", "description": "Title of a comment node" }
const COMMENT_TEXT_ARGUMENT : Dictionary = { "type": "string", "description": "Text of a comment node" }
const SUBGRAPH_ARGUMENT : Dictionary ={ "type": "string", "description": "Subgraph to work in: node names from the top level joined by '/', \"\" for the top level; default the graph the tab shows" }

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
		"description": "Applies several edits to a graph in order, as one undo step, and stops at the first that fails. Each edit has an op: add (node, name, parameters, title, text, x, y), connect or disconnect (from, from_port, to, to_port), remove (node) or set (node, parameters, title, text), with the arguments of add_node, connect_nodes, disconnect_nodes, remove_node and set_parameters; or add_parameter, update_parameter, rename_parameter or remove_parameter on the graph's exposed parameters, with the arguments edit_files describes. Later edits can use the names earlier add edits asked for. The tab shows the graph edited.",
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
			"title": COMMENT_TITLE_ARGUMENT,
			"text": COMMENT_TEXT_ARGUMENT,
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
		"description": "Sets parameters of a node, or the title and text of a comment. Colors are {\"type\": \"Color\", \"r\": 1, \"g\": 0, \"b\": 0, \"a\": 1}; enums take the index of the value.",
		"inputSchema": { "type": "object", "required": [ "node" ], "properties": {
			"node": { "type": "string" },
			"parameters": { "type": "object" },
			"title": COMMENT_TITLE_ARGUMENT,
			"text": COMMENT_TEXT_ARGUMENT,
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
		"name": "edit_files",
		"description": "Applies the same edits to .ptex files without opening them, and reports per file what changed, problems the edits caused and missing images. Saves only with save, each file in its own layout, and never a file open in a tab. Each edit has an op and a subgraph path (default top level): add (node: a node type or library item, name, parameters, x, y); connect and disconnect (from, from_port, to, to_port; a connection replaces the one into that input); remove (node; bridge: true, or [input, output] ports, connects what fed that input to whatever used that output); later edits can use the names add edits asked for; set (node, parameters, title, text; a value can be {\"expression\": \"value * RepeatMetres\"}, where value is the current value, the parameters of the graph's remote nodes are variables, and parameter(\"Sub/node\", \"name\") reads any other); add_parameter (node: a remote node, default gen_parameters; name, label, and either min, max, step, default, value for a named parameter used as $name in expressions, or links: [{node, parameter}] for a control of other nodes' parameters); update_parameter (node, name, label, min, max, step, default); rename_parameter (node, name, new_name: also changes $name in expressions, the subgraph's value and the controls linked to it); remove_parameter (node, name; refused while expressions use it); for these three, node defaults to the remote node that has the parameter; relink (from, to: replaced in image node paths); rename_graph (name: the graph's own name and label, default the file's name); sync_subgraph (subgraph, from: a master .ptex, from_subgraph: default the same path): replaces the subgraph with the master's copy, keeping each project's name, position, seed, exposed values and their slider defaults and ranges; a copy that differs from most of the copies it replaces, beyond those, has local edits: it is reported under local_edits and replaced only with overwrite_local. A value within 1e-9 (relative) of the old one keeps the old one, so values computed again do not change files.",
		"inputSchema": { "type": "object", "required": [ "files", "edits" ], "properties": {
			"files": { "type": "array", "items": { "type": "string" }, "description": ".ptex paths; * and ? match any characters, / included" },
			"edits": { "type": "array", "items": { "type": "object" } },
			"save": { "type": "boolean", "description": "Write the files; default false only reports. A file whose edits fail is not saved; the others are." },
			"skip_missing": { "type": "boolean", "description": "Skip files that lack a subgraph, node or parameter the edits name, instead of reporting them as errors" },
			"overwrite_local": { "type": "boolean", "description": "Let sync_subgraph replace copies with local edits too" } } }
	},
	{
		"name": "verify_export",
		"description": "Exports .ptex projects into a temporary folder (writing nowhere else) and compares each exported file with the shipped one of the same name in maps: identical, or the texels that differ and the largest difference (0-255) of any channel; .tres lines with numbers within 1e-9 (relative) count as equal. Maps are compared as RGBA, so a map stored grey or RGB compares with its RGBA export. Also lists shipped <project>_*.png maps the export no longer writes. A project takes about 5 s and a call at most 10 minutes, so verify large sets in parts.",
		"inputSchema": { "type": "object", "required": [ "files", "maps" ], "properties": {
			"files": { "type": "array", "items": { "type": "string" }, "description": ".ptex paths; * and ? match any characters, / included" },
			"maps": { "type": "string", "description": "Folder of the shipped files (<project>_albedo.png, <project>.tres, ...)" },
			"target": { "type": "string", "description": "Export target, default 'Godot/Godot 4 Standard'" },
			"size": { "type": "integer", "description": "Edge length in pixels; default is each map's Size" } } }
	},
	{
		"name": "quit",
		"description": "Closes this Material Maker, discarding unsaved changes. Only for an instance started with --mcp-port (e.g. by material_maker_mcp.py start <port>); the one started with --mcp is the user's.",
		"inputSchema": { "type": "object", "properties": {} }
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
			node.title = generator.title
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
	# Edits can change the graphs around this one (exposed parameters), so the undo step covers the project.
	# A copy: serialize() shares some data with the generators, e.g. a remote node's widgets.
	var before : Dictionary = graph_edit.top_generator.serialize().duplicate(true)
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
		var actions : Dictionary = step_actions(graph_edit, before, graph_edit.top_generator.serialize())
		if not actions.undo.is_empty():
			graph_edit.undoredo.add("MCP edits", actions.undo, actions.redo)
		# Comment edits do not mark the project changed by themselves
		graph_edit.set_need_save()
	return failure if failure != "" else { applied=results.size(), results=results }

# Undo and redo actions from one state of a project's data to another. Material Maker's own diff replaces a
# node whose parameters changed, which drops its connections, so parameter changes become setparams actions.
static func step_actions(graph_edit : MMGraphEdit, prev : Dictionary, next : Dictionary) -> Dictionary:
	prev = prev.duplicate(true)
	var undo_parameters : Array = []
	var redo_parameters : Array = []
	collect_parameter_changes(prev, next, "", undo_parameters, redo_parameters)
	# The diff rewrites both graphs in place
	var actions : Dictionary = graph_edit.undoredo_step_actions("", prev, next.duplicate(true))
	return { undo=actions.get("undo_actions", []) + undo_parameters, redo=redo_parameters + actions.get("redo_actions", []) }

# setparams actions for the nodes of a graph (subgraphs included) whose parameters are all that changed,
# with prev updated so the diff no longer sees them. Remote nodes are left to the diff, which updates them whole.
static func collect_parameter_changes(prev : Dictionary, next : Dictionary, prefix : String, undo : Array, redo : Array) -> void:
	for n in next.get("nodes", []):
		var found : Array = prev.get("nodes", []).filter(func(p): return p.name == n.name)
		if found.is_empty() or found[0].get("type") != n.get("type") or n.get("type") == "remote":
			continue
		var p : Dictionary = found[0]
		if n.has("nodes"):
			collect_parameter_changes(p, n, prefix+n.name+"/", undo, redo)
		else:
			var p_rest : Dictionary = p.duplicate()
			var n_rest : Dictionary = n.duplicate()
			p_rest.erase("parameters")
			n_rest.erase("parameters")
			if p_rest != n_rest:
				continue
		if not p.has("parameters"):
			p.parameters = {}
		var old : Dictionary = {}
		var new : Dictionary = {}
		for k in n.get("parameters", {}).keys():
			if not p.parameters.has(k) or differs(p.parameters[k], n.parameters[k]):
				new[k] = n.parameters[k]
				# A parameter the edits added stays when undone; it no longer matches an exposed parameter
				if p.parameters.has(k):
					old[k] = p.parameters[k]
		if new.is_empty():
			continue
		p.parameters.merge(new, true)
		if not old.is_empty():
			undo.push_front({ type="setparams", node=prefix+n.name, params=old })
		redo.append({ type="setparams", node=prefix+n.name, params=new })

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
			for key in [ "title", "text" ]:
				if edit.get(key) is String:
					data[key] = edit[key]
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
			var parameters = edit.get("parameters", {})
			var comment : Dictionary = {}
			for key in [ "title", "text" ]:
				if edit.has(key):
					comment[key] = str(edit[key])
			if not parameters is Dictionary or (comment.is_empty() and not edit.has("parameters")):
				return "Pass the parameters as an object"
			if not comment.is_empty() and not generator is MMGenComment:
				return "Only comments have a title and text"
			for p in parameters.keys():
				if generator.get_parameter_def(p).is_empty():
					var parameter_names : PackedStringArray = []
					for d in generator.get_parameter_defs():
						parameter_names.append(d.name)
					return "%s has no parameter '%s' (it has: %s)" % [ node, p, ", ".join(parameter_names) ]
			var result : Dictionary = { node=node, parameters={} }
			for p in parameters.keys():
				generator.set_parameter(p, MMType.deserialize_value(parameters[p]))
				result.parameters[p] = MMType.serialize_value(generator.get_parameter(p))
			for key in comment.keys():
				generator.set(key, comment[key])
				result[key] = comment[key]
			if not comment.is_empty():
				graph_edit.get_node(NodePath("node_"+node)).update_node()
			return result
		"add_parameter", "update_parameter", "rename_parameter", "remove_parameter":
			return await apply_parameter_edit(graph_edit, edit)
	return "Unknown op '%s': use add, connect, disconnect, remove, set, add_parameter, update_parameter, rename_parameter or remove_parameter" % edit.get("op", "")

# Exposed-parameter edits use edit_files' operations on the project's data, and the differences reach the
# open graph as editor commands
func apply_parameter_edit(graph_edit : MMGraphEdit, edit : Dictionary):
	var file = PtexFile.new()
	file.data = graph_edit.top_generator.serialize().duplicate(true)
	var current : Dictionary = file.data.duplicate(true)
	var error : String = file.apply(edit.merged({ subgraph=graph_edit.generator.get_hier_name() }, true))
	if error != "":
		return error
	for check in file.checks:
		var node = graph_edit.top_generator.get_node_or_null(NodePath(check.node))
		if not node is MMGenBase or node.get_parameter_def(check.parameter).is_empty():
			return "%s has no parameter '%s'" % [ check.node, check.parameter ]
	for action in step_actions(graph_edit, current, file.data).redo:
		await graph_edit.undoredo_command(action)
	return { changes=file.changes }

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
	DirAccess.make_dir_recursive_absolute(prefix.get_base_dir())
	var start : int = int(Time.get_unix_time_from_system())
	var exported
	if args.get("graph_path") is String:
		exported = await export_project_file(args.graph_path, prefix, target, size)
		if exported is String:
			return exported
	else:
		var graph_edit = target_graph_edit(args)
		if graph_edit is String:
			return graph_edit
		exported = await ExportCommand.export_generator(graph_edit.top_generator, prefix, target, size)
	if exported == 0:
		return "Nothing to export: the graph has no material or Export node"
	var files : Array = []
	var directory : String = prefix.get_base_dir()
	for f in DirAccess.get_files_at(directory):
		if FileAccess.get_modified_time(directory.path_join(f)) >= start:
			files.append(directory.path_join(f))
	return { exported=exported, files=files }

# Exports a .ptex file as the command line does: the number of exports, or an error message
func export_project_file(path : String, prefix : String, target : String, size : int):
	var generator : MMGenBase = await mm_loader.load_gen(path)
	if generator == null:
		return "Cannot load "+path
	add_child(generator)
	var exported : int = await ExportCommand.export_generator(generator, prefix, target, size)
	await wait_for_render_thread_idle()
	generator.queue_free()
	return exported

func tool_verify_export(args : Dictionary):
	var paths : PackedStringArray = matching_files(args.get("files"))
	if paths.is_empty():
		return "No .ptex file matches files"
	var maps : String = str(args.get("maps", "")).replace("\\", "/")
	if not DirAccess.dir_exists_absolute(maps):
		return "Folder '%s' does not exist" % maps
	var reports : Array = []
	var differing : int = 0
	for path in paths:
		var report : Dictionary = await verify_file(path, maps, str(args.get("target", "Godot/Godot 4 Standard")), int(args.get("size", 0)))
		if not report.get("identical", false):
			differing += 1
		reports.append(report)
	return { files=reports, differing=differing }

# Exports a project into a temporary folder and compares each file with the one of the same name in maps
func verify_file(path : String, maps : String, target : String, size : int) -> Dictionary:
	var folder : String = OS.get_cache_dir().path_join("material_maker_verify_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(folder)
	var name : String = path.get_file().get_basename()
	var exported = await export_project_file(path, folder.path_join(name), target, size)
	var results : Dictionary = {}
	for f in DirAccess.get_files_at(folder):
		var shipped : String = maps.path_join(f)
		if not FileAccess.file_exists(shipped):
			results[f] = "not shipped"
		elif f.get_extension() == "png":
			results[f] = compare_images(folder.path_join(f), shipped)
		elif f.get_extension() == "tres":
			results[f] = compare_text(folder.path_join(f), shipped)
		else:
			results[f] = "not compared"
		DirAccess.remove_absolute(folder.path_join(f))
	DirAccess.remove_absolute(folder)
	if exported is String or exported == 0:
		return { path=path, error=exported if exported is String else "Nothing to export: the graph has no material or Export node" }
	# Shipped maps of this project that it no longer exports
	for f in DirAccess.get_files_at(maps):
		if f.begins_with(name+"_") and f.get_extension() == "png" and not results.has(f):
			results[f] = "not exported"
	return { path=path, identical=results.values().all(func(r): return r is String and r == "identical"), files=results }

# "identical", or the texels that differ, compared as RGBA8 (so a grey or RGB file compares with an RGBA export),
# and the largest difference of any channel (0-255)
static func compare_images(path : String, shipped_path : String):
	var image : Image = Image.load_from_file(path)
	var shipped : Image = Image.load_from_file(shipped_path)
	if image == null or shipped == null:
		return "cannot read"
	if image.get_size() != shipped.get_size():
		return { size=[ image.get_width(), image.get_height() ], shipped_size=[ shipped.get_width(), shipped.get_height() ] }
	image.convert(Image.FORMAT_RGBA8)
	shipped.convert(Image.FORMAT_RGBA8)
	var a : PackedByteArray = image.get_data()
	var b : PackedByteArray = shipped.get_data()
	if a == b:
		return "identical"
	# Rows are compared whole first, so few differing texels cost little
	var row : int = image.get_width()*4
	var differing : int = 0
	for y in image.get_height():
		if a.slice(y*row, (y+1)*row) == b.slice(y*row, (y+1)*row):
			continue
		for i in range(y*row, (y+1)*row, 4):
			if a.decode_u32(i) != b.decode_u32(i):
				differing += 1
	return { differing_texels=differing, max_difference=int(image.compute_image_metrics(shipped, false).max) }

# "identical", or the lines that differ; numbers within 1e-9 (relative) count as equal
static func compare_text(path : String, shipped_path : String):
	var lines : Array = []
	for p in [ path, shipped_path ]:
		lines.append(Array(FileAccess.get_file_as_string(p).split("\n")).map(func(l): return l.strip_edges()).filter(func(l): return l != ""))
	var number : RegEx = RegEx.create_from_string("-?\\d+\\.\\d+(?:e-?\\d+)?")
	var differing : PackedStringArray = []
	for i in maxi(lines[0].size(), lines[1].size()):
		var line : String = lines[0][i] if i < lines[0].size() else ""
		var shipped : String = lines[1][i] if i < lines[1].size() else ""
		var same : bool = number.sub(line, "#", true) == number.sub(shipped, "#", true)
		var values : Array = number.search_all(line)
		var shipped_values : Array = number.search_all(shipped)
		for j in values.size() if same else 0:
			var x : float = values[j].get_string().to_float()
			same = same and absf(x-shipped_values[j].get_string().to_float()) <= 1e-9*maxf(1.0, absf(x))
		if not same:
			differing.append("%s | shipped: %s" % [ line, shipped ])
	return "identical" if differing.is_empty() else { differing_lines=differing.size(), first=differing.slice(0, 5) }

func tool_edit_files(args : Dictionary):
	if not args.get("edits") is Array or args.edits.is_empty():
		return "Pass a list of edits"
	var paths : PackedStringArray = matching_files(args.get("files"))
	if paths.is_empty():
		return "No .ptex file matches files"
	var open_paths : PackedStringArray = open_project_paths()
	var reports : Array = []
	for path in paths:
		reports.append(await edit_file(path, args.edits, args.get("skip_missing", false)))
	flag_local_copies(reports, args.get("overwrite_local", false))
	var saved : int = 0
	var skipped : int = 0
	for report in reports:
		if report.has("skipped"):
			skipped += 1
		var file = report.get("file")
		report.erase("file")
		if file != null and args.get("save", false) and not file.changes.is_empty() and not report.has("not_saved"):
			if report.has("problems"):
				report.not_saved = "The edits cause problems"
			elif report.path.to_lower() in open_paths:
				report.not_saved = "Open in a tab: close it first"
			else:
				var error : String = file.save()
				if error == "":
					report.saved = true
					saved += 1
				else:
					report.error = error
	return { files=reports, saved=saved, skipped=skipped }

# A copy sync_subgraph replaces that differs from most of the copies it replaces (beyond what each project
# sets) holds local edits: they are reported, and the file is only saved with overwrite_local
static func flag_local_copies(reports : Array, overwrite_local : bool) -> void:
	var counts : Dictionary = {}
	var copies : Dictionary = {}
	for report in reports:
		for s in report.get("file").synced if report.get("file") != null else []:
			var key : String = PtexFile.fingerprint(s.copy)
			if not counts.has(s.subgraph):
				counts[s.subgraph] = {}
			counts[s.subgraph][key] = counts[s.subgraph].get(key, 0)+1
			copies[key] = s.copy
	for report in reports:
		for s in report.get("file").synced if report.get("file") != null else []:
			var key : String = PtexFile.fingerprint(s.copy)
			if key == PtexFile.fingerprint(s.master):
				continue
			# The copy more than half the files share, else the master
			var common : String = ""
			for k in counts[s.subgraph].keys():
				if counts[s.subgraph][k] > counts[s.subgraph].get(common, 0):
					common = k
			var total : int = counts[s.subgraph].values().reduce(func(a, b): return a+b, 0)
			if counts[s.subgraph][common]*2 <= total:
				common = ""
			if key == common:
				continue
			var reference : Dictionary = copies[common] if common != "" else s.master
			if not report.has("local_edits"):
				report.local_edits = {}
			report.local_edits[s.subgraph] = PtexFile.subgraph_differences(s.copy, reference)
			if not overwrite_local:
				report.not_saved = "Its copy of %s differs from %s: pass overwrite_local to replace it" % [ s.subgraph, "most copies" if common != "" else "the master" ]

# Applies edits to one .ptex file's data: a report with path, changes and the problems the edits caused,
# and the edited file (unsaved) unless an edit failed
func edit_file(path : String, edits : Array, skip_missing : bool) -> Dictionary:
	var file = PtexFile.new()
	var report : Dictionary = { path=path }
	var error : String = file.read(path)
	if error != "":
		report.error = error
		return report
	var before : PackedStringArray = await data_problems(file)
	for i in edits.size():
		var edit : Dictionary = edits[i] if edits[i] is Dictionary else {}
		if edit.get("op") == "add":
			edit = edit.merged({ data=node_data(str(edit.get("node", ""))) })
		error = file.apply(edit)
		if error != "":
			error = error if edits.size() == 1 else "Edit %d (%s): %s" % [ i, edit.get("op", ""), error ]
			report["skipped" if skip_missing and file.missing else "error"] = error
			return report
	report.changes = file.changes
	var problems : PackedStringArray = []
	for problem in await data_problems(file):
		if not problem in before:
			problems.append(problem)
	if not problems.is_empty():
		report.problems = problems
	var missing : PackedStringArray = file.missing_images()
	if not missing.is_empty():
		report.missing_images = missing
	report.file = file
	return report

# What Material Maker reports when it builds a file's data: graph problems, and the parameters the edits
# used that do not exist
func data_problems(file) -> PackedStringArray:
	var data : Dictionary = MMLoader.replace_arrays_with_multiline_strings(file.data.duplicate(true))
	mm_loader.current_project_path = file.path.get_base_dir()
	var generator : MMGenBase = await mm_loader.create_gen(data)
	mm_loader.current_project_path = ""
	if generator == null:
		return [ "Material Maker cannot build this graph" ]
	var problems : PackedStringArray = graph_problems(data, generator)
	for check in file.checks:
		var node = generator.get_node_or_null(NodePath(check.node))
		if not node is MMGenBase or node.get_parameter_def(check.parameter).is_empty():
			problems.append("%s has no parameter '%s'" % [ check.node, check.parameter ])
	free_detached(generator)
	return problems

# The .ptex files of a list of paths and patterns, where * and ? also match /
static func matching_files(patterns) -> PackedStringArray:
	var paths : PackedStringArray = []
	for pattern in patterns if patterns is Array else []:
		pattern = str(pattern).replace("\\", "/")
		var wildcard : int = pattern.length()
		for c in [ "*", "?" ]:
			if pattern.find(c) >= 0:
				wildcard = mini(wildcard, pattern.find(c))
		if wildcard == pattern.length():
			if FileAccess.file_exists(pattern) and not pattern in paths:
				paths.append(pattern)
		else:
			var slash : int = pattern.rfind("/", wildcard)
			collect_files(pattern.left(slash) if slash >= 0 else ".", pattern, paths)
	return paths

static func collect_files(directory : String, pattern : String, paths : PackedStringArray) -> void:
	for f in DirAccess.get_files_at(directory):
		var file_path : String = directory.path_join(f)
		if f.get_extension() == "ptex" and file_path.matchn(pattern) and not file_path in paths:
			paths.append(file_path)
	for d in DirAccess.get_directories_at(directory):
		collect_files(directory.path_join(d), pattern, paths)

# The files of the projects open in tabs, lower case with forward slashes
func open_project_paths() -> PackedStringArray:
	var paths : PackedStringArray = []
	var projects = mm_globals.main_window.projects_panel.get_projects() if mm_globals.main_window != null else null
	for i in projects.get_tab_count() if projects != null else 0:
		var graph_edit : MMGraphEdit = tab_graph_edit(projects, i)
		if graph_edit != null and graph_edit.save_path != "":
			paths.append(graph_edit.save_path.replace("\\", "/").to_lower())
	return paths

func tool_quit(_args : Dictionary):
	var args : PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if not args.has("--mcp-port"):
		return "This Material Maker was started with --mcp, as the user's: only instances started with --mcp-port can be closed"
	# Once this reply is sent. Closing the tabs removes their recovery files, so the next start asks nothing.
	get_tree().create_timer(0.5).timeout.connect(func():
		await mm_renderer.stop_rendering_thread()
		get_tree().quit())
	return { quitting=true }

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
