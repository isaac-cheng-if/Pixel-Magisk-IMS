#!/system/bin/sh
# Magisk install-time customize script.

ui_print "- China Telecom IMS Auto-Inject"
ui_print "- Re-applies VoLTE/VoNR/VoWiFi carrier-config on every boot"

# make sure the injector + service are present
if [ ! -f "$MODPATH/injector.dex" ]; then
  ui_print "! injector.dex missing — aborting"
  abort "  injector.dex not found in module"
fi

ui_print "- Setting permissions"
set_perm "$MODPATH/service.sh"   0 0 0755
set_perm "$MODPATH/injector.dex" 0 0 0644

ui_print "- Installed. The fix runs automatically ~20-40s after each boot."
ui_print "  Log: /data/local/tmp/ct-ims-inject.log"
