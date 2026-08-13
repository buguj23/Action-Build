#!/usr/bin/env bash
set -euo pipefail

workspace_root="${1:-}"
mkdir -p "${GITHUB_WORKSPACE:-.}/cloud-results"
exec > >(tee "${GITHUB_WORKSPACE:-.}/cloud-results/apply.log") 2>&1
trap 'status=$?; echo "apply script exit=$status" >&2; exit "$status"' EXIT
if [[ -z "$workspace_root" || ! -d "$workspace_root/kernel_platform" ]]; then
  echo "Usage: $0 <synced-kernel-workspace>" >&2
  exit 2
fi

common_commit="f73647f94c84f5eabcaa00500594e152a29a4d38"
msm_commit="30483bd5380464b2fcdec9d5002ba4e4086620a0"
vendor_commit="de57127e10013d7269e791b43b8fce6718896e70"
donor_commit="5ab2a689ff87d7d28c511f1762cf41c1b90d965a"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vendor_root="$workspace_root"

assert_commit() {
  local repo_dir="$1"
  local expected="$2"
  local actual
  actual="$(git -C "$repo_dir" rev-parse HEAD 2>&1 || true)"
  echo "commit check: $repo_dir expected=$expected actual=$actual"
  if [[ "$actual" != "$expected" ]]; then
    echo "Source commit mismatch: $repo_dir" >&2
    echo "expected=$expected" >&2
    echo "actual=$actual" >&2
    exit 20
  fi
}

assert_blob() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(git -C "$vendor_root" rev-parse "HEAD:$path" 2>&1 || true)"
  echo "blob check: $path expected=$expected actual=$actual"
  if [[ "$actual" != "$expected" ]]; then
    echo "Source blob mismatch: $path" >&2
    echo "expected=$expected" >&2
    echo "actual=$actual" >&2
    exit 21
  fi
}

assert_commit "$workspace_root/kernel_platform/common" "$common_commit"
assert_commit "$workspace_root/kernel_platform/msm-kernel" "$msm_commit"
assert_commit "$vendor_root" "$vendor_commit"

assert_blob "vendor/qcom/opensource/wlan/platform/cnss2/main.c" "735041c4af6ec1c27caee583d97ef8da7539a52f"
assert_blob "vendor/qcom/opensource/wlan/platform/cnss_utils/cnss_common.h" "ad3f2290e8032548b66d35c1c4478d6e5583cdf4"
assert_blob "vendor/qcom/opensource/wlan/platform/inc/cnss2.h" "d1f212df6997f2eaf4764513d10f562da2d1e178"
assert_blob "vendor/qcom/opensource/wlan/qcacld-3.0/core/pld/inc/pld_common.h" "e8c32cca4acb06170df30bac194186dba9600637"
assert_blob "vendor/qcom/opensource/wlan/qcacld-3.0/core/pld/src/pld_common.c" "7a52fe62a4c8c7cb4606896e090ad18d073c83d4"
assert_blob "vendor/qcom/opensource/wlan/qcacld-3.0/core/pld/src/pld_pcie.h" "ea940f5cf3f3d707b1256accc31578d913dccadc"
assert_blob "kernel_platform/oplus/config/modules.ext.5.15.oplus" "90ccd3e2bc0a2d3e252dcc47470e39e334837441"
assert_blob "kernel_platform/oplus/config/modules.ext.oplus" "f98da7923140c1820d01b09f42cabda5f5710fd3"

if [[ -e "$vendor_root/vendor/oplus/kernel/wifi/wonder" ]]; then
  echo "Wonder target already exists; refusing to overwrite it." >&2
  exit 22
fi

echo "checking foundation patch"
git -C "$vendor_root" apply --check "$script_dir/ace2-pro-wonder-foundation.patch"
echo "applying foundation patch"
git -C "$vendor_root" apply "$script_dir/ace2-pro-wonder-foundation.patch"

donor_checkout="$(mktemp -d)"
trap 'rm -rf "$donor_checkout"' EXIT
echo "cloning fixed Wonder donor"
git clone --filter=blob:none --no-checkout \
  https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850.git \
  "$donor_checkout"
git -C "$donor_checkout" sparse-checkout set vendor/oplus/kernel/wifi/wonder
git -C "$donor_checkout" checkout --detach "$donor_commit"
git -C "$donor_checkout" rev-parse HEAD

mkdir -p "$vendor_root/vendor/oplus/kernel/wifi"
cp -a "$donor_checkout/vendor/oplus/kernel/wifi/wonder" \
  "$vendor_root/vendor/oplus/kernel/wifi/wonder"
cp "$script_dir/overrides/Makefile" \
  "$vendor_root/vendor/oplus/kernel/wifi/wonder/Makefile"
cp "$script_dir/overrides/Makefile.include" \
  "$vendor_root/vendor/oplus/kernel/wifi/wonder/Makefile.include"

changed_paths="$(git -C "$vendor_root" status --short)"
printf '%s\n' "$changed_paths"
if printf '%s\n' "$changed_paths" | grep -Eiq 'devicetree|zonda|rmx3820|realme'; then
  echo "Forbidden device-specific change detected." >&2
  exit 23
fi

echo "Ace 2 Pro Wonder compile experiment applied."
echo "No device-tree file was changed."
