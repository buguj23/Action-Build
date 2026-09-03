# Ace 2 Pro Wonder cloud build

- UTC: 2026-09-03T14:19:41Z
- Run: https://github.com/buguj23/Action-Build/actions/runs/33765854227
- Branch: wonder-ace2-pro-cloud
- Input: oneplus_ace2_pro_b
- Public Kalama GKI build: true
- CNSS + kiwi_v2 + Wonder external module gate: required
- Passthrough data path: stage-3 ENABLED (wlan_hdd_wondertap gate)
- Runtime bind path: stage-4 software vendor-wlan-wonder + wonder pdev (no DTBO)
- Sync step outcome: success
- Build step outcome: skipped
- Device-tree build and changes: none
- Boot/flashable package: none (deploy-staging only; NOT flash-authorized)
- DTBO: none

## Source commits
- kernel_workspace/kernel_platform/common: f73647f94c84f5eabcaa00500594e152a29a4d38
- kernel_workspace/kernel_platform/msm-kernel: 30483bd5380464b2fcdec9d5002ba4e4086620a0
- kernel_workspace: de57127e10013d7269e791b43b8fce6718896e70

## Located outputs
- explicit kiwi_v2.ko: MISSING at kernel_workspace/kernel_platform/out/vendor/qcom/opensource/wlan/qcacld-3.0/kiwi_v2.ko

## Wondertap compile gate
- wlan_hdd_wondertap.o: ABSENT (Kiwi passthrough NOT compiled)

## Module metadata

## Stage-4 apply markers
- same-run Image: MISSING
## Strip / deploy-staging
- strip tool: /usr/lib/llvm-16/bin/llvm-strip
- deploy-staging tarball: 394 bytes
