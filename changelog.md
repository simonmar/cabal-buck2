# 0.6.0.0

  * For `cabal-install` version 3.18
  * The way the C/C++ compiler is chosen has changed. Previously it
    always defaulted to `clang`/`clang++` because those are the Buck2
    toolchain defaults. Now we use the `--with-gcc` option to Cabal if
    supplied, or GHC's "C compiler command" if it uses an absolute path,
    or otherwise the `clang`/`clang++` default as before.
  * The path to GHC, its tools and the C/C++ compilers are now fixed
    when you run `cabal buck2` rather than being found via `PATH`
    (see https://github.com/simonmar/haskell-buck2/issues/29)
  * An executable with `enable_profiling = True` now links its libraries'
    profiled archives whatever the build mode, rather than their
    non-profiled shared libraries in a dev build
    (see https://github.com/simonmar/haskell-buck2/issues/30)
  * The mode flags (-O etc.) now come before the package-specific
    flags (from `ghc-options` etc.) on the GHC command line.
  * A package's `data-files` are now found by `getDataFileName` when
    its code runs in the buck2 build. This includes the data files of
    the packages it depends on that buck2 builds. Haskell rules have a
    `data_dirs` attribute for this, and `cabal-buck2/packages.bzl` has
    `DATA_PACKAGES`.
  * C and C++ targets are rebuilt when `cabal buck2` finds a different
    C toolchain, with or without an action cache: the C tools are now run
    from a directory named by the C toolchain's fingerprint
    (`third-party/haskell/toolchain/<role>/<fingerprint>/`).
  * `cabal buck2 --cache` writes its settings to `.buckconfig.local`
    rather than `.buckconfig`, which is usually committed. A block that
    an earlier version wrote to `.buckconfig` is moved out the next time
    `--cache` or `--no-cache` is given.
  * `--source-deps` supports cabal.project `source-repository-package`s.
  * The Buck2 support code now comes with `cabal-buck2`. If the project
    has no `buck2/` directory, `cabal buck2` creates one from its own
    copy, and replaces it after an upgrade. A git checkout of
    haskell-buck2 in `buck2/` still works as before.
  * A project's `cabal-buck2.bzl` can give `DEFAULTS` for the generated
    targets, for every package or for one package, as well as
    `OVERRIDES` for individual components
    (see https://github.com/simonmar/cabal-buck2/issues/18).
  * A test-suite, benchmark or executable that only runs a tool of its
    `build-tool-depends` can say so with
    `x-buck2-ignore-build-tool-depends` and
    `x-buck2-run-tool-depends`, so that buck2 builds the tool once
    rather than again for the execution platform
    (see https://github.com/simonmar/haskell-buck2/issues/62).

# 0.5.0.0

  * For `cabal-install` version 3.18
  * Now works on MacOS X
  * A component's C, C++, assembler and Cmm sources are part of its
    library, as in Cabal: their objects are in the library's archive
    and shared library, rather than in libraries of their own linked
    alongside it. A library with no Haskell modules (only C sources,
    say) no longer gets a placeholder module.
  * A library that isn't exposed (`exposed: False`) is registered as
    such, and one whose `ghc-options` give it a unit id
    (`-this-unit-id`) has that unit id.
  * `-m static` and `-m shared` say how executables are linked,
    independently of the build mode (whose default is shared for dev,
    static for opt and prof).
  * `haskell_library` has a `soname` attribute, for a shared library
    whose soname isn't its file's name.
  * Configurations can be named by a project's own constraints too:
    `named_constraint_settings` in the `[cfg]` section of its
    `.buckconfig`.
  * Fix for using a combination of a Cabal `main-is` declaration
    together with `ghc-options: -main-is ...`.
  * Modules in `other-modules` are now correctly hidden outside the
    component.
  * A Template Haskell splice can use a module of the same library
    when profiling (`-m prof`).

# 0.4.0.0

  * For `cabal-install` version 3.18
  * `--enable-custom-setup` builds the packages with `build-type:
    Custom` as if they had `build-type: Configure` (if they have a
    `configure` script) or `Simple`, instead of skipping them. Their
    `Setup.hs` isn't run, so the modules it would generate (its
    `autogen-modules`) must be provided by the project.
  * A project can override the generated targets of its packages in a
    `cabal-buck2.bzl` at its root, rather than in each package's
    `BUCK` file.
  * A package's `extra-source-files` are a target,
    `<package>-extra-source-files`, for other targets that need them
    (a generator of the package's sources, say).
  * The `.hs-boot` file of a module is an input of the module's
    compilation, and is found next to its source when that is
    generated (by `happy`, say).
  * Pass `extra-lib-dirs` and `ld-options` through to Buck2. This
    fixes some cases of `pkgconfig-depends` not working correctly
    with Buck2, amongst other things.

# 0.3.0.0

  * For `cabal-install` version 3.18
  * The generated `BUCK.cabal.bzl` files no longer contain the
    directory of the package, or of the packages it depends on. The
    packages are is now in `cabal-buck2/packages.bzl` in the root of
    the project (which has an entry for each package that the project
    builds), so a package's `BUCK.cabal.bzl` is the same wherever the
    package is in the project, and whichever project it is part of.
    All of the packages have to be in the root Buck2 cell.
  * Support a GHC install whose package database isn't next to the
    libraries of its packages, such as a Nix `ghcWithPackages`.

# 0.2.0.1

  * For `cabal-install` version 3.18
  * Fix an issue with duplicate generated haskell_prebuilt_library()
    targets due to dependencies of build tools.

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

# 0.1.0.0

  * For `cabal-install` version 3.18
