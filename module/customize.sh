#!/system/bin/sh

CFG_FILE="$MODPATH/config"
[ -f "$CFG_FILE" ] && . "$CFG_FILE"

print_msg() {
  ui_print "$1"
}

fail_install() {
  abort "$1"
}

DEVICE_ARCH="$ARCH"
TARGET_ARCH="$MODULE_ARCH"

if [ -n "$TARGET_ARCH" ] && [ "$DEVICE_ARCH" != "$TARGET_ARCH" ]; then
  fail_install "Module architecture does not match device"
fi

case "$DEVICE_ARCH" in
  arm) LIB_SUBDIR="armeabi-v7a" ;;
  arm64) LIB_SUBDIR="arm64-v8a" ;;
  x86) LIB_SUBDIR="x86" ;;
  x64) LIB_SUBDIR="x86_64" ;;
  *) fail_install "Unsupported device architecture" ;;
esac

APP_PACKAGE="$PKG_NAME"
MODULE_APK="$MODPATH/$APP_PACKAGE.apk"
PATCH_APK="$MODPATH/base.apk"
MOUNT_ROOT="/data/adb/runtime_overlay"
RUNTIME_APK="$MOUNT_ROOT/${MODPATH##*/}.apk"

set_perm_recursive "$MODPATH/bin" 0 0 0755 0755

if su -M -c true >/dev/null 2>/dev/null; then
  run_root() { su -M -c "$*"; }
else
  run_root() { nsenter -t1 -m sh -c "$*"; }
fi

run_root grep -F "$APP_PACKAGE" /proc/mounts | while read -r line; do
  print_msg "* Clearing previous mount binding"
  mp=${line#* }
  mp=${mp%% *}
  run_root umount -l "${mp%%\\*}"
done

am force-stop "$APP_PACKAGE"

pm_call() {
  OUT=$(pm "$@" 2>&1 </dev/null)
  RET=$?
  echo "$OUT"
  return $RET
}

if ! pm_call path "$APP_PACKAGE" >/dev/null 2>&1; then
  if pm_call install-existing "$APP_PACKAGE" >/dev/null 2>&1; then
    pm_call uninstall-system-updates "$APP_PACKAGE"
  fi
fi

IS_SYSTEM=false
INSTALL_NEEDED=true
INSTALL_PATH=""

if APP_PATH=$(pm_call path "$APP_PACKAGE"); then
  APP_PATH=${APP_PATH##*:}
  INSTALL_PATH=${APP_PATH%/*}

  if [ "${INSTALL_PATH:1:4}" != data ]; then
    print_msg "* Detected system application"
    IS_SYSTEM=true
  elif [ ! -f "$MODULE_APK" ]; then
    print_msg "* Module APK missing"
    VERSION=$(dumpsys package "$APP_PACKAGE" | grep -m1 versionName)
    VERSION=${VERSION#*=}
    if [ "$VERSION" = "$PKG_VER" ] || [ -z "$VERSION" ]; then
      print_msg "* Installed version already matches"
      INSTALL_NEEDED=false
    else
      fail_install "Installed package version differs from module"
    fi
  elif [ -f "$INSTALL_PATH/base.apk" ] && cmp -s "$INSTALL_PATH/base.apk" "$MODULE_APK"; then
    print_msg "* Installed package already identical to module"
    INSTALL_NEEDED=false
  fi
fi

install_package() {

  [ -f "$MODULE_APK" ] || fail_install "Required module package missing"

  print_msg "* Starting package installation"

  VERIFY_A=$(settings get global verifier_verify_adb_installs)
  VERIFY_B=$(settings get global package_verifier_enable)

  settings put global verifier_verify_adb_installs 0
  settings put global package_verifier_enable 0

  SIZE=$(stat -c "%s" "$MODULE_APK")

  for TRY in 1 2; do

    if ! SESSION=$(pm_call install-create --user 0 -r -d -S "$SIZE"); then
      INSTALL_ERR="$SESSION"
      break
    fi

    SESSION=${SESSION#*[}
    SESSION=${SESSION%]*}

    set_perm "$MODULE_APK" 1000 1000 0644 u:object_r:apk_data_file:s0

    if ! WRITE=$(pm_call install-write -S "$SIZE" "$SESSION" "$APP_PACKAGE.apk" "$MODULE_APK"); then
      INSTALL_ERR="$WRITE"
      break
    fi

    if ! RESULT=$(pm_call install-commit "$SESSION"); then

      echo "$RESULT"

      if echo "$RESULT" | grep -q -e INSTALL_FAILED_VERSION_DOWNGRADE -e INSTALL_FAILED_UPDATE_INCOMPATIBLE; then

        print_msg "* Resolving installation conflict"

        pm_call uninstall-system-updates "$APP_PACKAGE"

        if PATH_CHECK=$(pm_call path "$APP_PACKAGE"); then
          PATH_CHECK=${PATH_CHECK##*:}
          PATH_CHECK=${PATH_CHECK%/*}
          if [ "${PATH_CHECK:1:4}" != data ]; then
            IS_SYSTEM=true
          fi
        fi

        if [ "$IS_SYSTEM" = true ]; then

          SCRIPT="/data/adb/post-fs-data.d/${APP_PACKAGE}-cleanup.sh"

          if [ -f "$SCRIPT" ]; then
            print_msg "* Existing cleanup script detected"
            INSTALL_ERR=" "
            break
          fi

          mkdir -p /data/adb/runtime_overlay/empty /data/adb/post-fs-data.d
          echo "mount -o bind /data/adb/runtime_overlay/empty $PATH_CHECK" > "$SCRIPT"
          chmod +x "$SCRIPT"

          print_msg "* Temporary cleanup script created"
          print_msg "* Reboot device and reinstall module"

          INSTALL_ERR=" "
          break

        else

          print_msg "* Removing existing user installation"

          if ! OUT=$(pm_call uninstall -k --user 0 "$APP_PACKAGE"); then
            echo "$OUT"
            if [ $TRY = 2 ]; then
              INSTALL_ERR="Package removal failed"
              break
            fi
          fi

          continue
        fi
      fi

      INSTALL_ERR="$RESULT"
      break
    fi

    if PATH_OK=$(pm_call path "$APP_PACKAGE"); then
      PATH_OK=${PATH_OK##*:}
      INSTALL_PATH=${PATH_OK%/*}
    else
      INSTALL_ERR=" "
      break
    fi

    break
  done

  settings put global verifier_verify_adb_installs "$VERIFY_A"
  settings put global package_verifier_enable "$VERIFY_B"

  if [ "$INSTALL_ERR" ]; then
    echo "$INSTALL_ERR"
    fail_install "Disable module, reboot device, install app manually, then flash module again"
  fi
}

if [ "$INSTALL_NEEDED" = true ]; then
  install_package
fi

LIB_DIR="$INSTALL_PATH/lib/$DEVICE_ARCH"

if [ "$INSTALL_NEEDED" = true ] || [ -z "$(ls -A "$LIB_DIR" 2>/dev/null)" ]; then

  print_msg "* Extracting native library files"

  if [ ! -d "$LIB_DIR" ]; then
    mkdir -p "$LIB_DIR"
  else
    rm -f "$LIB_DIR"/* >/dev/null 2>&1
  fi

  unzip -o -j "$MODULE_APK" "lib/${LIB_SUBDIR}/*" -d "$LIB_DIR" >/dev/null 2>&1 \
    || fail_install "Native library extraction failed"

  set_perm_recursive "$INSTALL_PATH/lib" 1000 1000 0755 0755 u:object_r:apk_data_file:s0
fi

print_msg "* Applying module file permissions"

set_perm "$PATCH_APK" 1000 1000 0644 u:object_r:apk_data_file:s0

mkdir -p "$MOUNT_ROOT"

mv -f "$PATCH_APK" "$RUNTIME_APK"

print_msg "* Activating overlay mount"

if ! run_root mount -o bind "$RUNTIME_APK" "$INSTALL_PATH/base.apk"; then
  print_msg "Bind mount operation failed"
fi

am force-stop "$APP_PACKAGE"

print_msg "* Running package optimization"

cmd package compile -m speed-profile -f "$APP_PACKAGE"

if [ "$KSU" ]; then

  UID=$(dumpsys package "$APP_PACKAGE" | grep -m1 uid)
  UID=${UID#*=}
  UID=${UID%% *}

  if [ -z "$UID" ]; then
    UID=$(dumpsys package "$APP_PACKAGE" | grep -m1 userId)
    UID=${UID#*=}
    UID=${UID%% *}
  fi

  if [ -n "$UID" ]; then
    "$MODPATH/bin/$DEVICE_ARCH/ksu_profile" "$UID" "$APP_PACKAGE" >/dev/null 2>&1
  else
    print_msg "Unable to resolve package UID"
  fi
fi

rm -rf "${MODPATH:?}/bin" "$MODULE_APK"

print_msg "* Module installation process finished"
