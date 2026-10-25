extends VBoxContainer

# The current material as MegaMek shows it on the ground (game_view.gd), with the hex size and the size of one repeat
# of the maps in metres. The mouse wheel zooms. The maps render again shortly after the material changes, while the
# panel is visible.

const GameView = preload("res://material_maker/panels/game_view/game_view.gd")
const FloatEditScene = preload("res://material_maker/widgets/float_edit/float_edit.tscn")

var game_view : SubViewport = GameView.new()
var hex_edit : FloatEdit
var repeat_edit : FloatEdit
var grid_box : CheckBox
var view_metres : float = GameView.VIEW_METRES

var current_material : MMGenMaterial = null
var maps_outdated : bool = false
var rendering : bool = false

func _ready() -> void:
	clip_contents = true
	# Wraps in a narrow panel
	var controls : HFlowContainer = HFlowContainer.new()
	add_child(controls)
	hex_edit = add_float_edit(controls, "Hex (m)", "Width of a hex, from point to point", 5, 60, GameView.HEX_METRES)
	repeat_edit = add_float_edit(controls, "Repeat (m)", "Ground covered by one repeat of the maps", 1, 64, GameView.REPEAT_METRES)
	grid_box = CheckBox.new()
	grid_box.text = "Grid"
	grid_box.button_pressed = true
	grid_box.toggled.connect(func(_on): update_view())
	controls.add_child(grid_box)
	var container : SubViewportContainer = SubViewportContainer.new()
	container.stretch = true
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.gui_input.connect(on_view_gui_input)
	container.add_child(game_view)
	add_child(container)
	update_view()

func add_float_edit(parent : Control, text : String, tooltip : String, min_value : float, max_value : float, value : float) -> FloatEdit:
	var row : HBoxContainer = HBoxContainer.new()
	parent.add_child(row)
	var label : Label = Label.new()
	label.text = text
	label.tooltip_text = tooltip
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(label)
	var edit : FloatEdit = FloatEditScene.instantiate()
	edit.min_value = min_value
	edit.max_value = max_value
	edit.step = 0.5
	edit.value = value
	edit.tooltip_text = tooltip
	edit.custom_minimum_size.x = 80
	edit.value_changed.connect(func(_value): update_view())
	row.add_child(edit)
	return edit

func update_view() -> void:
	game_view.set_view(hex_edit.value, repeat_edit.value, view_metres, grid_box.button_pressed)

func on_view_gui_input(event : InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				view_metres = max(view_metres/1.1, 10.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				view_metres = min(view_metres*1.1, 600.0)
			_:
				return
		update_view()
		accept_event()

# The main window calls this when the current material or its graph changes; the material's own signal tells when
# its maps change
func show_material(generator : MMGenMaterial) -> void:
	if generator != current_material:
		if is_instance_valid(current_material):
			current_material.preview_texture_updated.disconnect(on_maps_changed)
		if generator != null:
			generator.preview_texture_updated.connect(on_maps_changed)
		current_material = generator
	on_maps_changed()

func on_maps_changed() -> void:
	maps_outdated = true
	update_maps()

func update_maps() -> void:
	if rendering or not maps_outdated or not is_visible_in_tree():
		return
	rendering = true
	while maps_outdated and is_visible_in_tree():
		# A change renders several preview textures one after the other
		await get_tree().create_timer(0.1).timeout
		maps_outdated = false
		if is_instance_valid(current_material):
			await game_view.update_maps(current_material)
		else:
			game_view.clear_maps()
	rendering = false

# Shown again, or added to the layout
func _notification(what : int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_ENTER_TREE:
		update_maps.call_deferred()
