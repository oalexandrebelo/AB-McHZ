#!/bin/zsh
# Remove o app e o LaunchAgent instalados por scripts/install.sh. Os perfis copiados ficam.
set -euo pipefail

LABEL=org.ab-mchz.agent
launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$LABEL.plist
rm -rf ~/Applications/AB-McHZ.app
print "AB-McHZ removido. Perfis mantidos em ~/Library/Application Support/AB-McHZ/profiles."
