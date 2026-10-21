#!/bin/sh
set -eu

service_name="dev.tomonari.inputmethod.Shizuku.ConverterServer"
default_app_path="${BUILT_PRODUCTS_DIR:-/tmp/ShizukuDerivedData/Build/Products/Debug}/Shizuku.app"
app_path="${1:-${default_app_path}}"
server_path="${app_path}/Contents/Helpers/Shizuku.app/ConverterServer"
# Older builds used an unbundled helper directory.
if [ ! -x "${server_path}" ]; then
    server_path="${app_path}/Contents/Helpers/ConverterServer/ConverterServer"
fi
agent_dir="${HOME}/Library/LaunchAgents"
agent_path="${agent_dir}/${service_name}.plist"
gui_domain="gui/$(id -u)"
script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "${server_path}" ]; then
    echo "ConverterServer not found: ${server_path}" >&2
    echo "Build Shizuku first, or pass the app bundle path as the first argument." >&2
    exit 1
fi

"${script_dir}/write_converter_server_launch_agent.sh" "${agent_path}" "${server_path}" "${service_name}"

launchctl bootout "${gui_domain}" "${agent_path}" >/dev/null 2>&1 || true
launchctl bootstrap "${gui_domain}" "${agent_path}"
launchctl kickstart -k "${gui_domain}/${service_name}"
launchctl print "${gui_domain}/${service_name}" >/dev/null
# Older binaries ignore CLI arguments and would start a second Server. Only run
# the waiting mode when its versioned readiness contract is embedded in the binary.
if /usr/bin/grep -aFq 'ConverterServer: input-ready-v1' "${server_path}"; then
    "${server_path}" --wait-ready
else
    echo "Legacy ConverterServer started; conversion readiness is unverified." >&2
fi

echo "Installed and started ${service_name}"
echo "${agent_path}"
