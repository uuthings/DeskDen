#!/usr/bin/env python3
"""Exercise native framing and kit preparation using fixture App/data only."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import unittest

EXE = Path(sys.argv.pop(1)).resolve()
SOURCE = Path(__file__).resolve().parents[1]
ORIGIN = 'chrome-extension://dbgielekmbgphidnnfidmlobjmdblagf/'

def frame(obj):
    data = json.dumps(obj).encode()
    return struct.pack('<I', len(data)) + data

def run(exe, root, data, origin=ORIGIN):
    return subprocess.run([str(exe), '--provider-usage-browser-host', '--provider-usage-browser-directory', str(root), origin], input=data, capture_output=True, timeout=10)

class NativeChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fangcun-native-fixture-')
        self.root = Path(self.temp.name).resolve()
    def tearDown(self): self.temp.cleanup()

    def prepare_fixture_kit(self):
        app = self.root / "Fixture's App.app"
        mac = app / 'Contents/MacOS'; mac.mkdir(parents=True)
        shutil.copy2(EXE, mac / 'Fixture')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Fixture','CFBundleIdentifier':'test.fixture'}))
        kit = self.root / 'Prepared Kit'
        subprocess.run([sys.executable, str(SOURCE / 'prepare-kit.py'), '--app', str(app),
                        '--bridge-directory', str(self.root / 'bridge'), '--output', str(kit)],
                       check=True, capture_output=True, timeout=10)
        return kit

    def install_fixture(self, kit, answer='INSTALL\n'):
        # HOME is deliberately isolated: these checks must never register with real Chrome.
        environment = os.environ.copy()
        environment['HOME'] = str(self.root / 'Fixture Home')
        return subprocess.run(['/bin/sh', str(kit / 'install.command')], input=answer.encode(),
                              env=environment, capture_output=True, timeout=10)

    def fixture_registration(self):
        return self.root / 'Fixture Home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.uuthings.fangcun.iproyal.json'

    def test_poll_frame_and_private_heartbeat(self):
        box = self.root/'mailbox'
        result = run(EXE, box, frame({'version':1,'type':'poll'}))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b'', result.stderr.decode(errors='replace'))
        self.assertGreaterEqual(len(result.stdout), 4, f'No frame: mailbox={box.exists()}, children={list(box.iterdir()) if box.exists() else []}')
        length, = struct.unpack('<I', result.stdout[:4])
        self.assertEqual(length, len(result.stdout)-4)
        self.assertEqual(json.loads(result.stdout[4:]), {'version':1,'type':'idle'})
        self.assertEqual(box.stat().st_mode & 0o777, 0o700)
        self.assertEqual((box/'heartbeat.json').stat().st_mode & 0o777, 0o600)
    def test_wrong_extension_cannot_create_mailbox(self):
        box = self.root/'wrong'
        result = run(EXE, box, frame({'version':1,'type':'poll'}), 'chrome-extension://'+'a'*32+'/')
        self.assertEqual(result.stdout, b'')
        self.assertFalse(box.exists())
    def test_invalid_frames_emit_no_data(self):
        for data in [b'\x01\x00', struct.pack('<I',16385), struct.pack('<I',0), frame({'version':1,'type':'poll','secret':'not-a-credential'})]:
            result = run(EXE, self.root/'invalid', data)
            self.assertEqual(result.stdout, b'')
            self.assertEqual(result.stderr, b'', result.stderr.decode(errors='replace'))
    def test_cancelled_and_expired_replies_keep_native_channel_alive(self):
        for expired in (False, True):
            box = self.root / ('expired' if expired else 'cancelled')
            box.mkdir(mode=0o700)
            request_id, source_id = str(uuid.uuid4()), str(uuid.uuid4())
            if expired:
                request = {'version':1, 'requestID':request_id, 'sourceID':source_id, 'orderID':'123', 'createdAt':time.time()-20, 'expiresAt':time.time()-10}
                request_path = box / (request_id.upper()+'.request.json')
                request_path.write_text(json.dumps(request)); request_path.chmod(0o600)
            reply = {'version':1,'type':'result','result':{'version':1,'requestID':request_id,'sourceID':source_id,'orderID':'123','status':'rateLimited','observedAt':time.time(),'retryAfterSeconds':120}}
            result = run(EXE, box, frame(reply)+frame({'version':1,'type':'poll'}))
            frames=[]; data=result.stdout
            while data:
                length, = struct.unpack('<I',data[:4]); frames.append(json.loads(data[4:4+length])); data=data[4+length:]
            self.assertEqual(frames,[{'version':1,'type':'idle'},{'version':1,'type':'idle'}])
            self.assertEqual(result.stderr,b'')
            self.assertTrue((box/'heartbeat.json').exists())

    def test_kit_is_portable_and_never_installs(self):
        app = self.root/"Fixture's App.app"
        mac = app/'Contents/MacOS'; mac.mkdir(parents=True)
        executable = mac/'Fixture'; shutil.copy2(EXE, executable)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Fixture','CFBundleIdentifier':'test.fixture'}))
        kit = self.root/'Prepared Kit'
        subprocess.run([sys.executable,str(SOURCE/'prepare-kit.py'),'--app',str(app),'--bridge-directory',str(self.root/'bridge'),'--output',str(kit)], check=True, capture_output=True)
        manifest = json.loads((kit/'com.uuthings.fangcun.iproyal.json').read_text())
        self.assertEqual(manifest['allowed_origins'],[ORIGIN])
        self.assertEqual(manifest['path'],str(kit/'native-host.command'))
        result = subprocess.run([manifest['path'],ORIGIN],input=frame({'version':1,'type':'poll'}),capture_output=True,timeout=10)
        self.assertEqual(json.loads(result.stdout[4:]),{'version':1,'type':'idle'})
        self.assertTrue((kit/'Extension/manifest.json').is_file())
        self.assertFalse((self.root/'Library').exists())
        duplicate = subprocess.run([sys.executable,str(SOURCE/'prepare-kit.py'),'--app',str(app),'--bridge-directory',str(self.root/'bridge'),'--output',str(kit)],capture_output=True)
        self.assertNotEqual(duplicate.returncode,0)
        subprocess.run(['/bin/sh','-n',str(kit/'install.command')],check=True,capture_output=True)

    def test_install_cancel_leaves_no_registration(self):
        kit = self.prepare_fixture_kit()
        result = self.install_fixture(kit, 'CANCEL\n')
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        self.assertFalse(self.fixture_registration().exists())
        self.assertFalse(self.fixture_registration().parent.exists())

    def test_install_uses_relocated_kit_path(self):
        kit = self.prepare_fixture_kit()
        old_path = json.loads((kit / 'com.uuthings.fangcun.iproyal.json').read_text())['path']
        moved = self.root / "常用工具's Moved Kit"
        kit.rename(moved)
        result = self.install_fixture(moved)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        registered = self.fixture_registration()
        manifest = json.loads(registered.read_text())
        launcher = self.root / 'Fixture Home/Library/Application Support/Fangcun/Connectors/IPRoyal/native-host.command'
        self.assertEqual(manifest['path'], str(launcher))
        self.assertEqual(launcher.stat().st_mode & 0o777, 0o700)
        self.assertEqual(launcher.read_bytes(), (moved / 'native-host.command').read_bytes())
        self.assertNotEqual(manifest['path'], old_path)
        self.assertEqual(manifest['allowed_origins'], [ORIGIN])
        self.assertEqual(manifest['name'], 'com.uuthings.fangcun.iproyal')
        self.assertEqual(manifest['type'], 'stdio')
        self.assertEqual(registered.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(registered.parent.glob('.fangcun-host.*')), [])
        shutil.rmtree(moved)  # Installed launcher must not depend on the exported kit path.
        reply = subprocess.run([manifest['path'], ORIGIN], input=frame({'version':1,'type':'poll'}),
                               capture_output=True, timeout=10)
        self.assertEqual(reply.returncode, 0, reply.stderr.decode(errors='replace'))
        self.assertEqual(json.loads(reply.stdout[4:]), {'version':1,'type':'idle'})

    def test_invalid_install_preserves_existing_registration(self):
        kit = self.prepare_fixture_kit()
        registered = self.fixture_registration()
        registered.parent.mkdir(parents=True)
        existing = b'{"name":"com.uuthings.fangcun.iproyal","path":"previous-fixture-host","type":"stdio"}\n'
        registered.write_bytes(existing)
        registered.chmod(0o600)
        (kit / 'com.uuthings.fangcun.iproyal.json').write_text('{"name":')
        result = self.install_fixture(kit)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(registered.read_bytes(), existing)
        self.assertEqual(registered.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(registered.parent.glob('.fangcun-host.*')), [])

if __name__ == '__main__': unittest.main()
