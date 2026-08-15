#!/bin/sh
# Install or upgrade the checksum-verified Clavenar Lite native service.
set -eu

PROGRAM=clavenar-lite
VERSION=1.0.0
DEFAULT_RELEASE_ROOT="https://github.com/clavenar/clavenar-lite/releases/download"
RELEASE_ROOT="${CLAVENAR_LITE_RELEASE_ROOT:-$DEFAULT_RELEASE_ROOT}"
INSTALL_ROOT=/
UPSTREAM_URL=http://localhost:9000/mcp
LISTEN_ADDRESS=127.0.0.1
LISTEN_PORT=8088
START_SERVICE=1
UPSTREAM_EXPLICIT=0

usage() {
    cat <<'EOF'
usage: install.sh [options]

Install or atomically upgrade the native Clavenar Lite service.

  --version VERSION       install an exact stable version
  --release-root URL      override the immutable release download root
  --upstream URL          seed the upstream URL on first install
  --bind ADDRESS          seed the listen address (default: 127.0.0.1)
  --port PORT             seed the listen port (default: 8088)
  --root DIRECTORY        stage under an alternate root without systemd
  --no-start              install files without enabling or starting service
  -h, --help              show this help

Configuration and ledger data are preserved when this installer is rerun.
EOF
}

die() {
    printf '%s\n' "[clavenar-lite-install] ERROR: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|--release-root|--upstream|--bind|--port|--root)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            case "$1" in
                --version) VERSION=$2 ;;
                --release-root) RELEASE_ROOT=$2 ;;
                --upstream) UPSTREAM_URL=$2; UPSTREAM_EXPLICIT=1 ;;
                --bind) LISTEN_ADDRESS=$2 ;;
                --port) LISTEN_PORT=$2 ;;
                --root) INSTALL_ROOT=$2 ;;
            esac
            shift 2
            ;;
        --no-start)
            START_SERVICE=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
    die "version must be stable numeric SemVer"
case "$RELEASE_ROOT" in
    https://*) ;;
    http://127.0.0.1:*|http://localhost:*)
        [ "$INSTALL_ROOT" != / ] || die "HTTP release roots are test-only"
        ;;
    *) die "release root must use HTTPS" ;;
esac
RELEASE_ROOT=${RELEASE_ROOT%/}
case "$INSTALL_ROOT" in
    /*) ;;
    *) die "install root must be an absolute path" ;;
esac
case "$INSTALL_ROOT" in
    *../*|*/..|*/./*|*/.) die "install root must be normalized" ;;
esac
printf '%s\n' "$UPSTREAM_URL" | grep -Eq '^https?://[^[:space:]]+$' ||
    die "upstream must be an HTTP(S) URL without whitespace"
printf '%s\n' "$LISTEN_ADDRESS" | grep -Eq '^[0-9A-Fa-f:.]+$' ||
    die "bind address must be an IP literal"
printf '%s\n' "$LISTEN_PORT" | grep -Eq '^[0-9]+$' ||
    die "port must be numeric"
[ "$LISTEN_PORT" -ge 1 ] 2>/dev/null && [ "$LISTEN_PORT" -le 65535 ] 2>/dev/null ||
    die "port must be within 1..65535"

for command_name in curl sha256sum tar install mktemp uname; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "$command_name is required"
done
if [ "$INSTALL_ROOT" = / ] && [ "$(id -u)" -ne 0 ]; then
    die "run the installer as root (for example: curl ... | sudo sh)"
fi

case "$(uname -m)" in
    x86_64|amd64) ARCHITECTURE=x86_64 ;;
    aarch64|arm64) ARCHITECTURE=aarch64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac
ASSET="$PROGRAM-$VERSION-$ARCHITECTURE-linux-musl.tar.gz"
ASSET_URL="$RELEASE_ROOT/v$VERSION/$ASSET"

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/clavenar-lite-install.XXXXXX")
cleanup() {
    rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' "[clavenar-lite-install] Downloading $ASSET"
download() {
    source_url=$1
    destination=$2
    case "$RELEASE_ROOT" in
        https://*)
            curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
                "$source_url" --output "$destination"
            ;;
        *)
            curl -fsSL --proto '=http' --proto-redir '=http' \
                "$source_url" --output "$destination"
            ;;
    esac
}
download "$ASSET_URL" "$temporary_dir/$ASSET"
download "$ASSET_URL.sha256" "$temporary_dir/$ASSET.sha256"
checksum_line=$(cat "$temporary_dir/$ASSET.sha256")
printf '%s\n' "$checksum_line" |
    grep -Eq "^[0-9a-f]{64}  $ASSET$" ||
    die "checksum sidecar has an unexpected format"
(
    cd "$temporary_dir"
    sha256sum -c "$ASSET.sha256"
)
archive_entries=$(tar -tzf "$temporary_dir/$ASSET" | LC_ALL=C sort)
expected_entries=$(printf '%s\n' LICENSE NOTICE clavenar-lite | LC_ALL=C sort)
[ "$archive_entries" = "$expected_entries" ] ||
    die "release archive has an unexpected file inventory"
tar -xzf "$temporary_dir/$ASSET" -C "$temporary_dir"
"$temporary_dir/$PROGRAM" --version | grep -F " $VERSION" >/dev/null ||
    die "downloaded binary version does not match $VERSION"

if [ "$INSTALL_ROOT" = / ]; then
    root_prefix=
else
    install -d -m 0755 "$INSTALL_ROOT"
    INSTALL_ROOT=$(cd "$INSTALL_ROOT" && pwd -P)
    root_prefix=${INSTALL_ROOT%/}
fi
binary_path="$root_prefix/usr/local/bin/$PROGRAM"
license_dir="$root_prefix/usr/local/share/licenses/$PROGRAM"
config_dir="$root_prefix/etc/$PROGRAM"
config_path="$config_dir/config.env"
data_dir="$root_prefix/var/lib/$PROGRAM"
unit_dir="$root_prefix/etc/systemd/system"
unit_path="$unit_dir/$PROGRAM.service"

for managed_directory in "$license_dir" "$config_dir" "$data_dir" "$unit_dir"; do
    [ ! -L "$managed_directory" ] || die "managed directory must not be a symlink: $managed_directory"
done

install -d -m 0755 "$(dirname "$binary_path")" "$license_dir" "$unit_dir"
install -m 0755 "$temporary_dir/$PROGRAM" "$binary_path.new"
mv -f "$binary_path.new" "$binary_path"
install -m 0644 "$temporary_dir/LICENSE" "$license_dir/LICENSE"
install -m 0644 "$temporary_dir/NOTICE" "$license_dir/NOTICE"

if [ "$INSTALL_ROOT" = / ]; then
    command -v systemctl >/dev/null 2>&1 || die "systemd is required"
    if ! id "$PROGRAM" >/dev/null 2>&1; then
        command -v useradd >/dev/null 2>&1 || die "useradd is required"
        nologin_shell=$(command -v nologin 2>/dev/null || printf '%s\n' /usr/sbin/nologin)
        useradd --system --user-group --home-dir "$data_dir" \
            --shell "$nologin_shell" "$PROGRAM"
    fi
    [ "$(id -gn "$PROGRAM")" = "$PROGRAM" ] ||
        die "existing $PROGRAM account does not use its dedicated group"
    install -d -m 0750 -o "$PROGRAM" -g "$PROGRAM" "$data_dir"
    install -d -m 0750 -o root -g "$PROGRAM" "$config_dir"
else
    install -d -m 0750 "$data_dir" "$config_dir"
fi

[ ! -L "$config_path" ] || die "configuration must not be a symlink: $config_path"
if [ -e "$config_path" ]; then
    [ -f "$config_path" ] || die "configuration must be a regular file: $config_path"
fi

if [ ! -e "$config_path" ]; then
    config_temporary=$(mktemp "$config_dir/.config.env.XXXXXX")
    chmod 0640 "$config_temporary"
    {
        printf 'CLAVENAR_LITE_BIND=%s\n' "$LISTEN_ADDRESS"
        printf 'CLAVENAR_LITE_PORT=%s\n' "$LISTEN_PORT"
        printf 'CLAVENAR_LITE_UPSTREAM_URL=%s\n' "$UPSTREAM_URL"
        printf 'CLAVENAR_LITE_MODE=observe\n'
        printf 'CLAVENAR_LITE_LEDGER=/var/lib/clavenar-lite/clavenar-lite.db\n'
        printf 'RUST_LOG=info\n'
    } > "$config_temporary"
    if [ "$INSTALL_ROOT" = / ]; then
        chown root:"$PROGRAM" "$config_temporary"
    fi
    mv -f "$config_temporary" "$config_path"
elif [ "$UPSTREAM_EXPLICIT" -eq 1 ]; then
    printf '%s\n' \
        "[clavenar-lite-install] Existing configuration preserved; edit $config_path to change upstream"
fi

unit_temporary=$(mktemp "$unit_dir/.clavenar-lite.service.XXXXXX")
cat > "$unit_temporary" <<'EOF'
[Unit]
Description=Clavenar Lite agent-security proxy
Documentation=https://github.com/clavenar/clavenar-lite
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=clavenar-lite
Group=clavenar-lite
WorkingDirectory=/var/lib/clavenar-lite
EnvironmentFile=/etc/clavenar-lite/config.env
ExecStart=/usr/local/bin/clavenar-lite start
Restart=on-failure
RestartSec=5s
UMask=0077
NoNewPrivileges=yes
PrivateDevices=yes
PrivateTmp=yes
ProtectClock=yes
ProtectControlGroups=yes
ProtectHome=yes
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/clavenar-lite
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$unit_temporary"
mv -f "$unit_temporary" "$unit_path"

if [ "$INSTALL_ROOT" = / ]; then
    systemctl daemon-reload
    if [ "$START_SERVICE" -eq 1 ]; then
        systemctl enable "$PROGRAM.service"
        systemctl restart "$PROGRAM.service"
        systemctl is-active --quiet "$PROGRAM.service" ||
            die "service did not become active; inspect journalctl -u $PROGRAM"
        printf '%s\n' "[clavenar-lite-install] Service active; endpoint is configured in $config_path"
    else
        printf '%s\n' "[clavenar-lite-install] Installed without starting the service"
    fi
else
    printf '%s\n' "[clavenar-lite-install] Staged under $INSTALL_ROOT (systemd was not invoked)"
fi
printf '%s\n' "[clavenar-lite-install] Installed $PROGRAM $VERSION"
printf '%s\n' "[clavenar-lite-install] Configuration: $config_path"
printf '%s\n' "[clavenar-lite-install] Ledger data: $data_dir"
