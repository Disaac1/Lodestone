extends SceneTree

# =====================================================================
#             TEST SUITE: UI THEME & PROCEDURAL FACTORIES
# =====================================================================
# Validates UITheme centralized color constants and static StyleBoxFlat
# factory builders.
# =====================================================================

var test_passed: bool = true

const UITheme = preload("res://scripts/ui/ui_theme.gd")

func _init() -> void:
	_run_suite.call_deferred()

func _fail(reason: String) -> void:
	printerr("  ❌ [FAIL] ", reason)
	test_passed = false

func _assert_true(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)

func _assert_color_approx_eq(c1: Color, c2: Color, msg: String) -> void:
	if not c1.is_equal_approx(c2):
		_fail("%s (Expected %s, got %s)" % [msg, str(c2), str(c1)])

func _finish() -> void:
	if test_passed:
		print("\n  [SUCCESS] All UITheme tests passed!")
		quit(0)
	else:
		printerr("\n  [FAILURE] Some UITheme tests failed.")
		quit(1)

func _run_suite() -> void:
	print("==================================================================")
	print("  TEST SUITE: UI THEME & PROCEDURAL FACTORIES                     ")
	print("==================================================================")

	# -------------------------------------------------------------
	# 1. Color Constants Verification
	# -------------------------------------------------------------
	print("\n[Test 1] Verifying centralized color constants...")
	_assert_color_approx_eq(UITheme.COLOR_HOST_PURPLE, Color(0.67, 0.44, 0.98), "COLOR_HOST_PURPLE mismatch")
	_assert_color_approx_eq(UITheme.COLOR_ERROR_RED, Color(1.0, 0.3, 0.3), "COLOR_ERROR_RED mismatch")
	_assert_color_approx_eq(UITheme.COLOR_MUTED_TEXT, Color(0.6, 0.65, 0.7), "COLOR_MUTED_TEXT mismatch")
	_assert_color_approx_eq(UITheme.COLOR_GUIDED_GREEN, Color(0.3, 0.9, 0.5), "COLOR_GUIDED_GREEN mismatch")
	_assert_color_approx_eq(UITheme.COLOR_PRIMARY_BLUE, Color(0.2, 0.7, 1.0), "COLOR_PRIMARY_BLUE mismatch")
	_assert_color_approx_eq(UITheme.COLOR_STATUS_READY, Color(0.2, 0.8, 0.2), "COLOR_STATUS_READY mismatch")
	_assert_color_approx_eq(UITheme.COLOR_STATUS_NOT_READY, Color(0.8, 0.8, 0.2), "COLOR_STATUS_NOT_READY mismatch")
	_assert_color_approx_eq(UITheme.COLOR_STATUS_OFFLINE, Color(0.4, 0.4, 0.4), "COLOR_STATUS_OFFLINE mismatch")
	_assert_color_approx_eq(UITheme.COLOR_SERVER_ACTIVE, Color(0.2, 0.8, 0.4), "COLOR_SERVER_ACTIVE mismatch")
	_assert_color_approx_eq(UITheme.COLOR_SERVER_INITIALIZING, Color(0.9, 0.6, 0.15), "COLOR_SERVER_INITIALIZING mismatch")
	_assert_color_approx_eq(UITheme.COLOR_LOCAL_PLAYER, Color(0.22, 0.74, 0.97), "COLOR_LOCAL_PLAYER mismatch")
	print("  -> Passed: All color constants verified.")

	# -------------------------------------------------------------
	# 2. Pill Style Factory (create_pill_style)
	# -------------------------------------------------------------
	print("\n[Test 2] Verifying create_pill_style...")
	var pill_bg = Color(0.2, 0.15, 0.05, 0.8)
	var pill_border = Color(0.8, 0.55, 0.1, 0.7)
	var pill: StyleBoxFlat = UITheme.create_pill_style(pill_bg, pill_border)
	_assert_true(pill != null, "Pill style should not be null")
	_assert_color_approx_eq(pill.bg_color, pill_bg, "Pill bg_color mismatch")
	_assert_color_approx_eq(pill.border_color, pill_border, "Pill border_color mismatch")
	_assert_true(pill.corner_radius_top_left == 4 and pill.corner_radius_bottom_right == 4, "Pill corner radius should default to 4")
	_assert_true(pill.border_width_left == 1 and pill.border_width_bottom == 1, "Pill border width should default to 1")
	_assert_true(pill.content_margin_left == 7.0 and pill.content_margin_top == 2.0, "Pill content margins should default to 7h / 2v")
	print("  -> Passed: create_pill_style verified.")

	# -------------------------------------------------------------
	# 3. Card Style Factory (create_card_style)
	# -------------------------------------------------------------
	print("\n[Test 3] Verifying create_card_style...")
	var card_default: StyleBoxFlat = UITheme.create_card_style()
	_assert_true(card_default != null, "Card style should not be null")
	_assert_color_approx_eq(card_default.bg_color, UITheme.COLOR_CARD_BG, "Card default bg mismatch")
	_assert_true(card_default.corner_radius_top_left == 6, "Card default corner radius should be 6")
	_assert_true(card_default.content_margin_left == 12.0 and card_default.content_margin_top == 8.0, "Card margins should default to 12h / 8v")

	var custom_card: StyleBoxFlat = UITheme.create_card_style(Color.RED, 8, Color.YELLOW, 2, 10.0, 5.0)
	_assert_color_approx_eq(custom_card.bg_color, Color.RED, "Custom card bg mismatch")
	_assert_true(custom_card.corner_radius_top_left == 8, "Custom card corner radius mismatch")
	_assert_true(custom_card.border_width_left == 2, "Custom card border width mismatch")
	_assert_color_approx_eq(custom_card.border_color, Color.YELLOW, "Custom card border color mismatch")
	print("  -> Passed: create_card_style verified.")

	# -------------------------------------------------------------
	# 4. Banner Style Factory (create_banner_style)
	# -------------------------------------------------------------
	print("\n[Test 4] Verifying create_banner_style...")
	var banner: StyleBoxFlat = UITheme.create_banner_style(Color.BLUE, 7)
	_assert_true(banner != null, "Banner style should not be null")
	_assert_color_approx_eq(banner.bg_color, Color.BLUE, "Banner bg mismatch")
	_assert_true(banner.corner_radius_top_left == 7 and banner.corner_radius_top_right == 7, "Banner top corners should be 7")
	_assert_true(banner.corner_radius_bottom_left == 0 and banner.corner_radius_bottom_right == 0, "Banner bottom corners should be 0")
	print("  -> Passed: create_banner_style verified.")

	# -------------------------------------------------------------
	# 5. Button Style Factory (create_button_style & apply_button_styles)
	# -------------------------------------------------------------
	print("\n[Test 5] Verifying button style helpers...")
	var btn_col = Color(0.2, 0.4, 0.6)
	var btn_style: StyleBoxFlat = UITheme.create_button_style(btn_col, 6)
	_assert_color_approx_eq(btn_style.bg_color, btn_col, "Button style bg mismatch")
	_assert_true(btn_style.corner_radius_top_left == 6, "Button corner radius mismatch")

	var hover: StyleBoxFlat = UITheme.create_hover_style(btn_style, 0.15)
	_assert_true(hover.bg_color.v > btn_style.bg_color.v, "Hover should be lightened")

	var pressed: StyleBoxFlat = UITheme.create_pressed_style(btn_style, 0.1)
	_assert_true(pressed.bg_color.v < btn_style.bg_color.v, "Pressed should be darkened")

	var test_btn = Button.new()
	UITheme.apply_button_styles(test_btn, btn_col, 6)
	_assert_true(test_btn.has_theme_stylebox_override("normal"), "Button should have normal style override")
	_assert_true(test_btn.has_theme_stylebox_override("hover"), "Button should have hover style override")
	_assert_true(test_btn.has_theme_stylebox_override("pressed"), "Button should have pressed style override")
	test_btn.queue_free()
	print("  -> Passed: Button style helpers verified.")

	_finish()

