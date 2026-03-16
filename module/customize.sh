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

RUNTIME_APK=/data/adb/rvhc/${MODPATH##*/}.apk

set_perm_recursive "$MODPATH/bin" 0 0 0755 0777

if su -M -c true >/dev/null 2>/dev/null; then
  alias root_exec='su -M -c'
else
  alias root_exec='nsenter -t1 -m'
fi

root_exec grep -F "$PKG_NAME" /proc/mounts | while read -r entry; do
  ui_print "* Removing existing bind"
  mnt=${entry#* }
  mnt=${mnt%% *}
  root_exec umount -l "${mnt%%\\*}"
done

am force-stop "$PKG_NAME"

pm_run() {
  RESULT=$(pm "$@" 2>&1 </dev/null)
  CODE=$?
  echo "$RESULT"
  return $CODE
}

if ! pm_run path "$PKG_NAME" >&2; then
  if pm_run install-existing "$PKG_NAME" >&2; then
    pm_run uninstall-system-updates "$PKG_NAME"
  fi
fi

IS_SYSTEM_APP=false
NEED_INSTALL=true

if BASE_PATH=$(pm_run path "$PKG_NAME"); then
  echo >&2 "'$BASE_PATH'"
  BASE_PATH=${BASE_PATH##*:}
  BASE_PATH=${BASE_PATH%/*}

  if [ "${BASE_PATH:1:4}" != data ]; then
    ui_print "* Detected system package"
    IS_SYSTEM_APP=true
  elif [ ! -f "$MODPATH/$PKG_NAME.apk" ]; then
    ui_print "* Missing stock package inside module"

    CURRENT_VER=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 versionName)
    CURRENT_VER=${CURRENT_VER#*=}

    if [ "$CURRENT_VER" = "$PKG_VER" ] || [ -z "$CURRENT_VER" ]; then
      ui_print "* Skipping installation step"
      NEED_INSTALL=false
    else
      abort "ERROR: version mismatch
installed: $CURRENT_VER
module:    $PKG_VER"
    fi
  elif "${MODPATH:?}/bin/$ARCH/cmpr" "$BASE_PATH/base.apk" "$MODPATH/$PKG_NAME.apk"; then
    ui_print "* Package already matches module"
    NEED_INSTALL=false
  fi
fi

perform_install() {

  if [ ! -f "$MODPATH/$PKG_NAME.apk" ]; then
    abort "ERROR: required APK not present"
  fi

  ui_print "* Installing $PKG_NAME version $PKG_VER"

  INSTALL_ERROR=""

  OLD_V1=$(settings get global verifier_verify_adb_installs)
  OLD_V2=$(settings get global package_verifier_enable)

  settings put global verifier_verify_adb_installs 0
  settings put global package_verifier_enable 0

  FILE_SIZE=$(stat -c "%s" "$MODPATH/$PKG_NAME.apk")

  for TRY in 1 2; do

    if ! SESSION=$(pm_run install-create --user 0 -i com.android.vending -r -d -S "$FILE_SIZE"); then
      ui_print "ERROR: failed creating install session"
      INSTALL_ERROR="$SESSION"
      break
    fi

    SESSION=${SESSION#*[}
    SESSION=${SESSION%]*}

    set_perm "$MODPATH/$PKG_NAME.apk" 1000 1000 644 u:object_r:apk_data_file:s0

    if ! OUT=$(pm_run install-write -S "$FILE_SIZE" "$SESSION" "$PKG_NAME.apk" "$MODPATH/$PKG_NAME.apk"); then
      ui_print "ERROR: write stage failed"
      INSTALL_ERROR="$OUT"
      break
    fi

    if ! OUT=$(pm_run install-commit "$SESSION"); then

      ui_print "$OUT"

      if echo "$OUT" | grep -q -e INSTALL_FAILED_VERSION_DOWNGRADE -e INSTALL_FAILED_UPDATE_INCOMPATIBLE; then

        ui_print "* Attempting recovery"
        pm_run uninstall-system-updates "$PKG_NAME"

        if BASE_PATH=$(pm_run path "$PKG_NAME"); then
          BASE_PATH=${BASE_PATH##*:}
          BASE_PATH=${BASE_PATH%/*}
          if [ "${BASE_PATH:1:4}" != data ]; then
            IS_SYSTEM_APP=true
          fi
        fi

        if [ "$IS_SYSTEM_APP" = true ]; then

          CLEAN_SCRIPT="/data/adb/post-fs-data.d/$PKG_NAME-uninstall.sh"

          if [ -f "$CLEAN_SCRIPT" ]; then
            ui_print "* Existing cleanup detected. Reboot then flash again."
            ui_print ""
            INSTALL_ERROR=" "
            break
          fi

          mkdir -p /data/adb/rvhc/empty /data/adb/post-fs-data.d
          echo "mount -o bind /data/adb/rvhc/empty $BASE_PATH" > "$CLEAN_SCRIPT"
          chmod +x "$CLEAN_SCRIPT"

          ui_print "* Cleanup script created"
          ui_print ""
          ui_print "* Reboot and flash the module again"
          INSTALL_ERROR=" "
          break

        else

          ui_print "* Removing previous installation"

          if ! OUT=$(pm_run uninstall -k --user 0 "$PKG_NAME"); then
            ui_print "$OUT"
            if [ $TRY = 2 ]; then
              INSTALL_ERROR="ERROR: uninstall failed"
              break
            fi
          fi

          continue
        fi
      fi

      ui_print "ERROR: commit stage failed"
      INSTALL_ERROR="$OUT"
      break
    fi

    if BASE_PATH=$(pm_run path "$PKG_NAME"); then
      BASE_PATH=${BASE_PATH##*:}
      BASE_PATH=${BASE_PATH%/*}
    else
      INSTALL_ERROR=" "
      break
    fi

    break
  done

  settings put global verifier_verify_adb_installs "$OLD_V1"
  settings put global package_verifier_enable "$OLD_V2"

  if [ "$INSTALL_ERROR" ]; then
    ui_print "$INSTALL_ERROR"
    abort "ERROR: disable module, reboot device, install app manually, then flash module again"
  fi
}

if [ $NEED_INSTALL = true ] && ! perform_install; then
  abort
fi

LIB_PATH=${BASE_PATH}/lib/${ARCH}

if [ $NEED_INSTALL = true ] || [ -z "$(ls -A1 "$LIB_PATH")" ]; then

  ui_print "* Extracting native libraries"

  if [ ! -d "$LIB_PATH" ]; then
    mkdir -p "$LIB_PATH"
  else
    rm -f "$LIB_PATH"/* >/dev/null 2>&1 || :
  fi

  if ! OUT=$(unzip -o -j "$MODPATH/$PKG_NAME.apk" "lib/${ABI_DIR}/*" -d "$LIB_PATH" 2>&1); then
    ui_print "ERROR: native library extraction failed"
    abort "$OUT"
  fi

  set_perm_recursive "${BASE_PATH}/lib" 1000 1000 755 755 u:object_r:apk_data_file:s0
fi

ui_print "* Applying permissions"
set_perm "$MODPATH/base.apk" 1000 1000 644 u:object_r:apk_data_file:s0

ui_print "* Mounting patched APK"

mkdir -p /data/adb/rvhc
RUNTIME_APK=/data/adb/rvhc/${MODPATH##*/}.apk
mv -f "$MODPATH/base.apk" "$RUNTIME_APK"

if ! OUT=$(root_exec mount -o bind "$RUNTIME_APK" "$BASE_PATH/base.apk" 2>&1); then
  ui_print "ERROR: bind mount failed"
  ui_print "$OUT"
fi

am force-stop "$PKG_NAME"

ui_print "* Running package optimization"

cmd package compile -m speed-profile -f "$PKG_NAME"

if [ "$KSU" ]; then

  UID=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 uid)
  UID=${UID#*=}
  UID=${UID%% *}

  if [ -z "$UID" ]; then
    UID=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 userId)
    UID=${UID#*=}
    UID=${UID%% *}
  fi

  if [ "$UID" ]; then
    if ! OUT=$("${MODPATH:?}/bin/$ARCH/ksu_profile" "$UID" "$PKG_NAME" 2>&1); then
      ui_print "  $OUT"
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
