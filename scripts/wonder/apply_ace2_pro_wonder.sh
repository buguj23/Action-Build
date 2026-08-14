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
echo "cloning fixed Wonder/Wondertap donor $donor_commit"
git clone --filter=blob:none --no-checkout \
  https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850.git \
  "$donor_checkout"
git -C "$donor_checkout" sparse-checkout set \
  vendor/oplus/kernel/wifi/wonder \
  vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_wondertap.c \
  vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/inc/wlan_hdd_wondertap.h \
  vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/inc/qdf_wondertap.h \
  vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/linux/src/i_qdf_wondertap.h \
  vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/linux/src/wondertap.h
git -C "$donor_checkout" checkout --detach "$donor_commit"
git -C "$donor_checkout" rev-parse HEAD
test "$(git -C "$donor_checkout" rev-parse \
  HEAD:vendor/oplus/kernel/wifi/wonder/mac80211.c)" = \
  "1e030ae84a00f311d5f76a58ae06782cea8c05c8"
test "$(git -C "$donor_checkout" rev-parse \
  HEAD:vendor/oplus/kernel/wifi/wonder/mac80211_txs.c)" = \
  "d19633819af0a0f021e86e0b2dbdfa815f25ee87"
test -f "$donor_checkout/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_wondertap.c"

mkdir -p "$vendor_root/vendor/oplus/kernel/wifi"
cp -a "$donor_checkout/vendor/oplus/kernel/wifi/wonder" \
  "$vendor_root/vendor/oplus/kernel/wifi/wonder"
cp "$script_dir/overrides/Makefile" \
  "$vendor_root/vendor/oplus/kernel/wifi/wonder/Makefile"
cp "$script_dir/overrides/Makefile.include" \
  "$vendor_root/vendor/oplus/kernel/wifi/wonder/Makefile.include"

echo "checking Wonder Linux 5.15 compatibility patch"
git -C "$vendor_root" apply --check \
  "$script_dir/ace2-pro-wonder-linux-5.15.patch"
echo "applying Wonder Linux 5.15 compatibility patch"
git -C "$vendor_root" apply \
  "$script_dir/ace2-pro-wonder-linux-5.15.patch"

echo "=== stage-3: import Kiwi Wondertap provider sources from donor ==="
# Prefer Ace2-compatible provider implementation shipped with Action-Build
if [[ -f "$script_dir/files/wlan_hdd_wondertap.c" ]]; then
  echo "using Ace2-compatible wlan_hdd_wondertap.c from scripts/wonder/files"
  cp -a "$script_dir/files/wlan_hdd_wondertap.c" \
    "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_wondertap.c"
else
  cp -a "$donor_checkout/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_wondertap.c" \
    "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_wondertap.c"
fi
if [[ -f "$script_dir/files/wlan_hdd_wondertap.h" ]]; then
  cp -a "$script_dir/files/wlan_hdd_wondertap.h" \
    "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/inc/wlan_hdd_wondertap.h"
else
  cp -a "$donor_checkout/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/inc/wlan_hdd_wondertap.h" \
    "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/inc/wlan_hdd_wondertap.h"
fi
cp -a "$donor_checkout/vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/inc/qdf_wondertap.h" \
  "$vendor_root/vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/inc/qdf_wondertap.h"
mkdir -p "$vendor_root/vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/linux/src"
cp -a "$donor_checkout/vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/linux/src/i_qdf_wondertap.h" \
  "$vendor_root/vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/linux/src/i_qdf_wondertap.h"
cp -a "$donor_checkout/vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/linux/src/wondertap.h" \
  "$vendor_root/vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/linux/src/wondertap.h"
for f in \
  vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_wondertap.c \
  vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/inc/wlan_hdd_wondertap.h \
  vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/inc/qdf_wondertap.h \
  vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/linux/src/i_qdf_wondertap.h \
  vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/linux/src/wondertap.h
 do
  test -s "$vendor_root/$f"
  ls -l "$vendor_root/$f"
 done

echo "=== stage-3: enable PASSTHRU/WONDER in Ace2 Pro kiwi tree ==="
python3 - <<'PY'
from pathlib import Path
import re
root = Path(r"""$vendor_root""")
# fix path - will be replaced
PY
# The above heredoc can't expand vendor_root inside single quotes properly for python path.
# Use env var:
export VENDOR_ROOT="$vendor_root"
python3 <<'PY'
from pathlib import Path
import re, os
root = Path(os.environ["VENDOR_ROOT"])

# --- qdf_types.h ---
p = root / "vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/inc/qdf_types.h"
t = p.read_text()
if "QDF_PASSTHRU_MODE" not in t:
    t = t.replace(
        " * @QDF_NAN_DISC_MODE: NAN Discovery device mode\n * @QDF_MAX_NO_OF_MODE: Max place holder",
        " * @QDF_NAN_DISC_MODE: NAN Discovery device mode\n * @QDF_PASSTHRU_MODE: Passthrough / Wonder mode\n * @QDF_MAX_NO_OF_MODE: Max place holder",
    )
    t = t.replace(
        "\tQDF_NAN_DISC_MODE,\n\n\t/* Add new OP Modes to qdf_opmode_str as well */",
        "\tQDF_NAN_DISC_MODE,\n\tQDF_PASSTHRU_MODE,\n\n\t/* Add new OP Modes to qdf_opmode_str as well */",
    )
    # also handle spaces-only indentation variants
    if "QDF_PASSTHRU_MODE" not in t:
        t = t.replace(
            "QDF_NAN_DISC_MODE,\n\n/* Add new OP Modes to qdf_opmode_str as well */",
            "QDF_NAN_DISC_MODE,\nQDF_PASSTHRU_MODE,\n\n/* Add new OP Modes to qdf_opmode_str as well */",
        )
    if "QDF_PASSTHRU_MODE" not in t:
        raise SystemExit("failed to patch qdf_types.h for QDF_PASSTHRU_MODE")
    p.write_text(t)
    print("patched qdf_types.h")
else:
    print("qdf_types.h already has PASSTHRU")

# --- qdf_types.c ---
p = root / "vendor/qcom/opensource/wlan/qca-wifi-host-cmn/qdf/src/qdf_types.c"
t = p.read_text()
if "QDF_PASSTHRU_MODE" not in t:
    needle = "\tcase QDF_NAN_DISC_MODE:\n\t\treturn \"NAN\";"
    if needle not in t:
        needle = "case QDF_NAN_DISC_MODE:\n\t\treturn \"NAN\";"
    if "return \"NAN\";" not in t:
        raise SystemExit("cannot find NAN case in qdf_types.c")
    t = t.replace(
        "case QDF_NAN_DISC_MODE:\n\t\treturn \"NAN\";",
        "case QDF_NAN_DISC_MODE:\n\t\treturn \"NAN\";\n\tcase QDF_PASSTHRU_MODE:\n\t\treturn \"PASSTHRU\";",
        1,
    )
    p.write_text(t)
    print("patched qdf_types.c")
else:
    print("qdf_types.c already has PASSTHRU")

# --- Kconfig ---
p = root / "vendor/qcom/opensource/wlan/qcacld-3.0/Kconfig"
t = p.read_text()
if "config DRIVER_PASSTHRU_MODE" not in t:
    if "endif # QCA_CLD_WLAN" not in t:
        raise SystemExit("Kconfig missing endif marker")
    block = '''
config DRIVER_PASSTHRU_MODE
	bool "Enable Driver Passthrough mode"
	default n
	help
	  Enable QCA driver passthrough mode used by Wonder/Wondertap.

config WONDER_SUPPORT
	bool "Enable Wonder support"
	depends on DRIVER_PASSTHRU_MODE
	default y
	help
	  Build HDD Wondertap provider ops for Google Wonder Soft-MAC.

'''
    t = t.replace("endif # QCA_CLD_WLAN", block + "endif # QCA_CLD_WLAN", 1)
    p.write_text(t)
    print("patched Kconfig")
else:
    print("Kconfig already has DRIVER_PASSTHRU_MODE")

# --- Kbuild ---
p = root / "vendor/qcom/opensource/wlan/qcacld-3.0/Kbuild"
t = p.read_text()
if "wlan_hdd_wondertap.o" not in t:
    marker = "$(call add-wlan-objs,hdd,$(HDD_OBJS))"
    insert = '''ifeq ($(CONFIG_DRIVER_PASSTHRU_MODE), y)
ifeq ($(CONFIG_WONDER_SUPPORT), y)
HDD_OBJS += $(HDD_SRC_DIR)/wlan_hdd_wondertap.o
endif
endif

'''
    if marker not in t:
        raise SystemExit("Kbuild missing add-wlan-objs hdd marker")
    t = t.replace(marker, insert + marker, 1)
    p.write_text(t)
    print("patched Kbuild HDD_OBJS")
else:
    print("Kbuild already has wondertap.o")

t = p.read_text()
if "ccflags-$(CONFIG_DRIVER_PASSTHRU_MODE)" not in t:
    # append near GET_DRIVER_MODE ccflags if present else end of file
    line = "ccflags-$(CONFIG_GET_DRIVER_MODE) += -DFEATURE_GET_DRIVER_MODE"
    add = (
        "ccflags-$(CONFIG_WONDER_SUPPORT) += -DCONFIG_WONDER_SUPPORT\n"
        "ccflags-$(CONFIG_DRIVER_PASSTHRU_MODE) += -DDRIVER_PASSTHRU_MODE\n"
    )
    if line in t:
        t = t.replace(line, line + "\n" + add, 1)
    else:
        t = t + "\n" + add
    p.write_text(t)
    print("patched Kbuild ccflags")
else:
    print("Kbuild ccflags already present")

# --- kiwi_v2_defconfig ---
p = root / "vendor/qcom/opensource/wlan/qcacld-3.0/configs/kiwi_v2_defconfig"
t = p.read_text()
if "CONFIG_DRIVER_PASSTHRU_MODE" not in t:
    t = t.rstrip() + "\n\n# Wonder / Wondertap provider (stage-3)\nCONFIG_DRIVER_PASSTHRU_MODE := y\nCONFIG_WONDER_SUPPORT := y\n"
    p.write_text(t)
    print("patched kiwi_v2_defconfig")
else:
    print("kiwi_v2_defconfig already has PASSTHRU")

# --- driver_ops.c ---
p = root / "vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_driver_ops.c"
t = p.read_text()
if "wlan_hdd_wondertap.h" not in t:
    import re as _re
    m = _re.search(r'#include\s+"[^"]+"', t)
    if not m:
        raise SystemExit("cannot insert wondertap include in driver_ops.c")
    pos = m.end()
    t = t[:pos] + '\n#include "wlan_hdd_wondertap.h"' + t[pos:]
if '#include "wlan_hdd_wondertap.h"' not in t:
    raise SystemExit("driver_ops.c missing wondertap include")
if "wlan_hdd_wondertap_register_ops" not in t:
    needle = "\toplus_register_oplus_wfd_wlan_ops_qcom();\n#endif\n\n\thdd_soc_load_unlock(dev);"
    repl = "\toplus_register_oplus_wfd_wlan_ops_qcom();\n#endif\n\twlan_hdd_wondertap_register_ops(dev);\n\n\thdd_soc_load_unlock(dev);"
    if needle not in t:
        # fallback without oplus block end exact
        needle2 = "\thdd_soc_load_unlock(dev);\n\n\treturn 0;\n\nwlan_exit:"
        if needle2 in t:
            t = t.replace(needle2, "\twlan_hdd_wondertap_register_ops(dev);\n\thdd_soc_load_unlock(dev);\n\n\treturn 0;\n\nwlan_exit:", 1)
        else:
            raise SystemExit("cannot insert register_ops in __hdd_soc_probe")
    else:
        t = t.replace(needle, repl, 1)
if "wlan_hdd_wondertap_unregister_ops" not in t:
    needle = "#ifdef OPLUS_FEATURE_WIFI_OPLUSWFD\nopplus_wfd_set_hdd_ctx(NULL);\n#endif\n\nqdf_rtpm_sync_resume();"
    # tabs variants
    for n in [
        "\toplus_wfd_set_hdd_ctx(NULL);\n#endif\n\n\tqdf_rtpm_sync_resume();",
        "oplus_wfd_set_hdd_ctx(NULL);\n#endif\n\nqdf_rtpm_sync_resume();",
    ]:
        if n in t:
            t = t.replace(n, n.replace("qdf_rtpm_sync_resume();", "wlan_hdd_wondertap_unregister_ops(dev, true);\n\tqdf_rtpm_sync_resume();"), 1)
            break
    else:
        # insert after Removing driver pr_info
        if "Removing driver" in t and "wlan_hdd_wondertap_unregister_ops" not in t:
            t = t.replace(
                "pr_info(\"%s: Removing driver v%s\\n\", WLAN_MODULE_NAME,\n\t\tQWLAN_VERSIONSTR);\n",
                "pr_info(\"%s: Removing driver v%s\\n\", WLAN_MODULE_NAME,\n\t\tQWLAN_VERSIONSTR);\n\twlan_hdd_wondertap_unregister_ops(dev, true);\n",
                1,
            )
p.write_text(t)
print("patched driver_ops.c")

# --- power.c ---
p = root / "vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_power.c"
t = p.read_text()

def ensure_include(src: str, header: str) -> str:
    needle = f'#include "{header}"'
    if needle in src:
        return src
    # Prefer after any existing wlan_hdd_*.h include
    import re
    m = re.search(r'#include\s+"wlan_hdd_[^"]+\.h"', src)
    if m:
        pos = m.end()
        return src[:pos] + f"\n#include \"{header}\"" + src[pos:]
    # Fallback: after first #include block line
    m = re.search(r'(#include\s+[<"][^>"]+[>"].*\n)', src)
    if m:
        pos = m.end()
        return src[:pos] + f'#include "{header}"\n' + src[pos:]
    raise SystemExit(f"cannot insert include {header} into {p}")

t = ensure_include(t, "wlan_hdd_wondertap.h")

if "wlan_hdd_wondertap_unregister_ops" not in t:
    if "hdd_wlan_stop_modules(hdd_ctx, false);" not in t:
        raise SystemExit("power.c missing hdd_wlan_stop_modules for unregister insert")
    t = t.replace(
        "hdd_wlan_stop_modules(hdd_ctx, false);",
        "wlan_hdd_wondertap_unregister_ops(hdd_ctx->parent_dev, true);\n\thdd_wlan_stop_modules(hdd_ctx, false);",
        1,
    )

if "wlan_hdd_wondertap_register_ops(hdd_ctx->parent_dev)" not in t:
    marker = 'hdd_info("WLAN host driver reinitiation completed!");'
    if marker not in t:
        raise SystemExit("power.c missing re_init completion marker")
    t = t.replace(
        marker,
        "wlan_hdd_wondertap_register_ops(hdd_ctx->parent_dev);\n\t" + marker,
        1,
    )

if '#include "wlan_hdd_wondertap.h"' not in t:
    raise SystemExit("power.c still missing wondertap include after patch")
if "wlan_hdd_wondertap_register_ops" not in t or "wlan_hdd_wondertap_unregister_ops" not in t:
    raise SystemExit("power.c missing wondertap call sites after patch")

p.write_text(t)
print("patched power.c (include+calls verified)")

print("stage-3 tree edits done")
PY

changed_paths="$(git -C "$vendor_root" status --short)"
printf '%s\n' "$changed_paths"
if printf '%s\n' "$changed_paths" | grep -Eiq 'devicetree|zonda|rmx3820|realme'; then
  echo "Forbidden device-specific change detected." >&2
  exit 23
fi

# Sanity: wondertap sources present and configs enabled
test -f "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_wondertap.c"
test -f "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/inc/wlan_hdd_wondertap.h"
grep -q 'CONFIG_DRIVER_PASSTHRU_MODE := y' \
  "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/configs/kiwi_v2_defconfig"
grep -q 'wlan_hdd_wondertap.o' \
  "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/Kbuild"
grep -q 'wlan_hdd_wondertap.h' \
  "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_power.c"
grep -q 'wlan_hdd_wondertap.h' \
  "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_driver_ops.c"
grep -q 'wlan_hdd_wondertap_register_ops' \
  "$vendor_root/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_power.c"
echo "stage-3 preflight OK: sources + includes + configs present"

echo "=== stage-4: no-DT software provider/bind path ==="
# Replace Wonder main.c with Ace2 software-bind implementation
if [[ -f "$script_dir/files/wonder_main.c" ]]; then
  cp -a "$script_dir/files/wonder_main.c" \
    "$vendor_root/vendor/oplus/kernel/wifi/wonder/main.c"
  echo "installed stage4 wonder main.c (software pdev + name match)"
else
  echo "ERROR: scripts/wonder/files/wonder_main.c missing" >&2
  exit 24
fi
grep -q 'stage4 software/DT' \
  "$vendor_root/vendor/oplus/kernel/wifi/wonder/main.c"
grep -q 'WONDER_PROVIDER_PDEV_NAME' \
  "$vendor_root/vendor/oplus/kernel/wifi/wonder/main.c"
grep -q 'platform_device_register_simple' \
  "$vendor_root/vendor/oplus/kernel/wifi/wonder/main.c"

# Patch cnss2 foundation wonder path: software vendor-wlan-wonder + id_table probe
export VENDOR_ROOT="$vendor_root"
python3 <<'PY4'
from pathlib import Path
import os, re
p = Path(os.environ["VENDOR_ROOT"]) / "vendor/qcom/opensource/wlan/platform/cnss2/main.c"
t = p.read_text()
if "cnss_ensure_software_wonder_pdev" in t:
    print("cnss stage4 already present")
else:
    # Insert software pdev helper before cnss_set_vendor_wonder_priv_data
    old_set = """int cnss_set_vendor_wonder_priv_data(const void *priv_data)
{
	wonder_priv_data = priv_data;

	if (!wonder_plat_dev) {
		cnss_pr_info("vendor wonder platform device not available\\n");
		return 0;
	}

	if (wonder_priv_data)
		return cnss_add_vendor_wonder_component();

	cnss_del_vendor_wonder_component();
	return 0;
}"""
    new_set = """/* Stage-4: create software pdev when DT lacks qcom,cnss-vendor-wlan-wonder */
static struct platform_device *wonder_sw_pdev;

static int cnss_ensure_software_wonder_pdev(void)
{
	if (wonder_plat_dev || wonder_sw_pdev)
		return 0;

	wonder_sw_pdev = platform_device_register_simple(
		"vendor-wlan-wonder", PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(wonder_sw_pdev)) {
		int ret = PTR_ERR(wonder_sw_pdev);

		wonder_sw_pdev = NULL;
		cnss_pr_err("software vendor-wlan-wonder register failed %d\\n",
			    ret);
		return ret;
	}
	cnss_pr_info("software vendor-wlan-wonder pdev registered (no-DT)\\n");
	return 0;
}

static bool cnss_is_wonder_vendor_pdev(struct platform_device *plat_dev)
{
	const struct platform_device_id *id;
	const struct of_device_id *of_id;

	id = platform_get_device_id(plat_dev);
	if (id && id->driver_data == WONDER_VENDOR_DEVICE_ID)
		return true;

	of_id = of_match_device(cnss_of_match_table, &plat_dev->dev);
	if (of_id && of_id->data) {
		id = of_id->data;
		if (id->driver_data == WONDER_VENDOR_DEVICE_ID)
			return true;
	}
	return false;
}

int cnss_set_vendor_wonder_priv_data(const void *priv_data)
{
	int ret;

	wonder_priv_data = priv_data;

	if (!wonder_plat_dev) {
		ret = cnss_ensure_software_wonder_pdev();
		if (ret)
			return ret;
		/* register_simple probes synchronously on same thread */
		if (!wonder_plat_dev) {
			cnss_pr_info("vendor wonder pdev pending probe\\n");
			return 0;
		}
	}

	if (wonder_priv_data)
		return cnss_add_vendor_wonder_component();

	cnss_del_vendor_wonder_component();
	return 0;
}"""
    if old_set not in t:
        raise SystemExit("cnss_set_vendor_wonder_priv_data block not found for stage4")
    t = t.replace(old_set, new_set, 1)

    # Probe: prefer id_table / software wonder before hard of_match fail
    old_probe = """	of_id = of_match_device(cnss_of_match_table, &plat_dev->dev);
	if (!of_id || !of_id->data) {
		cnss_pr_err("Failed to find of match device!\\n");
		ret = -ENODEV;
		goto out;
	}

	device_id = of_id->data;
	if (device_id->driver_data == WONDER_VENDOR_DEVICE_ID)
		return cnss_vendor_wonder_dev_probe(plat_dev);

	if (cnss_get_plat_priv(plat_dev)) {"""
    new_probe = """	/* Stage-4: software / id_table wonder pdev has no of_node */
	if (cnss_is_wonder_vendor_pdev(plat_dev))
		return cnss_vendor_wonder_dev_probe(plat_dev);

	of_id = of_match_device(cnss_of_match_table, &plat_dev->dev);
	if (!of_id || !of_id->data) {
		cnss_pr_err("Failed to find of match device!\\n");
		ret = -ENODEV;
		goto out;
	}

	device_id = of_id->data;

	if (cnss_get_plat_priv(plat_dev)) {"""
    if old_probe not in t:
        raise SystemExit("cnss_probe wonder early block not found for stage4")
    t = t.replace(old_probe, new_probe, 1)

    old_rm = """	of_id = of_match_device(cnss_of_match_table, &plat_dev->dev);
	if (!of_id || !of_id->data) {
		cnss_pr_err("cnss remove failed to find of match device!\\n");
		return -ENODEV;
	}

	device_id = of_id->data;
	if (device_id->driver_data == WONDER_VENDOR_DEVICE_ID) {
		cnss_vendor_wonder_dev_remove();
		return 0;
	}

	plat_priv = platform_get_drvdata(plat_dev);"""
    new_rm = """	if (cnss_is_wonder_vendor_pdev(plat_dev)) {
		cnss_vendor_wonder_dev_remove();
		return 0;
	}

	of_id = of_match_device(cnss_of_match_table, &plat_dev->dev);
	if (!of_id || !of_id->data) {
		cnss_pr_err("cnss remove failed to find of match device!\\n");
		return -ENODEV;
	}

	device_id = of_id->data;
	plat_priv = platform_get_drvdata(plat_dev);"""
    if old_rm not in t:
        raise SystemExit("cnss_remove wonder block not found for stage4")
    t = t.replace(old_rm, new_rm, 1)

    # Log on component add
    t = t.replace(
        "\twonder_component_added = true;\n\treturn 0;\n}\n\nstatic void cnss_del_vendor_wonder_component",
        "\twonder_component_added = true;\n\tcnss_pr_info(\"vendor wondertap ops component registered\\n\");\n\treturn 0;\n}\n\nstatic void cnss_del_vendor_wonder_component",
        1,
    )
    p.write_text(t)
    print("patched cnss2/main.c for stage4 software wonder pdev")

# verify
t2 = p.read_text()
for s in [
    "cnss_ensure_software_wonder_pdev",
    "cnss_is_wonder_vendor_pdev",
    "software vendor-wlan-wonder",
    "vendor wondertap ops component registered",
]:
    if s not in t2:
        raise SystemExit(f"missing after patch: {s}")
print("cnss stage4 verify OK")
PY4

grep -q 'cnss_ensure_software_wonder_pdev' \
  "$vendor_root/vendor/qcom/opensource/wlan/platform/cnss2/main.c"
grep -q 'cnss_is_wonder_vendor_pdev' \
  "$vendor_root/vendor/qcom/opensource/wlan/platform/cnss2/main.c"
echo "stage-4 preflight OK: no-DT wonder main + cnss software provider"


echo "Ace 2 Pro Wonder stage-3+4 applied (passthrough compile + no-DT bind)."
echo "No device-tree file was changed."
echo "Passthrough: ENABLED. Runtime bind: software vendor-wlan-wonder + wonder pdev."
