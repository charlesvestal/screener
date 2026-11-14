Vendored copy of attaswift/BigInt v5.7.0 (e07e00fa1fd435143a2dcf8b7eec9a7710b2fdfe),
MIT licensed (LICENSE.md). Sources are unmodified.

Why vendored: SwiftPM packages build at -Onone in Debug, which makes the SRP
4096-bit modexps ~17x slower (7.8 s vs 0.46 s per login on an M1 simulator).
project.yml builds this copy as a static library with -O in every
configuration.
