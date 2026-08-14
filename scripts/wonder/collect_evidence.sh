#!/usr/bin/env bash
# Stage-1 Wonder evidence collector for Ace 2 Pro cloud builds.
# Invoked from Build Kernel OnePlus.yml on branch wonder-ace2-pro-cloud.
set -euo pipefail

RUN_ID="${GITHUB_RUN_ID:-local}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
REPOSITORY="${GITHUB_REPOSITORY:-buguj23/Action-Build}"
REF_NAME="${GITHUB_REF_NAME:-wonder-ace2-pro-cloud}"
SHA="${GITHUB_SHA:-unknown}"
FILE_INPUT="${FILE:-oneplus_ace2_pro_b}"

mkdir -p cloud-results/artifacts "cloud-results/runs/${RUN_ID}/artifacts"
RUN_DIR="cloud-results/runs/${RUN_ID}"

{
  echo "# Ace 2 Pro Wonder cloud build"
  echo
  echo "- UTC: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "- Run: ${SERVER_URL}/${REPOSITORY}/actions/runs/${RUN_ID}"
  echo "- Branch: ${REF_NAME}"
  echo "- Checkout SHA: ${SHA}"
  echo "- Input: ${FILE_INPUT}"
  echo "- Public Kalama GKI build: true"
  echo "- CNSS + kiwi_v2 + Wonder external module gate: required"
  echo "- Passthrough data path: not enabled in this baseline build"
  echo "- Device-tree build and changes: none"
  echo "- Boot/flashable package: none"
  echo "- DTBO: none"
  echo
  echo "## Source commits"
  if [ -f cloud-results/apply.log ]; then
    grep -E 'commit check:|expected=' cloud-results/apply.log | sed 's/^/- /' || true
  elif [ -f cloud-results/apply-tail.txt ]; then
    grep -E 'commit check:|expected=' cloud-results/apply-tail.txt | sed 's/^/- /' || true
  fi
  echo
  echo "## Authoritative modules"
} > cloud-results/latest.md

FAIL=0

record_module() {
  local src="$1"
  local delivery_name="$2"
  if [ ! -f "$src" ]; then
    echo "- MISSING: $src (delivery $delivery_name)" | tee -a cloud-results/latest.md
    FAIL=1
    return 1
  fi
  local bytes sha dest
  bytes=$(stat -c '%s' "$src")
  sha=$(sha256sum "$src" | awk '{print $1}')
  dest="cloud-results/artifacts/${delivery_name}"
  cp -a "$src" "$dest"
  cp -a "$src" "$RUN_DIR/artifacts/${delivery_name}"
  {
    echo
    echo "### ${src}"
    echo "- delivery: ${dest}"
    echo "- original_name: $(basename "$src")"
    echo "- size_bytes: ${bytes}"
    echo "- sha256: ${sha}"
    if command -v file >/dev/null 2>&1; then
      echo "- file: $(file -b "$src" | tr '\n' ' ')"
    fi
    if command -v modinfo >/dev/null 2>&1; then
      echo
      echo '```'
      modinfo "$src" 2>&1 || true
      echo '```'
    fi
    local stripbin stripped sbytes ssha
    stripbin="$(command -v llvm-strip || command -v strip || true)"
    if [ -n "$stripbin" ]; then
      stripped="cloud-results/artifacts/${delivery_name}.stripped"
      cp -a "$src" "$stripped"
      if "$stripbin" --strip-debug "$stripped" 2>/dev/null; then
        sbytes=$(stat -c '%s' "$stripped")
        ssha=$(sha256sum "$stripped" | awk '{print $1}')
        echo "- stripped_size_bytes: ${sbytes}"
        echo "- stripped_sha256: ${ssha}"
        echo "- note: stripped copy is evidence-only; not for flash until ABI gate passes"
      else
        rm -f "$stripped"
        echo "- stripped: skip (strip failed)"
      fi
    fi
  } >> cloud-results/latest.md
  echo "recorded $src -> $dest bytes=$bytes"
}

pick_first() {
  local f
  for f in "$@"; do
    if [ -f "$f" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

CNSS_SRC=$(pick_first \
  kernel_workspace/kernel_platform/out/vendor/qcom/opensource/wlan/platform/cnss2/cnss2.ko \
  cloud-results/artifacts/cnss2.ko || true)
KIWI_SRC=$(pick_first \
  kernel_workspace/kernel_platform/out/vendor/qcom/opensource/wlan/qcacld-3.0/kiwi_v2.ko \
  cloud-results/artifacts/qca_cld3_kiwi_v2.ko \
  cloud-results/artifacts/kiwi_v2.ko || true)
WONDER_SRC=$(pick_first \
  kernel_workspace/kernel_platform/out/vendor/oplus/kernel/wifi/wonder/wonder.ko \
  cloud-results/artifacts/wonder.ko || true)

if [ -n "${CNSS_SRC:-}" ]; then record_module "$CNSS_SRC" cnss2.ko || true
else echo "- MISSING cnss2.ko" | tee -a cloud-results/latest.md; FAIL=1; fi

if [ -n "${KIWI_SRC:-}" ]; then
  record_module "$KIWI_SRC" qca_cld3_kiwi_v2.ko || true
  if [ "$(basename "$KIWI_SRC")" = "kiwi_v2.ko" ]; then
    cp -a "$KIWI_SRC" cloud-results/artifacts/kiwi_v2.ko
    cp -a "$KIWI_SRC" "$RUN_DIR/artifacts/kiwi_v2.ko"
    echo "- also_copied_as: cloud-results/artifacts/kiwi_v2.ko" >> cloud-results/latest.md
  fi
else
  echo "- MISSING kiwi_v2.ko / qca_cld3_kiwi_v2.ko" | tee -a cloud-results/latest.md
  FAIL=1
fi

if [ -n "${WONDER_SRC:-}" ]; then record_module "$WONDER_SRC" wonder.ko || true
else echo "- MISSING wonder.ko" | tee -a cloud-results/latest.md; FAIL=1; fi

{
  echo
  echo "## Wondertap compile gate (qcacld vs Soft-MAC)"
  if [ -f cloud-results/build.log ] && grep -q 'wlan_hdd_wondertap\.o' cloud-results/build.log; then
    echo "- wlan_hdd_wondertap.o: PRESENT in build.log (Kiwi HDD path)"
    grep -n 'wlan_hdd_wondertap' cloud-results/build.log | tail -n 20 | sed 's/^/  - /' || true
  else
    echo "- wlan_hdd_wondertap.o: ABSENT (Kiwi passthrough NOT compiled)"
  fi
  if [ -f cloud-results/build.log ] && grep -q 'wonder/wondertap\.o' cloud-results/build.log; then
    echo "- wonder/wondertap.o: PRESENT (Soft-MAC side only)"
  fi
  echo
  echo "## Located outputs (supplemental find)"
  find kernel_workspace cloud-results/artifacts -type f \( \
    -name 'Image' -o -name 'wonder.ko' -o -name 'cnss2.ko' \
    -o -name 'kiwi_v2.ko' -o -name 'qca_cld3*.ko' \
    -o -name 'Module.symvers' -o -name 'modules.order' \
  \) -printf '%p %s bytes\n' 2>/dev/null | sort -u | head -n 200 || true
} >> cloud-results/latest.md

if [ -f cloud-results/sync.log ]; then
  tail -n 1200 cloud-results/sync.log > cloud-results/sync-tail.txt
else
  echo "Sync step did not create sync.log." > cloud-results/sync-tail.txt
fi
if [ -f cloud-results/apply.log ]; then
  tail -n 1200 cloud-results/apply.log > cloud-results/apply-tail.txt
else
  echo "Apply step did not create apply.log." > cloud-results/apply-tail.txt
fi

{
  echo "# errors / diagnostics (filtered)"
  if [ -f cloud-results/build.log ]; then
    tail -n 1200 cloud-results/build.log > cloud-results/build-tail.txt
    echo
    echo "## compiler/linker failures"
    grep -nE 'error:|undefined reference|undefined symbol|MODPOST.*failed|make: \*\*\*' cloud-results/build.log \
      | grep -Ev 'ambiguous argument|de57127e~' \
      | tail -n 200 || echo "(none matched)"
    echo
    echo "## empty version macro arithmetic warnings (sample)"
    grep -n 'arithmetic expression: expecting primary' cloud-results/build.log | head -n 20 || echo "(none)"
  else
    echo "Build step did not create build.log." | tee cloud-results/build-tail.txt
  fi
  echo
  echo "## git shallow diagnostics"
  if [ -d kernel_workspace/.git ]; then
    if git -C kernel_workspace rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      echo "HEAD~1 available; shallow parent OK"
    else
      echo "diagnostic skipped: shallow history (no HEAD~1); vendor range-diff not available"
    fi
  else
    echo "diagnostic skipped: kernel_workspace/.git missing"
  fi
} > cloud-results/errors.txt

for f in latest.md sync-tail.txt apply-tail.txt build-tail.txt errors.txt; do
  cp -a "cloud-results/$f" "$RUN_DIR/$f"
done

if [ "$FAIL" -ne 0 ]; then
  echo "Evidence gate failed: one or more authoritative modules missing"
  exit 1
fi
