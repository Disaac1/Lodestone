import warnings
warnings.filterwarnings("ignore")
import sys
import os
os.environ["SKIP_REQUIREMENTS_UPDATE"] = "1"
import json
import shutil

def main():
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: generate_templates.py <archipelago_path> <output_dir> [custom_worlds_dir]"}))
        sys.exit(1)

    archipelago_path = os.path.abspath(sys.argv[1])
    output_dir = os.path.abspath(sys.argv[2])
    custom_worlds_dir = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else None

    # Inject Archipelago core repository in system path
    sys.path.insert(0, archipelago_path)

    # Disable interactive ModuleUpdate prompt
    try:
        import ModuleUpdate
        ModuleUpdate.update_ran = True
    except Exception:
        pass

    if custom_worlds_dir and os.path.exists(custom_worlds_dir):
        sys.path.insert(0, custom_worlds_dir)

    try:
        from worlds.AutoWorld import AutoWorldRegister
        from Utils import local_path, __version__, get_file_safe_name
        from Options import get_option_groups, Range
        from inspect import cleandoc
        import yaml
        from jinja2 import Template

        custom_dir = os.path.join(output_dir, "custom")
        preset_dir = os.path.join(output_dir, "Presets")
        custom_preset_dir = os.path.join(custom_dir, "Presets")

        os.makedirs(output_dir, exist_ok=True)
        os.makedirs(custom_dir, exist_ok=True)
        os.makedirs(preset_dir, exist_ok=True)

        # Copy meta.yaml if it exists
        meta_src = os.path.join(archipelago_path, "meta.yaml")
        if os.path.exists(meta_src):
            try:
                shutil.copy2(meta_src, os.path.join(output_dir, "meta.yaml"))
            except Exception as e:
                print(f"Warning: Failed to copy meta.yaml: {e}", file=sys.stderr)

        def dictify_range(option: Range, option_val: int | str):
            data = {option_val: 50}
            for sub_option in ['random', 'random-low', 'random-high', f'random-range-{option.range_start}-{option.range_end}']:
                if sub_option != option_val:
                    data[sub_option] = 0
            notes = {
                'random-low': 'random value weighted towards lower values',
                'random-high': 'random value weighted towards higher values',
                f'random-range-{option.range_start}-{option.range_end}': f'random value between {option.range_start} and {option.range_end}'
            }
            for name, number in getattr(option, 'special_range_names', {}).items():
                notes[name] = f'equivalent to {number}'
                if number in data:
                    data[name] = data[number]
                    del data[number]
                elif name in data:
                    pass
                else:
                    data[name] = 0
            return data, notes

        def yaml_dump_scalar(scalar) -> str:
            return yaml.dump(scalar).replace('...\n', '').strip()

        options_tpl_path = local_path('data', 'options.yaml')
        with open(options_tpl_path, encoding='utf-8') as f:
            file_data = f.read()
        template = Template(file_data)

        standard_count = 0
        custom_count = 0
        errors = []

        registered_custom_games = set()
        registry_path = os.path.join(archipelago_path, "..", "data", "custom_worlds_registry.json")
        if os.path.exists(registry_path):
            try:
                with open(registry_path, "r", encoding="utf-8") as rf:
                    reg_data = json.load(rf)
                    for item in reg_data.values():
                        if isinstance(item, dict) and "game" in item:
                            registered_custom_games.add(item["game"].strip().lower())
            except Exception:
                pass

        for game_name, world in AutoWorldRegister.world_types.items():
            is_custom = bool(
                getattr(world, 'zip_path', None)
                or 'custom_worlds' in getattr(world, '__file__', '')
                or game_name.strip().lower() in registered_custom_games
            )
            curr_target = custom_dir if is_custom else output_dir
            curr_presets = custom_preset_dir if is_custom else preset_dir

            try:
                presets = world.web.options_presets.copy() if hasattr(world, 'web') and hasattr(world.web, 'options_presets') else {}
                presets.update({'': {}})
                option_groups = get_option_groups(world)

                for name, preset in presets.items():
                    version_str = '1.0.0'
                    if hasattr(world, 'world_version'):
                        if hasattr(world.world_version, 'as_simple_string'):
                            version_str = world.world_version.as_simple_string()
                        else:
                            version_str = str(world.world_version)

                    res = template.render(
                        option_groups=option_groups,
                        __version__=__version__,
                        game=game_name,
                        world_version=version_str,
                        yaml_dump=yaml_dump_scalar,
                        dictify_range=dictify_range,
                        cleandoc=cleandoc,
                        preset_name=name,
                        preset=preset,
                    )
                    preset_name = f' - {name}' if name else ''
                    dest_dir = curr_presets if name else curr_target
                    os.makedirs(dest_dir, exist_ok=True)
                    dest_file = os.path.join(dest_dir, get_file_safe_name(game_name + preset_name) + '.yaml')
                    with open(dest_file, 'w', encoding='utf-8-sig') as f:
                        f.write(res)

                if is_custom:
                    custom_count += 1
                else:
                    standard_count += 1
            except Exception as ex:
                errors.append(f"{game_name}: {str(ex)}")

        # Remove empty preset folders if any
        for p_dir in [custom_preset_dir, preset_dir]:
            if os.path.exists(p_dir) and not os.listdir(p_dir):
                try:
                    os.rmdir(p_dir)
                except Exception:
                    pass

        print(json.dumps({
            "success": True,
            "standard_count": standard_count,
            "custom_count": custom_count,
            "errors": errors
        }))

    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

if __name__ == "__main__":
    main()
