# PR #2 unsigned app preview

This bundle contains the compiled Madeira app from PR #2, including performance
profiles, local DXMT Spatial upscaling and experimental optical-flow interpolation.
It is built from source commit `4781dcbbd2038171970495dadb75894f53fe5a6e`.

[Download PR #2 as ZIP, including both app archive parts](https://github.com/hazerbvisor/Madeira-QoL/archive/refs/heads/feature/madeira-performance-upgrade.zip)

1. Download the ZIP and unzip it. Open its `packages/pr2` folder.
2. Keep `Madeira-PR2-unsigned.7z.001` and `Madeira-PR2-unsigned.7z.002` together.
   Open the **.001** file using an archive app that supports multi-volume 7z.
   Both parts are required; the archive app reads the second automatically.
   iPad Files can unzip the outer ZIP, but needs a 7z-capable app for this step.
3. Extract `Madeira-PR2-unsigned.ipa`. The archive also includes its checksum,
   build provenance and instructions. No compilation or manual file joining
   is needed. Sign/install the unsigned IPA with your usual sideloading tool.
4. To try interpolation, select **MadeiraFX → Frame interpolation → 2×
   (experimental)**, set a **30 FPS cap**, and relaunch. Admission requires stable
   native pacing, GPU headroom and compatible SDR output.

Alternatively, download the two parts directly into the same folder:

- [Part 1](https://github.com/hazerbvisor/Madeira-QoL/raw/refs/heads/feature/madeira-performance-upgrade/packages/pr2/Madeira-PR2-unsigned.7z.001)
- [Part 2](https://github.com/hazerbvisor/Madeira-QoL/raw/refs/heads/feature/madeira-performance-upgrade/packages/pr2/Madeira-PR2-unsigned.7z.002)
- [Part checksums](SHA256SUMS)

The complete archive is about 65 MB. The two parts fit the GitHub upload API's
size limit. Its IPA uses standard uncompressed ZIP entries; extracted app files
and their permissions match the tested compressed IPA exactly. The expanded IPA
is roughly 508 MiB, so allow enough space for extraction and installation.

The full app/helper build and 14 host suites passed. Actual Metal execution,
iPad image quality and displayed cadence remain unverified. See
[the implementation report](../../docs/PERFORMANCE_IMPLEMENTATION.md) and
[PR #2](https://github.com/hazerbvisor/Madeira-QoL/pull/2).
