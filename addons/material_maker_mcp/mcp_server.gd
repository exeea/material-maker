extends Node

## Model Context Protocol server, so AI agents can drive Material Maker.
##
## Off unless Material Maker is started with --mcp (port 8790) or --mcp-port <port>.
## It answers MCP's Streamable HTTP transport with plain JSON responses on
## http://127.0.0.1:<port>/mcp and only accepts local connections.
## The tools are in mcp_tools.gd.

const DEFAULT_PORT : int = 8790
const PROTOCOL_VERSIONS : PackedStringArray = [ "2025-06-18", "2025-03-26", "2024-11-05" ]
const REQUEST_TIMEOUT_MS : int = 10000
const TOOL_TIMEOUT_MS : int = 600000
const MAX_REQUEST_SIZE : int = 64*1024*1024

var server : TCPServer
var tools : Node
var tool_running : bool = false


static func get_port() -> int:
	var args : PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var index : int = args.find("--mcp-port")
	if index != -1 and index+1 < args.size():
		return args[index+1].to_int()
	if args.has("--mcp"):
		return DEFAULT_PORT
	return 0

func _ready() -> void:
	var port : int = get_port()
	if port <= 0:
		set_process(false)
		return
	server = TCPServer.new()
	var error : Error = server.listen(port, "127.0.0.1")
	if error != OK:
		push_error("MCP server cannot listen on port %d: %s" % [ port, error_string(error) ])
		set_process(false)
		return
	tools = preload("res://addons/material_maker_mcp/mcp_tools.gd").new()
	add_child(tools)
	print("MCP server listening on http://127.0.0.1:%d/mcp" % port)

func _exit_tree() -> void:
	if server != null:
		server.stop()

func _process(_delta : float) -> void:
	while server.is_connection_available():
		handle_connection(server.take_connection())

# HTTP

func handle_connection(peer : StreamPeerTCP) -> void:
	var data : PackedByteArray = PackedByteArray()
	var header_size : int = -1
	var headers : Dictionary = {}
	var request_line : PackedStringArray = []
	var content_length : int = 0
	var deadline : int = Time.get_ticks_msec()+REQUEST_TIMEOUT_MS
	while header_size == -1 or data.size() < header_size+content_length:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() > deadline:
			return
		var available : int = peer.get_available_bytes()
		if available > 0:
			data.append_array(peer.get_data(available)[1])
			if header_size == -1:
				var header_end : int = data.get_string_from_ascii().find("\r\n\r\n")
				if header_end != -1:
					header_size = header_end+4
					var lines : PackedStringArray = data.slice(0, header_end).get_string_from_ascii().split("\r\n")
					request_line = lines[0].split(" ")
					for line in lines.slice(1):
						var colon : int = line.find(":")
						if colon != -1:
							headers[line.left(colon).strip_edges().to_lower()] = line.substr(colon+1).strip_edges()
					content_length = headers.get("content-length", "0").to_int()
					if content_length > MAX_REQUEST_SIZE:
						send_response(peer, 413)
						return
		else:
			await get_tree().process_frame
	if request_line.size() < 2 or request_line[1].split("?")[0] != "/mcp":
		send_response(peer, 404)
		return
	if not is_local_origin(headers.get("origin", "")):
		send_response(peer, 403)
		return
	if request_line[0] != "POST":
		# No server-initiated stream: every response comes back with its request
		send_response(peer, 405, "", { "Allow": "POST" })
		return
	var message = JSON.parse_string(data.slice(header_size, header_size+content_length).get_string_from_utf8())
	var response = await handle_message(message)
	if response == null:
		send_response(peer, 202)
	else:
		send_response(peer, 200, JSON.stringify(response), { "Content-Type": "application/json" })

# Browsers send an Origin header: only pages served from this machine may talk to the server
static func is_local_origin(origin : String) -> bool:
	if origin == "" or origin == "null":
		return true
	var host : String = origin.get_slice("://", 1).get_slice("/", 0)
	if host.begins_with("["):
		host = host.get_slice("]", 0)+"]"
	else:
		host = host.get_slice(":", 0)
	return host in [ "localhost", "127.0.0.1", "[::1]" ]

func send_response(peer : StreamPeerTCP, status : int, body : String = "", extra_headers : Dictionary = {}) -> void:
	const REASONS : Dictionary = { 200: "OK", 202: "Accepted", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large" }
	var body_bytes : PackedByteArray = body.to_utf8_buffer()
	var head : String = "HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n" % [ status, REASONS.get(status, ""), body_bytes.size() ]
	for header in extra_headers.keys():
		head += "%s: %s\r\n" % [ header, extra_headers[header] ]
	peer.put_data((head+"\r\n").to_utf8_buffer())
	if not body_bytes.is_empty():
		peer.put_data(body_bytes)
	peer.disconnect_from_host()

# JSON-RPC

func handle_message(message):
	if message == null:
		return rpc_error(null, -32700, "Parse error")
	if message is Array:
		var responses : Array = []
		for m in message:
			var response = await handle_message(m)
			if response != null:
				responses.append(response)
		return responses if not responses.is_empty() else null
	if not message is Dictionary or not message.has("method"):
		if message is Dictionary and (message.has("result") or message.has("error")):
			return null
		return rpc_error(null, -32600, "Invalid request")
	var id = message.get("id")
	var params : Dictionary = message.get("params", {}) if message.get("params") is Dictionary else {}
	var result
	match message.method:
		"initialize":
			var version : String = params.get("protocolVersion", "")
			result = {
				protocolVersion = version if version in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
				capabilities = { tools = { listChanged = false } },
				serverInfo = { name = "material-maker", title = "Material Maker", version = ProjectSettings.get_setting("application/config/actual_release", "") },
				instructions = tools.INSTRUCTIONS
			}
		"ping":
			result = {}
		"tools/list":
			result = { tools = tools.TOOLS }
		"tools/call":
			result = await call_tool(params.get("name", ""), params.get("arguments", {}) if params.get("arguments") is Dictionary else {})
		_:
			if not message.has("id"):
				return null
			return rpc_error(id, -32601, "Method not found: %s" % message.method)
	if not message.has("id"):
		return null
	return { jsonrpc = "2.0", id = id, result = result }

static func rpc_error(id, code : int, error_message : String) -> Dictionary:
	return { jsonrpc = "2.0", id = id, error = { code = code, message = error_message } }

func is_startup_finished() -> bool:
	return mm_globals.main_window != null and mm_globals.main_window.startup_finished

# One tool at a time, so agents cannot interleave edits of the same graph.
# A tool that does not finish in time is reported and no longer blocks the others.
func call_tool(tool_name : String, arguments : Dictionary) -> Dictionary:
	while tool_running:
		await get_tree().process_frame
	tool_running = true
	var start : int = Time.get_ticks_msec()
	# Tools work on the main window: wait until it has finished starting
	while not is_startup_finished() and Time.get_ticks_msec()-start < TOOL_TIMEOUT_MS:
		await get_tree().process_frame
	print("MCP tool %s started" % tool_name)
	var state : Dictionary = {}
	if is_startup_finished():
		# Tools wait for frames: unfocused, Material Maker would run them at its idle FPS limit
		mm_globals.main_window.full_speed = true
		(func(): state.result = await tools.call_tool(tool_name, arguments)).call()
	while not state.has("result") and Time.get_ticks_msec()-start < TOOL_TIMEOUT_MS:
		await get_tree().process_frame
	if is_startup_finished():
		mm_globals.main_window.full_speed = false
	tool_running = false
	var duration : int = Time.get_ticks_msec()-start
	if not state.has("result"):
		push_error("MCP tool %s did not finish within %d s" % [ tool_name, duration/1000 ])
		return tools.error_result("%s did not finish within %d s" % [ tool_name, duration/1000 ])
	print("MCP tool %s finished in %d ms" % [ tool_name, duration ])
	return state.result
