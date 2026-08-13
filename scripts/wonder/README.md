# Ace 2 Pro Wonder cloud experiment

This branch uses `oneplus_ace2_pro_b` as the only synchronized build source.
No RMX3820, realme GT5, zonda, or other device source is imported.

Verified fact: the user has boot-tested an Image built with
`oneplus_ace2_pro_b`. This does not prove that Ace 2 Pro DTBO or vendor
modules are compatible with the phone.

Current stage:

- full official GitHub Actions build, never a local compilation;
- fixed OnePlusOSS source commits and per-file blob checks;
- fixed SM8850 Wonder donor commit;
- no device-tree modification;
- no automatic flashable Wonder package;
- compile artifacts and diagnostics only.

A successful build proves source/build closure only. It does not prove the
Wonder RF path, runtime binding, firmware compatibility, or safe installation.
