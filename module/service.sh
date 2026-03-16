#!/system/bin/sh
MODDIR=${0%/*}
RVPATH=/data/adb/rvhc/${MODDIR##*/}.apk
. "$MODDIR/config"

fail() {
	[ ! -f "$MODDIR/err" ] && cp "$MODDIR/module.prop" "$MODDIR/err"
	sed -i "s/^des.*/description=⚠️ Needs reflash: '${1}'/g" "$MODDIR/module.prop"
}

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done
until [ -d "/sdcard/Android" ]; do sleep 1; done

while
	APPBASE=$(pm path "$PKG_NAME" 2>&1 </dev/null)
	SVC=$?
	[ $SVC = 20 ]
do sleep 2; done

execute() {
	if [ $SVC != 0 ]; then
		fail "app not installed"
		return
	fi

	sleep 4

	APPBASE=${APPBASE##*:}
	APPBASE=${APPBASE%/*}

	if [ ! -d "$APPBASE/lib" ]; then
		fail "mount failed (ROM issue). Dont report this, consider using rvmm-zygisk-mount."
		return
	fi

	CURVER=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 versionName)
	CURVER=${CURVER#*=}

	if [ "$CURVER" != "$PKG_VER" ] && [ "$CURVER" ]; then
		fail "version mismatch (installed:${CURVER}, module:$PKG_VER)"
		return
	fi

	grep "$PKG_NAME" /proc/mounts | while read -r line; do
		mp=${line#* }
		mp=${mp%% *}
		umount -l "${mp%%\\*}"
	done

	if ! chcon u:object_r:apk_data_file:s0 "$RVPATH"; then
		fail "apk not found"
		return
	fi

	mount -o bind "$RVPATH" "$APPBASE/base.apk"
	am force-stop "$PKG_NAME"

	[ -f "$MODDIR/err" ] && mv -f "$MODDIR/err" "$MODDIR/module.prop"
}

execute
