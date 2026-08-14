# Ace 2 Pro Wonder cloud experiment

Baseline: `oneplus_ace2_pro_b` only. No GT5/RMX3820/zonda sources.

## Stages

1. **Compile Soft-MAC Wonder + CNSS provider hooks** (done)
2. **Evidence gate** for kiwi_v2.ko / wondertap.o ABSENT|PRESENT (done on run 31770595720)
3. **Kiwi Wondertap provider** (this stage): import `wlan_hdd_wondertap.*` + QDF headers from fixed SM8850 donor, enable `CONFIG_DRIVER_PASSTHRU_MODE` + `CONFIG_WONDER_SUPPORT` on kiwi_v2, register ops from HDD probe/re_init.

A green cloud build with `wlan_hdd_wondertap.o: PRESENT` proves compile closure of the provider path only. It does not prove runtime bind, wonder0, RF passthrough correctness, or safe flash.

Still forbidden: Ace 2 Pro DTBO flash as foreign DT, peach bdwlan, X9U 6.12 ko, full Mosey install before kernel gates pass.
