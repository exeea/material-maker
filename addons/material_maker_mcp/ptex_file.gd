extends RefCounted

## A .ptex project edited as data by the edit_files tool, without opening it. The file is written back in
## its own layout (indentation, line endings, integers, escapes), so it only differs where it was edited.

var path : String
var data : Dictionary
var layout : Dictionary
# The text of the file's floats, written again for unchanged values: to_float() keeps about 15 digits
var literals : Dictionary
# What the edits changed, for the report
var changes : PackedStringArray = []
# Parameters the edits used, to check once Material Maker has built the edited graph: { node, parameter }
var checks : Array = []
# Whether the last error is about something this file does not have (a subgraph, node or parameter)
var missing : bool = false

# Names an expression can use besides variables and functions
const EXPRESSION_WORDS : PackedStringArray = [ "PI", "TAU", "INF", "NAN", "true", "false", "null", "and", "or", "not", "in" ]

func read(file_path : String) -> String:
	path = file_path
	var text : String = FileAccess.get_file_as_string(path)
	var parser : Parser = Parser.new(text)
	var parsed = parser.parse_value()
	if parser.failed or not parsed is Dictionary or not parsed.has("nodes"):
		return "%s is not a Material Maker graph" % path
	data = parsed
	literals = parser.literals
	var second_line : String = text.get_slice("\n", 1)
	var indent : String = second_line.substr(0, second_line.length()-second_line.lstrip(" \t").length())
	layout = {
		indent=indent if indent != "" else "\t",
		newline="\r\n" if text.contains("\r\n") else "\n",
		final_newline=text.ends_with("\n"),
		ascii=text.length() == text.to_utf8_buffer().size()
	}
	return ""

func save() -> String:
	var parts : PackedStringArray = []
	write_value(data, "", parts)
	if layout.final_newline:
		parts.append("\n")
	var file : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Cannot write %s: %s" % [ path, error_string(FileAccess.get_open_error()) ]
	file.store_string("".join(parts).replace("\n", layout.newline))
	return ""

# Edits

# Applies one edit, adding what it changed to changes; returns what went wrong, or ""
func apply(edit : Dictionary) -> String:
	var subgraph : String = str(edit.get("subgraph", ""))
	var graph = graph_at(subgraph)
	if graph == null:
		missing = true
		return "No subgraph '%s'" % subgraph
	match edit.get("op"):
		"set":
			return set_values(graph, subgraph, edit)
		"add_parameter":
			return add_parameter(graph, subgraph, edit)
		"update_parameter":
			return update_parameter(graph, subgraph, edit)
		"rename_parameter":
			return rename_parameter(graph, subgraph, edit, str(edit.get("new_name", "")))
		"remove_parameter":
			return rename_parameter(graph, subgraph, edit, "")
		"relink":
			return relink(str(edit.get("from", "")), str(edit.get("to", "")))
		"rename_graph":
			return rename_graph(str(edit.get("name", path.get_file().get_basename())))
	return "Unknown op '%s': use set, add_parameter, update_parameter, rename_parameter, remove_parameter, relink or rename_graph" % edit.get("op", "")

func set_values(graph : Dictionary, subgraph : String, edit : Dictionary) -> String:
	var name : String = str(edit.get("node", ""))
	var node = find_node(graph, name)
	if node == null:
		missing = true
		return "No node named '%s'" % name
	var label : String = node_path(subgraph, name)
	var parameters = edit.get("parameters", {})
	if not parameters is Dictionary:
		return "Pass the parameters as an object"
	for key in [ "title", "text" ]:
		if edit.has(key):
			if node.get("type") != "comment":
				return "Only comments have a title and text"
			node[key] = str(edit[key])
			changes.append("%s %s: %s" % [ label, key, node[key].left(120) ])
	for p in parameters.keys():
		var old = node.get("parameters", {}).get(p)
		var value = parameters[p]
		if value is Dictionary and value.has("expression"):
			var result : Dictionary = evaluate(str(value.expression), old, graph)
			if result.has("error"):
				return "%s %s: %s" % [ label, p, result.error ]
			value = result.value
		assign(graph, node, p, value)
		checks.append({ node=label, parameter=p })
		if typeof(old) != typeof(node.parameters[p]) or old != node.parameters[p]:
			changes.append("%s %s: %s -> %s" % [ label, p, shown(old), shown(node.parameters[p]) ])
	return ""

# Sets a parameter and, like Material Maker at run time, its copies: a subgraph's value is also its
# gen_parameters' value and the other way round, and a linked control sets the parameters it controls
func assign(graph : Dictionary, node : Dictionary, p : String, value) -> void:
	if not node.has("parameters"):
		node.parameters = {}
	node.parameters[p] = like(node.parameters.get(p), value)
	if node.has("nodes"):
		var parameters_node = find_node(node, "gen_parameters")
		if parameters_node != null and parameters_node.get("parameters", {}).has(p):
			parameters_node.parameters[p] = node.parameters[p]
	elif node.get("type") == "remote":
		if node.name == "gen_parameters" and not is_same(graph, data) and graph.has("parameters"):
			graph.parameters[p] = node.parameters[p]
		var w = find_widget(node, p)
		if w != null and w.type == "linked_control":
			for l in w.linked_widgets:
				var target = find_node(graph, str(l.node))
				if target != null:
					assign(graph, target, str(l.widget), value)

# An expression's value: value is the parameter's current value, the parameters of the graph's remote nodes
# (its exposed parameters) are variables, and parameter("path/to/node", "name") reads any other parameter
func evaluate(expression : String, value, graph : Dictionary) -> Dictionary:
	var names : PackedStringArray = [ "value" ]
	var values : Array = [ value ]
	for n in graph.nodes:
		if n is Dictionary and n.get("type") == "remote":
			for k in n.get("parameters", {}).keys():
				if not k in names:
					names.append(k)
					values.append(n.parameters[k])
	# Godot would report an unknown name as an invalid index of the context object
	var unknown : PackedStringArray = []
	var without_strings : String = RegEx.create_from_string("\"[^\"]*\"|'[^']*'").sub(expression, "", true)
	for m in RegEx.create_from_string("(?<![\\w.])([A-Za-z_]\\w*)\\b(?!\\s*[(.])").search_all(without_strings):
		var word : String = m.get_string(1)
		if not word in names and not word in EXPRESSION_WORDS and not word in unknown:
			unknown.append(word)
	if not unknown.is_empty():
		missing = true
		return { error="%s: no such parameter in this graph's remote nodes (they have: %s)" % [ ", ".join(unknown), ", ".join(names.slice(1)) ] }
	var e : Expression = Expression.new()
	if e.parse(expression, names) != OK:
		return { error="cannot read '%s': %s" % [ expression, e.get_error_text() ] }
	var context : ExpressionContext = ExpressionContext.new()
	context.file = self
	var result = e.execute(values, context)
	if e.has_execute_failed():
		return { error="'%s' failed: %s" % [ expression, e.get_error_text() ] }
	return { value=result }

class ExpressionContext:
	var file

	func parameter(node_path : String, name : String):
		var node = file.node_at(node_path)
		return node.get("parameters", {}).get(name) if node != null else null

func add_parameter(graph : Dictionary, subgraph : String, edit : Dictionary) -> String:
	var remote_name : String = str(edit.get("node", "gen_parameters"))
	var remote = find_node(graph, remote_name)
	if remote == null and remote_name == "gen_parameters" and not is_same(graph, data):
		remote = { name="gen_parameters", type="remote", parameters={}, widgets=[] }
		graph.nodes.append(remote)
	if remote == null or remote.get("type") != "remote":
		missing = remote == null
		return "No remote node named '%s'" % remote_name
	var name : String = str(edit.get("name", ""))
	if RegEx.create_from_string("^\\w+$").search(name) == null:
		return "A parameter name uses letters, digits and _"
	if find_widget(remote, name) != null:
		return "%s already has a parameter '%s'" % [ node_path(subgraph, remote_name), name ]
	var w : Dictionary = { name=name, label=str(edit.get("label", name)) }
	var value
	if edit.has("links"):
		w.type = "linked_control"
		w.linked_widgets = []
		for l in edit.links if edit.links is Array else []:
			var target = find_node(graph, str(l.get("node", ""))) if l is Dictionary else null
			if target == null:
				return "Links are { node, parameter } of nodes in the same graph"
			w.linked_widgets.append({ node=target.name, widget=str(l.get("parameter", "")) })
			checks.append({ node=node_path(subgraph, target.name), parameter=w.linked_widgets.back().widget })
			if value == null:
				value = target.get("parameters", {}).get(w.linked_widgets.back().widget)
		if w.linked_widgets.is_empty():
			return "Pass at least one link"
	else:
		w.type = "named_parameter"
		w.min = edit.get("min", 0.0)
		w.max = edit.get("max", 1.0)
		w.step = edit.get("step", 0.01)
		w.default = edit.get("default", edit.get("value", w.min))
		value = edit.get("value", w.default)
	if not remote.has("widgets"):
		remote.widgets = []
	remote.widgets.append(w)
	if not remote.has("parameters"):
		remote.parameters = {}
	remote.parameters[name] = value
	if remote_name == "gen_parameters" and not is_same(graph, data):
		if not graph.has("parameters"):
			graph.parameters = {}
		graph.parameters[name] = value
	changes.append("%s: added %s %s = %s" % [ node_path(subgraph, remote_name), w.type, name, shown(value) ])
	return ""

# The remote node a parameter edit works on: the one given as node, else the one of the graph that has the
# parameter; or an error message
func parameter_node(graph : Dictionary, subgraph : String, edit : Dictionary, name : String):
	if edit.has("node"):
		var remote = find_node(graph, str(edit.node))
		if remote == null or remote.get("type") != "remote":
			missing = remote == null
			return "No remote node named '%s'" % edit.node
		if find_widget(remote, name) == null:
			missing = true
			return "%s has no parameter '%s' (it has: %s)" % [ node_path(subgraph, remote.name), name, ", ".join(widget_names(remote)) ]
		return remote
	var holders : Array = []
	var names : PackedStringArray = []
	for n in graph.nodes:
		if n is Dictionary and n.get("type") == "remote":
			names.append_array(widget_names(n))
			if find_widget(n, name) != null:
				holders.append(n)
	if holders.is_empty():
		missing = true
		return "No remote node of %s has a parameter '%s' (they have: %s)" % [ subgraph if subgraph != "" else "the top level", name, ", ".join(names) ]
	if holders.size() > 1:
		return "'%s' is a parameter of %s: pass node" % [ name, " and ".join(PackedStringArray(holders.map(func(h): return h.name))) ]
	return holders[0]

func update_parameter(graph : Dictionary, subgraph : String, edit : Dictionary) -> String:
	var remote = parameter_node(graph, subgraph, edit, str(edit.get("name", "")))
	if remote is String:
		return remote
	var w = find_widget(remote, str(edit.get("name", "")))
	for key in [ "label", "min", "max", "step", "default" ]:
		if edit.has(key):
			if key != "label" and w.type != "named_parameter":
				return "Only named parameters have min, max, step and default"
			var old = w.get(key)
			w[key] = str(edit[key]) if key == "label" else like(old, edit[key])
			changes.append("%s %s %s: %s -> %s" % [ node_path(subgraph, remote.name), w.name, key, shown(old), shown(w[key]) ])
	return ""

# Renames an exposed parameter, or removes it when new_name is "": in the remote node, the expressions of
# its graph ($name), and for gen_parameters also the subgraph node and the controls linked to it
func rename_parameter(graph : Dictionary, subgraph : String, edit : Dictionary, new_name : String) -> String:
	var name : String = str(edit.get("name", ""))
	var remote = parameter_node(graph, subgraph, edit, name)
	if remote is String:
		return remote
	var remote_name : String = remote.name
	var w = find_widget(remote, name)
	var label : String = node_path(subgraph, remote_name)
	var removing : bool = new_name == ""
	if not removing and RegEx.create_from_string("^\\w+$").search(new_name) == null:
		return "A parameter name uses letters, digits and _"
	if not removing and find_widget(remote, new_name) != null:
		return "%s already has a parameter '%s'" % [ label, new_name ]
	var expression_users : PackedStringArray = []
	if w.type == "named_parameter":
		var regex : RegEx = RegEx.create_from_string("\\$"+name+"(?!\\w)")
		for n in graph.nodes:
			for p in n.get("parameters", {}).keys():
				var v = n.parameters[p]
				if v is String and regex.search(v) != null:
					expression_users.append(node_path(subgraph, n.name)+" "+p)
					if not removing:
						n.parameters[p] = regex.sub(v, "$$"+new_name, true)
	if removing and not expression_users.is_empty():
		return "$%s is still used by %s: change those first" % [ name, ", ".join(expression_users) ]
	if removing:
		remote.widgets.erase(w)
		remote.get("parameters", {}).erase(name)
	else:
		w.name = new_name
		rename_key(remote.get("parameters", {}), name, new_name)
	var links : int = 0
	if remote_name == "gen_parameters" and not is_same(graph, data):
		if removing:
			graph.get("parameters", {}).erase(name)
		else:
			rename_key(graph.get("parameters", {}), name, new_name)
		links = rename_links(graph_at(subgraph.get_base_dir()), graph.name, name, new_name)
	var change : String = ("%s: removed %s" % [ label, name ]) if removing else ("%s: renamed %s to %s" % [ label, name, new_name ])
	if w.type == "named_parameter":
		change += " (%d expressions, %d links)" % [ expression_users.size(), links ]
	else:
		# A control is not used by name: what it controls stays as it is
		var controlled : PackedStringArray = []
		for l in w.get("linked_widgets", []):
			controlled.append("%s.%s" % [ l.node, l.widget ])
		change += ", which %s %s" % [ "controlled" if removing else "still controls", ", ".join(controlled) ]
	changes.append(change)
	return ""

# Renames the links of the controls in a graph to a parameter of one of its nodes, or removes them when
# new_name is "" (with the controls left without links). Returns the number of links changed.
func rename_links(graph : Dictionary, node_name : String, name : String, new_name : String) -> int:
	var count : int = 0
	for remote in graph.nodes:
		if not remote is Dictionary or remote.get("type") != "remote":
			continue
		for w in remote.get("widgets", []).duplicate():
			var lists : Array = [ w.get("linked_widgets", []) ]
			lists.append_array(w.get("configurations", {}).values())
			for list in lists:
				for l in list.duplicate():
					if l.get("node") == node_name and l.get("widget") == name:
						count += 1
						if new_name == "":
							list.erase(l)
						else:
							l.widget = new_name
			if new_name == "" and w.has("linked_widgets") and w.linked_widgets.is_empty():
				remote.widgets.erase(w)
				remote.get("parameters", {}).erase(w.name)
				changes.append("%s: removed %s, which only controlled that parameter" % [ remote.name, w.name ])
	return count

func relink(from : String, to : String) -> String:
	if from == "":
		return "Pass the text to replace as from"
	for image in image_nodes(data, ""):
		var parameters : Dictionary = image.node.get("parameters", {})
		if parameters.get("image") is String and parameters.image.contains(from):
			var old : String = parameters.image
			parameters.image = old.replace(from, to)
			changes.append("%s image: %s -> %s" % [ image.path, old, parameters.image ])
	return ""

# The graph's own name, and its label when that only repeated the name (a label can describe the material)
func rename_graph(name : String) -> String:
	var old : String = str(data.get("name", ""))
	if old != name:
		if data.get("label") == old:
			data.label = name
		data.name = name
		changes.append("graph name: %s -> %s" % [ old, name ])
	return ""

func missing_images() -> PackedStringArray:
	var missing : PackedStringArray = []
	for image in image_nodes(data, ""):
		var file_path : String = str(image.node.get("parameters", {}).get("image", "")).replace("%PROJECT_PATH%", path.get_base_dir())
		if file_path != "" and not FileAccess.file_exists(file_path):
			missing.append("%s: %s" % [ image.path, file_path ])
	return missing

# Data helpers

# The graph at a subgraph path (node names joined by "/", "" for the top level), or null
func graph_at(subgraph : String):
	var graph = data
	if subgraph != "":
		for name in subgraph.split("/"):
			graph = find_node(graph, name)
			if graph == null or not graph.has("nodes"):
				return null
	return graph

# The node at a path ("SurfaceResponse/NegativeSlope", or "Material" at the top level), or null
func node_at(node_path : String):
	var graph = graph_at(node_path.get_base_dir())
	return find_node(graph, node_path.get_file()) if graph != null else null

func image_nodes(graph : Dictionary, prefix : String) -> Array:
	var images : Array = []
	for n in graph.get("nodes", []):
		if n is Dictionary and n.get("type") == "image":
			images.append({ path=prefix+n.name, node=n })
		elif n is Dictionary and n.has("nodes"):
			images.append_array(image_nodes(n, prefix+n.name+"/"))
	return images

static func find_node(graph : Dictionary, name : String):
	for n in graph.get("nodes", []):
		if n is Dictionary and n.get("name") == name:
			return n
	return null

static func find_widget(remote : Dictionary, name : String):
	for w in remote.get("widgets", []):
		if w.get("name") == name:
			return w
	return null

static func node_path(subgraph : String, name : String) -> String:
	return name if subgraph == "" else subgraph+"/"+name

# A new value in the file's style: the old value when they differ by less than 1e-9 (relative), so a value
# computed again does not change the file, and an int when it replaces an int with a whole number
static func like(old, value):
	if (old is int or old is float) and (value is int or value is float):
		if absf(value-old) <= 1e-9*maxf(absf(old), absf(value)):
			return old
		if old is int and value is float and value == floorf(value):
			return int(value)
	return value

# A value for the report, floats in full: JSON.stringify keeps about 12 digits
func shown(value) -> String:
	return literals.get(value, var_to_str(value)) if value is float else JSON.stringify(value)

static func widget_names(remote : Dictionary) -> PackedStringArray:
	var names : PackedStringArray = []
	for w in remote.get("widgets", []):
		names.append(str(w.get("name", "")))
	return names

# Renames a key in place, keeping the order of the keys
static func rename_key(d : Dictionary, old : String, new : String) -> void:
	if not d.has(old):
		return
	var copy : Dictionary = d.duplicate()
	d.clear()
	for k in copy.keys():
		d[new if k == old else k] = copy[k]

# Layout-preserving JSON

func write_value(value, indent : String, parts : PackedStringArray) -> void:
	match typeof(value):
		TYPE_DICTIONARY, TYPE_ARRAY:
			if value.is_empty():
				parts.append("{}" if value is Dictionary else "[]")
				return
			var inner : String = indent+layout.indent
			parts.append("{" if value is Dictionary else "[")
			var separator : String = "\n"
			for key in value.keys() if value is Dictionary else range(value.size()):
				parts.append(separator+inner)
				separator = ",\n"
				if value is Dictionary:
					parts.append(quote(str(key))+": ")
				write_value(value[key], inner, parts)
			parts.append("\n"+indent+("}" if value is Dictionary else "]"))
		TYPE_STRING, TYPE_STRING_NAME:
			parts.append(quote(value))
		TYPE_FLOAT:
			parts.append(literals.get(value, var_to_str(value)))
		TYPE_INT, TYPE_BOOL:
			parts.append(str(value))
		_:
			parts.append(JSON.stringify(value))

const ESCAPES : Dictionary = { 34: "\\\"", 92: "\\\\", 10: "\\n", 13: "\\r", 9: "\\t", 8: "\\b", 12: "\\f" }

# A JSON string, with non-ASCII characters escaped when the file had none (as Python writes JSON)
func quote(s : String) -> String:
	var parts : PackedStringArray = [ "\"" ]
	var start : int = 0
	for i in s.length():
		var c : int = s.unicode_at(i)
		var escape : String = ESCAPES.get(c, "")
		if escape == "" and (c < 32 or (c > 127 and layout.ascii)):
			if c > 0xFFFF:
				escape = "\\u%04x\\u%04x" % [ 0xD800+((c-0x10000) >> 10), 0xDC00+((c-0x10000) & 0x3FF) ]
			else:
				escape = "\\u%04x" % c
		if escape != "":
			parts.append(s.substr(start, i-start))
			parts.append(escape)
			start = i+1
	parts.append(s.substr(start))
	parts.append("\"")
	return "".join(parts)

# JSON.parse_string turns every number into a float; this keeps integers as int
class Parser:
	var text : String
	var pos : int = 0
	var failed : bool = false
	var literals : Dictionary = {}

	func _init(source : String) -> void:
		text = source

	# The next character that is not whitespace, -1 at the end
	func next_char() -> int:
		while pos < text.length():
			var c : int = text.unicode_at(pos)
			if c != 32 and c != 9 and c != 10 and c != 13:
				return c
			pos += 1
		return -1

	func parse_value():
		var c : int = next_char()
		if c == 123:
			return parse_object()
		if c == 91:
			return parse_array()
		if c == 34:
			return parse_string()
		for word in [ "true", "false", "null" ]:
			if text.substr(pos, word.length()) == word:
				pos += word.length()
				return { "true": true, "false": false, "null": null }[word]
		return parse_number()

	func parse_object() -> Dictionary:
		var result : Dictionary = {}
		pos += 1
		if next_char() == 125:
			pos += 1
			return result
		while not failed:
			if next_char() != 34:
				failed = true
				break
			var key : String = parse_string()
			if next_char() != 58:
				failed = true
				break
			pos += 1
			result[key] = parse_value()
			var c : int = next_char()
			pos += 1
			if c == 125:
				break
			failed = c != 44
		return result

	func parse_array() -> Array:
		var result : Array = []
		pos += 1
		if next_char() == 93:
			pos += 1
			return result
		while not failed:
			result.append(parse_value())
			var c : int = next_char()
			pos += 1
			if c == 93:
				break
			failed = c != 44
		return result

	func parse_string() -> String:
		pos += 1
		var parts : PackedStringArray = []
		var start : int = pos
		while pos < text.length():
			var c : int = text.unicode_at(pos)
			if c == 34:
				parts.append(text.substr(start, pos-start))
				pos += 1
				return "".join(parts)
			if c != 92:
				pos += 1
				continue
			parts.append(text.substr(start, pos-start))
			var e : String = text.substr(pos+1, 1)
			pos += 2
			if e == "u":
				var code : int = text.substr(pos, 4).hex_to_int()
				pos += 4
				if code >= 0xD800 and code < 0xDC00 and text.substr(pos, 2) == "\\u":
					code = 0x10000+((code-0xD800) << 10)+(text.substr(pos+2, 4).hex_to_int()-0xDC00)
					pos += 6
				parts.append(String.chr(code))
			else:
				parts.append({ "n": "\n", "r": "\r", "t": "\t", "b": String.chr(8), "f": String.chr(12) }.get(e, e))
			start = pos
		failed = true
		return ""

	func parse_number():
		var start : int = pos
		var is_float : bool = false
		while pos < text.length():
			var c : int = text.unicode_at(pos)
			if c == 46 or c == 101 or c == 69:
				is_float = true
			elif c != 45 and c != 43 and (c < 48 or c > 57):
				break
			pos += 1
		if pos == start:
			failed = true
			return null
		var literal : String = text.substr(start, pos-start)
		if not is_float:
			return literal.to_int()
		literals[literal.to_float()] = literal
		return literal.to_float()
