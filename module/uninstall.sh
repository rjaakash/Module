#!/system/bin/sh
{

	until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done
	until [ -d "/sdcard/Android" ]; do sleep 1; done

	DIR=${0%/*}
	. "$DIR/config"

	rm "/data/adb/rvhc/${DIR##*/}.apk"
	rmdir "/data/adb/rvhc"
	rm "/data/adb/post-fs-data.d/$PKG_NAME-uninstall.sh"

} &
