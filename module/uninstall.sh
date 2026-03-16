#!/system/bin/sh
{

	until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done
	until [ -d "/sdcard/Android" ]; do sleep 1; done

	MODDIR=${0%/*}
	. "$MODDIR/config"

	APK_CACHE_DIR=/data/adb/apk_cache
	APK_BIND_PATH=$APK_CACHE_DIR/${MODDIR##*/}.apk

	rm "$APK_BIND_PATH"
	rmdir "$APK_CACHE_DIR"
	rm "/data/adb/post-fs-data.d/$PKG_NAME-uninstall.sh"

} &
