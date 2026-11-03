#!/bin/zsh
# Instala o AB-McHZ na barra de menus, aberto no login por um LaunchAgent da sessão do usuário.
# - App em ~/Applications/AB-McHZ.app (assinatura ad hoc), CLI em ~/.local/bin/hetzctl,
#   perfis em ~/Library/Application Support/AB-McHZ/profiles (perfil já existente não é sobrescrito).
# - "Sair do AB-McHZ" encerra até o próximo login; se o app cair, o launchd o reabre.
# Desfazer: scripts/uninstall.sh
set -euo pipefail
cd "${0:A:h}/.."

APP=~/Applications/AB-McHZ.app
LABEL=org.ab-mchz.agent
PLIST=~/Library/LaunchAgents/$LABEL.plist
PROFILES=~/Library/Application\ Support/AB-McHZ/profiles

swift build -c release --product AB-McHZ
swift build -c release --product hetzctl
BIN=$(swift build -c release --show-bin-path)

launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
# O bootout é assíncrono: bootstrap logo em seguida falha com "Bootstrap failed: 5".
for _ in {1..20}; do launchctl print gui/$UID/$LABEL >/dev/null 2>&1 || break; sleep 0.25; done
# Cópia aberta à mão (fora do launchd) também sai: o app recusa rodar duas vezes.
pkill -x AB-McHZ 2>/dev/null || true
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/AB-McHZ $APP/Contents/MacOS/AB-McHZ
mkdir -p ~/.local/bin
cp $BIN/hetzctl ~/.local/bin/hetzctl

# Ícone: logo AB (assets/brand). 16 e 32 px usam os desenhos próprios para tamanho pequeno.
ICONDIR=$(mktemp -d)
trap 'rm -rf $ICONDIR' EXIT
ICONSET=$ICONDIR/AppIcon.iconset
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
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundleName</key><string>AB-McHZ</string>
    <key>CFBundleExecutable</key><string>AB-McHZ</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - $APP

mkdir -p $PROFILES
cp -n profiles/*.json $PROFILES/ 2>/dev/null || true

cat > $PLIST <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AB-McHZ</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootstrap gui/$UID $PLIST
print "AB-McHZ instalado em $APP e ativo na barra de menus (LaunchAgent $LABEL); CLI em ~/.local/bin/hetzctl."
