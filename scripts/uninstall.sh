#!/bin/sh
# Remove the Clavenar Lite native service, preserving customer state by default.
set -eu

PROGRAM=clavenar-lite
INSTALL_ROOT=/
PURGE=0

usage() {
    cat <<'EOF'
usage: uninstall.sh [--purge] [--root DIRECTORY]

Remove the native Clavenar Lite service and executable. Configuration, ledger
data, and the service account are preserved unless --purge is supplied.
EOF
}

die() {
    printf '%s\n' "[clavenar-lite-uninstall] ERROR: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --purge) PURGE=1; shift ;;
        --root)
            [ "$#" -ge 2 ] || die "--root requires a value"
            INSTALL_ROOT=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

case "$INSTALL_ROOT" in
    /*) ;;
    *) die "install root must be an absolute path" ;;
esac
case "$INSTALL_ROOT" in
    *../*|*/..|*/./*|*/.) die "install root must be normalized" ;;
esac
if [ "$INSTALL_ROOT" = / ]; then
    [ "$(id -u)" -eq 0 ] || die "run the uninstaller as root"
    root_prefix=
else
    [ -d "$INSTALL_ROOT" ] || die "install root does not exist"
    INSTALL_ROOT=$(cd "$INSTALL_ROOT" && pwd -P)
    root_prefix=${INSTALL_ROOT%/}
fi

binary_path="$root_prefix/usr/local/bin/$PROGRAM"
license_dir="$root_prefix/usr/local/share/licenses/$PROGRAM"
config_dir="$root_prefix/etc/$PROGRAM"
data_dir="$root_prefix/var/lib/$PROGRAM"
unit_path="$root_prefix/etc/systemd/system/$PROGRAM.service"

if [ "$INSTALL_ROOT" = / ] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$PROGRAM.service" >/dev/null 2>&1 || true
fi
rm -f "$unit_path" "$binary_path"
rm -rf "$license_dir"
if [ "$INSTALL_ROOT" = / ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl reset-failed "$PROGRAM.service" >/dev/null 2>&1 || true
fi

if [ "$PURGE" -eq 1 ]; then
    rm -rf "$config_dir" "$data_dir"
    if [ "$INSTALL_ROOT" = / ]; then
        if id "$PROGRAM" >/dev/null 2>&1; then
            userdel "$PROGRAM"
        fi
        if command -v getent >/dev/null 2>&1 && \
            getent group "$PROGRAM" >/dev/null 2>&1; then
            groupdel "$PROGRAM" >/dev/null 2>&1 || true
        fi
    fi
    printf '%s\n' "[clavenar-lite-uninstall] Removed service, configuration, and ledger data"
else
    printf '%s\n' "[clavenar-lite-uninstall] Removed service and executable"
    printf '%s\n' "[clavenar-lite-uninstall] Preserved configuration: $config_dir"
    printf '%s\n' "[clavenar-lite-uninstall] Preserved ledger data: $data_dir"
fi
