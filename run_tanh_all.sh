#!/bin/bash
set -euo pipefail

log() { echo ""; echo "[$(date +%H:%M:%S)] $*"; }

find_cann() {
    local c
    for c in "${CANN_ROOT:-}" \
             /opt/atomgit/Ascend/ascend-toolkit/latest \
             "$HOME/Ascend/ascend-toolkit/latest" \
             "${ASCEND_HOME_DIR:-}" \
             /usr/local/Ascend/ascend-toolkit/latest \
             "${ASCEND_HOME_PATH:-}"; do
        if [ -n "$c" ] && { [ -f "$c/set_env.sh" ] || [ -f "$c/bin/setenv.bash" ]; }; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

CANN="$(find_cann)" || { echo "ERROR: CANN not found"; exit 1; }
export ASCEND_HOME_DIR="$CANN"

# Source the complete CANN environment once. Do not override single variables afterwards.
if [ -f "$CANN/set_env.sh" ]; then
    source "$CANN/set_env.sh"
else
    source "$CANN/bin/setenv.bash"
fi

log "CANN=$CANN"
log "device:"
npu-smi info 2>/dev/null | head -15 || true
log "ASCEND_HOME_PATH=${ASCEND_HOME_PATH:-<unset>}"
log "ASCEND_OPP_PATH=${ASCEND_OPP_PATH:-<unset>}"
log "ASCEND_CUSTOM_OPP_PATH=${ASCEND_CUSTOM_OPP_PATH:-<unset>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$ROOT/TanhCustom/op_host" ]; then
    OP_DIR="$ROOT/TanhCustom"
elif [ -d "$ROOT/op_host" ]; then
    OP_DIR="$ROOT"
else
    echo "ERROR: operator project (TanhCustom/op_host) not found under $ROOT"
    exit 1
fi
if [ -d "$ROOT/AclNNInvocation" ]; then
    TEST_DIR="$ROOT/AclNNInvocation"
elif [ -d "$ROOT/../AclNNInvocation" ]; then
    TEST_DIR="$(cd "$ROOT/../AclNNInvocation" && pwd)"
else
    echo "ERROR: AclNNInvocation not found"
    exit 1
fi

log "build operator"
cd "$OP_DIR"
rm -rf build_out
bash build.sh

RUN_PKG="$(ls -1 build_out/*.run 2>/dev/null | grep -v source | head -1 || true)"
[ -n "$RUN_PKG" ] || { echo "ERROR: no .run package generated"; exit 1; }
log "package: $RUN_PKG"

log "install operator package"
cd "$OP_DIR/build_out"
if ! ./"$(basename "$RUN_PKG")"; then
    log "default install failed, retry into $HOME/Ascend/opp"
    ./"$(basename "$RUN_PKG")" --install-path="$HOME/Ascend/opp"
    export ASCEND_CUSTOM_OPP_PATH="$HOME/Ascend/opp/vendors"
fi

VENDOR="${ASCEND_CUSTOM_OPP_PATH:-$ASCEND_OPP_PATH/vendors}/customize"
log "vendor dir: $VENDOR"
test -f "$VENDOR/op_api/include/aclnn_tanh_custom.h" || {
    echo "ERROR: aclnn_tanh_custom.h not installed under $VENDOR"
    exit 1
}

if ! grep -Rq "TanhCustom" "$VENDOR/op_impl" 2>/dev/null; then
    echo "ERROR: TanhCustom is missing from the installed kernel config"
    find "$VENDOR/op_impl" -name "binary_info_config.json" 2>/dev/null | head -5
    echo "Kernel build logs:"
    find "$OP_DIR/build_out" -path "*build_logs*" -type f 2>/dev/null | head -20 || true
    exit 1
fi

log "run aclnn precision test"
cd "$TEST_DIR"
mkdir -p input output
rm -rf build
if ! ASCEND_HOME_DIR="$CANN" bash run.sh; then
    echo ""
    echo "test failed, recent CANN errors:"
    grep -RniE "TanhCustom|161001|Get regInfo failed|not support opType" "$HOME/ascend/log" 2>/dev/null | tail -30 || true
    exit 1
fi

log "done"