#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

readonly NAME="fix-dkms"
readonly VERSION="2.0.0"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
RUNNING="$(uname -r)"
ARCH="$(uname -m)"
FLAVOR="${RUNNING#*-}"
if [[ "$FLAVOR" =~ ^[0-9]+-(.+)$ ]]; then FLAVOR="${BASH_REMATCH[1]}"; fi
readonly SELF RUNNING ARCH FLAVOR
readonly DKMS_TREE="/var/lib/dkms"
readonly LOG_DIR="/var/log/$NAME"
readonly LOCK_FILE="/run/$NAME.lock"
readonly HOOK_BIN="/usr/local/sbin/$NAME"
readonly HOOK_CONF="/etc/apt/apt.conf.d/99$NAME"
readonly APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
readonly ORIG_ARGS=("$@")

MODE="fix"
ASSUME_YES=0
QUIET=0
DO_UPDATE=1
DO_PRUNE=0
KEEP=3
FORCE=0
DM_POLICY="ask"
PURGE_ORPHANS=0
USE_COLOR=1
LOG_FILE=""
TEE_PID=""
NEWEST=""
NVIDIA_WAS_LOADED=0
NEED_REBOOT=0

declare -a REQ_KERNELS=() KERNELS=() TARGETS=() MODULES=() BROKEN=() EXTRA_VERSIONS=() ORPHANS=() EXPECTED=() PROBLEMS=() WARNINGS=()
declare -A STATE=() REBUILT=() SKIPPED=() KO_NAME=() KO_VERSION=()
declare -a KO_FILES=()
KO_INDEXED=0

C_R="" C_G="" C_Y="" C_B="" C_D="" C_0=""

usage() {
    cat <<EOF
$NAME $VERSION - repair and verify DKMS kernel modules on Debian-based systems

Usage: sudo $NAME [options]

Modes:
  (default)             repair packages, headers, toolchain, DKMS builds and module loading
  -n, --check           read-only diagnosis, exit status 1 when problems are found
      --install-hook    install as $HOOK_BIN and run --check after every APT operation
      --remove-hook     remove the APT hook and the installed copy

Targets:
  -a, --all             every installed kernel (default)
  -c, --current         only the running kernel ($RUNNING)
  -k, --kernel VER      a specific kernel, repeatable

Repair options:
  -f, --force           rebuild modules even when already installed
      --no-update       skip apt-get update
      --prune           purge old kernels, keeping the newest N plus the running one
      --keep N          kernels kept by --prune (default: $KEEP)
      --purge-orphans   delete unregistered DKMS source trees from /usr/src
      --restart-dm      restart the display manager at the end without asking
      --no-restart-dm   never touch the display manager

General:
  -y, --yes             answer yes to every prompt
  -q, --quiet           print only problems
      --no-color        disable colors
  -V, --version         print version
  -h, --help            show this help

Exit status: 0 healthy, 1 problems remain, 2 usage error.
EOF
}

setup_colors() {
    if (( USE_COLOR )) && [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        C_R=$'\e[1;31m' C_G=$'\e[1;32m' C_Y=$'\e[1;33m' C_B=$'\e[1;34m' C_D=$'\e[2m' C_0=$'\e[0m'
    fi
}

say()  { (( QUIET )) || printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
info() { (( QUIET )) || printf '    %s\n' "$*"; }
ok()   { (( QUIET )) || printf '    %s[ ok ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() {
    WARNINGS+=("$*")
    (( QUIET )) || printf '    %s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2
}
fail() {
    PROBLEMS+=("$*")
    if (( QUIET )); then
        printf '%s: %s\n' "$NAME" "$*" >&2
    else
        printf '    %s[fail]%s %s\n' "$C_R" "$C_0" "$*" >&2
    fi
}
die() { printf '%s%s: fatal:%s %s\n' "$C_R" "$NAME" "$C_0" "$*" >&2; exit 1; }
usage_error() { printf '%s: %s\nTry: %s --help\n' "$NAME" "$*" "$NAME" >&2; exit 2; }
run() {
    (( QUIET )) || printf '    %s$ %s%s\n' "$C_D" "$*" "$C_0"
    "$@"
}

on_error() {
    local rc=$? line="$1" cmd="$2"
    printf '%s%s: unexpected failure (exit %d) at line %s: %s%s\n' "$C_R" "$NAME" "$rc" "$line" "$cmd" "$C_0" >&2
    if [[ -n "$LOG_FILE" ]]; then printf '%s: full log: %s\n' "$NAME" "$LOG_FILE" >&2; fi
}

on_signal() {
    printf '\n%s: interrupted\n' "$NAME" >&2
    exit 130
}

on_exit() {
    local rc=$?
    if [[ -n "$TEE_PID" ]]; then
        exec 1>&- 2>&-
        wait "$TEE_PID" 2>/dev/null || true
    fi
    exit "$rc"
}

confirm() {
    local question="$1" default="${2:-n}" hint="[y/N]" reply=""
    if [[ "$default" == y ]]; then hint="[Y/n]"; fi
    if (( ASSUME_YES )); then return 0; fi
    if [[ ! -t 0 ]]; then [[ "$default" == y ]]; return; fi
    read -r -p "    $question $hint " reply || true
    reply="${reply:-$default}"
    [[ "${reply,,}" == y || "${reply,,}" == yes ]]
}

in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then return 0; fi
    done
    return 1
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -n|--check) MODE="check" ;;
            --install-hook) MODE="install-hook" ;;
            --remove-hook) MODE="remove-hook" ;;
            -a|--all) REQ_KERNELS=() ;;
            -c|--current) REQ_KERNELS+=("$RUNNING") ;;
            -k|--kernel)
                if (( $# < 2 )) || [[ -z "$2" ]]; then usage_error "$1 requires a kernel version"; fi
                REQ_KERNELS+=("$2")
                shift
                ;;
            --kernel=*) REQ_KERNELS+=("${1#*=}") ;;
            -f|--force) FORCE=1 ;;
            --no-update) DO_UPDATE=0 ;;
            --prune) DO_PRUNE=1 ;;
            --keep)
                if (( $# < 2 )) || [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then usage_error "--keep requires a positive integer"; fi
                KEEP="$2"
                shift
                ;;
            --keep=*)
                KEEP="${1#*=}"
                if [[ ! "$KEEP" =~ ^[1-9][0-9]*$ ]]; then usage_error "--keep requires a positive integer"; fi
                ;;
            --purge-orphans) PURGE_ORPHANS=1 ;;
            --restart-dm) DM_POLICY="always" ;;
            --no-restart-dm) DM_POLICY="never" ;;
            -y|--yes) ASSUME_YES=1 ;;
            -q|--quiet) QUIET=1 ;;
            --no-color) USE_COLOR=0 ;;
            -V|--version) printf '%s %s\n' "$NAME" "$VERSION"; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            *) usage_error "unknown option: $1" ;;
        esac
        shift
    done
}

require_root() {
    if (( EUID == 0 )); then return 0; fi
    command -v sudo >/dev/null 2>&1 || die "root privileges are required"
    exec sudo -- "$SELF" "${ORIG_ARGS[@]}"
}

require_debian() {
    command -v dpkg-query >/dev/null 2>&1 || die "dpkg is required"
    command -v apt-get >/dev/null 2>&1 || die "apt-get is required"
}

acquire_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another $NAME instance is already running"
}

setup_log() {
    mkdir -p "$LOG_DIR"
    chmod 0750 "$LOG_DIR"
    find "$LOG_DIR" -name '*.log' -type f -mtime +30 -delete 2>/dev/null || true
    LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE")) 2>&1
    TEE_PID=$!
}

pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == installed ]]
}

pkg_available() {
    apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" { found = 1 } END { exit !found }'
}

pkg_is_auto() {
    apt-mark showauto "$1" 2>/dev/null | grep -qx -- "$1"
}

pkg_owner() {
    local out
    out="$(dpkg-query -S "$1" 2>/dev/null | head -n1 || true)"
    if [[ -z "$out" ]]; then return 1; fi
    printf '%s\n' "${out%%[,:]*}"
}

pkg_busy() {
    if command -v fuser >/dev/null 2>&1; then
        fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1
        return
    fi
    pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr|synaptic' >/dev/null 2>&1
}

conf_value() {
    sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*[\"']?([^\"'[:space:]]+)[\"']?.*$/\1/p" "$2" 2>/dev/null | head -n1 || true
}

join_by() {
    local sep="$1" out=""
    shift
    if (( $# )); then
        out="$1"
        shift
        while (( $# )); do out+="$sep$1"; shift; done
    fi
    printf '%s' "$out"
}

ktag() {
    local -a tags=()
    if [[ "$1" == "$RUNNING" ]]; then tags+=("running"); fi
    if [[ "$1" == "$NEWEST" ]]; then tags+=("newest, GRUB default"); fi
    if (( ${#tags[@]} )); then printf ' [%s]' "$(join_by ", " "${tags[@]}")"; fi
}

discover_kernels() {
    local f k
    local -a found=()
    for f in /boot/vmlinuz-*; do
        k="${f#/boot/vmlinuz-}"
        case "$k" in *.old|*.bak|*.dpkg-*) continue ;; esac
        if [[ -d "/lib/modules/$k/kernel" ]]; then found+=("$k"); fi
    done
    if [[ -d "/lib/modules/$RUNNING/kernel" ]] && ! in_list "$RUNNING" "${found[@]}"; then found+=("$RUNNING"); fi
    KERNELS=()
    if (( ${#found[@]} )); then mapfile -t KERNELS < <(printf '%s\n' "${found[@]}" | sort -uV); fi
    NEWEST=""
    if (( ${#KERNELS[@]} )); then NEWEST="${KERNELS[-1]}"; fi
}

resolve_targets() {
    local k
    TARGETS=()
    if (( ${#REQ_KERNELS[@]} == 0 )); then
        TARGETS=("${KERNELS[@]}")
        return 0
    fi
    for k in "${REQ_KERNELS[@]}"; do
        if ! in_list "$k" "${KERNELS[@]}"; then usage_error "kernel '$k' is not installed (installed: ${KERNELS[*]})"; fi
        if ! in_list "$k" "${TARGETS[@]}"; then TARGETS+=("$k"); fi
    done
}

discover_modules() {
    local src base m v x best
    local -A versions=()
    MODULES=() BROKEN=() EXTRA_VERSIONS=()
    for src in "$DKMS_TREE"/*/*/source; do
        base="${src%/source}"
        v="${base##*/}"
        m="${base%/*}"
        m="${m##*/}"
        if [[ ! -e "$src" ]]; then
            BROKEN+=("$m/$v")
            continue
        fi
        versions["$m"]+="$v"$'\n'
    done
    for m in "${!versions[@]}"; do
        best="$(printf '%s' "${versions[$m]}" | sort -V | tail -n1)"
        MODULES+=("$m/$best")
        while IFS= read -r x; do
            if [[ -n "$x" && "$x" != "$best" ]]; then EXTRA_VERSIONS+=("$m/$x"); fi
        done <<<"${versions[$m]}"
    done
    if (( ${#MODULES[@]} )); then mapfile -t MODULES < <(printf '%s\n' "${MODULES[@]}" | sort); fi
}

find_installed_ko() {
    local k="$1" base="$2" hit=""
    hit="$(find "/lib/modules/$k/updates" "/lib/modules/$k/extra" -name "$base" -type f -print -quit 2>/dev/null || true)"
    if [[ -z "$hit" ]]; then
        hit="$(find "/lib/modules/$k/kernel" -name "$base" -type f -print -quit 2>/dev/null || true)"
    fi
    printf '%s' "$hit"
}

tree_state() {
    local mv="$1" k="$2" m="${1%/*}" v="${1#*/}" built link target f inst
    local -a kos=()
    built="$DKMS_TREE/$m/$v/$k/$ARCH/module"
    link="$DKMS_TREE/$m/kernel-$k-$ARCH"
    target=""
    if [[ -L "$link" ]]; then target="$(readlink "$link" 2>/dev/null || true)"; fi
    kos=("$built"/*.ko*)
    if (( ${#kos[@]} == 0 )); then
        if [[ "$target" == "$v/$k/$ARCH" ]]; then printf 'degraded'; else printf 'missing'; fi
        return 0
    fi
    if [[ "$target" != "$v/$k/$ARCH" ]]; then
        printf 'built'
        return 0
    fi
    for f in "${kos[@]}"; do
        inst="$(find_installed_ko "$k" "${f##*/}")"
        if [[ -z "$inst" ]] || ! cmp -s "$f" "$inst"; then
            printf 'degraded'
            return 0
        fi
    done
    printf 'installed'
}

load_dkms_state() {
    local mv m v d k link target
    STATE=()
    for mv in "${MODULES[@]}" "${EXTRA_VERSIONS[@]}"; do
        m="${mv%/*}"
        v="${mv#*/}"
        for d in "$DKMS_TREE/$m/$v"/*/"$ARCH"; do
            k="${d%/"$ARCH"}"
            k="${k##*/}"
            case "$k" in source|build|original_module) continue ;; esac
            STATE["$mv|$k"]="$(tree_state "$mv" "$k")"
        done
        for link in "$DKMS_TREE/$m"/kernel-*-"$ARCH"; do
            target="$(readlink "$link" 2>/dev/null || true)"
            if [[ "${target%%/*}" != "$v" ]]; then continue; fi
            k="${link##*/kernel-}"
            k="${k%-"$ARCH"}"
            if [[ -z "${STATE["$mv|$k"]:-}" ]]; then STATE["$mv|$k"]="degraded"; fi
        done
    done
}

state_of() {
    if [[ -n "${SKIPPED["$1|$2"]:-}" ]]; then printf 'excluded'; return 0; fi
    printf '%s' "${STATE["$1|$2"]:-missing}"
}

autoinstall_enabled() {
    local v
    v="$(conf_value AUTOINSTALL "$DKMS_TREE/${1%/*}/${1#*/}/source/dkms.conf")"
    [[ "${v,,}" == yes ]]
}

headers_state() {
    if [[ -f "/lib/modules/$1/build/Makefile" ]]; then
        printf 'ok'
    elif pkg_installed "linux-headers-$1"; then
        printf 'broken'
    elif pkg_available "linux-headers-$1"; then
        printf 'missing'
    else
        printf 'unavailable'
    fi
}

kernel_cc() {
    local text
    text="$(sed -n 's/^CONFIG_CC_VERSION_TEXT="\(.*\)"$/\1/p' "/boot/config-$1" 2>/dev/null || true)"
    if [[ "$text" =~ (gcc-[0-9]+) ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ clang\ version\ ([0-9]+) ]]; then printf 'clang-%s' "${BASH_REMATCH[1]}"; return 0; fi
    return 1
}

has_nvidia_gpu() {
    local d vendor class
    for d in /sys/bus/pci/devices/*; do
        vendor="$(<"$d/vendor")" || continue
        class="$(<"$d/class")" || continue
        if [[ "$vendor" == 0x10de && "$class" == 0x03* ]]; then return 0; fi
    done
    return 1
}

gpu_summary() {
    local out
    out="$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display controller' | sed -E 's/^[^ ]+ [^:]+: //' | paste -sd ';' || true)"
    printf '%s' "${out:-unknown}"
}

dkms_kos() {
    local k="$1"
    find "/lib/modules/$k/updates" "/lib/modules/$k/extra" -name '*.ko*' -type f 2>/dev/null | sort || true
}

index_kos() {
    local ko line name version file
    if (( KO_INDEXED )); then return 0; fi
    KO_FILES=() KO_NAME=() KO_VERSION=()
    mapfile -t KO_FILES < <(dkms_kos "$RUNNING")
    for ko in "${KO_FILES[@]}"; do
        if [[ -z "$ko" ]]; then continue; fi
        name="" version=""
        while IFS= read -r line; do
            case "$line" in
                name:*) name="${line#name:}"; name="${name//[[:space:]]/}" ;;
                version:*) version="${line#version:}"; version="${version//[[:space:]]/}" ;;
            esac
        done < <(modinfo "$ko" 2>/dev/null || true)
        file="${ko##*/}"
        file="${file%%.ko*}"
        name="${name:-${file//-/_}}"
        KO_NAME["$ko"]="$name"
        KO_VERSION["$name"]="$version"
    done
    KO_INDEXED=1
}

compute_expected() {
    local ko name
    local -A provided=() wanted=()
    EXPECTED=()
    index_kos
    for ko in "${KO_FILES[@]}"; do
        if [[ -n "$ko" ]]; then provided["${KO_NAME[$ko]}"]=1; fi
    done
    if has_nvidia_gpu; then wanted[nvidia]=1; fi
    while IFS= read -r name; do
        if [[ -n "$name" ]]; then wanted["${name//-/_}"]=1; fi
    done < <(cat /etc/modules-load.d/*.conf /run/modules-load.d/*.conf /usr/lib/modules-load.d/*.conf /etc/modules 2>/dev/null | sed -E 's/[#;].*$//' | awk 'NF { print $1 }' || true)
    for name in "${!wanted[@]}"; do
        if [[ -n "${provided[$name]:-}" ]]; then EXPECTED+=("$name"); fi
    done
}

stale_module_dirs() {
    local d k p owned
    for d in /lib/modules/*/; do
        d="${d%/}"
        k="${d##*/}"
        if [[ -z "$k" || "$k" == "$RUNNING" ]]; then continue; fi
        if [[ -e "/boot/vmlinuz-$k" || -d "$d/kernel" ]]; then continue; fi
        owned=0
        for p in "linux-image-$k" "linux-image-$k-unsigned" "linux-headers-$k" "linux-modules-$k" "linux-modules-extra-$k"; do
            if pkg_installed "$p"; then owned=1; break; fi
        done
        if (( owned == 0 )); then printf '%s\n' "$d"; fi
    done
}

scan_orphans() {
    local conf dir name ver
    ORPHANS=()
    for conf in /usr/src/*/dkms.conf; do
        dir="${conf%/dkms.conf}"
        name="$(conf_value PACKAGE_NAME "$conf")"
        ver="$(conf_value PACKAGE_VERSION "$conf")"
        if [[ -z "$name" || -z "$ver" || "$name$ver" == *[\$\#]* ]]; then continue; fi
        if [[ -d "$DKMS_TREE/$name/$ver" ]]; then continue; fi
        ORPHANS+=("$dir|$name|$ver")
    done
}

banner() {
    local os
    os="$(sed -n -E 's/^PRETTY_NAME="?([^"]*)"?$/\1/p' /etc/os-release 2>/dev/null | head -n1 || true)"
    os="${os:-unknown}"
    if (( QUIET )); then return 0; fi
    printf '%s%s %s%s  (mode: %s)\n' "$C_B" "$NAME" "$VERSION" "$C_0" "$MODE"
    info "system       $os"
    info "running      $RUNNING (flavor: $FLAVOR, arch: $ARCH)"
    info "kernels      ${KERNELS[*]:-none}"
    info "targets      ${TARGETS[*]:-none}"
    info "dkms         $(dkms --version 2>/dev/null || printf 'not installed')"
    info "modules      ${MODULES[*]:-none registered}"
    info "gpu          $(gpu_summary)"
    if secure_boot_enabled; then info "secure boot  enabled"; else info "secure boot  disabled or unsupported"; fi
    if [[ -n "$LOG_FILE" ]]; then info "log          $LOG_FILE"; fi
}

secure_boot_enabled() {
    local var byte
    if command -v mokutil >/dev/null 2>&1; then
        mokutil --sb-state 2>/dev/null | grep -qi 'secureboot enabled'
        return
    fi
    for var in /sys/firmware/efi/efivars/SecureBoot-*; do
        byte="$(od -An -t u1 -j 4 -N 1 "$var" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$byte" == 1 ]]; then return 0; fi
    done
    return 1
}

mok_cert() {
    local c=""
    c="$(sed -n -E 's/^[[:space:]]*mok_certificate=["]?([^"]+)["]?.*$/\1/p' /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf 2>/dev/null | tail -n1 || true)"
    printf '%s' "${c:-$DKMS_TREE/mok.pub}"
}

wait_pkg_manager() {
    local waited=0 limit=600
    while pkg_busy; do
        if (( waited == 0 )); then info "waiting for another package manager to finish"; fi
        if (( waited >= limit )); then die "package manager still busy after ${limit}s"; fi
        sleep 5
        waited=$(( waited + 5 ))
    done
}

repair_packages() {
    say "Repairing package manager state"
    if ! run dpkg --configure -a; then warn "dpkg --configure -a reported errors"; fi
    if ! run apt-get -f install "${APT_OPTS[@]}"; then warn "apt-get -f install reported errors"; fi
    if (( DO_UPDATE )); then
        if ! run apt-get update -q; then warn "apt-get update failed, using cached package lists"; fi
    else
        info "apt-get update skipped"
    fi
}

apt_install() {
    local pkg
    if (( $# == 0 )); then return 0; fi
    if run apt-get install "${APT_OPTS[@]}" "$@"; then return 0; fi
    warn "bulk install failed, retrying one package at a time"
    for pkg in "$@"; do
        if ! run apt-get install "${APT_OPTS[@]}" "$pkg"; then warn "could not install $pkg"; fi
    done
}

ensure_packages() {
    say "Ensuring DKMS toolchain and kernel headers"
    local k cc pkg meta="linux-headers-$FLAVOR"
    local -a want=() reinstall=()
    local -A seen=()
    if ! command -v dkms >/dev/null 2>&1; then want+=(dkms); fi
    if ! command -v modprobe >/dev/null 2>&1; then want+=(kmod); fi
    if ! command -v make >/dev/null 2>&1; then want+=(make); fi
    if secure_boot_enabled && ! command -v mokutil >/dev/null 2>&1 && pkg_available mokutil; then want+=(mokutil); fi
    if pkg_installed "linux-image-$FLAVOR" && ! pkg_installed "$meta" && pkg_available "$meta"; then want+=("$meta"); fi
    for k in "${TARGETS[@]}"; do
        case "$(headers_state "$k")" in
            missing) want+=("linux-headers-$k") ;;
            broken) reinstall+=("linux-headers-$k") ;;
        esac
        if cc="$(kernel_cc "$k")" && ! command -v "$cc" >/dev/null 2>&1 && pkg_available "$cc"; then want+=("$cc"); fi
    done
    local -a unique=()
    for pkg in "${want[@]}"; do
        if [[ -z "${seen[$pkg]:-}" ]]; then seen["$pkg"]=1; unique+=("$pkg"); fi
    done
    if (( ${#unique[@]} )); then
        info "installing: ${unique[*]}"
        apt_install "${unique[@]}"
    fi
    if (( ${#reinstall[@]} )); then
        info "reinstalling broken headers: ${reinstall[*]}"
        if ! run apt-get install --reinstall "${APT_OPTS[@]}" "${reinstall[@]}"; then warn "headers reinstall failed"; fi
    fi
    hash -r
    for pkg in "$meta" "linux-image-$FLAVOR"; do
        if pkg_installed "$pkg" && pkg_is_auto "$pkg"; then
            if run apt-mark manual "$pkg" >/dev/null; then ok "$pkg marked manual so autoremove keeps it"; fi
        fi
    done
    if (( ${#unique[@]} == 0 && ${#reinstall[@]} == 0 )); then ok "toolchain and headers already present"; fi
    command -v dkms >/dev/null 2>&1 || die "dkms is still missing after installation attempt"
}

fix_broken_sources() {
    local mv m v owner
    if (( ${#BROKEN[@]} == 0 )); then return 0; fi
    say "Repairing DKMS registrations with missing sources"
    for mv in "${BROKEN[@]}"; do
        m="${mv%/*}"
        v="${mv#*/}"
        if owner="$(pkg_owner "/usr/src/$m-$v")"; then
            if run apt-get install --reinstall "${APT_OPTS[@]}" "$owner"; then
                ok "$mv restored by reinstalling $owner"
            else
                warn "reinstall of $owner failed"
            fi
        elif run dkms remove "$mv" --all; then
            ok "removed dead registration $mv"
        else
            warn "could not remove dead registration $mv, delete $DKMS_TREE/$m/$v manually"
        fi
    done
}

handle_orphans() {
    local entry dir name ver owner
    if (( ${#ORPHANS[@]} == 0 )); then return 0; fi
    say "Handling unregistered DKMS source trees"
    for entry in "${ORPHANS[@]}"; do
        IFS='|' read -r dir name ver <<<"$entry"
        if owner="$(pkg_owner "$dir")" && [[ "${dir##*/}" == "$name-$ver" ]]; then
            if run dkms add "$name/$ver"; then ok "registered $name/$ver from package $owner"; else warn "dkms add $name/$ver failed"; fi
            continue
        fi
        if (( PURGE_ORPHANS )); then
            if confirm "Delete unregistered source tree $dir ($name $ver)?" n; then
                run rm -rf --one-file-system -- "$dir"
                ok "deleted $dir"
            else
                info "kept $dir"
            fi
        else
            info "$dir ($name $ver) is not registered, left untouched (use --purge-orphans to delete it)"
        fi
    done
}

ensure_added() {
    local mv="$1" m="${1%/*}" v="${1#*/}"
    if [[ -e "$DKMS_TREE/$m/$v/source" ]]; then return 0; fi
    if [[ -f "/usr/src/$m-$v/dkms.conf" ]]; then
        run dkms add "$mv"
        return
    fi
    return 1
}

clean_stale() {
    say "Cleaning leftovers of removed kernels"
    local key mv k d cleaned=0
    local -a rc_pkgs=() dirs=()
    mapfile -t rc_pkgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 'linux-headers-*' 'linux-modules-*' 2>/dev/null | awk '$1 == "rc" { print $2 }' || true)
    if (( ${#rc_pkgs[@]} )); then
        if run dpkg --purge "${rc_pkgs[@]}"; then cleaned=1; else warn "could not purge leftover packages: ${rc_pkgs[*]}"; fi
    fi
    load_dkms_state
    for key in "${!STATE[@]}"; do
        mv="${key%|*}"
        k="${key#*|}"
        if in_list "$k" "${KERNELS[@]}"; then continue; fi
        if run dkms remove "$mv" -k "$k"; then cleaned=1; else warn "could not remove stale DKMS build $mv for $k"; fi
    done
    mapfile -t dirs < <(stale_module_dirs)
    for d in "${dirs[@]}"; do
        if [[ -n "$d" && "$d" == /lib/modules/?* ]]; then
            run rm -rf --one-file-system -- "$d"
            cleaned=1
        fi
    done
    for mv in "${MODULES[@]}"; do
        if ! ensure_added "$mv"; then warn "$mv lost its registration and its source is missing"; fi
    done
    if (( cleaned )); then ok "leftovers removed"; else ok "nothing to clean"; fi
}

secure_boot_fix() {
    say "Checking Secure Boot module signing"
    local cert out
    if ! secure_boot_enabled; then
        ok "Secure Boot disabled, signatures are not enforced"
        return 0
    fi
    cert="$(mok_cert)"
    if [[ ! -r "$cert" ]]; then
        if run dkms generate_mok; then ok "generated DKMS signing key"; else warn "could not generate DKMS signing key"; fi
    fi
    if [[ ! -r "$cert" ]]; then return 0; fi
    out="$(mokutil --test-key "$cert" 2>&1 || true)"
    case "$out" in
        *"already enrolled"*)
            ok "DKMS signing key is enrolled"
            ;;
        *"enrollment request"*|*"already in the"*)
            warn "DKMS key enrollment is pending: reboot and choose 'Enroll MOK' in MokManager"
            NEED_REBOOT=1
            ;;
        *)
            if [[ -t 0 ]] && confirm "Enroll DKMS signing key $cert into MOK now? You will choose a one-time password." y; then
                if mokutil --import "$cert"; then
                    NEED_REBOOT=1
                    warn "reboot, choose 'Enroll MOK' in MokManager and type that password"
                else
                    warn "mokutil --import failed"
                fi
            else
                warn "DKMS key not enrolled, enroll it with: sudo mokutil --import $cert"
            fi
            ;;
    esac
}

show_build_log() {
    local m="$1" v="$2" k="$3" f
    for f in "$DKMS_TREE/$m/$v/build/make.log" "$DKMS_TREE/$m/$v/$k/$ARCH/log/make.log"; do
        if [[ ! -r "$f" ]]; then continue; fi
        info "build log: $f"
        grep -nE '(error|Error|ERROR|fatal):' "$f" 2>/dev/null | head -n 8 | sed 's/^/      ! /' || true
        tail -n 20 "$f" | sed 's/^/      | /'
        return 0
    done
    info "no build log found for $m/$v on $k"
}

build_module() {
    local mv="$1" k="$2" st="$3" m="${1%/*}" v="${1#*/}" rc=0
    local -a extra=()
    if (( FORCE )) || [[ "$st" == degraded ]]; then extra=(--force); fi
    if run dkms install "$mv" -k "$k" "${extra[@]}"; then return 0; else rc=$?; fi
    if (( rc == 77 )); then return 77; fi
    warn "$k: $mv failed (exit $rc), cleaning and retrying"
    run dkms remove "$mv" -k "$k" >/dev/null 2>&1 || true
    ensure_added "$mv" || true
    if run dkms install "$mv" -k "$k" --force; then return 0; else rc=$?; fi
    if (( rc == 77 )); then return 77; fi
    show_build_log "$m" "$v" "$k"
    return "$rc"
}

build_all() {
    say "Building DKMS modules"
    local k mv st rc
    local -a auto=()
    if (( ${#MODULES[@]} == 0 )); then
        warn "no DKMS modules are registered"
        return 0
    fi
    for mv in "${MODULES[@]}"; do
        if autoinstall_enabled "$mv"; then auto+=("$mv"); else info "$mv has AUTOINSTALL disabled, skipped"; fi
    done
    load_dkms_state
    for k in "${TARGETS[@]}"; do
        if [[ "$(headers_state "$k")" != ok ]]; then
            warn "$k: skipped, kernel headers are not usable"
            continue
        fi
        for mv in "${auto[@]}"; do
            st="$(state_of "$mv" "$k")"
            if [[ "$st" == installed ]] && (( FORCE == 0 )); then
                ok "$k: $mv installed"
                continue
            fi
            info "$k: $mv is $st, building"
            if build_module "$mv" "$k" "$st"; then
                ok "$k: $mv installed"
                REBUILT["$k"]=1
            else
                rc=$?
                if (( rc == 77 )); then
                    info "$k: $mv excluded by its BUILD_EXCLUSIVE rules"
                    SKIPPED["$mv|$k"]=1
                else
                    warn "$k: $mv build failed (exit $rc)"
                fi
            fi
        done
    done
    load_dkms_state
}

prune_kernels() {
    say "Pruning old kernels (keep newest $KEEP plus running)"
    local k p i
    local -a keep=() drop=() pkgs=() extra=()
    for (( i = ${#KERNELS[@]} - 1; i >= 0; i-- )); do
        k="${KERNELS[i]}"
        if [[ "$k" == "$RUNNING" ]]; then keep+=("$k"); continue; fi
        if [[ "$k" != "$NEWEST" && "$(headers_state "$k")" == unavailable ]]; then continue; fi
        if (( ${#keep[@]} < KEEP )); then keep+=("$k"); fi
    done
    if ! in_list "$RUNNING" "${keep[@]}"; then keep+=("$RUNNING"); fi
    for k in "${KERNELS[@]}"; do
        if ! in_list "$k" "${keep[@]}"; then drop+=("$k"); fi
    done
    if (( ${#drop[@]} == 0 )); then
        ok "nothing to prune"
        return 0
    fi
    for k in "${drop[@]}"; do
        for p in "linux-image-$k" "linux-image-$k-unsigned" "linux-headers-$k" "linux-modules-$k" "linux-modules-extra-$k"; do
            if pkg_installed "$p"; then pkgs+=("$p"); fi
        done
    done
    info "keeping:  ${keep[*]}"
    info "removing: ${drop[*]}"
    if (( ${#pkgs[@]} == 0 )); then
        warn "no packages own the kernels selected for removal"
        return 0
    fi
    printf '      %s\n' "${pkgs[@]}"
    if ! confirm "Purge these packages?" n; then
        info "prune skipped"
        return 0
    fi
    if ! run apt-get purge "${APT_OPTS[@]}" "${pkgs[@]}"; then
        warn "kernel purge failed"
        return 0
    fi
    mapfile -t extra < <(apt-get -s autoremove 2>/dev/null | awk '/^Remv linux-(headers|kbuild|image|modules)-[0-9]/ { print $2 }' || true)
    if (( ${#extra[@]} )); then
        if ! run apt-get purge "${APT_OPTS[@]}" "${extra[@]}"; then warn "could not purge orphaned kernel support packages"; fi
    fi
    if command -v update-grub >/dev/null 2>&1; then
        if ! run update-grub; then warn "update-grub failed"; fi
    fi
    ok "pruned ${#drop[@]} kernel(s)"
}

refresh_boot_files() {
    local k
    local -a ks=()
    for k in "${!REBUILT[@]}"; do
        if in_list "$k" "${KERNELS[@]}"; then ks+=("$k"); fi
    done
    if (( ${#ks[@]} == 0 )); then return 0; fi
    say "Refreshing module indexes and initramfs"
    mapfile -t ks < <(printf '%s\n' "${ks[@]}" | sort -V)
    for k in "${ks[@]}"; do
        if ! run depmod -a "$k"; then warn "depmod failed for $k"; fi
        if command -v update-initramfs >/dev/null 2>&1; then
            if ! run update-initramfs -u -k "$k"; then warn "initramfs update failed for $k"; fi
        fi
    done
}

load_running_modules() {
    say "Loading modules into running kernel $RUNNING"
    local ko name file any=0
    if ! in_list "$RUNNING" "${KERNELS[@]}"; then
        warn "running kernel is not among installed kernels, skipping module loading"
        return 0
    fi
    run depmod -a "$RUNNING" || warn "depmod failed for $RUNNING"
    KO_INDEXED=0
    compute_expected
    for ko in "${KO_FILES[@]}"; do
        if [[ -z "$ko" ]]; then continue; fi
        any=1
        name="${KO_NAME[$ko]}"
        file="${ko##*/}"
        file="${file%%.ko*}"
        case "$name" in *peermem*) continue ;; esac
        if [[ -d "/sys/module/$name" ]]; then
            ok "$name already loaded"
            continue
        fi
        if run modprobe "$name" 2>/dev/null || run modprobe "$file"; then
            ok "$name loaded"
        elif in_list "$name" "${EXPECTED[@]}"; then
            warn "modprobe $name failed (inspect: journalctl -k -b | tail -n 50)"
        else
            info "$name not loaded (optional, no matching hardware or configuration)"
        fi
    done
    if (( any == 0 )); then warn "no DKMS modules installed for the running kernel"; fi
}

verify_meta() {
    local meta="linux-headers-$FLAVOR"
    if ! pkg_installed "linux-image-$FLAVOR"; then return 0; fi
    if ! pkg_installed "$meta"; then
        fail "$meta is not installed: kernel upgrades arrive without headers and DKMS cannot build (fix: apt-get install $meta)"
    elif pkg_is_auto "$meta"; then
        warn "$meta is marked automatic and may be autoremoved (fix: apt-mark manual $meta)"
    fi
}

verify_toolchain() {
    local k cc
    if ! command -v dkms >/dev/null 2>&1; then fail "dkms is not installed"; return 0; fi
    for k in "${TARGETS[@]}"; do
        if cc="$(kernel_cc "$k")" && ! command -v "$cc" >/dev/null 2>&1; then
            fail "$k$(ktag "$k"): compiler $cc used to build this kernel is missing (fix: apt-get install $cc)"
        fi
    done
}

verify_headers() {
    local k
    for k in "${TARGETS[@]}"; do
        case "$(headers_state "$k")" in
            broken) fail "$k$(ktag "$k"): linux-headers-$k installed but /lib/modules/$k/build is broken" ;;
            missing) fail "$k$(ktag "$k"): kernel headers missing, DKMS modules cannot be built (fix: apt-get install linux-headers-$k)" ;;
            unavailable) fail "$k$(ktag "$k"): no headers package in APT, DKMS can never build here (remove it with --prune)" ;;
        esac
    done
}

verify_builds() {
    local k mv st
    local -a bad=()
    for k in "${TARGETS[@]}"; do
        if [[ "$(headers_state "$k")" != ok ]]; then continue; fi
        bad=()
        for mv in "${MODULES[@]}"; do
            if ! autoinstall_enabled "$mv"; then continue; fi
            st="$(state_of "$mv" "$k")"
            if [[ "$st" != installed && "$st" != excluded ]]; then bad+=("$mv ($st)"); fi
        done
        if (( ${#bad[@]} )); then
            fail "$k$(ktag "$k"): DKMS modules not installed: $(join_by ", " "${bad[@]}")"
        fi
    done
}

verify_registrations() {
    local mv key k d
    local -a dirs=()
    for mv in "${BROKEN[@]}"; do fail "DKMS registration $mv points to a missing source tree"; done
    for mv in "${EXTRA_VERSIONS[@]}"; do warn "older DKMS version still registered: $mv"; done
    for key in "${!STATE[@]}"; do
        k="${key#*|}"
        if ! in_list "$k" "${KERNELS[@]}"; then warn "stale DKMS build ${key%|*} for removed kernel $k"; fi
    done
    mapfile -t dirs < <(stale_module_dirs)
    for d in "${dirs[@]}"; do
        if [[ -n "$d" ]]; then warn "leftover module directory of a removed kernel: $d"; fi
    done
}

verify_orphans() {
    local entry dir name ver
    for entry in "${ORPHANS[@]}"; do
        IFS='|' read -r dir name ver <<<"$entry"
        if [[ "${dir##*/}" != "$name-$ver" ]]; then
            warn "unregistered DKMS source $dir ($name $ver): dkms expects /usr/src/$name-$ver"
        else
            warn "unregistered DKMS source $dir: register with 'dkms install $name/$ver' or delete with --purge-orphans"
        fi
    done
}

verify_secure_boot() {
    local cert out
    if ! secure_boot_enabled; then return 0; fi
    if ! command -v mokutil >/dev/null 2>&1; then
        fail "Secure Boot is enabled but mokutil is missing, MOK enrollment cannot be verified (fix: apt-get install mokutil)"
        return 0
    fi
    cert="$(mok_cert)"
    if [[ ! -r "$cert" ]]; then
        fail "Secure Boot is enabled but the DKMS signing certificate $cert is missing"
        return 0
    fi
    out="$(mokutil --test-key "$cert" 2>&1 || true)"
    case "$out" in
        *"already enrolled"*) ;;
        *"enrollment request"*|*"already in the"*) warn "DKMS key enrollment pending, reboot to finish it in MokManager"; NEED_REBOOT=1 ;;
        *) fail "Secure Boot is enabled but the DKMS key is not enrolled, modules will be rejected (fix: mokutil --import $cert)" ;;
    esac
    out="$(journalctl -k -b --no-pager 2>/dev/null | grep -m1 'Key was rejected by service' || true)"
    if [[ -n "$out" ]]; then warn "the kernel rejected a module signature during this boot"; fi
}

verify_running() {
    local name loaded disk out
    if ! in_list "$RUNNING" "${KERNELS[@]}"; then return 0; fi
    compute_expected
    for name in "${EXPECTED[@]}"; do
        if [[ ! -d "/sys/module/$name" ]]; then fail "$name should be loaded on $RUNNING but is not"; fi
    done
    for name in "${!KO_VERSION[@]}"; do
        if [[ ! -d "/sys/module/$name" ]]; then continue; fi
        loaded="$(cat "/sys/module/$name/version" 2>/dev/null || true)"
        disk="${KO_VERSION[$name]}"
        if [[ -n "$loaded" && -n "$disk" && "$loaded" != "$disk" ]]; then
            warn "$name $loaded is loaded but $disk is installed, reboot to switch"
            NEED_REBOOT=1
        fi
    done
    if [[ -d /sys/module/nvidia ]] && command -v nvidia-smi >/dev/null 2>&1; then
        if out="$(timeout 20 nvidia-smi -L 2>&1)"; then
            ok "nvidia-smi: ${out%%$'\n'*}"
        elif [[ "$out" == *ismatch* ]]; then
            warn "NVIDIA kernel module and userspace libraries differ, reboot required"
            NEED_REBOOT=1
        else
            fail "nvidia-smi failed: ${out%%$'\n'*}"
        fi
    fi
}

verify_all() {
    say "Verifying"
    load_dkms_state
    verify_meta
    verify_toolchain
    verify_headers
    verify_builds
    verify_registrations
    verify_orphans
    verify_secure_boot
    verify_running
    if (( ${#PROBLEMS[@]} == 0 )); then ok "all checks passed"; fi
}

cell() {
    local text="$1" width="$2" color="$C_Y" padded
    case "$text" in
        ok|installed) color="$C_G" ;;
        missing|unavailable|broken|failed) color="$C_R" ;;
        excluded) color="$C_D" ;;
    esac
    printf -v padded '%-*s' "$width" "$text"
    printf '%s%s%s' "$color" "$padded" "$C_0"
}

col_width() {
    local n="${1%/*}"
    if (( ${#n} > 11 )); then printf '%s' "${#n}"; else printf '11'; fi
}

print_summary() {
    local k mv flags w=6 item
    if (( QUIET )); then return 0; fi
    say "Summary"
    for k in "${KERNELS[@]}"; do
        if (( ${#k} > w )); then w=${#k}; fi
    done
    printf '    %-*s  %-5s  %-11s' "$w" KERNEL FLAGS HEADERS
    for mv in "${MODULES[@]}"; do printf '  %-*s' "$(col_width "$mv")" "${mv%/*}"; done
    printf '\n'
    for k in "${KERNELS[@]}"; do
        flags=""
        if [[ "$k" == "$RUNNING" ]]; then flags+="R"; fi
        if [[ "$k" == "$NEWEST" ]]; then flags+="N"; fi
        printf '    %-*s  %-5s  ' "$w" "$k" "${flags:--}"
        cell "$(headers_state "$k")" 11
        for mv in "${MODULES[@]}"; do
            printf '  '
            cell "$(state_of "$mv" "$k")" "$(col_width "$mv")"
        done
        printf '\n'
    done
    printf '    %sR = running kernel, N = newest kernel (GRUB default entry)%s\n' "$C_D" "$C_0"
    if (( ${#WARNINGS[@]} )); then
        printf '\n    %s%d warning(s):%s\n' "$C_Y" "${#WARNINGS[@]}" "$C_0"
        for item in "${WARNINGS[@]}"; do printf '      - %s\n' "$item"; done
    fi
    if (( ${#PROBLEMS[@]} )); then
        printf '\n    %s%d problem(s) remain:%s\n' "$C_R" "${#PROBLEMS[@]}" "$C_0"
        for item in "${PROBLEMS[@]}"; do printf '      - %s\n' "$item"; done
        if [[ "$MODE" == check ]]; then printf '\n    Repair with: sudo %s\n' "$SELF"; fi
    else
        printf '\n    %sNo problems found.%s\n' "$C_G" "$C_0"
    fi
    if (( NEED_REBOOT )); then printf '    %sReboot required to finish.%s\n' "$C_Y" "$C_0"; fi
    if [[ -n "$LOG_FILE" ]]; then printf '    Log: %s\n' "$LOG_FILE"; fi
}

dm_unit() {
    local load id
    command -v systemctl >/dev/null 2>&1 || return 1
    load="$(systemctl show -p LoadState --value display-manager.service 2>/dev/null || true)"
    if [[ "$load" != loaded ]]; then return 1; fi
    id="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"
    if [[ -z "$id" ]]; then return 1; fi
    printf '%s' "$id"
}

handle_display_manager() {
    local unit state reason=""
    if [[ "$DM_POLICY" == never ]]; then return 0; fi
    if ! unit="$(dm_unit)"; then return 0; fi
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    say "Display manager: $unit ($state)"
    if (( NEED_REBOOT )); then
        warn "reboot instead of restarting $unit, the loaded modules are outdated"
        return 0
    fi
    if [[ "$state" != active ]]; then
        reason="it is $state"
    elif (( NVIDIA_WAS_LOADED == 0 )) && [[ -d /sys/module/nvidia ]]; then
        reason="the NVIDIA driver was not loaded when the session started"
    elif [[ "$DM_POLICY" == always ]]; then
        reason="--restart-dm was given"
    fi
    if [[ -z "$reason" ]]; then
        ok "$unit is healthy, no restart needed"
        return 0
    fi
    if [[ "$DM_POLICY" == always ]] || confirm "Restart $unit now because $reason? This closes every graphical session." n; then
        if [[ -n "$LOG_FILE" ]]; then info "log saved to $LOG_FILE"; fi
        run systemctl --no-block restart "$unit"
    else
        info "skipped, run later: sudo systemctl restart $unit (or reboot)"
    fi
}

install_hook() {
    require_root
    if [[ "$SELF" != "$HOOK_BIN" ]]; then run install -D -m 0755 "$SELF" "$HOOK_BIN"; fi
    printf 'DPkg::Post-Invoke { "if [ -x %s ]; then %s --check --quiet --no-color || true; fi"; };\n' "$HOOK_BIN" "$HOOK_BIN" >"$HOOK_CONF"
    chmod 0644 "$HOOK_CONF"
    ok "installed $HOOK_BIN"
    ok "APT hook $HOOK_CONF runs '$NAME --check' after every package operation"
}

remove_hook() {
    require_root
    if [[ -e "$HOOK_CONF" ]]; then run rm -f -- "$HOOK_CONF"; fi
    if [[ -e "$HOOK_BIN" ]]; then run rm -f -- "$HOOK_BIN"; fi
    ok "APT hook removed"
}

finish() {
    if (( QUIET )) && (( ${#PROBLEMS[@]} )); then
        printf '%s: %d problem(s) found, repair with: sudo %s\n' "$NAME" "${#PROBLEMS[@]}" "$NAME" >&2
    fi
    if (( ${#PROBLEMS[@]} )); then exit 1; fi
    exit 0
}

main_check() {
    if [[ -n "${FIX_DKMS_ACTIVE:-}" ]] && (( QUIET )); then exit 0; fi
    require_debian
    discover_kernels
    resolve_targets
    discover_modules
    scan_orphans
    banner
    verify_all
    print_summary
    finish
}

main_fix() {
    require_root
    require_debian
    export FIX_DKMS_ACTIVE=1
    acquire_lock
    setup_log
    if [[ -d /sys/module/nvidia ]]; then NVIDIA_WAS_LOADED=1; fi
    discover_kernels
    resolve_targets
    discover_modules
    banner
    wait_pkg_manager
    repair_packages
    discover_kernels
    resolve_targets
    ensure_packages
    discover_modules
    scan_orphans
    fix_broken_sources
    handle_orphans
    discover_modules
    scan_orphans
    clean_stale
    discover_modules
    secure_boot_fix
    build_all
    if (( DO_PRUNE )); then
        prune_kernels
        discover_kernels
        local -a still=()
        local k
        for k in "${TARGETS[@]}"; do
            if in_list "$k" "${KERNELS[@]}"; then still+=("$k"); fi
        done
        TARGETS=("${still[@]}")
    fi
    refresh_boot_files
    load_running_modules
    verify_all
    print_summary
    handle_display_manager
    finish
}

main() {
    parse_args "$@"
    setup_colors
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
    trap on_signal INT TERM
    trap on_exit EXIT
    case "$MODE" in
        check) main_check ;;
        install-hook) install_hook ;;
        remove-hook) remove_hook ;;
        *) main_fix ;;
    esac
}

main "$@"
