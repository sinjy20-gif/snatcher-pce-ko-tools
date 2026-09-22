@echo off
rem Publishes the portable single-file Studio next to the source, then copies it
rem over the one the workspace actually runs.
cd /d "%~dp0"
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o portable_release
if errorlevel 1 (
  echo.
  echo PUBLISH FAILED
  pause
  exit /b 1
)
copy /y "portable_release\SnatcherTranslationStudio.exe" "..\SnatcherTranslationStudio.exe"
copy /y "portable_release\SnatcherTranslationStudio.pdb" "..\SnatcherTranslationStudio.pdb"
echo.
echo OK - C:\snatcher\snatcher_tool\SnatcherTranslationStudio.exe updated
pause
