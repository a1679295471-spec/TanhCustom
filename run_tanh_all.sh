#!/bin/bash
set -euo pipefail

log() { echo ""; echo "[$(date +%H:%M:%S)] $*"; }

find_cann() {
    local c
    for c in "${CANN_ROOT:-}" \
             "${ASCEND_HOME_PATH:-}" \
             "${ASCEND_HOME_DIR:-}" \
             /usr/local/Ascend/cann-8.5.0 \
             /usr/local/Ascend/ascend-toolkit/latest \
             "$HOME/Ascend/ascend-toolkit/latest" \
             /opt/atomgit/Ascend/cann \
             /opt/atomgit/Ascend/ascend-toolkit/latest; do
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
if [ -f "$CANN/version.cfg" ]; then
    log "CANN version: $(head -3 "$CANN/version.cfg" | tr '\n' ' ')"
fi
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
    ./"$(basename "$RUN_PKG")" --install-path="$HOME/Ascend/opp" || {
        echo "ERROR: operator package install failed"
        exit 1
    }
fi

HEADER="$(find "$HOME/Ascend" "$CANN" "${ASCEND_OPP_PATH:-}" /usr/local/Ascend \
    -name aclnn_tanh_custom.h 2>/dev/null | head -1 || true)"
if [ -z "$HEADER" ]; then
    echo "ERROR: aclnn_tanh_custom.h was not installed"
    echo "checked under: $HOME/Ascend and $CANN"
    exit 1
fi
CUSTOM_DIR="$(cd "$(dirname "$HEADER")/../.." && pwd)"
VENDOR_ROOT="$(cd "$CUSTOM_DIR/.." && pwd)"
export ASCEND_CUSTOM_OPP_PATH="$VENDOR_ROOT"
log "installed vendor: $CUSTOM_DIR"

if ! grep -Rq "TanhCustom" "$CUSTOM_DIR/op_impl" 2>/dev/null; then
    echo "ERROR: TanhCustom is missing from the installed kernel config"
    find "$CUSTOM_DIR/op_impl" -name "binary_info_config.json" 2>/dev/null | head -5 || true
    echo "Kernel build logs:"
    find "$OP_DIR/build_out" -path "*build_logs*" -type f 2>/dev/null | head -20 || true
    exit 1
fi

# AclNNInvocation derives its custom-op include path from DDK_PATH=$ASCEND_HOME_DIR.
# Always use a private shadow toolkit root: the system CANN dir is read-only here and
# its setenv.bash would otherwise point ASCEND_OPP_PATH back to the system directory.
TEST_DDK="$HOME/.tanh_cann_root"
log "preparing shadow toolkit root: $TEST_DDK"
rm -rf "$TEST_DDK"
mkdir -p "$TEST_DDK/opp/vendors" "$TEST_DDK/bin"
for entry in "$CANN"/*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    case "$base" in
        bin|opp|set_env.sh) continue ;;
    esac
    ln -s "$entry" "$TEST_DDK/$base"
done
for entry in "$CANN"/opp/*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    [ "$base" = "vendors" ] && continue
    ln -s "$entry" "$TEST_DDK/opp/$base"
done
for entry in "$CANN"/opp/vendors/*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    [ "$base" = "customize" ] && continue
    ln -s "$entry" "$TEST_DDK/opp/vendors/$base"
done
ln -s "$CUSTOM_DIR" "$TEST_DDK/opp/vendors/customize"
for entry in "$CANN"/bin/*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    [ "$base" = "setenv.bash" ] && continue
    ln -s "$entry" "$TEST_DDK/bin/$base"
done
if [ -f "$CANN/bin/setenv.bash" ]; then
    cp "$CANN/bin/setenv.bash" "$TEST_DDK/bin/setenv.bash"
fi
if [ -f "$CANN/set_env.sh" ]; then
    cp "$CANN/set_env.sh" "$TEST_DDK/set_env.sh"
fi
touch "$TEST_DDK/bin/setenv.bash"
chmod u+w "$TEST_DDK/bin/setenv.bash"
cat >> "$TEST_DDK/bin/setenv.bash" <<EOF

# injected by run_tanh_all.sh
export ASCEND_HOME_PATH="$TEST_DDK"
export ASCEND_OPP_PATH="$TEST_DDK/opp"
export ASCEND_CUSTOM_OPP_PATH="$CUSTOM_DIR:$TEST_DDK/opp/vendors"
export LD_LIBRARY_PATH="$CUSTOM_DIR/op_api/lib:\${LD_LIBRARY_PATH:-}"
EOF
export ASCEND_CUSTOM_OPP_PATH="$CUSTOM_DIR:$TEST_DDK/opp/vendors"
log "test DDK: $TEST_DDK"

if [ -f "$CUSTOM_DIR/bin/set_env.sh" ]; then
    log "source vendor env: $CUSTOM_DIR/bin/set_env.sh"
    source "$CUSTOM_DIR/bin/set_env.sh"
fi

log "run aclnn precision test"
cd "$TEST_DIR"
mkdir -p input output
rm -rf build
if ! ASCEND_HOME_DIR="$TEST_DDK" bash run.sh; then
    echo ""
    echo "test failed, diagnostics:"
    echo "  ASCEND_OPP_PATH=${ASCEND_OPP_PATH:-<unset>}"
    echo "  ASCEND_CUSTOM_OPP_PATH=${ASCEND_CUSTOM_OPP_PATH:-<unset>}"
    echo "  installed vendor: $CUSTOM_DIR"
    echo "  runtime libraries:"
    (
        set +u
        source "$TEST_DDK/bin/setenv.bash" >/dev/null 2>&1 || true
        echo "    ASCEND_OPP_PATH=${ASCEND_OPP_PATH:-<unset>}"
        echo "    ASCEND_CUSTOM_OPP_PATH=${ASCEND_CUSTOM_OPP_PATH:-<unset>}"
        ldd "$TEST_DIR/output/execute_sigmoid_op" 2>/dev/null | grep -Ei "cust_opapi|ascendcl|nnopbase" || true
    )
    echo "  kernel registration:"
    grep -Rl "TanhCustom" "$CUSTOM_DIR/op_impl" 2>/dev/null | head -10 || true
    find "$CUSTOM_DIR/op_impl" -type f 2>/dev/null | grep -Ei "tanh_custom|binary_info_config" | head -20 || true
    echo "  rerun with CANN error logs:"
    (
        cd "$TEST_DIR/output"
        set +u
        source "$TEST_DDK/bin/setenv.bash" >/dev/null 2>&1 || true
        ASCEND_SLOG_PRINT_TO_STDOUT=1 ASCEND_GLOBAL_LOG_LEVEL=1 ./execute_sigmoid_op
    ) 2>&1 | tail -60 || true
    exit 1
fi

log "done"
