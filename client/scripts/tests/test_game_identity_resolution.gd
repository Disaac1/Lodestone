extends SceneTree

const GameIdentityResolverScript = preload("res://scripts/core/game_identity_resolver.gd")
const GuidedSetupRegistryScript = preload("res://scripts/guided_setup/guided_setup_registry.gd")
const DashboardGameCardScene = preload("res://scenes/components/dashboard_game_card.tscn")
const BannerService = preload("res://scripts/core/banner_service.gd")

var test_passed: bool = true
var lobby: Control = null

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
	print("  SUITE: GAME IDENTITY RESOLUTION & STATIC METHOD VALIDATION      ")
	print("==================================================================")

	var lobby_scene = load("res://scenes/lobby.tscn")
	if not lobby_scene:
		_fail("Failed to load res://scenes/lobby.tscn")
		_finish()
		return

	lobby = lobby_scene.instantiate()
	root.add_child(lobby)

	# -------------------------------------------------------------
	# 1. Static methods on GameIdentityResolver
	# -------------------------------------------------------------
	print("\n[Test 1] Testing GameIdentityResolver.normalize() & slugify() static methods...")
	
	var norm_test_cases = [
		{"input": "Pokémon Emerald", "expected": "pokemonemerald"},
		{"input": "Pokemon Emerald", "expected": "pokemonemerald"},
		{"input": "Pokemon - Emerald", "expected": "pokemonemerald"},
		{"input": "Pokemon: Emerald", "expected": "pokemonemerald"},
		{"input": "Castlevania: Symphony of the Night", "expected": "castlevaniasymphonyofthenight"},
		{"input": "Castlevania - Symphony of the Night", "expected": "castlevaniasymphonyofthenight"},
		{"input": "Luigi's Mansion", "expected": "luigismansion"},
		{"input": "Plants vs. Zombies", "expected": "plantsvszombies"},
		{"input": "Mega Man X-3 (USA)", "expected": "megamanx3usa"}
	]

	for tc in norm_test_cases:
		var actual = GameIdentityResolverScript.normalize(tc["input"])
		_assert_true(actual == tc["expected"], "normalize('%s'): expected '%s', got '%s'" % [tc["input"], tc["expected"], actual])

	var slug_test_cases = [
		{"input": "Pokémon Emerald", "expected": "pokemon_emerald"},
		{"input": "Pokemon Emerald", "expected": "pokemon_emerald"},
		{"input": "Pokemon - Emerald", "expected": "pokemon_emerald"},
		{"input": "Castlevania: Symphony of the Night", "expected": "castlevania_symphony_of_the_night"},
		{"input": "Castlevania - Symphony of the Night", "expected": "castlevania_symphony_of_the_night"},
		{"input": "Luigi's Mansion", "expected": "luigis_mansion"},
		{"input": "Plants vs. Zombies", "expected": "plants_vs_zombies"},
		{"input": "Super Mario 64", "expected": "super_mario_64"}
	]

	for tc in slug_test_cases:
		var actual = GameIdentityResolverScript.slugify(tc["input"])
		_assert_true(actual == tc["expected"], "slugify('%s'): expected '%s', got '%s'" % [tc["input"], tc["expected"], actual])

	print("  -> Passed: Static normalization and slugification verified.")

	# -------------------------------------------------------------
	# 2. GuidedSetupRegistry Slug & Alias Resolution
	# -------------------------------------------------------------
	print("\n[Test 2] Testing GuidedSetupRegistry alias & special character resolution...")
	GuidedSetupRegistryScript.refresh_slug_cache()

	var guided_test_cases = [
		{"input": "Pokémon Emerald", "expected_slug": "pokemon_emerald"},
		{"input": "Pokemon Emerald", "expected_slug": "pokemon_emerald"},
		{"input": "Pokemon - Emerald", "expected_slug": "pokemon_emerald"},
		{"input": "pokemon_emerald", "expected_slug": "pokemon_emerald"},
		{"input": "Symphony of the Night", "expected_slug": "symphony_of_the_night"},
		{"input": "Castlevania: Symphony of the Night", "expected_slug": "symphony_of_the_night"},
		{"input": "Castlevania - Symphony of the Night", "expected_slug": "symphony_of_the_night"},
		{"input": "sotn", "expected_slug": "symphony_of_the_night"},
		{"input": "Luigi's Mansion", "expected_slug": "luigis_mansion"},
		{"input": "Plants vs. Zombies", "expected_slug": "plants_vs_zombies"}
	]

	for tc in guided_test_cases:
		var slug = GuidedSetupRegistryScript.get_game_slug(tc["input"])
		_assert_true(slug == tc["expected_slug"], "GuidedSetupRegistry.get_game_slug('%s'): expected '%s', got '%s'" % [tc["input"], tc["expected_slug"], slug])
		_assert_true(GuidedSetupRegistryScript.has_guided_setup(tc["input"]), "GuidedSetupRegistry.has_guided_setup('%s') should be true" % tc["input"])

	print("  -> Passed: GuidedSetupRegistry resolves aliases & special characters.")

	# -------------------------------------------------------------
	# 3. GameLauncher Slug & Preset Resolution
	# -------------------------------------------------------------
	print("\n[Test 3] Testing GameLauncher integration with GameIdentityResolver...")
	var launcher = lobby.launcher
	var mock_presets = {
		"Pokemon Emerald": {
			"game_name": "Pokemon Emerald",
			"slug": "pokemon_emerald",
			"aliases": ["Pokémon Emerald", "Pokemon - Emerald", "pokemon_emerald"],
			"platform": "GBA"
		},
		"Symphony of the Night": {
			"game_name": "Symphony of the Night",
			"slug": "symphony_of_the_night",
			"aliases": ["Castlevania: Symphony of the Night", "Castlevania - Symphony of the Night", "sotn"],
			"platform": "PS1"
		}
	}
	launcher.launcher_presets = mock_presets
	launcher._identity_resolver = GameIdentityResolverScript.new(mock_presets)

	for tc in guided_test_cases:
		if mock_presets.has(tc["input"]) or tc["input"] in ["Pokémon Emerald", "Pokemon - Emerald", "pokemon_emerald", "Castlevania: Symphony of the Night", "Castlevania - Symphony of the Night", "sotn"]:
			var l_slug = launcher.get_game_slug(tc["input"])
			_assert_true(l_slug == tc["expected_slug"], "GameLauncher.get_game_slug('%s'): expected '%s', got '%s'" % [tc["input"], tc["expected_slug"], l_slug])
			_assert_true(launcher.has_preset(tc["input"]), "GameLauncher.has_preset('%s') should be true" % tc["input"])

	var norm_slug = launcher.normalize_game_slug("Pokémon Emerald")
	_assert_true(norm_slug == "pokemonemerald", "launcher.normalize_game_slug mismatch: %s" % norm_slug)

	print("  -> Passed: GameLauncher resolves aliases and slugs via GameIdentityResolver.")

	# -------------------------------------------------------------
	# 4. DashboardGameCard Consistency
	# -------------------------------------------------------------
	print("\n[Test 4] Testing DashboardGameCard resolution consistency...")
	var dummy_tex = ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	BannerService.set_cached_texture("pokemon_emerald", dummy_tex)
	BannerService.set_cached_texture("symphony_of_the_night", dummy_tex)

	var card_node = DashboardGameCardScene.instantiate()
	root.add_child(card_node)

	var p_emerald = mock_presets["Pokemon Emerald"]
	card_node.setup("Pokémon Emerald", "Slot1", p_emerald, {}, {})
	var c_slug_1 = card_node._get_game_slug("Pokémon Emerald")
	var c_slug_2 = card_node._get_game_slug("Pokemon - Emerald")
	_assert_true(c_slug_1 == "pokemon_emerald", "DashboardGameCard slug for 'Pokémon Emerald' expected 'pokemon_emerald', got '%s'" % c_slug_1)
	_assert_true(c_slug_2 == "pokemon_emerald", "DashboardGameCard slug for 'Pokemon - Emerald' expected 'pokemon_emerald', got '%s'" % c_slug_2)
	_assert_true(card_node.mode_tag_label.text == "GBA", "Expected GBA mode tag for 'Pokémon Emerald', got '%s'" % card_node.mode_tag_label.text)

	var p_sotn = mock_presets["Symphony of the Night"]
	card_node.setup("Castlevania: Symphony of the Night", "Slot2", p_sotn, {}, {})
	var c_slug_3 = card_node._get_game_slug("Castlevania: Symphony of the Night")
	var c_slug_4 = card_node._get_game_slug("Castlevania - Symphony of the Night")
	var c_slug_5 = card_node._get_game_slug("sotn")
	_assert_true(c_slug_3 == "symphony_of_the_night", "DashboardGameCard slug for 'Castlevania: Symphony of the Night' expected 'symphony_of_the_night', got '%s'" % c_slug_3)
	_assert_true(c_slug_4 == "symphony_of_the_night", "DashboardGameCard slug for 'Castlevania - Symphony of the Night' expected 'symphony_of_the_night', got '%s'" % c_slug_4)
	_assert_true(c_slug_5 == "symphony_of_the_night", "DashboardGameCard slug for 'sotn' expected 'symphony_of_the_night', got '%s'" % c_slug_5)
	_assert_true(card_node.mode_tag_label.text == "PS1", "Expected PS1 mode tag for SOTN, got '%s'" % card_node.mode_tag_label.text)

	card_node.queue_free()
	print("  -> Passed: DashboardGameCard resolves aliases, colons, hyphens and accents identically.")

	_finish()

func _finish() -> void:
	print("\n==================================================================")
	if test_passed:
		print("  ALL GAME IDENTITY RESOLUTION TESTS PASSED! [OK]                ")
	else:
		printerr("  COMPLETED WITH FAILURES!                                       ")
	print("==================================================================")
	if lobby:
		lobby.queue_free()
	await create_timer(0.2).timeout
	quit(0 if test_passed else 1)
