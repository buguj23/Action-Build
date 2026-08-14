# Cloud build — Ace2 mon-session / soft_init (next kiwi)

## Goal
1. `get_capabilities` real bits (not stub zero)
2. `wlan_hdd_wondertap_init` default **soft_init=1** (no mon session → no hard reboot)
3. `CONFIG_PANIC_ON_BUG := n` so full_init failures return errno instead of rebooting
4. Optional: `soft_init=0` to exercise MONITOR mon-session once logs are greppable

## Inputs already in tree
| Path | Content |
|------|---------|
| `stage4/files/wlan_hdd_wondertap.c` | Ace2 provider + soft_init + real caps + no ASSERT_RTNL |
| `stage4/apply_ace2_pro_wonder.sh` | copies files/, patches defconfig PASSTHRU + **PANIC_ON_BUG=n** |

## Build
Same Stage5 cloud workflow as run `31791244784` / Action-Build Wonder CI:
1. apply `apply_ace2_pro_wonder.sh` on Ace2 Pro workspace
2. build kiwi_v2 + cnss2 + wonder (vermagic `5.15.180-android13-wonder-ci`)
3. collect `kiwi_v2.ko` / renamed `kiwi_w2.ko`

## Device bring-up after flash/push
```sh
# modules in KSU wonder_stack/renamed/
# cnss5 (id_table) + kiwi_w2 (new) + wonder (start0 or full)

# soft_init is default 1 — vendor init is stub, safe:
insmod kiwi_w2.ko
# verify:
dmesg | grep soft_init
# full mon-session attempt (expect errno, not reboot, with PANIC_ON_BUG=n):
echo 0 > /sys/module/kiwi_v2/parameters/soft_init   # if param lives under kiwi_v2 name
# name may be kiwi_v2 even when file is kiwi_w2.ko
```

## After soft_init green on device
1. Switch wonder from **start0** to full `wonder_start` (calls wondertap_init)
2. `physical_name=wlan0` or wondertap0 once full_init creates it
3. Enable `netdev_rx_handler_register` for data path
4. QS / ART

## Local interim (current phone)
| Module | Role |
|--------|------|
| cnss5.ko | id_table bind |
| kiwi_w2_cap.ko | binary get_capabilities=0x1f00 |
| wonder_start0.ko | start returns 0 → **wonder0 UP** |
| wonder_cache.sh | nl80211 cache only |

Do **not** call real mon-session init until new kiwi lands.
