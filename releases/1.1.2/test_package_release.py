import base64
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('package_release', HERE / 'package_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
CANDIDATE = Path(sys.argv.pop(1)).resolve()


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        cls.pem = cls.key.private_bytes(serialization.Encoding.PEM,
                                       serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption())
        cls.expected = cls.key.public_key().public_numbers()
        cls.real_pin = release.verified_candidate(CANDIDATE)[2]

    def test_pem_signature_verifies(self):
        key = release.read_private(self.pem, None, self.expected)
        message = b'synthetic release validation'
        signature = key.sign(message, padding.PKCS1v15(), hashes.SHA256())
        self.assertEqual(len(signature), 384)
        self.expected.public_key().verify(signature, message, padding.PKCS1v15(), hashes.SHA256())

    def test_xml_with_windows_bom(self):
        n = self.key.private_numbers()
        values = dict(Modulus=n.public_numbers.n, Exponent=n.public_numbers.e,
                      P=n.p, Q=n.q, D=n.d, DP=n.dmp1, DQ=n.dmq1, InverseQ=n.iqmp)
        xml = '<RSAKeyValue>' + ''.join('<'+k+'>'+base64.b64encode(
            v.to_bytes((v.bit_length()+7)//8, 'big')).decode()+'</'+k+'>'
            for k, v in values.items()) + '</RSAKeyValue>'
        for encoding in ('utf-8-sig', 'utf-16'):
            self.assertEqual(release.read_private(xml.encode(encoding), None, self.expected)
                             .public_key().public_numbers(), self.expected)

    def test_encrypted_pem(self):
        pem = self.key.private_bytes(serialization.Encoding.PEM,
                                    serialization.PrivateFormat.PKCS8,
                                    serialization.BestAvailableEncryption(b'synthetic-password'))
        self.assertEqual(release.read_private(pem, b'synthetic-password', self.expected)
                         .public_key().public_numbers(), self.expected)
        with self.assertRaisesRegex(ValueError, '^SIGNING_KEY_INVALID$'):
            release.read_private(pem, b'wrong', self.expected)

    def test_wrong_key_cannot_create_feed(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'assets'
            with self.assertRaisesRegex(ValueError, '^SIGNING_KEY_DOES_NOT_MATCH_INSTALLED_APP$'):
                release.build(CANDIDATE, output, self.pem)
            self.assertFalse(output.exists())

    def test_missing_key_cannot_create_feed(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'assets'
            env = {k: v for k, v in os.environ.items() if not k.startswith('AVATA_UPDATE_SIGNING_')}
            result = subprocess.run([sys.executable, str(HERE/'package_release.py'),
                                     '--candidate', str(CANDIDATE), '--output', str(output), '--sign'],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stderr.strip(), 'SIGNING_KEY_MISSING')
            self.assertFalse(output.exists())

    def test_unsigned_package_matches_verified_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            first, second = Path(temp)/'first', Path(temp)/'second'
            one = release.build(CANDIDATE, first)
            two = release.build(CANDIDATE, second)
            self.assertFalse(one['Signed'])
            self.assertFalse((first/'avata-update.json').exists())
            self.assertEqual(one['PackageSha256'], two['PackageSha256'])
            with zipfile.ZipFile(first/release.PACKAGE) as package, zipfile.ZipFile(CANDIDATE) as kit:
                self.assertEqual(set(package.namelist()), release.FILES | {'release.json'})
                for name in package.namelist():
                    self.assertEqual(package.read(name), kit.read('bundle/'+name))

    def test_changed_candidate_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            bad = Path(temp)/'changed.zip'
            bad.write_bytes(CANDIDATE.read_bytes()+b'changed')
            with self.assertRaisesRegex(ValueError, '^CANDIDATE_HASH$'):
                release.build(bad, Path(temp)/'assets')

    def test_existing_output_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)/'assets'
            output.mkdir()
            sentinel = output/'existing.txt'
            sentinel.write_text('keep')
            with self.assertRaisesRegex(ValueError, '^OUTPUT_MUST_BE_EMPTY$'):
                release.build(CANDIDATE, output)
            self.assertEqual(sentinel.read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
