#!/bin/sh -ex

# shellcheck disable=SC2086
: "${BUILD_DIR:=build}"
cd "$BUILD_DIR" || exit 1

cd bin
if [ ! -f "rpcs3.app/Contents/MacOS/rpcs3" ]; then
  echo "Missing bundle executable: rpcs3.app/Contents/MacOS/rpcs3" >&2
  exit 1
fi

# CMake normally adds this file while creating the app bundle. Keep the
# packaging step defensive because `open` and Qt both rely on a valid bundle.
if [ ! -f "rpcs3.app/Contents/Info.plist" ]; then
  GENERATED_INFO_PLIST="../rpcs3/.qt/info_plist/rpcs3/Info.plist"
  if [ ! -f "$GENERATED_INFO_PLIST" ]; then
    echo "Missing bundle Info.plist" >&2
    exit 1
  fi
  cp "$GENERATED_INFO_PLIST" "rpcs3.app/Contents/Info.plist"
fi

# Homebrew's macdeployqt does not deploy the Cocoa platform plugin when RPCS3
# is built against its Qt package. Without it Qt aborts before the GUI is
# created with "Could not find the Qt platform plugin cocoa".
QT_PLATFORM_PLUGIN="${QT_PLUGIN_DIR:-$WORKDIR/qt-downloader/$QT_VER/clang_64/plugins}/platforms/libqcocoa.dylib"
if [ ! -f "$QT_PLATFORM_PLUGIN" ]; then
  echo "Missing Qt Cocoa platform plugin: $QT_PLATFORM_PLUGIN" >&2
  exit 1
fi
mkdir -p "rpcs3.app/Contents/PlugIns/platforms"
cp "$QT_PLATFORM_PLUGIN" "rpcs3.app/Contents/PlugIns/platforms/libqcocoa.dylib"
install_name_tool -add_rpath "@loader_path/../../../Frameworks" \
  "rpcs3.app/Contents/PlugIns/platforms/libqcocoa.dylib"

mkdir -p "rpcs3.app/Contents/Resources/vulkan/icd.d" || true
wget https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2-rc1/MoltenVK-macos-privateapi.tar
tar -xvf MoltenVK-macos-privateapi.tar
cp "MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "rpcs3.app/Contents/Frameworks/libMoltenVK.dylib"
cp "MoltenVK/MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json" "rpcs3.app/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json"
sed -i '' "s/.\//..\/..\/..\/Frameworks\//g" "rpcs3.app/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json"

cp "$(realpath $BREW_PATH/opt/llvm@$LLVM_COMPILER_VER/lib/c++/libc++abi.1.0.dylib)" "rpcs3.app/Contents/Frameworks/libc++abi.1.dylib"
cp "$(realpath $BREW_PATH/opt/gcc/lib/gcc/current/libgcc_s.1.1.dylib)" "rpcs3.app/Contents/Frameworks/libgcc_s.1.1.dylib"

rm -rf "rpcs3.app/Contents/Frameworks/QtPdf.framework" \
"rpcs3.app/Contents/Frameworks/QtQml.framework" \
"rpcs3.app/Contents/Frameworks/QtQmlModels.framework" \
"rpcs3.app/Contents/Frameworks/QtQuick.framework" \
"rpcs3.app/Contents/Frameworks/QtVirtualKeyboard.framework" \
"rpcs3.app/Contents/Plugins/platforminputcontexts" \
"rpcs3.app/Contents/Plugins/virtualkeyboard" \
"rpcs3.app/Contents/Resources/git" || true

../../.ci/optimize-mac.sh rpcs3.app

# Download translations
mkdir -p "rpcs3.app/Contents/translations"
ZIP_URL="https://github.com/RPCS3/rpcs3_translations/releases/latest/download/RPCS3-languages.zip"
echo "Downloading translations from: $ZIP_URL"
if curl -fsSL --retry 3 --retry-delay 60 "$ZIP_URL" -o "translations.zip"; then
  echo "Successfully downloaded translations."
  if unzip -o translations.zip -d "rpcs3.app/Contents/translations" >/dev/null 2>&1; then
    rm -f translations.zip
  else
    echo "Failed to extract translations.zip. Continuing without translations."
    rm -f translations.zip
  fi
else
  echo "Warning: Failed to download translations. Skipping..."
fi

# Copy Qt translations manually
QT_TRANS="${QT_TRANSLATIONS_DIR:-$WORKDIR/qt-downloader/$QT_VER/clang_64/translations}"
cp $QT_TRANS/qt_*.qm rpcs3.app/Contents/translations
cp $QT_TRANS/qtbase_*.qm rpcs3.app/Contents/translations
cp $QT_TRANS/qtmultimedia_*.qm rpcs3.app/Contents/translations
rm -f rpcs3.app/Contents/translations/qt_help_*.qm || true

# Need to do this rename hack due to case insensitive filesystem
mv rpcs3.app RPCS3_.app
mv RPCS3_.app RPCS3.app

# Hack to fix rpath issues
BIN="RPCS3.app/Contents/MacOS/rpcs3"
install_name_tool -delete_rpath /opt/homebrew/lib $BIN || true
install_name_tool -delete_rpath /usr/local/lib $BIN || true

# Fix dylib IDs
for lib in RPCS3.app/Contents/Frameworks/*.dylib; do
  name=$(basename "$lib")
  install_name_tool -id "@rpath/$name" "$lib"
done

# Rewrite any hardcoded Homebrew paths to use @rpath
find "RPCS3.app/Contents/" -type f \( -perm +111 -o -name "*.dylib" \) | while read -r bin; do
  otool -L "$bin" | grep -E "/opt/homebrew|/usr/local" | awk '{print $1}' | while read -r dep; do
    base=$(basename "$dep")
    echo "Fixing $dep -> @rpath/$base in $bin"
    install_name_tool -change "$dep" "@rpath/$base" "$bin"
  done
done

# macdeployqt signs nested Qt bundles. Thinning a universal Mach-O invalidates
# those signatures, so remove them and sign the final bundle only after every
# deployment-time mutation is complete.
find "RPCS3.app" -type d -name "_CodeSignature" -prune -exec rm -rf {} +

# NOTE: "--deep" is deprecated
codesign --deep -fs - RPCS3.app

echo "[InternetShortcut]" > Quickstart.url
echo "URL=https://rpcs3.net/quickstart" >> Quickstart.url
echo "IconIndex=0" >> Quickstart.url

if [ "$(arch)" = "arm64" ]; then
  ARCHIVE_FILEPATH="$BUILD_ARTIFACTSTAGINGDIRECTORY/rpcs3-v${LVER}_macos_aarch64.7z"
else
  ARCHIVE_FILEPATH="$BUILD_ARTIFACTSTAGINGDIRECTORY/rpcs3-v${LVER}_macos.7z"
fi
7z a -mx9 "$ARCHIVE_FILEPATH" RPCS3.app Quickstart.url

if [ "${SKIP_RELEASE_HASH:-0}" != "1" ]; then
  FILESIZE=$(stat -f %z "$ARCHIVE_FILEPATH")
  SHA256SUM=$(shasum -a 256 "$ARCHIVE_FILEPATH" | awk '{ print $1 }')
  cd ..
  echo "${SHA256SUM};${FILESIZE}B" > "$RELEASE_MESSAGE"
else
  cd ..
fi
cd bin
