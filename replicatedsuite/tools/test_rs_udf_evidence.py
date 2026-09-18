"""Read-only collector: JS ZIP interoperability and actual local Chromium delivery.
Fixtures are synthetic and never include a user account/database. This does not
validate native Windows folder-picker behavior or ArcheRage's disk serialization.
If browser policy blocks local file navigation, the browser class is explicitly
skipped. Do not relax enterprise policy or report skipped cases as passing.
"""
from __future__ import annotations
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

TOOLS = Path(__file__).resolve().parent
HTML = TOOLS / "rs_udf_evidence.html"
NODE = shutil.which("node")
CHROMIUM = shutil.which("chromium")
PLAYWRIGHT = importlib.util.find_spec("playwright")


@unittest.skipUnless(NODE, "Node required for collector pure-logic tests")
class CollectorZipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.result = subprocess.run([NODE, str(TOOLS / 'test_rs_udf_evidence.js')],
                                    capture_output=True, text=True, timeout=30)

    def test_node_regressions(self):
        self.assertEqual(self.result.returncode, 0, self.result.stdout+self.result.stderr)
        self.assertIn('13 passed / 0 failed', self.result.stdout)

    def test_standard_zip_reader_bytes_hashes_and_empty_lock(self):
        self.assertEqual(self.result.returncode, 0, self.result.stdout+self.result.stderr)
        with zipfile.ZipFile(TOOLS / '.udf_collector_test.zip') as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(set(archive.namelist()),
                             {'evidence_manifest.json', 'udf/数据.sst', 'udf/CURRENT', 'udf/LOCK'})
            manifest = json.loads(archive.read('evidence_manifest.json'))
            self.assertFalse(manifest['saveIntegrityVerified'])
            self.assertEqual(manifest['omittedFiles'], 0)
            for row in manifest['files']:
                value = archive.read(row['path'])
                self.assertEqual(len(value), row['bytes'])
                self.assertEqual(hashlib.sha256(value).hexdigest(), row['sha256'])
            self.assertEqual(archive.read('udf/数据.sst'), (TOOLS/'.udf_collector_expected.bin').read_bytes())
            self.assertEqual(archive.read('udf/LOCK'), b'')


@unittest.skipUnless(CHROMIUM and PLAYWRIGHT, "Chromium + Playwright required for browser delivery")
class BrowserCollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from playwright.sync_api import sync_playwright
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch(executable_path=CHROMIUM, headless=True,
                                            args=['--no-sandbox', '--disable-dev-shm-usage'])
        cls.url = HTML.as_uri()
        probe = cls.browser.new_page()
        try:
            probe.goto(cls.url)
        except Exception as error:
            probe.close(); cls.browser.close(); cls.pw.stop()
            if 'ERR_BLOCKED_BY_ADMINISTRATOR' in str(error):
                raise unittest.SkipTest('browser policy blocks file://; 5 browser delivery cases NOT executed')
            raise
        probe.close()

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.udf = self.base / 'udf'
        self.udf.mkdir()
        self.files = {'CURRENT': b'MANIFEST-000001\n', 'LOCK': b'',
                      '.hidden': b'preserve hidden filename',
                      '数据.sst': bytes(range(256))*7}
        for name, value in self.files.items():
            (self.udf/name).write_bytes(value)
        self.page = self.browser.new_page(viewport={'width': 1100, 'height': 950}, accept_downloads=True)
        self.network = []
        self.page.on('request', lambda r: self.network.append(r.url) if r.url.startswith(('http:', 'https:')) and r.url != self.url else None)
        self.page.goto(self.url)

    def tearDown(self):
        self.assertEqual(self.network, [], 'collector attempted external network access')
        self.page.close()
        self.tmp.cleanup()

    def choose(self):
        self.page.locator('#folder').set_input_files(str(self.udf))
        self.page.wait_for_function("document.querySelector('#selection').textContent.includes('4 个文件')")

    def generate(self):
        self.choose()
        self.page.locator('#closed').check()
        self.page.locator('#consent').check()
        self.page.locator('#build').click()
        self.page.locator('#download').wait_for(state='visible')

    def test_starts_without_download_and_requires_both_confirmations(self):
        self.assertFalse(self.page.locator('#download').is_visible())
        self.assertTrue(self.page.locator('#build').is_disabled())
        self.choose()
        self.page.locator('#closed').check()
        self.assertTrue(self.page.locator('#build').is_disabled())
        self.page.locator('#consent').check()
        self.assertTrue(self.page.locator('#build').is_enabled())

    def test_browser_download_contains_every_selected_byte_and_no_source_writes(self):
        self.generate()
        with self.page.expect_download() as event:
            self.page.locator('#download').click()
        target = self.base/'export.zip'
        event.value.save_as(str(target))
        with zipfile.ZipFile(target) as z:
            self.assertIsNone(z.testzip())
            for name, data in self.files.items():
                self.assertEqual(z.read('udf/'+name), data)
                self.assertEqual((self.udf/name).read_bytes(), data)
            manifest = json.loads(z.read('evidence_manifest.json'))
            self.assertEqual(manifest['sourceFileCount'], len(self.files))
            self.assertIn('not_atomic', manifest['consistency'])
        self.assertEqual(set(p.name for p in self.udf.iterdir()), set(self.files))

    def test_wrong_directory_refused_not_silently_swept(self):
        bad=self.base/'USER-private';bad.mkdir();(bad/'private.txt').write_text('do not include')
        self.page.locator('#folder').set_input_files(str(bad))
        self.assertIn('DIRECTORY', self.page.locator('#selection').inner_text())
        self.assertTrue(self.page.locator('#build').is_disabled())
        self.assertFalse(self.page.locator('#download').is_visible())

    def test_reselection_revokes_old_download_and_resets_consent(self):
        self.generate()
        self.page.locator('#folder').set_input_files([])
        self.assertFalse(self.page.locator('#download').is_visible())
        self.assertTrue(self.page.locator('#build').is_disabled())
        self.assertFalse(self.page.locator('#closed').is_checked())
        self.assertFalse(self.page.locator('#consent').is_checked())

    def test_read_exception_does_not_offer_a_partial_zip(self):
        self.choose()
        self.page.evaluate("File.prototype.arrayBuffer = async function(){throw Error('synthetic lock');}")
        self.page.locator('#closed').check();self.page.locator('#consent').check()
        self.page.locator('#build').click()
        self.page.wait_for_function("document.querySelector('#status').textContent.includes('READ')")
        self.assertFalse(self.page.locator('#download').is_visible())
        self.assertIn('没有提供部分 ZIP', self.page.locator('#status').inner_text())


if __name__ == '__main__':
    unittest.main()
