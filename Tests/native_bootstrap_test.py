"""Candidate bootstrap archive verification without network or any installed app writes."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / 'docs/install-native.sh'


class NativeBootstrapTests(unittest.TestCase):
    def test_prebuilt_checksum_signature_and_rejection_without_install(self):
        with tempfile.TemporaryDirectory(prefix='vella-bootstrap-test-') as directory:
            root = pathlib.Path(directory); release = root / 'release'; release.mkdir()
            app = root / 'Vella.app'; macos = app / 'Contents/MacOS'; macos.mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes((ROOT / 'Resources/Info.plist').read_bytes())
            for name in ('Vella', 'VellaModelTool'):
                path = macos / name; shutil.copyfile('/bin/echo', path); path.chmod(0o755)
            tool = root / 'VellaInstallTool'; shutil.copyfile('/bin/echo', tool); tool.chmod(0o755)
            for item in [macos / 'VellaModelTool', app, tool]:
                signed = subprocess.run(['codesign', '--force', '--sign', '-', str(item)], capture_output=True, text=True)
                self.assertEqual(signed.returncode, 0, signed.stderr)
            archive = release / 'Vella-0.9.0.zip'
            packaged = subprocess.run(['bash', str(ROOT/'scripts/package-native-release.sh'), '0.9.0', str(app), str(tool), str(release)], capture_output=True, text=True)
            self.assertEqual(packaged.returncode, 0, packaged.stderr)
            sums = release / 'SHA256SUMS'
            bin_dir = root / 'bin'; bin_dir.mkdir()
            curl = bin_dir / 'curl'
            curl.write_text('#!/bin/bash\nfor ((i=1;i<=$#;i++)); do if [[ "${!i}" == "-o" ]]; then j=$((i+1)); out="${!j}"; fi; if [[ "${!i}" == https://* ]]; then url="${!i}"; fi; done\ncp "$QA_RELEASE_FIXTURE/$(basename "$url")" "$out"\n')
            curl.chmod(0o755)
            target = root / 'NeverInstall/Vella.app'
            env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'], QA_RELEASE_FIXTURE=str(release),
                       VELLA_NATIVE_VERIFY_ONLY='1', VELLA_DESTINATION_APP=str(target))
            success = subprocess.run(['bash', str(BOOTSTRAP)], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(success.returncode, 0, success.stderr + '\n' + subprocess.check_output(['zipinfo', '-1', str(archive)], text=True))
            self.assertIn('nothing installed', success.stdout)
            self.assertFalse(target.exists())
            sums.write_text('0' * 64 + f'  {archive.name}\n')
            failure = subprocess.run(['bash', str(BOOTSTRAP)], env=env, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(failure.returncode, 0)
            self.assertIn('checksum mismatch', failure.stderr)
            self.assertFalse(target.exists())

    def test_published_bootstraps_remain_untouched_by_candidate(self):
        self.assertEqual((ROOT / 'docs/install.sh').read_bytes(), (ROOT / 'scripts/install.sh').read_bytes())
        script = BOOTSTRAP.read_text()
        self.assertIn('Vella-$VERSION.zip', script)
        self.assertIn('Vella-$VERSION-source.tar.gz', script)
        self.assertIn('SHA256SUMS', script)

    def test_source_fallback_extracts_verified_archive_without_install(self):
        with tempfile.TemporaryDirectory(prefix='vella-source-fallback-') as directory:
            root = pathlib.Path(directory); release = root/'release'; release.mkdir()
            source = root/'Vella-0.9.0'; (source/'scripts').mkdir(parents=True)
            (source/'Package.swift').write_text('// isolated source fixture\n')
            install = source/'scripts/install-native.sh'; install.write_text('#!/bin/sh\necho source-fallback-ready\n'); install.chmod(0o755)
            archive = release/'Vella-0.9.0-source.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar: tar.add(source, arcname=source.name)
            digest = subprocess.check_output(['shasum', '-a', '256', str(archive)], text=True).split()[0]
            (release/'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
            bin_dir = root/'bin'; bin_dir.mkdir()
            curl = bin_dir/'curl'
            curl.write_text('#!/bin/bash\nfor ((i=1;i<=$#;i++)); do if [[ "${!i}" == "-o" ]]; then j=$((i+1)); out="${!j}"; fi; if [[ "${!i}" == https://* ]]; then url="${!i}"; fi; done\ncp "$QA_RELEASE_FIXTURE/$(basename "$url")" "$out"\n')
            curl.chmod(0o755)
            target = root/'NeverInstall/Vella.app'
            env = dict(os.environ, PATH=str(bin_dir)+':'+os.environ['PATH'], QA_RELEASE_FIXTURE=str(release),
                       VELLA_NATIVE_INSTALL_MODE='source', VELLA_NATIVE_VERIFY_ONLY='1', VELLA_DESTINATION_APP=str(target))
            result = subprocess.run(['bash', str(BOOTSTRAP)], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('source-fallback-ready', result.stdout)
            self.assertFalse(target.exists())


if __name__ == '__main__': unittest.main()
