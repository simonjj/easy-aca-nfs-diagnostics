#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPSTREAM_DIR="${REPO_ROOT}/vendor/NfsDiagnostics"

SERVER=""
EXPORT_PATH=""
MOUNT_POINT="/mnt/aca-nfs-diagnostics"
MOUNT_OPTIONS="vers=4.1,sec=sys"
MOUNT_TIMEOUT_SECONDS=120
POST_MOUNT_CAPTURE_SECONDS=20
INSTALL_DEPENDENCIES=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/Run-NfsClientCapture.sh \
    --server <storage-account>.file.core.windows.net \
    --export /<storage-account>/<share> \
    [--mount-point /mnt/aca-nfs-diagnostics] \
    [--mount-options vers=4.1,sec=sys] \
    [--mount-timeout-seconds 120] \
    [--post-mount-capture-seconds 20] \
    [--install-dependencies]

Run this on a fresh or newly rebooted customer-controlled Linux host. Do not run
it inside Azure Container Apps; the required host state is not available there.
EOF
}

install_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      nfs-common trace-cmd tcpdump zip iproute2 kmod util-linux procps
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nfs-utils trace-cmd tcpdump zip iproute kmod util-linux procps-ng
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nfs-utils trace-cmd tcpdump zip iproute kmod util-linux procps-ng
  elif command -v tdnf >/dev/null 2>&1; then
    tdnf install -y nfs-utils trace-cmd tcpdump zip iproute kmod util-linux procps-ng
  else
    echo "Unsupported package manager. Install the dependencies documented in vendor/NfsDiagnostics/README." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)
      SERVER="${2:-}"
      shift 2
      ;;
    --export)
      EXPORT_PATH="${2:-}"
      shift 2
      ;;
    --mount-point)
      MOUNT_POINT="${2:-}"
      shift 2
      ;;
    --mount-options)
      MOUNT_OPTIONS="${2:-}"
      shift 2
      ;;
    --mount-timeout-seconds)
      MOUNT_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --post-mount-capture-seconds)
      POST_MOUNT_CAPTURE_SECONDS="${2:-}"
      shift 2
      ;;
    --install-dependencies)
      INSTALL_DEPENDENCIES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

if [[ -z "${SERVER}" || -z "${EXPORT_PATH}" ]]; then
  usage
  exit 2
fi

if [[ "${SERVER}" == *:* ]]; then
  echo "--server must not include a colon or export path." >&2
  exit 2
fi

if [[ "${EXPORT_PATH}" != /* ]]; then
  echo "--export must begin with '/'." >&2
  exit 2
fi

for value in "${MOUNT_TIMEOUT_SECONDS}" "${POST_MOUNT_CAPTURE_SECONDS}"; do
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "Timeout values must be non-negative integers." >&2
    exit 2
  fi
done

if [[ "${INSTALL_DEPENDENCIES}" -eq 1 ]]; then
  install_dependencies
fi

required_commands=(mount umount mountpoint timeout trace-cmd tcpdump zip ss python3)
for command_name in "${required_commands[@]}"; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
done

if [[ ! -f "${UPSTREAM_DIR}/nfsclientlogs.sh" || ! -f "${UPSTREAM_DIR}/trace-nfsbpf" ]]; then
  echo "Vendored NFS diagnostics files are missing from ${UPSTREAM_DIR}." >&2
  exit 1
fi

mkdir -p "${MOUNT_POINT}"
if mountpoint -q "${MOUNT_POINT}"; then
  echo "Mount point is already mounted. Use a clean mount point for a first-mount capture." >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%d_%H%M%S)"
work_dir="$(pwd)/nfs-capture-${timestamp}"
mkdir -p "${work_dir}"
cp "${UPSTREAM_DIR}/nfsclientlogs.sh" "${UPSTREAM_DIR}/trace-nfsbpf" "${work_dir}/"
chmod +x "${work_dir}/nfsclientlogs.sh" "${work_dir}/trace-nfsbpf"

cd "${work_dir}"

cat > capture-context.txt <<EOF
captureStartedUtc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
server=${SERVER}
export=${EXPORT_PATH}
mountPoint=${MOUNT_POINT}
mountOptions=${MOUNT_OPTIONS}
mountTimeoutSeconds=${MOUNT_TIMEOUT_SECONDS}
hostUptime=$(cat /proc/uptime)
kernel=$(uname -a)
EOF

./nfsclientlogs.sh v4 start CaptureNetwork

set +e
timeout "${MOUNT_TIMEOUT_SECONDS}" \
  mount -t nfs4 -o "${MOUNT_OPTIONS}" "${SERVER}:${EXPORT_PATH}" "${MOUNT_POINT}" \
  > output/mount-command.txt 2>&1
mount_status=$?
set -e

{
  echo "mountExitCode=${mount_status}"
  echo "mountCompletedUtc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  cat capture-context.txt
} > output/capture-context.txt

if mountpoint -q "${MOUNT_POINT}"; then
  {
    echo "Mount succeeded."
    mount | grep " ${MOUNT_POINT} " || true
    df -T "${MOUNT_POINT}" || true
    find "${MOUNT_POINT}" -mindepth 1 -maxdepth 1 -print | head -100 || true
  } >> output/mount-command.txt 2>&1

  sleep "${POST_MOUNT_CAPTURE_SECONDS}"
  umount "${MOUNT_POINT}"
else
  echo "Mount did not complete successfully; preserving the failure capture." >> output/mount-command.txt
fi

./nfsclientlogs.sh stop

archive="$(find "${work_dir}" -maxdepth 1 -type f -name 'output_*.zip' -print | sort | tail -1)"
if [[ -z "${archive}" ]]; then
  echo "The canonical collector did not create an archive." >&2
  exit 1
fi

echo "Capture complete."
echo "Mount exit code: ${mount_status}"
echo "Bundle: ${archive}"
