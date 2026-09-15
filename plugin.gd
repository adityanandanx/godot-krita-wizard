@tool
extends EditorPlugin

const NoopImportPlugin = preload("importers/noop_import_plugin.gd")
const TextureImportPlugin = preload("importers/static_texture_import_plugin.gd")
const TextureSplitImportPlugin = preload("importers/static_texture_multiple_import_plugin.gd")
const LayerTextureImportPlugin = preload("importers/layer_texture_import_plugin.gd")
const TilesetTextureImportPlugin = preload("importers/tileset_texture_import_plugin.gd")
const ParallaxLayersImportPlugin = preload("importers/parallax_layers_import_plugin.gd")
const SpriteFramesImportPlugin = preload("importers/sprite_frames_import_plugin.gd")
const FileSystemHelper = preload("importers/helpers/file_system_helper.gd")

const WizardDock = preload("interface/wizard_dock.gd")
const ConfigDialog = preload("interface/config_dialog.gd")

const tool_menu_name = "Krita Wizard"
const menu_item_name = "Layers Wizard Dock..."
const config_menu_item_name = "Config..."

var config = preload("config/config.gd").new()
var window: Control
var config_window: Window

var _importers = []

var file_system_helper


func _enter_tree():
	_load_config()
	_setup_menu_entries()
	_setup_importer()


func _exit_tree():
	_disable_plugin()


func _disable_plugin():
	_remove_menu_entries()
	_remove_importer()
	_remove_wizard_dock()
	_remove_config_dialog()


func _load_config():
	config.initialize_project_settings()


func _setup_menu_entries():
	var submenu = PopupMenu.new()
	add_tool_submenu_item(tool_menu_name, submenu)
	submenu.add_item(menu_item_name)
	submenu.add_item(config_menu_item_name)
	submenu.index_pressed.connect(_on_tool_menu_pressed)


func _remove_menu_entries():
	remove_tool_menu_item(tool_menu_name)


func _setup_importer():
	file_system_helper = FileSystemHelper.new()
	add_child(file_system_helper)

	_importers = [
		NoopImportPlugin.new(),
		TextureImportPlugin.new(),
		TextureSplitImportPlugin.new(file_system_helper),
		LayerTextureImportPlugin.new(),
		TilesetTextureImportPlugin.new(),
		ParallaxLayersImportPlugin.new(),
		SpriteFramesImportPlugin.new(),
	]

	for i in _importers:
		add_import_plugin(i)


func _remove_importer():
	for i in _importers:
		remove_import_plugin(i)

	if file_system_helper != null:
		file_system_helper.queue_free()
		file_system_helper = null


func _remove_wizard_dock():
	if window:
		remove_control_from_bottom_panel(window)
		window.queue_free()
		window = null


func _remove_config_dialog():
	if is_instance_valid(config_window):
		config_window.queue_free()


func _open_window():
	if window:
		make_bottom_panel_item_visible(window)
		return

	window = WizardDock.new()
	window.connect("close_requested", Callable(self, "_on_window_closed"))
	add_control_to_bottom_panel(window, "Krita Wizard")
	make_bottom_panel_item_visible(window)


func _open_config_dialog():
	if is_instance_valid(config_window):
		config_window.queue_free()

	config_window = ConfigDialog.new()
	get_editor_interface().get_base_control().add_child(config_window)
	config_window.popup_centered_ratio(0.5)


func _on_window_closed():
	if window:
		remove_control_from_bottom_panel(window)
		window.queue_free()
		window = null


func _on_tool_menu_pressed(index):
	match index:
		0: # wizard dock
			_open_window()
		1: # config
			_open_config_dialog()
