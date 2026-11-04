#!/bin/zsh
# Gera dist/AB-McHZ.app e dist/AB-McHZ-<versão>.dmg (arrastar para Aplicativos), como nas releases do GitHub.
# Assinatura: Developer ID com hardened runtime se SIGN_IDENTITY estiver definido; senão ad hoc.
# Notarização: com SIGN_IDENTITY e NOTARY_PROFILE (perfil criado por `xcrun notarytool store-credentials`).
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(<VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
DIST=dist
APP=$DIST/AB-McHZ.app
DMG=$DIST/AB-McHZ-$VERSION.dmg

swift build -c release --product AB-McHZ
swift build -c release --product hetzctl
BIN=$(swift build -c release --show-bin-path)

rm -rf $DIST
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources/profiles
cp $BIN/AB-McHZ $BIN/hetzctl $APP/Contents/MacOS/
cp profiles/*.json $APP/Contents/Resources/profiles/
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" packaging/Info.plist > $APP/Contents/Info.plist

# Ícone: logo AB (assets/brand). 16 e 32 px usam os desenhos próprios para tamanho pequeno.
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
ICONSET=$WORK/AppIcon.iconset
mkdir -p $ICONSET
cp assets/brand/ab-16.png $ICONSET/icon_16x16.png
cp assets/brand/ab-32.png $ICONSET/icon_16x16@2x.png
cp assets/brand/ab-32.png $ICONSET/icon_32x32.png
cp assets/brand/ab-512.png $ICONSET/icon_256x256@2x.png
cp assets/brand/ab-512.png $ICONSET/icon_512x512.png
for name size in icon_32x32@2x 64 icon_128x128 128 icon_128x128@2x 256 icon_256x256 256; do
  sips -z $size $size assets/brand/ab-512.png --out $ICONSET/$name.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns

# O hetzctl é assinado antes do app, que o sela junto com o resto do bundle.
if [[ -n ${SIGN_IDENTITY:-} ]]; then
  SIGN=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
else
  SIGN=(--force --sign -)
fi
codesign $SIGN $APP/Contents/MacOS/hetzctl
codesign $SIGN $APP
codesign --verify --strict $APP

STAGE=$WORK/dmg
mkdir -p $STAGE
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Aplicativos
hdiutil create -quiet -volname "AB-McHZ $VERSION" -srcfolder $STAGE -fs HFS+ -format UDZO -ov $DMG

if [[ -n ${SIGN_IDENTITY:-} ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" $DMG
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    xcrun notarytool submit $DMG --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple $DMG
  fi
fi
print "$APP\n$DMG"
