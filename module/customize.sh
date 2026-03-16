. "$MODPATH/config"

ui_print ""

if [ -n "$MODULE_ARCH" ] && [ "$MODULE_ARCH" != "$ARCH" ]; then
  abort "ERROR: Unsupported architecture
Device: $ARCH
Module: $MODULE_ARCH"
fi

if [ "$ARCH" = "arm" ]; then
  ABI_DIR=armeabi-v7a
elif [ "$ARCH" = "arm64" ]; then
  ABI_DIR=arm64-v8a
elif [ "$ARCH" = "x86" ]; then
  ABI_DIR=x86
elif [ "$ARCH" = "x64" ]; then
  ABI_DIR=x86_64
else
  abort "ERROR: unexpected architecture: ${ARCH}"
fi

APK_CACHE_DIR=/data/adb/apk_cache
APK_BIND_PATH=$APK_CACHE_DIR/${MODPATH##*/}.apk

set_perm_recursive "$MODPATH/bin" 0 0 0755 0777

if su -M -c true >/dev/null 2>/dev/null; then
  alias run_root='su -M -c'
else
  alias run_root='nsenter -t1 -m'
fi

run_root grep -F "$PKG_NAME" /proc/mounts | while read -r mount_line; do
  ui_print "* Removing existing bind"
  mount_point=${mount_line#* }
  mount_point=${mount_point%% *}
  run_root umount -l "${mount_point%%\\*}"
done

am force-stop "$PKG_NAME"

run_pm() {
  cmd_output=$(pm "$@" 2>&1 </dev/null)
  cmd_code=$?
  echo "$cmd_output"
  return $cmd_code
}

if ! run_pm path "$PKG_NAME" >&2; then
  if run_pm install-existing "$PKG_NAME" >&2; then
    run_pm uninstall-system-updates "$PKG_NAME"
  fi
fi

SYSTEM_APP=false
INSTALL_REQUIRED=true

if APP_BASE=$(run_pm path "$PKG_NAME"); then
  echo >&2 "'$APP_BASE'"
  APP_BASE=${APP_BASE##*:}
  APP_BASE=${APP_BASE%/*}

  if [ "${APP_BASE:1:4}" != data ]; then
    ui_print "* Detected system package"
    SYSTEM_APP=true
  elif [ ! -f "$MODPATH/$PKG_NAME.apk" ]; then
    ui_print "* Missing stock package inside module"

    INSTALLED_VER=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 versionName)
    INSTALLED_VER=${INSTALLED_VER#*=}

    if [ "$INSTALLED_VER" = "$PKG_VER" ] || [ -z "$INSTALLED_VER" ]; then
      ui_print "* Skipping installation step"
      INSTALL_REQUIRED=false
    else
      abort "ERROR: version mismatch
installed: $INSTALLED_VER
module:    $PKG_VER"
    fi
  elif "${MODPATH:?}/bin/$ARCH/cmpr" "$APP_BASE/base.apk" "$MODPATH/$PKG_NAME.apk"; then
    ui_print "* Package already matches module"
    INSTALL_REQUIRED=false
  fi
fi

install_package() {

  if [ ! -f "$MODPATH/$PKG_NAME.apk" ]; then
    abort "ERROR: required APK not present"
  fi

  ui_print "* Installing $PKG_NAME version $PKG_VER"

  install_error=""

  OLD_VERIFY1=$(settings get global verifier_verify_adb_installs)
  OLD_VERIFY2=$(settings get global package_verifier_enable)

  settings put global verifier_verify_adb_installs 0
  settings put global package_verifier_enable 0

  APK_SIZE=$(stat -c "%s" "$MODPATH/$PKG_NAME.apk")

  for attempt in 1 2; do

    if ! session_id=$(run_pm install-create --user 0 -i com.android.vending -r -d -S "$APK_SIZE"); then
      ui_print "ERROR: failed creating install session"
      install_error="$session_id"
      break
    fi

    session_id=${session_id#*[}
    session_id=${session_id%]*}

    set_perm "$MODPATH/$PKG_NAME.apk" 1000 1000 644 u:object_r:apk_data_file:s0

    if ! cmd_output=$(run_pm install-write -S "$APK_SIZE" "$session_id" "$PKG_NAME.apk" "$MODPATH/$PKG_NAME.apk"); then
      ui_print "ERROR: write stage failed"
      install_error="$cmd_output"
      break
    fi

    if ! cmd_output=$(run_pm install-commit "$session_id"); then

      ui_print "$cmd_output"

      if echo "$cmd_output" | grep -q -e INSTALL_FAILED_VERSION_DOWNGRADE -e INSTALL_FAILED_UPDATE_INCOMPATIBLE; then

        ui_print "* Attempting recovery"
        run_pm uninstall-system-updates "$PKG_NAME"

        if APP_BASE=$(run_pm path "$PKG_NAME"); then
          APP_BASE=${APP_BASE##*:}
          APP_BASE=${APP_BASE%/*}
          if [ "${APP_BASE:1:4}" != data ]; then
            SYSTEM_APP=true
          fi
        fi

        if [ "$SYSTEM_APP" = true ]; then

          CLEAN_SCRIPT="/data/adb/post-fs-data.d/$PKG_NAME-uninstall.sh"

          if [ -f "$CLEAN_SCRIPT" ]; then
            ui_print "* Existing cleanup detected. Reboot then flash again."
            ui_print ""
            install_error=" "
            break
          fi

          mkdir -p "$APK_CACHE_DIR/empty" /data/adb/post-fs-data.d
          echo "mount -o bind $APK_CACHE_DIR/empty $APP_BASE" > "$CLEAN_SCRIPT"
          chmod +x "$CLEAN_SCRIPT"

          ui_print "* Cleanup script created"
          ui_print ""
          ui_print "* Reboot and flash the module again"
          install_error=" "
          break

        else

          ui_print "* Removing previous installation"

          if ! cmd_output=$(run_pm uninstall -k --user 0 "$PKG_NAME"); then
            ui_print "$cmd_output"
            if [ $attempt = 2 ]; then
              install_error="ERROR: uninstall failed"
              break
            fi
          fi

          continue
        fi
      fi

      ui_print "ERROR: commit stage failed"
      install_error="$cmd_output"
      break
    fi

    if APP_BASE=$(run_pm path "$PKG_NAME"); then
      APP_BASE=${APP_BASE##*:}
      APP_BASE=${APP_BASE%/*}
    else
      install_error=" "
      break
    fi

    break
  done

  settings put global verifier_verify_adb_installs "$OLD_VERIFY1"
  settings put global package_verifier_enable "$OLD_VERIFY2"

  if [ "$install_error" ]; then
    ui_print "$install_error"
    abort "ERROR: disable module, reboot device, install app manually and flash module again"
  fi
}

if [ $INSTALL_REQUIRED = true ] && ! install_package; then
  abort
fi

LIB_DIR=${APP_BASE}/lib/${ARCH}

if [ $INSTALL_REQUIRED = true ] || [ -z "$(ls -A1 "$LIB_DIR")" ]; then

  ui_print "* Extracting native libraries"

  if [ ! -d "$LIB_DIR" ]; then
    mkdir -p "$LIB_DIR"
  else
    rm -f "$LIB_DIR"/* >/dev/null 2>&1 || :
  fi

  if ! cmd_output=$(unzip -o -j "$MODPATH/$PKG_NAME.apk" "lib/${ABI_DIR}/*" -d "$LIB_DIR" 2>&1); then
    ui_print "ERROR: native library extraction failed"
    abort "$cmd_output"
  fi

  set_perm_recursive "${APP_BASE}/lib" 1000 1000 755 755 u:object_r:apk_data_file:s0
fi

ui_print "* Applying permissions"
set_perm "$MODPATH/base.apk" 1000 1000 644 u:object_r:apk_data_file:s0

ui_print "* Mounting patched APK"

mkdir -p "$APK_CACHE_DIR"
APK_BIND_PATH="$APK_CACHE_DIR/${MODPATH##*/}.apk"
mv -f "$MODPATH/base.apk" "$APK_BIND_PATH"

if ! cmd_output=$(run_root mount -o bind "$APK_BIND_PATH" "$APP_BASE/base.apk" 2>&1); then
  ui_print "ERROR: bind mount failed"
  ui_print "$cmd_output"
fi

am force-stop "$PKG_NAME"

ui_print "* Running package optimization"

cmd package compile -m speed-profile -f "$PKG_NAME"

if [ "$KSU" ]; then

  APP_UID=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 uid)
  APP_UID=${APP_UID#*=}
  APP_UID=${APP_UID%% *}

  if [ -z "$APP_UID" ]; then
    APP_UID=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 userId)
    APP_UID=${APP_UID#*=}
    APP_UID=${APP_UID%% *}
  fi

  if [ "$APP_UID" ]; then
    if ! cmd_output=$("${MODPATH:?}/bin/$ARCH/ksu_profile" "$APP_UID" "$PKG_NAME" 2>&1); then
      ui_print "  $cmd_output"
      ui_print "* KernelSU fork detected"
      ui_print "  disable 'Unmount modules' for $PKG_NAME"
    fi
  else
    ui_print "ERROR: unable to determine UID for $PKG_NAME"
    dumpsys package "$PKG_NAME" >&2
  fi
fi

rm -rf "${MODPATH:?}/bin" "$MODPATH/$PKG_NAME.apk"

ui_print "* Finished"
ui_print " "
