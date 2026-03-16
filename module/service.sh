#!/system/bin/sh
MODDIR=${0%/*}

APK_CACHE_DIR=/data/adb/apk_cache
APK_BIND_PATH=$APK_CACHE_DIR/${MODDIR##*/}.apk

. "$MODDIR/config"

report_error() {
	[ ! -f "$MODDIR/err" ] && cp "$MODDIR/module.prop" "$MODDIR/err"
	sed -i "s/^des.*/description=⚠️ Needs reflash: '${1}'/g" "$MODDIR/module.prop"
}

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done
until [ -d "/sdcard/Android" ]; do sleep 1; done

while
	APP_PATH=$(pm path "$PKG_NAME" 2>&1 </dev/null)
	SERVICE_STATUS=$?
	[ $SERVICE_STATUS = 20 ]
do sleep 2; done

run_service() {

	if [ $SERVICE_STATUS != 0 ]; then
		report_error "app not installed"
		return
	fi

	sleep 4

	APP_BASE=${APP_PATH##*:}
	APP_BASE=${APP_BASE%/*}

	if [ ! -d "$APP_BASE/lib" ]; then
		report_error "mount failed (ROM issue)"
		return
	fi

	INSTALLED_VER=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 versionName)
	INSTALLED_VER=${INSTALLED_VER#*=}

	if [ "$INSTALLED_VER" != "$PKG_VER" ] && [ "$INSTALLED_VER" ]; then
		report_error "version mismatch (installed:${INSTALLED_VER}, module:$PKG_VER)"
		return
	fi

	grep "$PKG_NAME" /proc/mounts | while read -r mount_line; do
		mount_point=${mount_line#* }
		mount_point=${mount_point%% *}
		umount -l "${mount_point%%\\*}"
	done

	if ! chcon u:object_r:apk_data_file:s0 "$APK_BIND_PATH"; then
		report_error "apk not found"
		return
	fi

	mount -o bind "$APK_BIND_PATH" "$APP_BASE/base.apk"
	am force-stop "$PKG_NAME"

	[ -f "$MODDIR/err" ] && mv -f "$MODDIR/err" "$MODDIR/module.prop"
}

run_service
