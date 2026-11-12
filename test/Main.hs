-- | Runs @cabal-buck2@ on the fixture projects in @test/fixtures@ and checks
-- the files it generates. None of these needs a buck2 binary, or a buck2
-- prelude: the fixtures' @buck2@ directory only has to exist.
module Main (main) where

import Control.Exception (SomeException, bracket, displayException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.List (isInfixOf, isPrefixOf, nub)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Map as Map
import qualified Data.Set as Set
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , doesPathExist
  , executable
  , getPermissions
  , removeFile
  , findExecutable
  , getTemporaryDirectory
  , listDirectory
  , makeAbsolute
  , removeDirectoryRecursive
  )
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (CreateProcess (..), callProcess, getCurrentPid, proc, readCreateProcessWithExitCode, readProcess)

import Distribution.Client.Buck2.Cache (cacheBlock, spliceBlock)
import Distribution.Client.Buck2.Fingerprint (ccFingerprintOf, fingerprintOf)
import Distribution.Client.Buck2.Prebuilt (RepoPaths (..), externalDirs, prebuiltLinkerFlags, toRepoRelative)
import Distribution.Client.Buck2.Toolchain (chooseCompilers, cxxCompilerFor)
import Distribution.Client.Buck2.Version (cabalBuck2Version)
import Distribution.InstalledPackageInfo (InstalledPackageInfo (..), emptyInstalledPackageInfo)
import Distribution.PackageDescription (dataFiles, packageDescription, specVersion)
import Distribution.Simple.Glob (matchDirFileGlob)
import Distribution.Simple.PackageDescription (readGenericPackageDescription)
import Distribution.Utils.Path (getSymbolicPath, makeSymbolicPath)
import Distribution.Verbosity (defaultVerbosityHandles, mkVerbosity, silent)

main :: IO ()
main = do
  -- The executable to test: $CABAL_BUCK2_EXE if it's set (as when this is run by
  -- buck2, which only puts a build-tool-depends executable on PATH for
  -- building, not for running tests - see BUCK), otherwise the one on PATH (as
  -- `cabal test` has it, from build-tool-depends).
  fromEnv <- lookupEnv "CABAL_BUCK2_EXE"
  exe <- case fromEnv of
    Just path -> makeAbsolute path -- the tests run in other directories
    Nothing -> maybe (fail "cabal-buck2 not found on PATH") return =<< findExecutable "cabal-buck2"
  results <- mapM (runTest exe) tests
  unitResults <- mapM runUnitTest unitTests
  let failures =
        [name | (name, False) <- zip (map fst tests) results]
          ++ [name | (name, False) <- zip (map fst unitTests) unitResults]
  unless (null failures) $ do
    hPutStrLn stderr $ "FAILED: " ++ unwords failures
    exitFailure

unitTests :: [(String, IO ())]
unitTests = [("fingerprint", fingerprint), ("cc-fingerprint", ccFingerprint), ("splice-block", spliceBlockTest), ("external-dirs", externalDirsTest), ("linker-flags", linkerFlagsTest), ("choose-compilers", chooseCompilersTest), ("data-files", dataFilesTest)]

runUnitTest :: (String, IO ()) -> IO Bool
runUnitTest (name, test) = do
  r <- try test
  case r of
    Right () -> putStrLn ("PASS " ++ name) >> return True
    Left e -> do
      hPutStrLn stderr ("FAIL " ++ name ++ ": " ++ displayException (e :: SomeException))
      return False

tests :: [(String, Project -> IO ())]
tests =
  [ ("basic", basic)
  , ("disabled-stanzas", disabledStanzas)
  , ("missing-module", missingModule)
  , ("cache-config", cacheConfig)
  , ("source-deps", sourceDeps)
  , ("custom-setup", customSetup)
  , ("reexports", reexports)
  , ("buck2-version", buck2Version)
  , ("buck2-unpack", buck2Unpack)
  , ("project-overrides", projectOverrides)
  , ("pkgconfig", pkgconfig)
  , ("project-overrides", projectOverrides)
  , ("same-name", sameName)
  , ("normalise-paths", normalisePaths)
  , ("run-tools", runTools)
  ]

-- | A library and an executable with the same name in one package, and
-- another package that needs that executable as a build tool.
sameName :: Project -> IO ()
sameName project = do
  _ <- buck2 project []

  -- The executable can't have the library's target name, so it gets a
  -- suffix - and a build-tool-depends on it from another package has to
  -- name it the same way, or buck2 won't find the target.
  toolBzl <- readIn project ("tool" </> "BUCK.cabal.bzl")
  let tool = assertContains "tool/BUCK.cabal.bzl"
  tool "'kind': 'library'" toolBzl
  tool "'name': 'tool'" toolBzl
  tool "'kind': 'executable'" toolBzl
  tool "'name': 'tool-exe'" toolBzl
  userBzl <- readIn project ("user" </> "BUCK.cabal.bzl")
  assertContains "user/BUCK.cabal.bzl" "'exe': 'tool-exe'" userBzl
  assertContains "user/BUCK.cabal.bzl" "'package': 'tool'" userBzl

-- | Check that we handle @x-buck2-ignore-build-tool-depends@ and
-- @x-buck2-run-tool-depends@ correctly for a test suite. 
runTools :: Project -> IO ()
runTools project = do
  original <- readIn project cabalFile
  let with stanza fields = do
        let (before, after) = breakOn stanza original
        writeFile (projectDir project </> cabalFile) (before ++ stanza ++ fields ++ drop (length stanza) after)
        runBuck2 project ["--enable-tests"]
      tool = "  build-tool-depends: exe-pkg:exe-pkg-exe\n"

  -- Without either field, the executable is both a build tool and a run
  -- tool, because cabal test puts build-tool-depends on the test's PATH.
  _ <- with testStanza tool
  plain <- readIn project bzl
  assertContains bzl "'build_tools'" plain
  assertContains bzl "'run_tools'" plain

  -- With both fields, the executable is only a run tool.
  (_, _) <- with testStanza (tool ++ "  x-buck2-ignore-build-tool-depends: exe-pkg:exe-pkg-exe\n  x-buck2-run-tool-depends: exe-pkg:exe-pkg-exe\n")
  fields <- readIn project bzl
  assertNotContains bzl "'build_tools'" fields
  assertContains bzl "'run_tools': [\n                {\n                    'exe': 'exe-pkg-exe',\n                    'package': 'exe-pkg',\n                },\n            ]" fields

  -- An empty x-buck2-run-tool-depends means that the test runs no tools.
  _ <- with testStanza (tool ++ "  x-buck2-run-tool-depends:\n")
  empty <- readIn project bzl
  assertContains bzl "'build_tools'" empty
  assertNotContains bzl "'run_tools'" empty

  -- cabal-buck2 rejects fields that it can't use. Its output wraps the
  -- message, so these checks compare words rather than lines.
  (_, unlisted) <- with testStanza "  x-buck2-ignore-build-tool-depends: exe-pkg:exe-pkg-exe\n"
  assertContains "output" "skipping test-suite exe-pkg-test (x-buck2-ignore-build-tool-depends lists exe-pkg:exe-pkg-exe, which build-tool-depends doesn't)" (unwords (words unlisted))

  (_, library) <- with "library\n" "  x-buck2-run-tool-depends: exe-pkg:exe-pkg-exe\n"
  assertContains "output" "skipping library exe-pkg (x-buck2-run-tool-depends is only for components that run)" (unwords (words library))
  where
    cabalFile = "exe-pkg" </> "exe-pkg.cabal"
    bzl = "exe-pkg" </> "BUCK.cabal.bzl"
    testStanza = "test-suite exe-pkg-test\n"
    breakOn needle s = go "" s
      where
        go acc rest@(c : cs)
          | needle `isPrefixOf` rest = (reverse acc, rest)
          | otherwise = go (c : acc) cs
        go acc [] = (reverse acc, [])

-- | Paths written with a @.\/@ prefix, in cabal.project and in the file
-- patterns of a package: buck2 accepts neither in a label nor in a glob.
normalisePaths :: Project -> IO ()
normalisePaths project = do
  _ <- buck2 project []

  -- `./pkg/pkg.cabal` in cabal.project is the package in `pkg`.
  packages <- readIn project ("cabal-buck2" </> "packages.bzl")
  assertContains "cabal-buck2/packages.bzl" "'pkg': 'pkg'" packages
  assertNotContains "cabal-buck2/packages.bzl" "./" packages

  -- The patterns buck2 globs for come out without the prefix too.
  pkgBzl <- readIn project ("pkg" </> "BUCK.cabal.bzl")
  assertContains "pkg/BUCK.cabal.bzl" "'data/x.txt'" pkgBzl
  assertContains "pkg/BUCK.cabal.bzl" "'README'" pkgBzl
  assertNotContains "pkg/BUCK.cabal.bzl" "'./" pkgBzl

-- | A copy of a fixture project, and how to run @cabal-buck2@ in it.
data Project = Project
  { projectDir :: FilePath
  , runBuck2 :: [String] -> IO (ExitCode, String)
  -- ^ The exit code and the output (stdout and stderr).
  }

runTest :: FilePath -> (String, Project -> IO ()) -> IO Bool
runTest exe (name, test) = do
  tmp <- getTemporaryDirectory
  pid <- getCurrentPid
  let dir = tmp </> ("cabal-buck2-test-" ++ show pid ++ "-" ++ name)
  bracket (setup dir) (const (cleanup dir)) $ \project -> do
    r <- try (test project)
    case r of
      Right () -> putStrLn ("PASS " ++ name) >> return True
      Left e -> do
        hPutStrLn stderr ("FAIL " ++ name ++ ": " ++ displayException (e :: SomeException))
        return False
  where
    -- The fixture is named after the test, except for tests that reuse one.
    fixture = case name of
      "disabled-stanzas" -> "basic"
      "cache-config" -> "basic"
      "buck2-version" -> "basic"
      "buck2-unpack" -> "basic"
      "project-overrides" -> "basic"
      "run-tools" -> "basic"
      _ -> name
    setup dir = do
      cleanup dir
      copyTree ("test" </> "fixtures" </> fixture) (dir </> "project")
      -- What a checkout of the right branch of haskell-buck2 has.
      writeBuck2Version (dir </> "project") cabalBuck2Version
      env <- getEnvironment
      -- The compiler to use: $HC if it's set (as haskell-ci does), otherwise
      -- whatever `ghc` is on the PATH.
      compilerArgs <- maybe [] (\hc -> ["-w", hc]) <$> lookupEnv "HC"
      -- A private cabal directory and config, so that the user's store and
      -- config (which $CABAL_DIR and $CABAL_CONFIG may point to, as in
      -- haskell-ci) are neither used nor changed.
      let cabalDir = dir </> "cabal-dir"
          -- A fixture can have pkg-config files of its own, in pkgconfig/.
          pkgConfigPath = dir </> "project" </> "pkgconfig" ++ maybe "" (':' :) (lookup "PKG_CONFIG_PATH" env)
          cabalEnv =
            [("CABAL_DIR", cabalDir), ("CABAL_CONFIG", cabalDir </> "config"), ("PKG_CONFIG_PATH", pkgConfigPath)]
              ++ [kv | kv@(k, _) <- env, k `notElem` ["CABAL_DIR", "CABAL_CONFIG", "PKG_CONFIG_PATH"]]
          run args = do
            (code, out, err) <-
              readCreateProcessWithExitCode
                (proc exe (compilerArgs ++ args)){cwd = Just (dir </> "project"), env = Just cabalEnv}
                ""
            return (code, out ++ err)
      createDirectoryIfMissing True cabalDir
      writeFile (cabalDir </> "config") ""
      return Project{projectDir = dir </> "project", runBuck2 = run}
    cleanup dir = do
      exists <- doesDirectoryExist dir
      when exists $ removeDirectoryRecursive dir

writeBuck2Version :: FilePath -> String -> IO ()
writeBuck2Version projectDir' version =
  writeFile (projectDir' </> "buck2" </> "version.bzl") ("CABAL_BUCK2_VERSION = \"" ++ version ++ "\"\n")

copyTree :: FilePath -> FilePath -> IO ()
copyTree from to = do
  createDirectoryIfMissing True to
  names <- listDirectory from
  forM_ names $ \n -> do
    isDir <- doesDirectoryExist (from </> n)
    if isDir then copyTree (from </> n) (to </> n) else copyFile (from </> n) (to </> n)

-- * Assertions

-- | Run @cabal-buck2@ and check that it succeeded.
buck2 :: Project -> [String] -> IO String
buck2 project args = do
  (code, out) <- runBuck2 project args
  when (code /= ExitSuccess) $ failure ("cabal-buck2 " ++ unwords args ++ " failed:\n" ++ out)
  return out

failure :: String -> IO a
failure = ioError . userError

readIn :: Project -> FilePath -> IO String
readIn project path = do
  s <- readFile (projectDir project </> path)
  length s `seq` return s

assertContains :: String -> String -> String -> IO ()
assertContains what needle haystack =
  unless (needle `isInfixOf` haystack) $
    failure (what ++ ": expected to contain " ++ show needle ++ ", but it is:\n" ++ haystack)

assertNotContains :: String -> String -> String -> IO ()
assertNotContains what needle haystack =
  when (needle `isInfixOf` haystack) $
    failure (what ++ ": expected not to contain " ++ show needle ++ ", but it is:\n" ++ haystack)

-- * Tests

-- | The fingerprint of the GHC installation, which keeps the buck2 action
-- cache from serving the output of a different GHC.
fingerprint :: IO ()
fingerprint = do
  let props = Map.fromList [("Project version", "9.6.7"), ("Target platform", "x86_64-unknown-linux"), ("Project Git commit id", "2b22b6ae69c94e721fde8af0108eb0feed97cc82"), ("RTS ways", "debug thr")]
      conf abi = BS8.pack ("name: base\nversion: 4.18\nabi: " ++ abi ++ "\nid: base-4.18\n")
      confs = [("base-4.18.conf", conf "aaaa"), ("ghc-prim-0.10.conf", conf "bbbb")]
      fp = fingerprintOf props confs
  -- Readable: version, platform and source commit come first.
  assertContains "fingerprint" "9.6.7-x86_64-unknown-linux-2b22b6ae-" fp
  -- It doesn't depend on the order of the files.
  assertEqual "fingerprint of reordered confs" fp (fingerprintOf props (reverse confs))
  -- It changes with the interface hash of any package, with the GHC commit,
  -- and with the build properties.
  assertDiffers "changed abi" fp (fingerprintOf props [("base-4.18.conf", conf "aaaa"), ("ghc-prim-0.10.conf", conf "cccc")])
  assertDiffers "changed commit" fp (fingerprintOf (Map.insert "Project Git commit id" "3b22b6ae69c9" props) confs)
  assertDiffers "changed RTS ways" fp (fingerprintOf (Map.insert "RTS ways" "debug thr dyn" props) confs)
  -- Properties it doesn't use don't matter.
  assertEqual "unused property" fp (fingerprintOf (Map.insert "C compiler command" "gcc" props) confs)

-- | The fingerprint of the C toolchain: GHC uses it to preprocess and link, and
-- buck2 to compile and link C and C++.
ccFingerprint :: IO ()
ccFingerprint = do
  let reports =
        [ ("target", "x86_64-pc-linux-gnu")
        , ("libc", "ldd (GNU libc) 2.39")
        , ("libstdc++", "libstdc++.so.6.0.33")
        , ("gcc", "gcc (GCC) 13.2.0")
        , ("ld", "GNU ld 2.42")
        ]
      fp = ccFingerprintOf reports
  assertContains "cc fingerprint" "x86_64-pc-linux-gnu-" fp
  assertEqual "reordered" fp (ccFingerprintOf (reverse reports))
  let changed name new = [(n, if n == name then new else v) | (n, v) <- reports]
  assertDiffers "libc" fp (ccFingerprintOf (changed "libc" "ldd (GNU libc) 2.40"))
  assertDiffers "libstdc++" fp (ccFingerprintOf (changed "libstdc++" "libstdc++.so.6.0.34"))
  assertDiffers "compiler" fp (ccFingerprintOf (changed "gcc" "gcc (GCC) 14.1.0"))
  assertDiffers "linker" fp (ccFingerprintOf (changed "ld" "GNU ld 2.43"))
  assertDiffers "target" fp (ccFingerprintOf (changed "target" "aarch64-linux-gnu"))

-- | The C compiler, C++ compiler and linker for buck2: the user's, else GHC's
-- if it has absolute paths for them (Nix), else clang, linking with g++.
chooseCompilersTest :: IO ()
chooseCompilersTest = do
  let choose uc ux gc gx = let (c, x, l) = chooseCompilers uc ux gc gx in unwords [c, x, l]
      nixCc = "/nix/store/aaa-gcc-wrapper/bin/cc"
      nixCxx = "/nix/store/aaa-gcc-wrapper/bin/c++"
  assertEqual "GHC's are names" "clang clang++ g++" (choose Nothing Nothing (Just "gcc") (Just "g++"))
  assertEqual "GHC doesn't say" "clang clang++ g++" (choose Nothing Nothing Nothing Nothing)
  assertEqual "GHC's are absolute" (unwords [nixCc, nixCxx, nixCxx]) (choose Nothing Nothing (Just nixCc) (Just nixCxx))
  assertEqual "the user's" "clang clang++ clang++" (choose (Just "clang") (Just "clang++") (Just nixCc) (Just nixCxx))
  assertEqual "the user's C compiler only" (unwords ["clang", nixCxx, nixCxx]) (choose (Just "clang") Nothing (Just nixCc) (Just nixCxx))
  -- The C++ compiler that goes with the user's C compiler.
  let cxxFor cc = fromMaybe "none" (cxxCompilerFor cc)
  assertEqual "gcc" "g++" (cxxFor "gcc")
  assertEqual "clang" "clang++" (cxxFor "clang")
  assertEqual "cc" "/usr/bin/c++" (cxxFor "/usr/bin/cc")
  assertEqual "versioned clang" "/usr/bin/clang++-18" (cxxFor "/usr/bin/clang-18")
  assertEqual "prefixed gcc" "x86_64-linux-gnu-g++-13" (cxxFor "x86_64-linux-gnu-gcc-13")
  assertEqual "already C++" "none" (cxxFor "clang++")
  assertEqual "unknown" "none" (cxxFor "icx")

-- | Adding, changing and removing the block that @--cache@ puts in a config
-- file, without touching anything else in it.
spliceBlockTest :: IO ()
spliceBlockTest = do
  let user = "[cells]\n  root = .\n\n[build]\n  threads = 4\n"
      add address = spliceBlock (Just (cacheBlock address))
      once = add "grpc://a:1" user
  -- The user's part is kept, and the block comes after it.
  assertContains "added block" "[cells]\n  root = .\n\n[build]\n  threads = 4\n\n# >>> cabal buck2: cache" once
  assertContains "added block" "action_cache_address = grpc://a:1" once
  -- Doing it again changes nothing; a new address replaces the old one.
  assertEqual "idempotent" once (add "grpc://a:1" once)
  let changed = add "grpc://b:2" once
  assertContains "changed address" "action_cache_address = grpc://b:2" changed
  assertNotContains "changed address" "grpc://a:1" changed
  -- Removing it gives back the original, and removing again is a no-op.
  let removed = spliceBlock Nothing changed
  assertEqual "removed" user removed
  assertEqual "removed twice" user (spliceBlock Nothing removed)
  -- A file without a trailing newline or blocks is left alone when there is nothing to remove.
  assertEqual "nothing to remove" "[a]" (spliceBlock Nothing "[a]")
  -- Text after the block is kept too.
  assertContains "text after the block" "[later]" (add "grpc://c:3" (once ++ "[later]\n"))

assertEqual :: String -> String -> String -> IO ()
assertEqual what a b = unless (a == b) $ failure (what ++ ": " ++ show a ++ " /= " ++ show b)

assertDiffers :: String -> String -> String -> IO ()
assertDiffers what a b = when (a == b) $ failure (what ++ ": expected a different fingerprint, got " ++ show a)

-- | The main mapping rules, end to end: a plain library (lib-pkg), a second
-- package (exe-pkg) whose library depends on it, an executable with
-- @c-sources@, an exitcode-stdio-1.0 test-suite and a benchmark (both only
-- generated because tests and benchmarks are enabled), a @detailed-0.9@
-- test-suite (which gets a generated stub @Main@), and a manual flag gating
-- @cpp-options@.
basic :: Project -> IO ()
basic project = do
  _ <- buck2 project ["--enable-tests", "--enable-benchmarks", "-f+loud"]

  -- The GHC fingerprint is generated into tools.bzl, and is stable.
  let toolsPath = "third-party" </> "haskell" </> "tools.bzl"
  tools <- readIn project toolsPath
  assertContains toolsPath "GHC_FINGERPRINT = \"" tools
  assertContains toolsPath "CC_FINGERPRINT = \"" tools
  -- The C tools are run from a directory named by that fingerprint, so that
  -- it is part of the commands that run them. (Those that were found: one
  -- that wasn't, such as clang where it isn't installed, is run by its name.)
  let ccPrint = [takeWhile (/= '"') (drop (length "CC_FINGERPRINT = \"") l) | l <- lines tools, "CC_FINGERPRINT = " `isPrefixOf` l]
  forM_ ccPrint $ \fp ->
    forM_ [("CC", "cc"), ("CXX", "cxx"), ("LINKER", "linker")] $ \(var, role) ->
      forM_ [l | l <- lines tools, (var ++ " = ") `isPrefixOf` l, ("/toolchain/" ++ role ++ "/") `isInfixOf` l] $
        assertContains toolsPath ("/toolchain/" ++ role ++ "/" ++ fp ++ "/")
  _ <- buck2 project ["--enable-tests", "--enable-benchmarks", "-f+loud"]
  tools' <- readIn project toolsPath
  assertEqual "tools.bzl after a second run" tools tools'

  -- The generated file is a build spec - a plain dict describing each
  -- component as Cabal sees it - interpreted by buck2/cabal.bzl, which
  -- decides which rules, labels and flags that becomes.
  libBzl <- readIn project ("lib-pkg" </> "BUCK.cabal.bzl")
  let lib = assertContains "lib-pkg/BUCK.cabal.bzl"
      noLib = assertNotContains "lib-pkg/BUCK.cabal.bzl"
  lib "local_build_spec" libBzl
  lib "'kind': 'library'" libBzl
  lib "'name': 'lib-pkg'" libBzl
  -- extra-source-files reach the spec as they are (patterns), for
  -- cabal.bzl to glob.
  lib "'extra_source_files': [\n        'include/*.h',\n    ]" libBzl
  -- extra-lib-dirs, as configured (so with the directories of any
  -- pkgconfig-depends), go in the spec for the link.
  lib "'extra_lib_dirs': [\n                'libs',\n            ]" libBzl
  -- A module's boot file is found next to its source.
  lib "'boot_srcs': {\n                'MyLib': 'src/MyLib.hs-boot',\n            }" libBzl
  noLib "haskell_library(" libBzl
  -- Project-level options and test options are only recorded where they
  -- apply.
  noLib "'ghc_options'" libBzl
  noLib "'test_args'" libBzl

  exeBzl <- readIn project ("exe-pkg" </> "BUCK.cabal.bzl")
  let exe = assertContains "exe-pkg/BUCK.cabal.bzl"
  forM_ ["library", "executable", "test-suite", "benchmark"] $ \kind ->
    exe ("'kind': '" ++ kind ++ "'") exeBzl
  exe "'name': 'exe-pkg-bench'" exeBzl

  -- A dependency on another local package is just its name: where packages
  -- are is in cabal-buck2/packages.bzl, written once for the project, so that
  -- a package's own file doesn't change when the package moves.
  exe "'package': 'lib-pkg'" exeBzl
  assertNotContains "exe-pkg/BUCK.cabal.bzl" "'dir'" exeBzl
  assertNotContains "lib-pkg/BUCK.cabal.bzl" "'dir'" libBzl
  packages <- readIn project ("cabal-buck2" </> "packages.bzl")
  let pk = assertContains "cabal-buck2/packages.bzl"
  pk "PACKAGES = {" packages
  pk "'exe-pkg': 'exe-pkg'," packages
  pk "'lib-pkg': 'lib-pkg'," packages

  -- C sources and include directories are recorded as written in the .cabal
  -- file; cabal.bzl turns them into a cxx_library().
  exe "'cbits/helper.c'" exeBzl
  exe "'include_dirs'" exeBzl
  -- The manual flag's cpp-options.
  exe "'-DLOUD'" exeBzl

  -- `ghc-options:` and `test-options:` from cabal.project (not the .cabal
  -- file) reach the spec: the former once per package, the latter as
  -- `test_args` with template variables expanded per test-suite. The
  -- `-hide-all-packages` that cabal-install always adds (a workaround for
  -- custom Setup.hs scripts) is deliberately not copied over.
  exe "'ghc_options'" exeBzl
  exe "'-fno-ignore-asserts'" exeBzl
  assertNotContains "exe-pkg/BUCK.cabal.bzl" "-hide-all-packages" exeBzl
  exe "'test_args'" exeBzl
  exe "'--opt-one'" exeBzl
  exe "'--opt-two=exe-pkg-test'" exeBzl
  exe "'exe-pkg-detailed-test'" exeBzl

  -- Paths_<pkg>.hs and the detailed-0.9 stub Main both live under
  -- cabal-buck2/autogen/, which has its own BUCK file (see below): the spec
  -- names them, and cabal.bzl refers to them by that file's export_file()
  -- target.
  exe "'Paths_exe_pkg': {" exeBzl
  exe "'autogen': 'Paths_exe_pkg'" exeBzl
  exe "'autogen': 'exe-pkg-detailed-test-stub-main'" exeBzl

  -- The hand-editable BUCK wrapper is created (only once) and loads the
  -- generated file, whose entry point passes customisation through to
  -- cabal.bzl's cabal_targets().
  wrapper <- readIn project ("exe-pkg" </> "BUCK")
  assertContains "exe-pkg/BUCK" "generated_targets" wrapper
  exe "def generated_targets(**kwargs):" exeBzl

  -- The detailed-0.9 test-suite's stub Main is our own generated driver
  -- (not Cabal's stdin-driven one), importing the user's named test-module
  -- directly.
  let autogen = "exe-pkg" </> "cabal-buck2" </> "autogen"
  stub <- readIn project (autogen </> "exe-pkg-detailed-test" </> "Main.hs")
  assertContains "stub Main" "import qualified DetailedTests as CabalBuck2TestModule" stub

  -- cabal_macros.h and Paths_<pkg>.hs come from Cabal's own generators, not
  -- hand-rolled stand-ins.
  macros <- readIn project (autogen </> "exe-pkg" </> "cabal_macros.h")
  assertContains "cabal_macros.h" "CURRENT_PACKAGE_KEY" macros
  paths <- readIn project (autogen </> "Paths_exe_pkg.hs")
  assertContains "Paths_exe_pkg.hs" "version =" paths

  -- cabal-buck2/autogen/BUCK exports every autogen file as a real target
  -- via export_file(): both what makes cabal_component's $(location ...)
  -- reference a buck2-tracked dependency, and what lets a hand-written BUCK
  -- file elsewhere refer to e.g. Paths_<pkg>.
  autogenBuck <- readIn project (autogen </> "BUCK")
  let ab = assertContains "cabal-buck2/autogen/BUCK"
  ab "name = 'exe-pkg-cabal-macros'" autogenBuck
  ab "name = 'Paths_exe_pkg'" autogenBuck
  ab "name = 'exe-pkg-detailed-test-stub-main'" autogenBuck
  -- Each export_file() must set `out` to the real file's basename: without
  -- it, `out` defaults to the rule's name, the artifact loses its extension,
  -- and buck2 silently stops treating it as a Haskell source.
  ab "out = 'Paths_exe_pkg.hs'" autogenBuck
  ab "out = 'cabal_macros.h'" autogenBuck
  ab "out = 'Main.hs'" autogenBuck

-- | Make a repository of the packages in the project's @dep@ directory, which is
-- the only one used, and a @cabal.project@ for the project's @app@ package.
localRepository :: Project -> [String] -> IO ()
localRepository project names = do
  let dir = projectDir project
  createDirectoryIfMissing True (dir </> "repo")
  forM_ names $ \name ->
    callProcess "tar" ["-C", dir </> "dep", "-czf", dir </> "repo" </> (name ++ ".tar.gz"), name]
  writeFile (dir </> "cabal.project") $
    unlines ["packages: app", "repository localrepo", "  url: file+noindex://" ++ dir </> "repo", "active-repositories: localrepo"]

-- | @--source-deps@ unpacks the dependencies (here one package from a local
-- repository) under @dist-newstyle/src@ and generates their targets like
-- those of the project's own packages; without it they are left to the cabal
-- store, and what an earlier run generated for them is removed.
sourceDeps :: Project -> IO ()
sourceDeps project = do
  let dir = projectDir project
  localRepository project ["dep-1.0"]

  -- With the dependency already in the store, from a run without the flag.
  _ <- buck2 project []
  _ <- buck2 project ["--source-deps"]
  let depBzlPath = "dist-newstyle" </> "src" </> "dep-1.0" </> "BUCK.cabal.bzl"
  depBzl <- readIn project depBzlPath
  assertContains depBzlPath "'name': 'dep'" depBzl
  assertContains depBzlPath "'version': '1.0'" depBzl
  -- ... but not where it is (the 'dir' of its data files is something else).
  assertContains depBzlPath "'version': '1.0',\n    }," depBzl
  -- Where it is, is in packages.bzl, with the packages of the project.
  packages <- readIn project ("cabal-buck2" </> "packages.bzl")
  assertContains "cabal-buck2/packages.bzl" "'dep': 'dist-newstyle/src/dep-1.0'," packages
  -- dep has data-files, so dep needs them, and so does app, which depends on
  -- dep and so may run dep's code.
  assertContains "cabal-buck2/packages.bzl" "DATA_PACKAGES = {\n    'app': [\n        'dep',\n    ],\n    'dep': [\n        'dep',\n    ],\n}" packages
  -- Its data files are recorded, for the tools that read them.
  assertContains depBzlPath "'data/*.txt'" depBzl
  -- hsc2hs is told what it is compiling for.
  assertContains depBzlPath "'-D__GLASGOW_HASKELL__=" depBzl
  assertContains depBzlPath "'asm_sources'" depBzl
  assertContains depBzlPath "'asm_options'" depBzl
  assertContains depBzlPath "'cmm_sources'" depBzl
  assertContains depBzlPath "'cmm/Dep.cmm'" depBzl
  appBzl <- readIn project ("app" </> "BUCK.cabal.bzl")
  -- A literate happy grammar is a module source.
  assertContains "app/BUCK.cabal.bzl" "'Parser': 'Parser.ly'" appBzl
  assertContains "app/BUCK.cabal.bzl" "'package': 'dep'," appBzl
  assertNotContains "app/BUCK.cabal.bzl" "'dir'" appBzl

  -- Without the flag the dependency is the store's again.
  _ <- buck2 project []
  removed <- not <$> doesDirectoryExist (dir </> "dist-newstyle" </> "src" </> "dep-1.0")
  unless removed $ failure "dist-newstyle/src/dep-1.0 should have been removed"
  appBzl' <- readIn project ("app" </> "BUCK.cabal.bzl")
  assertNotContains "app/BUCK.cabal.bzl" "dist-newstyle/src/dep-1.0" appBzl'

-- | @reexported-modules@: a module re-exported from another package (by name
-- or found in a dependency, renamed or not) or from another library of the
-- package is resolved as Cabal does, and recorded in the spec with where it comes from, which is how the
-- library claims it - so that a package that depends on the library, and not
-- on where the module is from, can import it. A module of the library itself is recorded without a library.
reexports :: Project -> IO ()
reexports project = do
  _ <- buck2 project []
  reBzl <- readIn project ("re-lib" </> "BUCK.cabal.bzl")
  let re = assertContains "re-lib/BUCK.cabal.bzl"
  re "'reexports'" reBzl
  re "'module': 'Orig.A',\n                    'original': 'Orig.A',\n                    'from': {\n                        'package': 'base-lib',\n                    }," reBzl
  re "'module': 'New.B',\n                    'original': 'Orig.B'," reBzl
  re "'module': 'Sub.M',\n                    'original': 'Sub.M',\n                    'from': {\n                        'package': 're-lib',\n                        'library': 'sub'," reBzl
  -- One of its own modules has no library it comes from, and no module of its own.
  re "'module': 'New.X',\n                    'original': 'Own.X',\n                }," reBzl
  assertNotContains "re-lib/BUCK.cabal.bzl" "'New.X': {" reBzl

  -- What a library re-exports from another that re-exports it is recorded as
  -- where it is defined, and by that name, as Cabal does.
  re2Bzl <- readIn project ("re2" </> "BUCK.cabal.bzl")
  assertContains "re2/BUCK.cabal.bzl" "'module': 'Newer.B',\n                    'original': 'Orig.B',\n                    'from': {\n                        'package': 'base-lib'," re2Bzl
  assertContains "re2/BUCK.cabal.bzl" "'module': 'Orig.A',\n                    'original': 'Orig.A',\n                    'from': {\n                        'package': 'base-lib'," re2Bzl

  -- A library with no modules has one that doesn't need base.
  emptyBzl <- readIn project ("empty" </> "BUCK.cabal.bzl")
  assertContains "empty/BUCK.cabal.bzl" "'CabalBuck2Empty'" emptyBzl
  stub <- readIn project ("empty" </> "cabal-buck2" </> "autogen" </> "empty" </> "empty" </> "CabalBuck2Empty.hs")
  assertContains "the empty module" "NoImplicitPrelude" stub

  -- What depends on the library doesn't need to depend on where they are from.
  userBzl <- readIn project ("user" </> "BUCK.cabal.bzl")
  assertContains "user/BUCK.cabal.bzl" "'package': 're-lib'" userBzl
  assertNotContains "user/BUCK.cabal.bzl" "base-lib" userBzl

-- | What Cabal's configure makes of @pkgconfig-depends@ and @extra-lib-dirs@ is
-- in the spec as it is, for the link: also for a component that has no C
-- sources, which buck2 doesn't run pkg-config for. The fixture has a
-- @foo.pc@ with its own library and include directories, a define and an
-- rpath.
pkgconfig :: Project -> IO ()
pkgconfig project = do
  _ <- buck2 project []
  bzl <- readIn project ("lib" </> "BUCK.cabal.bzl")
  let spec = assertContains "lib/BUCK.cabal.bzl"
  spec "'extra_libraries': [\n                'foo',\n            ]" bzl
  -- The directory of the package's own extra-lib-dirs and then that of pkg-config.
  spec "'extra_lib_dirs': [\n                'plain',\n                '/opt/foo/lib',\n            ]" bzl
  spec "'ld_options': [\n                '-Wl,-rpath,/opt/foo/lib',\n            ]" bzl
  spec "'include_dirs': [\n                '/opt/foo/include',\n            ]" bzl
  spec "'cc_options': [\n                '-DFOO_ENABLED',\n            ]" bzl
  -- and for buck2 to run pkg-config for the C sources there are.
  spec "'pkgconfig': [\n                'foo',\n            ]" bzl

-- | The checkout of haskell-buck2 has to be for this release of cabal-buck2:
-- if it is not, or doesn't say, the error says which branch is needed.
buck2Version :: Project -> IO ()
buck2Version project = do
  let wrong (code', msg) = when (code' == ExitSuccess) $ failure ("accepted: " ++ msg)
  -- An earlier release didn't have a version.bzl.
  removeFile (projectDir project </> "buck2" </> "version.bzl")
  (code, out) <- runBuck2 project []
  wrong (code, "buck2/ with no version")
  assertContains "no version" ("needs the " ++ cabalBuck2Version ++ " branch") out
  assertContains "no version" "buck2/ is for no release" out
  assertContains "no version" "git -C buck2 checkout " out

  writeBuck2Version (projectDir project) "0.0.0.1"
  (code', out') <- runBuck2 project []
  wrong (code', "buck2/ for another release")
  assertContains "other version" ("This is cabal-buck2 " ++ cabalBuck2Version ++ ", and buck2/ is for cabal-buck2 0.0.0.1.") out'

  writeBuck2Version (projectDir project) cabalBuck2Version
  _ <- buck2 project []
  return ()

-- | A project without a buck2/ directory gets a copy of the one that was
-- installed with cabal-buck2. That copy is replaced when a different release
-- of cabal-buck2 runs.
--
-- The test does nothing when buck2 runs it (see BUCK), because then the data
-- files of cabal-buck2 don't include the support code. In this project,
-- buck2/ is a buck2 package of its own and buck2/prelude is a separate cell,
-- and the glob that collects the data files of the root package doesn't look
-- inside either of them.
buck2Unpack :: Project -> IO ()
buck2Unpack project = do
  dataDir <- lookupEnv "cabal_buck2_datadir"
  available <- maybe (return True) (\d -> doesFileExist (d </> "buck2" </> "version.bzl")) dataDir
  when available $ buck2UnpackTest project

buck2UnpackTest :: Project -> IO ()
buck2UnpackTest project = do
  let dir = projectDir project </> "buck2"
      checkVersion what = do
        version <- readIn project ("buck2" </> "version.bzl")
        assertContains what ("CABAL_BUCK2_VERSION = \"" ++ cabalBuck2Version ++ "\"") version
  removeDirectoryRecursive dir
  _ <- buck2 project []
  checkVersion "unpacked buck2/version.bzl"
  isExe <- executable <$> getPermissions (dir </> "run_test.sh")
  unless isExe $ failure "buck2/run_test.sh was unpacked without its executable permission"

  writeBuck2Version (projectDir project) "0.0.0.1"
  writeFile (dir </> "stale") ""
  _ <- buck2 project []
  checkVersion "replaced buck2/version.bzl"
  stale <- doesFileExist (dir </> "stale")
  when stale $ failure "buck2/ for another release was not replaced"

-- | A package with a @Custom@ build type needs its @Setup.hs@ to be run, which
-- is not done: it, and what depends on it, can't be built.
customSetup :: Project -> IO ()
customSetup project = do
  localRepository project ["custom-dep-0.1"]
  (code, failed) <- runBuck2 project ["--source-deps"]
  when (code == ExitSuccess) $ failure "a package with build-type: Custom was accepted"
  assertContains "error" "custom-dep" failed
  assertContains "error" "build-type: Custom" failed
  assertContains "error" "--keep-going" failed

  out <- buck2 project ["--source-deps", "--keep-going"]
  assertContains "warning" "build-type: Custom" out
  assertContains "warning" "skipping executable app" out
  depBzl <- readIn project ("dist-newstyle" </> "src" </> "custom-dep-0.1" </> "BUCK.cabal.bzl")
  assertNotContains "custom-dep BUCK.cabal.bzl" "'kind': 'library'" depBzl

  -- With --enable-custom-setup it is built as if it had build-type: Simple,
  -- and the module its Setup.hs would generate is left to the project.
  translated <- buck2 project ["--source-deps", "--enable-custom-setup"]
  assertContains "warning" "custom-dep-0.1 as if it had build-type: Simple" translated
  assertNotContains "output" "skipping" translated
  translatedBzl <- readIn project ("dist-newstyle" </> "src" </> "custom-dep-0.1" </> "BUCK.cabal.bzl")
  assertContains "custom-dep BUCK.cabal.bzl" "'kind': 'library'" translatedBzl
  assertContains "custom-dep BUCK.cabal.bzl" "'Custom.Generated': {\n                    'provided': True," translatedBzl
  appBzl <- readIn project ("app" </> "BUCK.cabal.bzl")
  assertContains "app BUCK.cabal.bzl" "'kind': 'executable'" appBzl

-- | A project's @cabal-buck2.bzl@, with its overrides and defaults for the
-- generated targets, is loaded by @packages.bzl@. Whichever of them the
-- project doesn't define is given there as empty.
projectOverrides :: Project -> IO ()
projectOverrides project = do
  let packagesWith bzl = do
        writeFile (projectDir project </> "cabal-buck2.bzl") bzl
        _ <- buck2 project []
        readIn project ("cabal-buck2" </> "packages.bzl")
  _ <- buck2 project []
  without <- readIn project ("cabal-buck2" </> "packages.bzl")
  assertContains "packages.bzl" "OVERRIDES = {}" without
  assertContains "packages.bzl" "DEFAULTS = {}" without
  assertNotContains "packages.bzl" "cabal-buck2.bzl\"" without

  overrides <- packagesWith "OVERRIDES = {}\n"
  assertContains "packages.bzl" "load(\"//:cabal-buck2.bzl\", _OVERRIDES = \"OVERRIDES\")" overrides
  assertContains "packages.bzl" "OVERRIDES = _OVERRIDES" overrides
  assertContains "packages.bzl" "DEFAULTS = {}" overrides

  -- A comparison, or a name that only starts with DEFAULTS, isn't a
  -- definition of it.
  defaults <- packagesWith "DEFAULTS = {\"*\": {}}\nDEFAULTS == {}\nDEFAULTS_X = {}\n"
  assertContains "packages.bzl" "load(\"//:cabal-buck2.bzl\", _DEFAULTS = \"DEFAULTS\")" defaults
  assertContains "packages.bzl" "DEFAULTS = _DEFAULTS" defaults
  assertContains "packages.bzl" "OVERRIDES = {}" defaults

  both <- packagesWith "DEFAULTS={}\nOVERRIDES = {}\n"
  assertContains "packages.bzl" "load(\"//:cabal-buck2.bzl\", _OVERRIDES = \"OVERRIDES\", _DEFAULTS = \"DEFAULTS\")" both

-- | @--cache=ADDRESS@ adds the cache's settings to @.buckconfig@, which are
-- kept by later runs without the flag, and @--no-cache@ removes.
cacheConfig :: Project -> IO ()
cacheConfig project = do
  let buckconfig = ".buckconfig"
      local = ".buckconfig.local"
      localPath = projectDir project </> local
      block = "# >>> cabal buck2: cache"
  before <- readIn project buckconfig
  assertNotContains buckconfig block before
  localBefore <- doesFileExist localPath
  when localBefore $ failure (local ++ " exists before --cache")

  -- The block goes in .buckconfig.local, which is created for it; the
  -- project's .buckconfig is left alone.
  out <- buck2 project ["--cache=grpc://127.0.0.1:9092"]
  -- A running buck2 daemon would keep the old settings.
  assertContains "notice" "buck2 kill" out
  withCache <- readIn project local
  assertContains local "[cabal_buck2]\n  cache = true" withCache
  assertContains local "default_allow_cache_upload = true" withCache
  assertContains local "action_cache_address = grpc://127.0.0.1:9092" withCache
  assertContains local "tls = false" withCache
  afterOn <- readIn project buckconfig
  assertEqual "the .buckconfig after --cache" before afterOn

  -- Later runs leave it alone.
  _ <- buck2 project []
  again <- readIn project local
  assertEqual "after a run without --cache" withCache again

  -- Removing it removes the file it was the only thing in.
  _ <- buck2 project ["--no-cache"]
  localAfter <- doesFileExist localPath
  when localAfter $ failure (local ++ " left behind by --no-cache")

  -- What else is in .buckconfig.local is kept.
  let mine = "[haskell]\n  compiler_flags = -Wall\n"
  writeFile localPath mine
  _ <- buck2 project ["--cache=grpc://127.0.0.1:9092"]
  mixed <- readIn project local
  assertContains local mine mixed
  assertContains local block mixed
  _ <- buck2 project ["--no-cache"]
  mineAgain <- readIn project local
  assertEqual "after --no-cache" mine mineAgain
  removeFile localPath

  -- A block that an earlier version put in .buckconfig is moved out.
  writeFile (projectDir project </> buckconfig) (spliceBlock (Just (cacheBlock "grpc://127.0.0.1:9092")) before)
  _ <- buck2 project ["--cache=grpc://127.0.0.1:9092"]
  moved <- readIn project buckconfig
  assertEqual "the .buckconfig after moving the block out" before moved
  movedTo <- readIn project local
  assertContains local "action_cache_address = grpc://127.0.0.1:9092" movedTo
  _ <- buck2 project ["--no-cache"]

  -- Mistakes are reported.
  (badCode, badOut) <- runBuck2 project ["--cache=http://example.org"]
  when (badCode == ExitSuccess) $ failure "--cache=http://... was accepted"
  assertContains "bad address" "grpc://" badOut
  (code', out') <- runBuck2 project ["--cache=grpc://a:1", "--no-cache"]
  when (code' == ExitSuccess) $ failure "--cache with --no-cache was accepted"
  assertContains "both flags" "can't be used together" out'

-- | A plain run, without @--enable-tests@ or @--enable-benchmarks@, must
-- succeed even though the package has test-suites and a benchmark. The
-- benchmark depends on @stm@, which nothing else in the fixture uses: since
-- its stanza isn't enabled, @stm@ is (correctly) absent from the dependency
-- plan that the installed package index is built from, so configuring the
-- benchmark anyway would fail with "the given installed package instance
-- does not exist". The disabled components just get no rule.
disabledStanzas :: Project -> IO ()
disabledStanzas project = do
  _ <- buck2 project []
  exeBzl <- readIn project ("exe-pkg" </> "BUCK.cabal.bzl")
  let exe = "exe-pkg/BUCK.cabal.bzl"
  assertContains exe "'kind': 'library'" exeBzl
  assertContains exe "'kind': 'executable'" exeBzl
  assertNotContains exe "'exe-pkg-bench'" exeBzl
  assertNotContains exe "'kind': 'test-suite'" exeBzl
  assertNotContains exe "'kind': 'benchmark'" exeBzl

-- | A component whose sources can't all be found is skipped with a warning
-- saying why (a rule that names a missing file would take down the whole
-- buck2 build), and so is every component of the same package that depends
-- on it. By default that is an error and nothing is generated; with
-- @--keep-going@ everything else is generated.
missingModule :: Project -> IO ()
missingModule project = do
  (code, failed) <- runBuck2 project []
  when (code == ExitSuccess) $ failure "a component that can't be built was accepted"
  assertContains "error" "for module Absent" failed
  assertContains "error" "skipping library broken-pkg" failed
  assertContains "error" "--keep-going" failed
  generated <- doesFileExist (projectDir project </> "broken-pkg" </> "BUCK.cabal.bzl")
  when generated $ failure "files were generated despite the error"

  out <- buck2 project ["--keep-going"]
  assertContains "output" "for module Absent" out
  assertContains "output" "skipping library broken-pkg" out
  assertContains "output" "skipping executable uses-lib" out

  bzl <- readIn project ("broken-pkg" </> "BUCK.cabal.bzl")
  assertContains "broken-pkg/BUCK.cabal.bzl" "'name': 'standalone'" bzl
  assertNotContains "broken-pkg/BUCK.cabal.bzl" "'name': 'uses-lib'" bzl
  assertNotContains "broken-pkg/BUCK.cabal.bzl" "'kind': 'library'" bzl

-- | Libraries outside GHC's libdir and the cabal store (as in a Nix
-- @ghcWithPackages@) are reached through a symlink for each directory.
-- | The data-files of cabal-buck2.cabal are the files of the haskell-buck2
-- submodule (buck2/) that cabal-buck2 copies into a project. They should be
-- all of the submodule's files apart from those that 'notShipped' leaves out.
-- When this fails because of a new file in the submodule, the file probably
-- needs a pattern of its own: a pattern can't match every kind of file.
--
-- It also checks that every executable file that is shipped starts with @#!@,
-- because that is how the copy in a project gets its executable permission
-- back (Cabal installs data files without it).
--
-- This needs the git checkout of the submodule, so it does nothing in an
-- unpacked sdist.
dataFilesTest :: IO ()
dataFilesTest = do
  checkout <- (&&) <$> doesFileExist "cabal-buck2.cabal" <*> doesPathExist ("buck2" </> ".git")
  when checkout $ do
    gpd <- readGenericPackageDescription verbosity Nothing (makeSymbolicPath "cabal-buck2.cabal")
    let pd = packageDescription gpd
    matched <- concat <$> mapM (matchDirFileGlob verbosity (specVersion pd) Nothing) (dataFiles pd)
    -- Each line is "<mode> <object> <stage>\t<path>".
    entries <- map (break (== '\t')) . lines <$> readProcess "git" ["-C", "buck2", "ls-files", "--stage"] ""
    let tracked = [(path, takeWhile (/= ' ') mode) | (mode, _ : path) <- entries, not (notShipped path)]
        expected = Set.fromList ["buck2" </> path | (path, _) <- tracked]
        shipped = Set.fromList (map getSymbolicPath matched)
        unmatched = Set.toList (expected `Set.difference` shipped)
        unwanted = Set.toList (shipped `Set.difference` expected)
    unless (null unmatched) $ failure ("files of buck2/ that no data-files pattern matches:\n" ++ unlines unmatched)
    unless (null unwanted) $ failure ("data-files that should be left out:\n" ++ unlines unwanted)
    scripts <- forM [path | (path, "100755") <- tracked, path `notElem` notScripts] $ \path -> do
      start <- BS8.take 2 <$> BS8.readFile ("buck2" </> path)
      return (path, start == BS8.pack "#!")
    let noShebang = [path | (path, False) <- scripts]
    unless (null noShebang) $ failure ("executable files of buck2/ that don't start with #!:\n" ++ unlines noShebang)
  where
    verbosity = mkVerbosity defaultVerbosityHandles silent
    notShipped path =
      path `elem` ["flake.nix", "flake.lock", "perf-chart.svg", "CLAUDE.md", ".gitignore", "prelude/.gitignore", "prelude/toolchains/apple/xcode_version_checker/.gitignore"]
        || any (`isPrefixOf` path) ["tests/", ".github/", "prelude/toolchains/android/test/", "prelude/ide_integrations/visual_studio/assets/"]
    -- These are executable in git, but nothing that builds Haskell runs them.
    -- The Python ones are the main modules of python_bootstrap_binary
    -- targets, which run them with the Python interpreter. The others are
    -- used only when building or testing Java or Apple code.
    notScripts =
      [ "prelude/apple/tools/selective_debugging/test_resources/HelloWorld"
      , "prelude/git/tools/git_fetch.py"
      , "prelude/rust/tools/buildscript_run.py"
      , "prelude/toolchains/android/src/com/facebook/buck/testrunner/BaseRunner.java"
      , "prelude/toolchains/apple/xcode_version_checker/xcode_version_checker"
      ]

externalDirsTest :: IO ()
externalDirsTest = do
  let paths = RepoPaths{rpGhcVersion = "9.6.7", rpGlobalRootAbs = "/ghc/lib", rpStoreRootAbs = "/home/u/.cabal/store/ghc-9.6.7", rpStoreDbRel = "package.db", rpExternal = Map.empty, rpDllExtension = "so", rpPicByDefault = False}
      aeson = "/nix/store/aaa-aeson-lib-aeson-2.2.5.1/lib/x86_64-linux-ghc-9.6.7"
      text = "/nix/store/bbb-text-lib-text-2.1.4/lib/x86_64-linux-ghc-9.6.7"
      dirs =
        [ aeson ++ "/aeson-2.2.5.1-X" -- the static libraries, inside the shared libraries' directory
        , aeson
        , text ++ "/text-2.1.4-Y"
        , text
        , "/ghc/lib/x86_64-linux-ghc-9.6.7/base-4.18.3.0" -- under GHC's libdir
        , "/home/u/.cabal/store/ghc-9.6.7/foo-1/lib" -- in the cabal store
        ]
      linked = externalDirs paths dirs
      check what expected actual =
        unless (expected == actual) $
          failure (what ++ ": expected " ++ show expected ++ ", got " ++ show actual)
  check "one link for each package, for neither GHC's libdir nor the store" [aeson, text] (map fst linked)
  check "links are the same on every run" linked (externalDirs paths (reverse dirs ++ dirs))
  let names = map snd linked
  check "links are in external/" True (all (\n -> take 9 n == "external/") names)
  check "the links are different" 2 (length (nub names))
  let paths' = paths{rpExternal = Map.fromList linked}
      aesonLink = fromMaybe (error "no link for aeson") (lookup aeson linked)
  check "a library in a linked directory" (Just (aesonLink ++ "/aeson-2.2.5.1-X/libHSaeson-2.2.5.1-X.a")) (toRepoRelative paths' (aeson ++ "/aeson-2.2.5.1-X/libHSaeson-2.2.5.1-X.a"))
  check "a library under GHC's libdir" (Just "ghc-9.6.7/x86_64-linux-ghc-9.6.7/base-4.18.3.0/libHSbase.a") (toRepoRelative paths' "/ghc/lib/x86_64-linux-ghc-9.6.7/base-4.18.3.0/libHSbase.a")
  check "a library in the store" (Just "cabal-store/foo-1/lib/libHSfoo.a") (toRepoRelative paths' "/home/u/.cabal/store/ghc-9.6.7/foo-1/lib/libHSfoo.a")
  check "something that isn't linked" Nothing (toRepoRelative paths' "/usr/include/stdio.h")

-- | The @-L@ flags for a prebuilt package's @extra-libraries@ come from its
-- @library-dirs@, as they do when GHC links against the package itself; a
-- package without any needs no @-L@ flags at all.
linkerFlagsTest :: IO ()
linkerFlagsTest = do
  let withLibs =
        emptyInstalledPackageInfo
          { libraryDirs = ["/nix/store/aaa-hmatrix-0.20.2/lib/x86_64-linux-ghc-9.6.7/hmatrix-0.20.2-X", "/nix/store/bbb-openblas-0.3.33/lib", "/nix/store/bbb-openblas-0.3.33/lib"]
          , extraLibraries = ["openblas"]
          }
      withoutLibs = emptyInstalledPackageInfo{libraryDirs = ["/nix/store/ccc-text-2.1.4/lib"]}
      check what expected actual =
        unless (expected == actual) $
          failure (what ++ ": expected " ++ show expected ++ ", got " ++ show actual)
  check
    "a package with extra-libraries"
    ["-L/nix/store/aaa-hmatrix-0.20.2/lib/x86_64-linux-ghc-9.6.7/hmatrix-0.20.2-X", "-L/nix/store/bbb-openblas-0.3.33/lib", "-lopenblas"]
    (prebuiltLinkerFlags withLibs)
  check "a package without" [] (prebuiltLinkerFlags withoutLibs)
