@echo off
rem Windows 打包: PyInstaller 单目录 exe
cd /d "%~dp0.."
python -m pip install pyinstaller
python -m PyInstaller --noconfirm --distpath dist ^
  --hidden-import hid --hidden-import hidapi ^
  --add-data "framework/web;framework/web" ^
  --add-data "framework/plugins;framework/plugins" ^
  --windowed --name GanssDriver run.py
echo 完成: dist\GanssDriver\GanssDriver.exe
