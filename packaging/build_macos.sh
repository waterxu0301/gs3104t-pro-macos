#!/bin/zsh
# macOS 打包: PyInstaller --onedir --windowed → .app + ad-hoc 签名
set -e
cd "$(dirname "$0")/.."
APP_NAME="GanssDriver"
if [ -x "../.venv/bin/python" ]; then VENV="../.venv"
elif [ -x "../archive/ganss-mac/.venv/bin/python" ]; then VENV="../archive/ganss-mac/.venv"
else VENV="../.venv"; fi

$VENV/bin/python -m pip install pyinstaller 2>/dev/null | tail -1

cat > /tmp/ganss_driver.spec <<'SPEC'
# -*- mode: python -*-
a = Analysis(['run.py'], pathex=['.'], hiddenimports=['hid', 'hidapi'],
    datas=[('framework/web', 'framework/web'), ('framework/plugins', 'framework/plugins')])
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='GanssDriver',
    console=False, disable_windowed_traceback=False)
coll = COLLECT(exe, a.binaries, a.datas, name='GanssDriver')
app = BUNDLE(coll, name='GanssDriver.app', icon=None,
    info_plist={'CFBundleName': 'GANSS Device Hub',
                'CFBundleIdentifier': 'org.ganss.driver',
                'NSHumanReadableCopyright': 'MIT License'})
SPEC
$VENV/bin/python -m PyInstaller /tmp/ganss_driver.spec --noconfirm --distpath dist
codesign --force --deep -s - "dist/${APP_NAME}.app" && echo "signed (ad-hoc)"
echo "完成: dist/${APP_NAME}.app  （用户首次打开: xattr -cr dist/${APP_NAME}.app）"
