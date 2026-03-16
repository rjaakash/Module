#!/system/bin/sh

# ---- Load configuration ----
CFG_FILE="$MODPATH/config"
[ -f "$CFG_FILE" ] && . "$CFG_FILE"

print_msg() {
  ui_print "$1"
}

fail_install() {
  abort "$1"
}

# ---- Validate architecture ----
DEVICE_ARCH="$ARCH"
TARGET_ARCH="$MODULE_ARCH"

if [ -n "$TARGET_ARCH" ] && [ "$DEVICE_ARCH" != "$TARGET_ARCH" ]; then
  fail_install "Architecture mismatch: device=$DEVICE_ARCH module=$TARGET_ARCH"
fi

case "$DEVICE_ARCH" in
  arm) LIB_SUBDIR="armeabi-v7a" ;;
  arm64) LIB_SUBDIR="arm64-v8a" ;;
  x86) LIB_SUBDIR="x86" ;;
  x64) LIB_SUBDIR="x86_64" ;;
  *) fail_install "Unsupported CPU architecture: $DEVICE_ARCH" ;;
esac

# ---- Prepare environment ----
APP_PACKAGE="$PKG_NAME"
MODULE_APK="$MODPATH/$APP_PACKAGE.apk"
PATCH_APK="$MODPATH/base.apk"
MOUNT_DIR="/data/adb/module_runtime"
RUNTIME_APK="$MOUNT_DIR/${MODPATH##*/}.apk"

set_perm_recursive "$MODPATH/bin" 0 0 0755 0755

# Determine mount executor
if su -M -c true >/dev/null 2>&1; then
  run_mount() { su -M -c "$*"; }
else
  run_mount() { nsenter -t1 -m sh -c "$*"; }
fi

# ---- Remove previous mounts ----
run_mount grep -F "$APP_PACKAGE" /proc/mounts | while read -r entry; do
  print_msg "* Removing previous mount"
  target=${entry#* }
  target=${target%% *}
  run_mount umount -l "${target%%\\*}"
done

# ---- Stop running app ----
am force-stop "$APP_PACKAGE"

# ---- Package manager helper ----
pm_call() {
  out=$(pm "$@" 2>&1 </dev/null)
  rc=$?
  echo "$out"
  return $rc
}

# ---- Ensure package exists ----
if ! pm_call path "$APP_PACKAGE" >/dev/null 2>&1; then
  if pm_call install-existing "$APP_PACKAGE" >/dev/null 2>&1; then
    pm_call uninstall-system-updates "$APP_PACKAGE"
  fi
fi

# ---- Determine install path ----
INSTALL_PATH=""
SYSTEM_APP=false
INSTALL_REQUIRED=true

if APP_PATH=$(pm_call path "$APP_PACKAGE"); then
  APP_PATH=${APP_PATH##*:}
  INSTALL_PATH=${APP_PATH%/*}

  case "$INSTALL_PATH" in
    /data/*) SYSTEM_APP=false ;;
    *) SYSTEM_APP=true ;;
  esac

  if [ ! -f "$MODULE_APK" ]; then
    print_msg "* Stock APK missing in module"
    CURRENT_VER=$(dumpsys package "$APP_PACKAGE" | grep -m1 versionName)
    CURRENT_VER=${CURRENT_VER#*=}

    if [ "$CURRENT_VER" = "$PKG_VER" ] || [ -z "$CURRENT_VER" ]; then
      INSTALL_REQUIRED=false
      print_msg "* Skipping installation"
    else
      fail_install "Version mismatch: installed=$CURRENT_VER module=$PKG_VER"
    fi
  fi
fi

# ---- Install or update APK ----
install_apk() {

  [ -f "$MODULE_APK" ] || fail_install "Required APK not found"

  print_msg "* Installing $APP_PACKAGE"

  prev_v1=$(settings get global verifier_verify_adb_installs)
  prev_v2=$(settings get global package_verifier_enable)

  settings put global verifier_verify_adb_installs 0
  settings put global package_verifier_enable 0

  APK_SIZE=$(stat -c "%s" "$MODULE_APK")

  if ! SESSION=$(pm_call install-create --user 0 -r -d -S "$APK_SIZE"); then
    fail_install "Session creation failed"
  fi

  SESSION=${SESSION#*[}
  SESSION=${SESSION%]*}

  set_perm "$MODULE_APK" 1000 1000 0644 u:object_r:apk_data_file:s0

  if ! pm_call install-write -S "$APK_SIZE" "$SESSION" "$APP_PACKAGE.apk" "$MODULE_APK"; then
    fail_install "APK write failed"
  fi

  RESULT=$(pm_call install-commit "$SESSION")

  echo "$RESULT" | grep -q INSTALL_FAILED && {
    pm_call uninstall-system-updates "$APP_PACKAGE"

    if [ "$SYSTEM_APP" = false ]; then
      pm_call uninstall -k --user 0 "$APP_PACKAGE"
      install_apk
      return
    else
      fail_install "System app conflict detected"
    fi
  }

  settings put global verifier_verify_adb_installs "$prev_v1"
  settings put global package_verifier_enable "$prev_v2"

  NEW_PATH=$(pm_call path "$APP_PACKAGE")
  INSTALL_PATH=${NEW_PATH##*:}
  INSTALL_PATH=${INSTALL_PATH%/*}
}

if [ "$INSTALL_REQUIRED" = true ]; then
  install_apk
fi

# ---- Native library extraction ----
LIB_DIR="$INSTALL_PATH/lib/$DEVICE_ARCH"

if [ "$INSTALL_REQUIRED" = true ] || [ -z "$(ls -A "$LIB_DIR" 2>/dev/null)" ]; then
  print_msg "* Extracting native libraries"

  mkdir -p "$LIB_DIR"
  rm -f "$LIB_DIR"/* 2>/dev/null

  unzip -o -j "$MODULE_APK" "lib/${LIB_SUBDIR}/*" -d "$LIB_DIR" >/dev/null \
    || fail_install "Native library extraction failed"

  set_perm_recursive "$INSTALL_PATH/lib" 1000 1000 0755 0755 u:object_r:apk_data_file:s0
fi

# ---- Prepare patched APK ----
print_msg "* Preparing runtime mount"
set_perm "$PATCH_APK" 1000 1000 0644 u:object_r:apk_data_file:s0

mkdir -p "$MOUNT_DIR"
mv -f "$PATCH_APK" "$RUNTIME_APK"

# ---- Bind mount patched APK ----
print_msg "* Mounting patched APK"

if ! run_mount mount -o bind "$RUNTIME_APK" "$INSTALL_PATH/base.apk"; then
  print_msg "Mount operation failed"
fi

am force-stop "$APP_PACKAGE"

# ---- Optimize package ----
print_msg "* Optimizing application"
cmd package compile -m speed-profile -f "$APP_PACKAGE"

# ---- KernelSU compatibility ----
if [ "$KSU" ]; then
  UID_LINE=$(dumpsys package "$APP_PACKAGE" | grep -m1 uid)
  APP_UID=${UID_LINE#*=}
  APP_UID=${APP_UID%% *}

  if [ -z "$APP_UID" ]; then
    UID_LINE=$(dumpsys package "$APP_PACKAGE" | grep -m1 userId)
    APP_UID=${UID_LINE#*=}
    APP_UID=${APP_UID%% *}
  fi

  if [ -n "$APP_UID" ]; then
    "$MODPATH/bin/$DEVICE_ARCH/ksu_profile" "$APP_UID" "$APP_PACKAGE" >/dev/null 2>&1
  else
    print_msg "Unable to determine application UID"
  fi
fi

# ---- Cleanup ----
rm -rf "$MODPATH/bin" "$MODULE_APK"

print_msg "* Installation complete"
