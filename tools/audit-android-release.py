"""Static APK metadata/native audit. Never launches an app or device."""
import argparse
import re
import struct
import subprocess
import zipfile


def audit(apk, aapt, version, code):
    def dump(*args):
        return subprocess.run([aapt, 'dump', *args, apk], check=True,
                              capture_output=True, text=True, timeout=30).stdout
    badging = dump('badging')
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging, re.M)
    if not package or package.groups() != ('com.unng.serverdeck', str(code), version):
        raise ValueError('APK identity mismatch')
    if "sdkVersion:'24'" not in badging or "targetSdkVersion:'36'" not in badging:
        raise ValueError('APK SDK mismatch')
    permissions = set(re.findall(r"^uses-permission: name='([^']+)'", badging, re.M))
    if permissions != {'android.permission.INTERNET', 'com.unng.serverdeck.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'}:
        raise ValueError('APK permissions mismatch')
    manifest = subprocess.run([aapt, 'dump', 'xmltree', apk, 'AndroidManifest.xml'],
                              check=True, capture_output=True, text=True, timeout=30).stdout
    for attribute in ('allowBackup', 'usesCleartextTraffic'):
        if not re.search(r'android:' + attribute + r'\([^\n]+\)=\(type 0x12\)0x0\b', manifest):
            raise ValueError('APK privacy attribute mismatch: ' + attribute)
    with zipfile.ZipFile(apk) as archive:
        native = [n for n in archive.namelist() if n.startswith('lib/') and n.endswith('.so')]
        if {n.split('/')[1] for n in native} != {'arm64-v8a', 'x86_64'}:
            raise ValueError('APK ABI mismatch')
        for abi in ('arm64-v8a', 'x86_64'):
            if f'lib/{abi}/libisar.so' not in native:
                raise ValueError('Packaged Isar missing')
        for name in native:
            data = archive.read(name)
            if data[:6] != b'\x7fELF\x02\x01' or len(data) < 64:
                raise ValueError('Expected little-endian ELF64: ' + name)
            offset = struct.unpack_from('<Q', data, 32)[0]
            size, count = struct.unpack_from('<HH', data, 54)
            if size < 56 or offset + size * count > len(data):
                raise ValueError('Invalid program headers')
            for index in range(count):
                header = offset + index * size
                if struct.unpack_from('<I', data, header)[0] != 1:
                    continue
                file_offset, address = struct.unpack_from('<QQ', data, header + 8)
                alignment = struct.unpack_from('<Q', data, header + 48)[0]
                if alignment < 16384 or file_offset % 16384 != address % 16384:
                    raise ValueError('Native library lacks16KiB LOAD alignment: ' + name)
    print('Static APK identity/SDK/privacy/permissions/ABIs/Isar/ELF alignment audit passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for flag in ('apk', 'aapt', 'version'):
        parser.add_argument('--' + flag, required=True)
    parser.add_argument('--code', required=True, type=int)
    arguments = parser.parse_args()
    audit(arguments.apk, arguments.aapt, arguments.version, arguments.code)
