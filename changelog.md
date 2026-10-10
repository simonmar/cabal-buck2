# 0.1.0.0

  * For `cabal-install` version 3.18

# 0.2.0.0

  * For `cabal-install` version 3.18
  * Major new features (see the README for more details):
    * Support for a build cache (`cabal buck2 --cache=...`), setup
      instructions in the README.
    * Support for building the whole dependency tree with Buck2,
      avoiding the Cabal store entirely (`cabal buck2
      --source-deps`). This works particularly well in conjunction
      with a build cache, because the cache does the job of the Cabal
      store. The biggest blocker here is that packages using
      `build-type: Custom` are not supported, however.
    * Partial support for `build-type: hooks`.
  * Minor new features:
    * Support for `asm-sources` and `cmm-sources`.
    * `cabal buck2` now aborts with an error if any components cannot
      be translated due to an unsupported feature (e.g. `build-type:
      Custom`). Use `--keep-going` to skip unsupported components
      instead of failing.
  * Fixes:
    * Various fixes for `hsc2hs`
    * Handle Happy parsers with a `.ly` extension
    * Module re-exports are handled correctly
    * Fix name clash problem with prebuilt sublibraries
    * Fix broken `cabal buck2 -j`
