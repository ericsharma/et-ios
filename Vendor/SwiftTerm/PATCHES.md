# SwiftTerm, vendored

Upstream: https://github.com/migueldeicaza/SwiftTerm, tag v1.20.0
(5d14406844143538cd8f8851d2d8a67c1fe443e5). Only `Sources/SwiftTerm`.

Changes:

- `Package.swift`: the `SwiftTerm` library target only. Upstream runs a
  build tool plugin (`SwiftTermBuildInfoPlugin`) that writes
  `SwiftTermBuildInfo.swift` from git. On the Mac mini (2026-10-23) every
  package plugin hung in its first CoreServices call (`bootstrap_look_up2`
  for coreservicesd), so no build could finish; the plugin is dropped.
- `Sources/SwiftTerm/SwiftTermBuildInfo.swift`: the generated file, written
  by hand for v1.20.0.

To update: copy `Sources/SwiftTerm` from the new tag and update the
version strings in `SwiftTermBuildInfo.swift`.
