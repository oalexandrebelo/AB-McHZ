#!/bin/zsh
# Remove o app e o LaunchAgent instalados por scripts/install.sh. Os perfis copiados ficam.
set -euo pipefail

LABEL=org.ab-mchz.agent
launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$LABEL.plist
rm -rf ~/Applications/AB-McHZ.app
rm -f ~/.local/bin/hetzctl
print "AB-McHZ removido. Mantidos: perfis em ~/Library/Application Support/AB-McHZ/profiles, licença e preferências (defaults org.ab-mchz.shared) e o perfil de cor atribuído às telas (Ajustes do Sistema > Telas)."
