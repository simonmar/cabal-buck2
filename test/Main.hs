-- | Runs @cabal-buck2@ on the fixture projects in @test/fixtures@ and checks
-- the files it generates. None of these needs a buck2 binary, or a buck2
-- prelude: the fixtures' @buck2@ directory only has to exist.
module Main (main) where

import Control.Exception (SomeException, bracket, displayException, try)
import Control.Monad (forM_, unless, when)
import Data.List (isInfixOf)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Map as Map
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , findExecutable
  , getTemporaryDirectory
  , listDirectory
  , removeDirectoryRecursive
  )
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (CreateProcess (..), callProcess, getCurrentPid, proc, readCreateProcessWithExitCode)

import Distribution.Client.Buck2.Cache (cacheBlock, spliceBlock)
import Distribution.Client.Buck2.Fingerprint (ccFingerprintOf, fingerprintOf)

main :: IO ()
main = do
  exe <- maybe (fail "cabal-buck2 not found on PATH") return =<< findExecutable "cabal-buck2"
  results <- mapM (runTest exe) tests
  unitResults <- mapM runUnitTest unitTests
  let failures =
        [name | (name, False) <- zip (map fst tests) results]
          ++ [name | (name, False) <- zip (map fst unitTests) unitResults]
  unless (null failures) $ do
    hPutStrLn stderr $ "FAILED: " ++ unwords failures
    exitFailure

unitTests :: [(String, IO ())]
unitTests = [("fingerprint", fingerprint), ("cc-fingerprint", ccFingerprint), ("splice-block", spliceBlockTest)]

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
  ]

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
      _ -> name
    setup dir = do
      cleanup dir
      copyTree ("test" </> "fixtures" </> fixture) (dir </> "project")
      env <- getEnvironment
      -- The compiler to use: $HC if it's set (as haskell-ci does), otherwise
      -- whatever `ghc` is on the PATH.
      compilerArgs <- maybe [] (\hc -> ["-w", hc]) <$> lookupEnv "HC"
      -- A private cabal directory and config, so that the user's store and
      -- config (which $CABAL_DIR and $CABAL_CONFIG may point to, as in
      -- haskell-ci) are neither used nor changed.
      let cabalDir = dir </> "cabal-dir"
          cabalEnv =
            [("CABAL_DIR", cabalDir), ("CABAL_CONFIG", cabalDir </> "config")]
              ++ [kv | kv@(k, _) <- env, k `notElem` ["CABAL_DIR", "CABAL_CONFIG"]]
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

  -- A dependency on another local package carries that package's directory
  -- (from which the target label is made).
  exe "'package': 'lib-pkg'" exeBzl
  exe "'dir': 'lib-pkg'" exeBzl

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

-- | @--source-deps@ unpacks the dependencies (here one package from a local
-- repository) under @dist-newstyle/src@ and generates their targets like
-- those of the project's own packages; without it they are left to the cabal
-- store, and what an earlier run generated for them is removed.
sourceDeps :: Project -> IO ()
sourceDeps project = do
  let dir = projectDir project
  createDirectoryIfMissing True (dir </> "repo")
  callProcess "tar" ["-C", dir </> "dep", "-czf", dir </> "repo" </> "dep-1.0.tar.gz", "dep-1.0"]
  writeFile (dir </> "cabal.project") $
    unlines ["packages: app", "repository localrepo", "  url: file+noindex://" ++ dir </> "repo", "active-repositories: localrepo"]

  -- With the dependency already in the store, from a run without the flag.
  _ <- buck2 project []
  _ <- buck2 project ["--source-deps"]
  let depBzlPath = "dist-newstyle" </> "src" </> "dep-1.0" </> "BUCK.cabal.bzl"
  depBzl <- readIn project depBzlPath
  assertContains depBzlPath "'name': 'dep'" depBzl
  assertContains depBzlPath "'version': '1.0'" depBzl
  assertContains depBzlPath "'dir': 'dist-newstyle/src/dep-1.0'" depBzl
  -- Its data files are recorded, for the tools that read them.
  assertContains depBzlPath "'data/*.txt'" depBzl
  appBzl <- readIn project ("app" </> "BUCK.cabal.bzl")
  assertContains "app/BUCK.cabal.bzl" "'dir': 'dist-newstyle/src/dep-1.0'" appBzl

  -- Without the flag the dependency is the store's again.
  _ <- buck2 project []
  removed <- not <$> doesDirectoryExist (dir </> "dist-newstyle" </> "src" </> "dep-1.0")
  unless removed $ failure "dist-newstyle/src/dep-1.0 should have been removed"
  appBzl' <- readIn project ("app" </> "BUCK.cabal.bzl")
  assertNotContains "app/BUCK.cabal.bzl" "dist-newstyle/src/dep-1.0" appBzl'

-- | @--cache=ADDRESS@ adds the cache's settings to @.buckconfig@, which are
-- kept by later runs without the flag, and @--no-cache@ removes.
cacheConfig :: Project -> IO ()
cacheConfig project = do
  let buckconfig = ".buckconfig"
      block = "# >>> cabal buck2: cache"
  before <- readIn project buckconfig
  assertNotContains buckconfig block before

  out <- buck2 project ["--cache=grpc://127.0.0.1:9092"]
  -- A running buck2 daemon would keep the old settings.
  assertContains "notice" "buck2 kill" out
  withCache <- readIn project buckconfig
  assertContains buckconfig "[cabal_buck2]\n  cache = true" withCache
  assertContains buckconfig "default_allow_cache_upload = true" withCache
  assertContains buckconfig "action_cache_address = grpc://127.0.0.1:9092" withCache
  assertContains buckconfig "tls = false" withCache
  -- What was there is kept.
  assertContains buckconfig (take 40 before) withCache

  -- Later runs leave it alone.
  _ <- buck2 project []
  again <- readIn project buckconfig
  assertEqual "after a run without --cache" withCache again

  -- Removing it restores the original file.
  _ <- buck2 project ["--no-cache"]
  without <- readIn project buckconfig
  assertEqual "after --no-cache" before without

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
-- on it. Everything else is still generated.
missingModule :: Project -> IO ()
missingModule project = do
  out <- buck2 project []
  assertContains "output" "for module Absent" out
  assertContains "output" "skipping library broken-pkg" out
  assertContains "output" "skipping executable uses-lib" out

  bzl <- readIn project ("broken-pkg" </> "BUCK.cabal.bzl")
  assertContains "broken-pkg/BUCK.cabal.bzl" "'name': 'standalone'" bzl
  assertNotContains "broken-pkg/BUCK.cabal.bzl" "'name': 'uses-lib'" bzl
  assertNotContains "broken-pkg/BUCK.cabal.bzl" "'kind': 'library'" bzl
