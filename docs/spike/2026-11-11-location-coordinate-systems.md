# Location coordinate systems

## Evidence

After 0.4.1, the user confirmed location changes worked, but a mainland address selected from search appeared approximately 704 metres away in Amap. The selected map coordinate was sent directly to the device, which expects WGS-84 GPS coordinates. A manual GCJ-02 to WGS-84 conversion was tested on the same device; the user confirmed it was essentially accurate and reached the intended destination. This confirms the correction for this observed case, not every map provider or region.

## 0.4.2 / build 21

- Search metadata `CN` selects GCJ-02; other country codes, including HK/MO/TW, select WGS-84. Missing metadata uses the visible map-region setting.
- Map taps use the selected map region. This setting controls coordinate interpretation and display, not MapKit's provider. Mainland is the default for the current environment; choose other regions for Hong Kong, Macau, Taiwan and overseas maps.
- Manual input has an explicit coordinate type. GPS input uses WGS-84. The device always receives WGS-84, while the source values and their type are retained for display and reuse.
- Changing the map region only changes display interpretation; it does not change the chosen input type or device target. Repeated apply and relaunch must not compound conversion.
- Legacy saved values without a type retain WGS-84 semantics, matching the former direct-send behavior and preserving the manually corrected workaround. Search again and select a result after upgrading to obtain automatic source metadata.
- The forward formula is adapted from MIT-licensed `wandergis/coordtransform`, pinned at `606c6f3b57b6f1d60458793fea39928d2b11b637`. The inverse iterates with a bound and convergence check. The numerical rectangle limits formula use; it is not a country classifier. Attribution and the MIT notice are bundled.

## Verification

Regression coverage includes independently fixed forward/inverse vectors, the on-device-confirmed mainland case, repeated apply, relaunch, manual GPS input, map taps, legacy values, map-region changes, and HK/MO/TW/overseas search metadata. Windows packaging tests passed (8); macOS XCTest and final artifact verification are pending.

## Device check

Cover-update using the existing Apple ID and LocSign identifier. Keep LocalDevVPN enabled. Search the same mainland address again, select the result and apply location, then verify Amap's actual blue dot. Repeat apply and relaunch to check that the destination remains stable. Manual GPS coordinates should use WGS-84. The new automatic implementation still needs this device confirmation; the successful manual comparison predates this build.
