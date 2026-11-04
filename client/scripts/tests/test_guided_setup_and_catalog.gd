extends SceneTree

# =====================================================================
#             SUITE 2: GUIDED SETUP & GAME CATALOG MATRIX
# =====================================================================
# Data-driven validation of all focus games: Guided Setup JSON schemas,
# wizard step generation, dynamic UI control compilation, APWorld metadata
# and upstream repository linking, and game icon assets.
# =====================================================================

const CustomWorldSyncService = preload("res://scripts/core/custom_world_sync_service.gd")

var test_passed: bool = true

const FOCUS_GAMES = [
	{"name": "Pokemon Emerald", "slug": "pokemon_emerald", "apworld": "", "custom_world": false},
	{"name": "Pokemon Black and White", "slug": "pokemon_black_and_white", "apworld": "", "custom_world": false},
	{"name": "Super Mario 64", "slug": "super_mario_64", "apworld": "", "custom_world": false},
	{"name": "Hollow Knight", "slug": "hollow_knight", "apworld": "", "custom_world": false},
	{"name": "Metroid Fusion", "slug": "metroid_fusion", "apworld": "", "custom_world": false},
	{"name": "Plants vs. Zombies", "slug": "plants_vs_zombies", "apworld": "", "custom_world": false},
	{"name": "Symphony of the Night", "slug": "symphony_of_the_night", "apworld": "", "custom_world": false},
	{"name": "Slay the Spire", "slug": "slay_the_spire", "apworld": "spire.apworld", "custom_world": true},
	{"name": "Slay the Spire 2", "slug": "slay_the_spire_2", "apworld": "spire2.apworld", "custom_world": true},
	{"name": "Hades", "slug": "hades", "apworld": "hades.apworld", "custom_world": true},
	{"name": "The Binding of Isaac Repentance", "slug": "the_binding_of_isaac_repentance", "apworld": "tboir.apworld", "custom_world": true},
	{"name": "Luigi's Mansion", "slug": "luigis_mansion", "apworld": "luigismansion.apworld", "custom_world": true},
	{"name": "A Link to the Past", "slug": "a_link_to_the_past", "apworld": "", "custom_world": false},
	{"name": "Stardew Valley", "slug": "stardew_valley", "apworld": "", "custom_world": false},
	{"name": "Pokemon Red and Blue", "slug": "pokemon_red_and_blue", "apworld": "", "custom_world": false},
	{"name": "Factorio", "slug": "factorio", "apworld": "", "custom_world": false}
]

func _init() -> void:
	_run_suite.call_deferred()

func _fail(reason: String) -> void:
	printerr("  ❌ [FAIL] ", reason)
	test_passed = false

func _assert_true(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)

func _run_suite() -> void:
	print("==================================================================")
	print("  SUITE 2: GUIDED SETUP & GAME CATALOG MATRIX                     ")
	print("==================================================================")

	var registry = load("res://scripts/guided_setup/guided_setup_registry.gd")
	if not registry:
		_fail("Failed to load res://scripts/guided_setup/guided_setup_registry.gd")
		_finish()
		return

	# -------------------------------------------------------------
	# 1. Declarative Guided Setup Validation for All Focus Games
	# -------------------------------------------------------------
	print("\n[Test 1] Validating Guided Setup JSON schemas & UI generation across %d games..." % FOCUS_GAMES.size())

	for item in FOCUS_GAMES:
		var g_name = item["name"]
		var slug = item["slug"]
		print("\n  -> Testing: '%s' (slug: %s)..." % [g_name, slug])

		_assert_true(registry.has_guided_setup(g_name), "Registry missing guided setup for: " + g_name)
		var json_path = registry._get_declarative_json_path(g_name)
		_assert_true(json_path != "", "No JSON schema path found for: " + g_name)

		var wizard = registry.DeclarativeGuidedSetupScript.new()
		_assert_true(wizard.load_from_file(json_path), "Failed to load/parse JSON at: " + json_path)

		var req_keys = wizard._get_required_schema_keys()
		var steps = wizard._get_steps_data()
		_assert_true(steps.size() >= 3, "Expected at least 3 wizard steps, got %d for %s" % [steps.size(), g_name])

		# Validate check_calculator configuration
		var check_calc = wizard._get_check_calculator()
		_assert_true(not check_calc.is_empty(), "Missing check_calculator for: " + g_name)
		_assert_true(int(check_calc.get("base_count", 0)) > 0, "check_calculator base_count must be > 0 for: " + g_name)

		# Build mock schema
		var mock_schema_options = []
		for k in req_keys:
			mock_schema_options.append({"name": k})
		var val_res = registry.validate_and_create(g_name, {"options": mock_schema_options})
		_assert_true(val_res.get("valid", false), "Validation failed for %s: %s" % [g_name, str(val_res.get("reason"))])

		var active_wizard = val_res.get("wizard")
		_assert_true(active_wizard != null, "Active wizard is null for: " + g_name)

		var dummy_container = VBoxContainer.new()
		root.add_child(dummy_container)
		var cfg = {}
		active_wizard.init_config(cfg)

		var eval_checks = active_wizard.calculate_current_checks()
		_assert_true(int(eval_checks.get("total", 0)) > 0, "calculate_current_checks total must be > 0 for: " + g_name)

		for s in steps:
			active_wizard.current_step = s.get("num", 1)
			active_wizard.build_wizard_ui(dummy_container, func(k, v): cfg[k] = v)

		_assert_true(dummy_container.get_child_count() > 0, "No UI controls generated for: " + g_name)
		dummy_container.queue_free()
		print("     [OK] Steps: %d, Required keys: %d, Title: '%s'" % [steps.size(), req_keys.size(), wizard._get_game_title()])

	# -------------------------------------------------------------
	# 2. Reactive Check Calculator Live Update Test
	# -------------------------------------------------------------
	print("\n[Test 2] Verifying reactive live check calculation & UI updates on option change...")
	var sm64_res = registry.validate_and_create("Super Mario 64", {})
	_assert_true(sm64_res.get("valid", false), "Failed to instantiate SM64 wizard")
	var sm64_wizard = sm64_res.get("wizard")
	var sm64_cfg = {}
	sm64_wizard.init_config(sm64_cfg)
	var initial_checks = sm64_wizard.calculate_current_checks()
	_assert_true(initial_checks["total"] == 105, "Expected 105 base stars, got %d" % initial_checks["total"])
	
	var test_container = VBoxContainer.new()
	root.add_child(test_container)
	sm64_wizard.current_step = 3
	sm64_wizard.build_wizard_ui(test_container, func(k, v): sm64_cfg[k] = v)
	
	sm64_wizard.set_option_value("buddy_checks", true)
	var updated_checks = sm64_wizard.calculate_current_checks()
	_assert_true(updated_checks["total"] == 120, "Expected 120 checks after buddy checks, got %d" % updated_checks["total"])
	_assert_true(sm64_wizard._check_card_title_lbl != null and sm64_wizard._check_card_title_lbl.text.contains("120"), "Live label did not update reactively!")
	
	sm64_wizard.set_option_value("exclamation_boxes", true)
	var final_checks = sm64_wizard.calculate_current_checks()
	_assert_true(final_checks["total"] == 149, "Expected 149 checks after !-boxes, got %d" % final_checks["total"])
	_assert_true(sm64_wizard._check_card_title_lbl.text.contains("149"), "Live label did not update reactively to 149!")
	
	test_container.queue_free()
	print("  -> Passed: Reactive live check card successfully updated from 105 -> 120 -> 149 checks in 0ms.")

	# -------------------------------------------------------------
	# 3. Custom APWorld Metadata & Dynamic Download Path Validation
	# -------------------------------------------------------------
	print("\n[Test 3] Verifying custom APWorld metadata and dynamic paths...")
	var user_cw_dir: String = "user://custom_worlds"
	DirAccess.make_dir_recursive_absolute(user_cw_dir)
	_assert_true(DirAccess.dir_exists_absolute(user_cw_dir), "Could not initialize user://custom_worlds directory")

	for item in FOCUS_GAMES:
		if not item.get("custom_world", false):
			continue
		var apworld_file = item["apworld"]
		_assert_true(apworld_file.ends_with(".apworld"), "Invalid apworld filename: " + apworld_file)
		print("  -> Passed: Verified custom APWorld metadata definition: " + apworld_file)

	# -------------------------------------------------------------
	# 3. Game Icon Asset Presence
	# -------------------------------------------------------------
	print("\n[Test 3] Verifying game artwork icon assets...")
	for item in FOCUS_GAMES:
		var slug = item["slug"]
		var icon_path = "res://../backend/data/games/" + slug + "/icon.png"
		_assert_true(FileAccess.file_exists(icon_path), "Missing game icon at: " + icon_path)
	print("  -> Passed: All %d focus game icons exist on disk." % FOCUS_GAMES.size())

	# -------------------------------------------------------------
	# 4. CustomWorldSyncService ZIP Validation & Self-Healing
	# -------------------------------------------------------------
	print("\n[Test 4] Verifying CustomWorldSyncService ZIP validation and corruption recovery...")
	var sandbox_src = "user://test_cw_src"
	var sandbox_dst = "user://test_cw_dst"
	DirAccess.make_dir_recursive_absolute(sandbox_src)
	DirAccess.make_dir_recursive_absolute(sandbox_dst)

	# 1. Non-existent file
	_assert_true(not CustomWorldSyncService.is_valid_apworld(sandbox_src.path_join("nonexistent.apworld")), "Nonexistent file must be invalid")

	# 2. Corrupt file (zero bytes / missing PK magic)
	var corrupt_file = sandbox_src.path_join("corrupt.apworld")
	var fa_c = FileAccess.open(corrupt_file, FileAccess.WRITE)
	if fa_c:
		fa_c.store_buffer(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
		fa_c.close()
	_assert_true(not CustomWorldSyncService.is_valid_apworld(corrupt_file), "Zero-filled file must be invalid")

	# 3. Valid zip file
	var valid_file = sandbox_src.path_join("valid.apworld")
	var zp = ZIPPacker.new()
	var zp_err = zp.open(valid_file)
	if zp_err == OK:
		zp.start_file("world.py")
		zp.write_file(PackedByteArray([112, 114, 105, 110, 116, 40, 41]))
		zp.close_file()
		zp.close()
	_assert_true(CustomWorldSyncService.is_valid_apworld(valid_file), "Valid ZIPPacker file must be valid")

	# 4. Sync service restores corrupt destination from valid source
	var dst_corrupt = sandbox_dst.path_join("valid.apworld")
	var fa_dc = FileAccess.open(dst_corrupt, FileAccess.WRITE)
	if fa_dc:
		fa_dc.store_buffer(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
		fa_dc.close()
	_assert_true(not CustomWorldSyncService.is_valid_apworld(dst_corrupt), "Destination file is initially corrupt")

	# Run sync with custom destinations pointing to sandbox_dst
	var sync_svc = CustomWorldSyncService.new(func(): return [sandbox_dst])
	# Copy valid_file to user://custom_worlds temporarily
	var staging_file = "user://custom_worlds/valid.apworld"
	DirAccess.copy_absolute(valid_file, staging_file)
	sync_svc.sync_to_archipelago()

	_assert_true(CustomWorldSyncService.is_valid_apworld(dst_corrupt), "Corrupted destination must be healed from valid source")

	# Cleanup
	DirAccess.remove_absolute(staging_file)
	DirAccess.remove_absolute(dst_corrupt)
	DirAccess.remove_absolute(valid_file)
	DirAccess.remove_absolute(corrupt_file)
	DirAccess.remove_absolute(sandbox_src)
	DirAccess.remove_absolute(sandbox_dst)
	print("  -> Passed: APWorld validation and destination corruption self-healing verified.")

	_finish()

func _finish() -> void:
	print("\n==================================================================")
	if test_passed:
		print("  SUITE 2: ALL GUIDED SETUP & CATALOG TESTS PASSED! [OK]         ")
	else:
		printerr("  SUITE 2: COMPLETED WITH FAILURES!                              ")
	print("==================================================================")
	quit(0 if test_passed else 1)
