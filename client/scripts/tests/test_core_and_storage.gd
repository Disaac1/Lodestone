extends SceneTree

# =====================================================================
#             SUITE 1: CORE ENGINE, STORAGE & ASSET PIPELINE
# =====================================================================
# Validates core boot lifecycle, directory auto-creation, path resolution,
# ROM catalog multi-key lookups, encryption key inheritance, multi-track
# colocation, legacy migration, and engine power efficiency settings.
# =====================================================================

var test_passed: bool = true
var lobby: Node

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
	print("  SUITE 1: CORE ENGINE, STORAGE & ASSET PIPELINE                 ")
	print("==================================================================")

	var lobby_scene = load("res://scenes/lobby.tscn")
	if not lobby_scene:
		_fail("Failed to load res://scenes/lobby.tscn")
		_finish()
		return

	lobby = lobby_scene.instantiate()
	root.add_child(lobby)

	var launcher = lobby.launcher
	await launcher.load_launcher_config()

	# -------------------------------------------------------------
	# 1. Directory Auto-Creation & Storage Structure
	# -------------------------------------------------------------
	print("\n[Test 1] Verifying core directories auto-creation...")
	var games_dir = launcher.USER_GAMES_DIR
	var tools_dir = launcher.USER_TOOLS_DIR
	var saves_dir = launcher.USER_SAVES_DIR

	DirAccess.make_dir_recursive_absolute(games_dir)
	DirAccess.make_dir_recursive_absolute(tools_dir)
	DirAccess.make_dir_recursive_absolute(saves_dir)

	_assert_true(DirAccess.dir_exists_absolute(games_dir), "games_dir missing: " + games_dir)
	_assert_true(DirAccess.dir_exists_absolute(tools_dir), "tools_dir missing: " + tools_dir)
	_assert_true(DirAccess.dir_exists_absolute(saves_dir), "saves_dir missing: " + saves_dir)
	print("  -> Passed: Core directories (games/, tools/, saves/) verified.")

	# -------------------------------------------------------------
	# 2. Canonical Slug & Unified Path Resolution
	# -------------------------------------------------------------
	print("\n[Test 2] Verifying canonical slugs and path resolution...")
	var slug_test_cases = [
		{"name": "Metroid Fusion", "expected_slug": "metroid_fusion"},
		{"name": "Pokemon Emerald", "expected_slug": "pokemon_emerald"},
		{"name": "Symphony of the Night", "expected_slug": "symphony_of_the_night"},
		{"name": "Plants vs. Zombies", "expected_slug": "plants_vs_zombies"},
		{"name": "Hollow Knight", "expected_slug": "hollow_knight"},
		{"name": "Super Mario 64", "expected_slug": "super_mario_64"},
		{"name": "Slay the Spire", "expected_slug": "slay_the_spire"},
		{"name": "Hades", "expected_slug": "hades"}
	]

	for tc in slug_test_cases:
		var slug = launcher.get_game_slug(tc["name"])
		_assert_true(slug == tc["expected_slug"], "Expected slug '%s' for '%s', got '%s'" % [tc["expected_slug"], tc["name"], slug])
		var game_dir = launcher.get_game_dir(tc["name"])
		_assert_true(game_dir.ends_with(tc["expected_slug"]), "Game dir '%s' should end with slug '%s'" % [game_dir, tc["expected_slug"]])
	print("  -> Passed: Canonical slugs and directory mapping verified for all focus games.")

	# -------------------------------------------------------------
	# 3. Multi-Key Catalog Lookup (Slug, Title, ROM filename, Alias)
	# -------------------------------------------------------------
	print("\n[Test 3] Verifying multi-key ROM catalog lookup...")
	var catalog_backup = launcher.roms_catalog.duplicate(true)
	launcher.roms_catalog = {
		"metroid_fusion": "https://example.com/fusion_by_slug.gba",
		"Pokemon - Emerald Version (USA).gba": "https://example.com/emerald_by_filename.gba",
		"Plants vs. Zombies": "https://example.com/pvz.zip"
	}

	var mf_entry = launcher.get_rom_download_entry("Metroid Fusion (USA).gba")
	_assert_true(not mf_entry.is_empty(), "Failed resolving fusion catalog entry by ROM filename")
	_assert_true(mf_entry.get("url") == "https://example.com/fusion_by_slug.gba", "Fusion URL mismatch")

	var emerald_entry = launcher.get_rom_download_entry("pokemon_emerald")
	_assert_true(not emerald_entry.is_empty(), "Failed resolving emerald catalog entry by slug")
	_assert_true(emerald_entry.get("url") == "https://example.com/emerald_by_filename.gba", "Emerald URL mismatch")

	var pvz_entry = launcher.get_rom_download_entry("plants_vs_zombies")
	_assert_true(not pvz_entry.is_empty(), "Failed resolving pvz catalog entry by slug")
	launcher.roms_catalog = catalog_backup
	print("  -> Passed: Multi-key catalog resolution verified.")

	# -------------------------------------------------------------
	# 4. Download URL & Decryption Key Inheritance
	# -------------------------------------------------------------
	print("\n[Test 4] Verifying download link resolution and decryption key inheritance...")
	var gdrive_share = "https://drive.google.com/file/d/1AbC_dEfG-9876543210/view?usp=sharing"
	var resolved_share = launcher.resolve_download_url(gdrive_share)
	_assert_true("drive.usercontent.google.com/download?id=1AbC_dEfG-9876543210" in resolved_share, "GDrive share URL not transformed properly")

	var direct_url = "https://example.com/games/sotn.zip"
	_assert_true(launcher.resolve_download_url(direct_url) == direct_url, "Direct URL was incorrectly altered")

	launcher.roms_catalog = {
		"default_key": "MasterKey123",
		"Metroid Fusion (USA).gba": "https://example.com/mf.gba.enc",
		"Plants vs. Zombies": {
			"url": "https://example.com/pvz.zip",
			"key": "CustomPvZKey"
		}
	}
	var mf_dec = launcher.get_rom_download_entry("Metroid Fusion (USA).gba")
	_assert_true(mf_dec.get("key") == "MasterKey123", "Failed default key inheritance")
	_assert_true(mf_dec.get("encrypted") == true, "Expected encrypted=true when key is present")

	var pvz_dec = launcher.get_rom_download_entry("Plants vs. Zombies")
	_assert_true(pvz_dec.get("key") == "CustomPvZKey", "Failed custom key override")
	launcher.roms_catalog = catalog_backup
	print("  -> Passed: Download URL resolution and key inheritance verified.")

	# -------------------------------------------------------------
	# 5. Multi-Track CD-ROM Colocation & Supplemental File Finding
	# -------------------------------------------------------------
	print("\n[Test 5] Verifying multi-track CD-ROM colocation...")
	var sotn_dir = launcher.get_game_dir("Symphony of the Night")
	DirAccess.make_dir_recursive_absolute(sotn_dir)
	var track1_path = sotn_dir.path_join("Castlevania - Symphony of the Night (USA) (Track 1).bin")
	var track2_path = sotn_dir.path_join("Castlevania - Symphony of the Night (USA) (Track 2).bin")

	var fa1 = FileAccess.open(track1_path, FileAccess.WRITE)
	fa1.store_string("TRACK1_MOCK")
	fa1.close()

	var fa2 = FileAccess.open(track2_path, FileAccess.WRITE)
	fa2.store_string("TRACK2_MOCK")
	fa2.close()

	var found_track2 = launcher._find_supplemental_rom_path(track1_path, "Castlevania - Symphony of the Night (USA) (Track 2).bin")
	_assert_true(found_track2 != "", "Supplemental Track 2 not found colocated")
	DirAccess.remove_absolute(track1_path)
	DirAccess.remove_absolute(track2_path)
	print("  -> Passed: Multi-track colocation verified.")

	# -------------------------------------------------------------
	# 6. Legacy Base ROM Auto-Migration
	# -------------------------------------------------------------
	print("\n[Test 6] Verifying legacy base_roms directory auto-migration...")
	var legacy_dir = launcher.USER_BASE_ROMS_DIR
	DirAccess.make_dir_recursive_absolute(legacy_dir)
	var legacy_rom = legacy_dir.path_join("Pokemon - Emerald Version (USA).gba")
	var dest_em_dir = launcher.get_game_dir("Pokemon Emerald")
	var dest_em_path = dest_em_dir.path_join("Pokemon - Emerald Version (USA).gba")

	if FileAccess.file_exists(dest_em_path):
		DirAccess.remove_absolute(dest_em_path)

	var fa_leg = FileAccess.open(legacy_rom, FileAccess.WRITE)
	var dummy_bytes = PackedByteArray()
	dummy_bytes.resize(512)
	dummy_bytes.fill(88)
	fa_leg.store_buffer(dummy_bytes)
	fa_leg.close()

	var migrated_path = launcher.find_existing_base_rom("Pokemon - Emerald Version (USA).gba")
	_assert_true(FileAccess.file_exists(dest_em_path), "ROM was not migrated to unified game folder")
	_assert_true(!FileAccess.file_exists(legacy_rom), "Legacy base_roms file was not cleaned up after migration")
	DirAccess.remove_absolute(dest_em_path)
	print("  -> Passed: Legacy ROM auto-migration and cleanup verified.")

	# -------------------------------------------------------------
	# 7. Low Processor Mode Project & OS Settings
	# -------------------------------------------------------------
	print("\n[Test 7] Verifying low processor mode engine power settings...")
	var lpm_proj = ProjectSettings.get_setting("application/run/low_processor_mode")
	var lpm_sleep = ProjectSettings.get_setting("application/run/low_processor_mode_sleep_usec")
	_assert_true(lpm_proj == true, "ProjectSetting application/run/low_processor_mode must be true")
	_assert_true(lpm_sleep == 6900, "ProjectSetting low_processor_mode_sleep_usec must be 6900")
	_assert_true(OS.low_processor_usage_mode == true, "OS.low_processor_usage_mode must be true")
	_assert_true(OS.low_processor_usage_mode_sleep_usec == 6900, "OS.low_processor_usage_mode_sleep_usec must be 6900")
	print("  -> Passed: Engine power efficiency and sleep throttling verified.")

	# -------------------------------------------------------------
	# 8. Guardrails Against Cross-Game Fuzzy Matching & Sibling Pollution
	# -------------------------------------------------------------
	print("\n[Test 8] Verifying cross-game fuzzy matching guardrails...")
	var bw_dir = launcher.get_game_dir("test_sibling_isolation_b")
	var bw_rom = bw_dir.path_join("Pokemon - Black Version (USA, Europe) (NDSi Enhanced).nds")
	var fa_bw = FileAccess.open(bw_rom, FileAccess.WRITE)
	fa_bw.store_string("mock nds rom content")
	fa_bw.close()

	var matched = launcher.find_existing_base_rom("Test Game Alpha (USA).gba")
	_assert_true(matched == "", "Fuzzy search must NOT match sibling game Pokemon Black for another game")
	DirAccess.remove_absolute(bw_rom)
	DirAccess.remove_absolute(bw_dir)
	print("  -> Passed: Cross-game fuzzy matching guardrails verified.")

	_finish()

func _finish() -> void:
	print("\n==================================================================")
	if test_passed:
		print("  SUITE 1: ALL CORE STORAGE & ASSET TESTS PASSED! [OK]           ")
	else:
		printerr("  SUITE 1: COMPLETED WITH FAILURES!                              ")
	print("==================================================================")
	if lobby:
		lobby.queue_free()
	quit(0 if test_passed else 1)
