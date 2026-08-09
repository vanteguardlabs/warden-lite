#!/usr/bin/env bash
# Exercise both static assets and the complete data-preserving host lifecycle.
set -euo pipefail

usage() {
    echo "usage: smoke-native-install.sh VERSION ASSET_DIRECTORY [INSTALLER_DIRECTORY]" >&2
    exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
version="$1"
asset_directory="$2"
if [ "$#" -eq 3 ]; then
    script_root="$(cd "$3" && pwd -P)"
else
    script_root="$(cd "$(dirname "$0")" && pwd -P)"
fi

case "$asset_directory" in
    /*) ;;
    *) asset_directory="$(cd "$asset_directory" && pwd -P)" ;;
esac
[ -d "$asset_directory" ] || usage
[ -x "$script_root/install.sh" ] && [ -x "$script_root/uninstall.sh" ] || usage

for command_name in curl file python3 sha256sum tar; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "smoke-native-install: $command_name is required" >&2
        exit 1
    }
done

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/clavenar-lite-native-smoke.XXXXXX")"
server_pid=""
runtime_pid=""
cleanup() {
    if [ -n "$runtime_pid" ]; then
        kill -INT "$runtime_pid" >/dev/null 2>&1 || true
        wait "$runtime_pid" >/dev/null 2>&1 || true
    fi
    if [ -n "$server_pid" ]; then
        kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

release_directory="$temporary_dir/server/v$version"
mkdir -p "$release_directory"
for architecture in x86_64 aarch64; do
    asset="clavenar-lite-$version-$architecture-linux-musl.tar.gz"
    [ -f "$asset_directory/$asset" ] && [ -f "$asset_directory/$asset.sha256" ] || {
        echo "smoke-native-install: missing $architecture release assets" >&2
        exit 1
    }
    ln -s "$asset_directory/$asset" "$release_directory/$asset"
    ln -s "$asset_directory/$asset.sha256" "$release_directory/$asset.sha256"
    (
        cd "$asset_directory"
        sha256sum -c "$asset.sha256"
    )
    archive_entries="$(tar -tzf "$asset_directory/$asset" | LC_ALL=C sort)"
    expected_entries="$(printf '%s\n' LICENSE NOTICE clavenar-lite | LC_ALL=C sort)"
    [ "$archive_entries" = "$expected_entries" ] || {
        echo "smoke-native-install: unexpected $architecture archive inventory" >&2
        exit 1
    }
    architecture_root="$temporary_dir/$architecture"
    mkdir "$architecture_root"
    tar -xzf "$asset_directory/$asset" -C "$architecture_root" clavenar-lite
    file "$architecture_root/clavenar-lite" | grep -Eq 'statically linked|static-pie linked' || {
        echo "smoke-native-install: $architecture binary is not static" >&2
        exit 1
    }
done
file "$temporary_dir/x86_64/clavenar-lite" | grep -Eiq 'x86-64|x86_64' || {
    echo "smoke-native-install: x86_64 asset architecture drifted" >&2
    exit 1
}
file "$temporary_dir/aarch64/clavenar-lite" | grep -Eiq 'aarch64|ARM aarch64' || {
    echo "smoke-native-install: arm64 asset architecture drifted" >&2
    exit 1
}

server_port="$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"
python3 -m http.server "$server_port" --bind 127.0.0.1 \
    --directory "$temporary_dir/server" >"$temporary_dir/server.log" 2>&1 &
server_pid=$!

for _ in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:$server_port/v$version/" >/dev/null; then
        break
    fi
    sleep 0.25
done
curl -fsS "http://127.0.0.1:$server_port/v$version/" >/dev/null

install_root="$temporary_dir/root"
"$script_root/install.sh" \
    --version "$version" \
    --release-root "http://127.0.0.1:$server_port" \
    --root "$install_root" \
    --no-start
installed_binary="$install_root/usr/local/bin/clavenar-lite"
[ -x "$installed_binary" ]
[ -s "$install_root/etc/systemd/system/clavenar-lite.service" ]
[ -s "$install_root/etc/clavenar-lite/config.env" ]
config_checksum="$(sha256sum "$install_root/etc/clavenar-lite/config.env")"

runtime_port="$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"
runtime_directory="$temporary_dir/runtime-without-policy-files"
mkdir "$runtime_directory"
(
    cd "$runtime_directory"
    exec "$installed_binary" start \
        --bind 127.0.0.1 \
        --port "$runtime_port" \
        --upstream http://127.0.0.1:9/mcp \
        --ledger :memory: \
        --mode observe
) >"$temporary_dir/runtime.log" 2>&1 &
runtime_pid=$!
for _ in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:$runtime_port/health" >/dev/null; then
        break
    fi
    sleep 0.25
done
curl -fsS "http://127.0.0.1:$runtime_port/health" >/dev/null
grep -F 'policies=embedded:governance.rego' "$temporary_dir/runtime.log" >/dev/null
kill -INT "$runtime_pid"
wait "$runtime_pid"
runtime_pid=""

"$script_root/uninstall.sh" --root "$install_root"
[ ! -e "$installed_binary" ]
[ -s "$install_root/etc/clavenar-lite/config.env" ]
[ -d "$install_root/var/lib/clavenar-lite" ]

"$script_root/install.sh" \
    --version "$version" \
    --release-root "http://127.0.0.1:$server_port" \
    --root "$install_root" \
    --no-start
[ "$(sha256sum "$install_root/etc/clavenar-lite/config.env")" = "$config_checksum" ]
"$script_root/uninstall.sh" --root "$install_root" --purge
[ ! -e "$install_root/etc/clavenar-lite" ]
[ ! -e "$install_root/var/lib/clavenar-lite" ]

echo "smoke-native-install: PASS ($version, x86_64 + aarch64, embedded policy, preserve + purge)"
