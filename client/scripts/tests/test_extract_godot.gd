extends SceneTree

func _init():
	var z = ZIPReader.new()
	var err = z.open("C:/Users/disaa/Desktop/Code/Wayfinder/backend/public/tools/dolphin.zip")
	var files = z.get_files()
	var dest_dir = "user://test_dolphin_extract"
	DirAccess.make_dir_recursive_absolute(dest_dir)
	var root_prefix = "Dolphin-x64/"
	for f in files:
		if "QtPlugins" in f:
			var rel = f.substr(root_prefix.length())
			var out = dest_dir.path_join(rel)
			if f.ends_with("/"):
				DirAccess.make_dir_recursive_absolute(out)
			else:
				DirAccess.make_dir_recursive_absolute(out.get_base_dir())
				var fa = FileAccess.open(out, FileAccess.WRITE)
				if fa:
					fa.store_buffer(z.read_file(f))
					fa.close()
					print("Extracted: ", out)
				else:
					print("FAILED to open: ", out, " Error: ", FileAccess.get_open_error())
	z.close()
	quit()
