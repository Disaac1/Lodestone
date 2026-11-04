class_name UITheme
extends RefCounted

## UITheme
## Centralized theme definitions, color constants, and procedural StyleBoxFlat
## builders for consistent UI presentation across Wayfinder client interfaces.

# =========================================================================
# COLOR CONSTANTS
# =========================================================================

# Brand & Accent Colors
const COLOR_PRIMARY_BLUE: Color = Color(0.2, 0.7, 1.0)
const COLOR_HOST_PURPLE: Color = Color(0.67, 0.44, 0.98)
const COLOR_GUIDED_GREEN: Color = Color(0.3, 0.9, 0.5)
const COLOR_ACCENT_CYAN: Color = Color(0.2, 0.8, 1.0)
const COLOR_ACTION_BLUE: Color = Color(0.35, 0.8, 1.0)
const COLOR_SELECTED: Color = Color(0.67, 0.44, 0.98)

# Status & Feedback Colors
const COLOR_STATUS_READY: Color = Color(0.2, 0.8, 0.2)
const COLOR_STATUS_NOT_READY: Color = Color(0.8, 0.8, 0.2)
const COLOR_STATUS_OFFLINE: Color = Color(0.4, 0.4, 0.4)
const COLOR_SERVER_ACTIVE: Color = Color(0.2, 0.8, 0.4)
const COLOR_SERVER_INITIALIZING: Color = Color(0.9, 0.6, 0.15)
const COLOR_SUCCESS_GREEN: Color = Color(0.2, 0.85, 0.5)
const COLOR_WARNING_YELLOW: Color = Color(0.98, 0.75, 0.14)
const COLOR_ERROR_RED: Color = Color(1.0, 0.3, 0.3)

# Text & Foreground Colors
const COLOR_TEXT_LIGHT: Color = Color(0.9, 0.95, 1.0)
const COLOR_MUTED_TEXT: Color = Color(0.6, 0.65, 0.7)
const COLOR_TEXT_MUTED: Color = Color(0.6, 0.65, 0.7)
const COLOR_LOCAL_PLAYER: Color = Color(0.22, 0.74, 0.97)

# Background & Container Colors
const COLOR_BG_DARK: Color = Color(0.14, 0.16, 0.22)
const COLOR_CARD_BG: Color = Color(0.14, 0.16, 0.22, 0.9)
const COLOR_CARD_SELECTED_BG: Color = Color(0.2, 0.45, 0.7)
const COLOR_BORDER_DEFAULT: Color = Color(0.3, 0.35, 0.45)
const COLOR_BORDER_FOCUS: Color = Color(0.4, 0.8, 1.0)
const COLOR_BORDER_HOVER: Color = Color(0.5, 0.85, 1.0)

# Pill Status Preset Colors (Background & Border)
const COLOR_PILL_READY_BG: Color = Color(0.08, 0.18, 0.13, 0.8)
const COLOR_PILL_READY_BORDER: Color = Color(0.16, 0.65, 0.38, 0.7)
const COLOR_PILL_WARNING_BG: Color = Color(0.2, 0.15, 0.05, 0.8)
const COLOR_PILL_WARNING_BORDER: Color = Color(0.8, 0.55, 0.1, 0.7)
const COLOR_PILL_RUNNING_BG: Color = Color(0.06, 0.16, 0.24, 0.8)
const COLOR_PILL_RUNNING_BORDER: Color = Color(0.2, 0.7, 0.95, 0.7)
const COLOR_PILL_REMOTE_BG: Color = Color(0.14, 0.1, 0.22, 0.8)
const COLOR_PILL_REMOTE_BORDER: Color = Color(0.55, 0.35, 0.85, 0.7)

# Button Preset Colors
const COLOR_BTN_PRIMARY_BG: Color = Color(0.25, 0.45, 0.85)
const COLOR_BTN_SUCCESS_BG: Color = Color(0.18, 0.55, 0.35)
const COLOR_BTN_SECONDARY_BG: Color = Color(0.14, 0.16, 0.22)


# =========================================================================
# PROCEDURAL STYLEBOX FACTORIES
# =========================================================================

## Creates a pill stylebox with rounded corners, optional borders, and content margins.
static func create_pill_style(
	bg_color: Color = Color.TRANSPARENT,
	border_color: Color = Color.TRANSPARENT,
	corner_radius: int = 4,
	border_width: int = 1,
	margin_h: float = 7.0,
	margin_v: float = 2.0
) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_corner_radius_all(corner_radius)
	if border_width > 0:
		style.border_width_left = border_width
		style.border_width_top = border_width
		style.border_width_right = border_width
		style.border_width_bottom = border_width
		style.border_color = border_color
	style.content_margin_left = margin_h
	style.content_margin_top = margin_v
	style.content_margin_right = margin_h
	style.content_margin_bottom = margin_v
	return style


## Creates a card/panel container stylebox with rounded corners and margins.
static func create_card_style(
	bg_color: Color = COLOR_CARD_BG,
	corner_radius: int = 6,
	border_color: Color = Color.TRANSPARENT,
	border_width: int = 0,
	margin_h: float = 12.0,
	margin_v: float = 8.0,
	top_corners_only: bool = false
) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg_color
	if top_corners_only:
		style.corner_radius_top_left = corner_radius
		style.corner_radius_top_right = corner_radius
	else:
		style.set_corner_radius_all(corner_radius)
	if border_width > 0:
		style.border_width_left = border_width
		style.border_width_top = border_width
		style.border_width_right = border_width
		style.border_width_bottom = border_width
		style.border_color = border_color
	if margin_h > 0.0 or margin_v > 0.0:
		style.content_margin_left = margin_h
		style.content_margin_top = margin_v
		style.content_margin_right = margin_h
		style.content_margin_bottom = margin_v
	return style


## Creates a top-rounded banner stylebox for card headers.
static func create_banner_style(
	bg_color: Color,
	corner_radius_top: int = 7
) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg_color
	style.corner_radius_top_left = corner_radius_top
	style.corner_radius_top_right = corner_radius_top
	return style


## Creates a button stylebox with base color and uniform corner rounding.
static func create_button_style(
	base_color: Color,
	corner_radius: int = 6,
	border_color: Color = Color.TRANSPARENT,
	border_width: int = 0
) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = base_color
	style.set_corner_radius_all(corner_radius)
	if border_width > 0:
		style.border_width_left = border_width
		style.border_width_top = border_width
		style.border_width_right = border_width
		style.border_width_bottom = border_width
		style.border_color = border_color
	return style


## Creates a hover variant from a base StyleBoxFlat by lightening the background color.
static func create_hover_style(
	normal_style: StyleBoxFlat,
	lighten_amount: float = 0.15,
	hover_border_color: Color = Color.TRANSPARENT
) -> StyleBoxFlat:
	var hover: StyleBoxFlat = normal_style.duplicate()
	hover.bg_color = normal_style.bg_color.lightened(lighten_amount)
	if hover_border_color != Color.TRANSPARENT:
		hover.border_color = hover_border_color
	return hover


## Creates a pressed variant from a base StyleBoxFlat by darkening the background color.
static func create_pressed_style(
	normal_style: StyleBoxFlat,
	darken_amount: float = 0.1
) -> StyleBoxFlat:
	var pressed: StyleBoxFlat = normal_style.duplicate()
	pressed.bg_color = normal_style.bg_color.darkened(darken_amount)
	return pressed


## Applies normal, hover, and pressed stylebox overrides to a Button.
static func apply_button_styles(
	btn: Button,
	base_color: Color,
	corner_radius: int = 6,
	border_color: Color = Color.TRANSPARENT,
	border_width: int = 0,
	hover_border_color: Color = Color.TRANSPARENT,
	hover_lighten: float = 0.15,
	pressed_darken: float = 0.1
) -> void:
	var normal: StyleBoxFlat = create_button_style(base_color, corner_radius, border_color, border_width)
	btn.add_theme_stylebox_override("normal", normal)
	var hover: StyleBoxFlat = create_hover_style(normal, hover_lighten, hover_border_color)
	btn.add_theme_stylebox_override("hover", hover)
	if pressed_darken > 0.0:
		var pressed: StyleBoxFlat = create_pressed_style(normal, pressed_darken)
		btn.add_theme_stylebox_override("pressed", pressed)

