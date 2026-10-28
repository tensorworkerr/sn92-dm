#!/usr/bin/env bash
# Build the dm-all candidate image without a Docker daemon (go-containerregistry `crane`) and push it to DEST.
#   base   = REAX's own Blink text reference image (ref-blink ab02e141 = reax-engine @4230e50 on vLLM 0.30.0), so every base
#            layer is a reference layer and the Blink path is the reference's exact code;
#   layer  = engine/direct_serve.py into /opt/reax/engine (Blink), the reax-engine @6741836 engine tree at /opt/reax-j (Jeffan,
#            the ref-jeffan code; 4230e50 has no Jeffan family), both entrypoints with the server line switched to
#            engine.direct_serve, a dispatcher on REAX_MODEL, and the Jeffan licence files;
#   config = non-root user 10002, our labels (hotkey, declared models), entrypoint = the dispatcher. No weights.
#   DEST=docker.io/<user>/<repo>:<tag> HOTKEY=<ss58> [MODELS=blink,jeffan] bash build_image.sh
# Needs: crane on PATH and `crane auth login <registry>` for DEST; the reax-engine clone with commits 4230e50 and 6741836.
set -euo pipefail
: "${DEST:?}" "${HOTKEY:?}"; MODELS=${MODELS:-blink,jeffan}
BASE=ghcr.io/reaxlabs/reax-engine-ref-blink@sha256:ab02e141ffb5672dc68e137736be0a6fa15445c7cc824a51f6ad2a6664c0e10a
HERE=$(cd "$(dirname "$0")" && pwd); ENGINE=${ENGINE:-$HERE/../../../repos/sn92-reax-engine}
B=4230e50e8b5247f113f7c4b55c6d1c4efa7c2e94; J=6741836e7479baf2b43366d62ce9b0a21ca733cd
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/opt/reax/engine" "$R/opt/reax-j" "$R/licenses/jeffan"
cp "$HERE/candidate/direct_serve.py" "$R/opt/reax/engine/direct_serve.py"
git -C "$ENGINE" show "$B:docker/vllm-readout/entrypoint.sh" \
  | sed 's/python3 -m engine\.serve /python3 -m engine.direct_serve /' > "$R/opt/reax/entrypoint.sh"
git -C "$ENGINE" archive "$J" engine | tar -x -C "$R/opt/reax-j"
cp "$HERE/candidate/direct_serve.py" "$R/opt/reax-j/engine/direct_serve.py"
git -C "$ENGINE" show "$J:docker/vllm-readout/entrypoint.sh" \
  | sed 's/python3 -m engine\.serve /python3 -m engine.direct_serve /' > "$R/opt/reax-j/entrypoint.sh"
for f in LICENSE NOTICE; do git -C "$ENGINE" show "$J:upstream/jeffan/$f" > "$R/licenses/jeffan/$f"; done
cat > "$R/opt/reax/dispatch.sh" <<'EOF'
#!/bin/bash
# REAX_MODEL picks the engine tree: Jeffan runs the ref-jeffan code (reax-engine @6741836), everything else the base image's
# (ref-blink, @4230e50). Both trees serve through engine.direct_serve.
case "${REAX_MODEL:-}" in
  jeffan|jeffan-31b-1710) export PYTHONPATH=/opt/reax-j; cd /opt/reax-j && exec /opt/reax-j/entrypoint.sh ;;
  *) exec /opt/reax/entrypoint.sh ;;
esac
EOF
for f in "$R/opt/reax/entrypoint.sh" "$R/opt/reax-j/entrypoint.sh"; do
  [ "$(grep -c 'engine.direct_serve' "$f")" = 1 ] || { echo "server line not switched in $f"; exit 1; }
done
chmod 0755 "$R/opt/reax/entrypoint.sh" "$R/opt/reax-j/entrypoint.sh" "$R/opt/reax/dispatch.sh"
find "$R" -type f ! -name '*.sh' -exec chmod 0644 {} +; find "$R" -type d -exec chmod 0755 {} +
python3 - "$R" "$T/layer.tar" <<'PY'  # portable, deterministic layer: root-owned, fixed mtime, no macOS xattrs
import os, sys, tarfile
root, out = sys.argv[1:3]
def norm(ti):
    ti.uid = ti.gid = 0; ti.uname = ti.gname = "root"; ti.mtime = 1793145600; ti.pax_headers = {}
    return ti
with tarfile.open(out, "w", format=tarfile.GNU_FORMAT) as t:
    for top in ("opt", "licenses"):
        t.add(os.path.join(root, top), arcname=top, filter=norm)
PY
crane append --platform linux/amd64 -b "$BASE" -f "$T/layer.tar" -t "$DEST.tmp" >/dev/null
crane mutate "$DEST.tmp" -t "$DEST" --user 10002:10002 --entrypoint /opt/reax/dispatch.sh \
  --label ai.reax.engine.hotkey="$HOTKEY" --label ai.reax.engine.models="$MODELS" \
  --label org.opencontainers.image.title=sn92-dm-all-candidate ${SOURCE:+--label org.opencontainers.image.source=$SOURCE} \
  --label org.opencontainers.image.licenses="LicenseRef-REAX-Engine-1.1 AND Apache-2.0" >/dev/null
echo "$DEST@$(crane digest "$DEST")"
