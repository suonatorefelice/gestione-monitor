#!/bin/zsh
# Compila e installa "Gestione Monitor.app" in /Applications, poi la avvia.
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x GestioneMonitor 2>/dev/null || true
sleep 1
rm -rf "/Applications/Gestione Monitor.app"
cp -R "Gestione Monitor.app" /Applications/
LABEL=local.pasquale.gestionemonitor.agent
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    launchctl kickstart "gui/$(id -u)/$LABEL"
else
    open "/Applications/Gestione Monitor.app"
fi
echo "Installata in /Applications/Gestione Monitor.app"
