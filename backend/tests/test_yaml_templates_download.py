#!/usr/bin/env python3
"""
Test YAML Templates Download Endpoint
=====================================
Verifies that:
1. The admin endpoint /api/admin/yaml-templates/download returns 200 and a valid ZIP file.
2. The ZIP contains standard game YAML templates at root.
3. Custom ROMs / APWorlds are located in the 'custom/' subfolder.
4. Presets and meta.yaml are included.
5. Non-localhost / invalid host requests are rejected with 403 Forbidden.
"""

import unittest
import urllib.request
import urllib.error
import zipfile
import io
import os

BASE_URL = os.environ.get("WAYFINDER_SERVER_URL", "http://127.0.0.1:8080")

def is_backend_online(base_url=BASE_URL):
    try:
        req = urllib.request.Request(f"{base_url}/api/games", headers={"User-Agent": "CI-Test"})
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.status == 200
    except Exception:
        return False

class TestYamlTemplatesDownload(unittest.TestCase):
    def test_yaml_templates_download_endpoint(self):
        if not is_backend_online():
            raise unittest.SkipTest(f"Backend is not running at {BASE_URL}")

        endpoint = f"{BASE_URL}/api/admin/yaml-templates/download"
        req = urllib.request.Request(endpoint, headers={"Host": "127.0.0.1:8080"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            self.assertEqual(resp.status, 200)
            data = resp.read()
            self.assertGreater(len(data), 10000, "Downloaded archive should be larger than 10KB")

            # Parse as zip
            zip_buffer = io.BytesIO(data)
            with zipfile.ZipFile(zip_buffer, "r") as zf:
                names = zf.namelist()
                
                # Check custom folder contents
                custom_files = [n for n in names if n.startswith("custom/") and n.endswith(".yaml")]
                self.assertGreaterEqual(len(custom_files), 1, "Should have at least 1 custom template in custom/")
                
                # Verify custom roms are in custom/
                custom_names_lower = [os.path.basename(n).lower() for n in custom_files]
                self.assertTrue(
                    any("pokemon black" in n or "metroid fusion" in n or "plants vs" in n for n in custom_names_lower),
                    f"Expected custom roms in custom/, got: {custom_names_lower}"
                )

                # Check root templates
                root_files = [n for n in names if "/" not in n and n.endswith(".yaml")]
                self.assertGreaterEqual(len(root_files), 10, "Should have standard game templates at root")

                # Verify meta.yaml and Presets
                self.assertIn("meta.yaml", names, "meta.yaml should be included in zip root")
                preset_files = [n for n in names if n.startswith("Presets/")]
                self.assertGreaterEqual(len(preset_files), 1, "Presets directory should have preset templates")

    def test_forbidden_for_non_localhost(self):
        if not is_backend_online():
            raise unittest.SkipTest(f"Backend is not running at {BASE_URL}")

        endpoint = f"{BASE_URL}/api/admin/yaml-templates/download"
        # Simulate request with external host header
        req = urllib.request.Request(endpoint, headers={"Host": "external.domain.com"})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                self.fail(f"Expected 403 Forbidden, but got {resp.status}")
        except urllib.error.HTTPError as err:
            self.assertEqual(err.code, 403, f"Expected 403 HTTP error, got: {err.code}")

if __name__ == "__main__":
    unittest.main()
