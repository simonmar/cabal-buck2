-- | cabal-install CLI command: buck2
--
-- Sets up (or refreshes) a buck2 build for the current project, using the
-- prelude and support scripts checked out at @buck2\/@ (a checkout of
-- <https://github.com/simonmar/haskell-buck2>, see @buck2\/README.md@).
--
-- There are 6 main pieces to this, each with a small API:
--
--   1. "Distribution.Client.Buck2.BuildDependencies": Build every
--      dependency (never the local packages themselves), the same as
--      @cabal build all --only-dependencies@ would.
--
--   2. "Distribution.Client.Buck2.Setup": Create
--      @.buckconfig@\/@PACKAGE@ if they don't exist yet. These are
--      boilerplate copied from @buck2\/example@.
--
--   3. "Distribution.Client.Buck2.Prebuilt": Tell @buck2@ about all
--      the library and tool dependencies. These are all recorded
--      under @third-party\/haskell@.
--
--   4. "Distribution.Client.Buck2.Configure": Configure every
--      component of the local packages, to get the 'LocalBuildInfo'.
--
--   5. "Distribution.Client.Buck2.Generate": Generate buck2 targets
--      for each local component to be built. A pure function of
--      'PackageDescription', 'LocalBuildInfo' and a few other things.
--
--   6. "Distribution.Client.Buck2.Write": Write the generated buck2
--      targets for each package to @BUCK.cabal.bzl@, and the autogen
--      files into @cabal-buck2/autogen@ in each package's directory.
module Distribution.Client.CmdBuck2
  ( buck2Command
  , buck2Action
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import Distribution.Client.DistDirLayout (DistDirLayout (distProjectRootDirectory))
import Distribution.Client.NixStyleOptions
  ( NixStyleFlags (..)
  , cfgVerbosity
  , defaultNixStyleFlags
  , nixStyleOptions
  )
import Distribution.Client.ProjectOrchestration
import Distribution.Client.ScriptUtils
  ( AcceptNoTargets (..)
  , TargetContext (..)
  , updateContextAndWriteProjectFile
  , withContextAndSelectors
  )
import Distribution.Client.Setup
  ( GlobalFlags
  , InstallFlags (installOnlyDeps)
  )

import Distribution.Simple.Command (CommandUI (..), usageAlternatives)
import Distribution.Simple.Flag (toFlag)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Simple.Utils (die', notice)
import Distribution.Verbosity (normal)

import Distribution.Client.Buck2.BuildDependencies (buildDependencies)
import Distribution.Client.Buck2.Cache (cacheSetting, configureCache)
import Distribution.Client.Buck2.Configure (configureComponents)
import Distribution.Client.Buck2.Flags (Buck2Flags, buck2FlagOptions, defaultBuck2Flags, dependencyMode)
import Distribution.Client.Buck2.LocalPackages
  ( builtLocalPackages
  , localToolTargets
  , projectTestOptions
  , wantedBuildTools
  )
import Distribution.Client.Buck2.Prebuilt (generatePrebuilt)
import Distribution.Client.Buck2.Setup
  ( checkBuck2Prelude
  , ensureBuckconfigAndPackage
  )
import Distribution.Client.Buck2.Write (writeAllPackages)

-- | The @cabal buck2@ CLI command
buck2Command :: CommandUI (NixStyleFlags Buck2Flags)
buck2Command =
  CommandUI
    { commandName = "buck2"
    , commandSynopsis = "Set up (or refresh) a buck2 build for this project."
    , commandUsage = usageAlternatives "buck2" ["[FLAGS]"]
    , commandDescription = Just $ \_ ->
        "Builds every dependency of the project (as `cabal build all "
          ++ "--only-dependencies` would), then generates the buck2 build "
          ++ "files (.buckconfig, PACKAGE, third-party/haskell, and a "
          ++ "BUCK.cabal.bzl for each local package) needed to build the "
          ++ "project with buck2 instead of cabal. Requires a checkout of "
          ++ "https://github.com/simonmar/haskell-buck2 at ./buck2. See "
          ++ "buck2/README.md for details.\n\n"
          ++ "Flags that would normally be passed to `cabal build`/`cabal "
          ++ "configure` (-f, --enable-profiling, --enable-tests, etc.) are "
          ++ "honoured here too, and apply to the dependency build."
    , commandNotes = Nothing
    , commandDefaultFlags = defaultNixStyleFlags defaultBuck2Flags
    , commandOptions = nixStyleOptions buck2FlagOptions
    }

-- | Implement @cabal buck2@
buck2Action :: NixStyleFlags Buck2Flags -> [String] -> GlobalFlags -> IO ()
buck2Action flags extraArgs globalFlags = do
  unless (null extraArgs) $
    die' verbosity ("'cabal buck2' doesn't take any extra arguments: " ++ unwords extraArgs)
  cache <- either (die' verbosity) return (cacheSetting (extraFlags flags))

  withContextAndSelectors verbosity RejectNoTargets Nothing depsFlags ["all"] globalFlags BuildCommand $
    \targetCtx ctx targetSelectors -> do
      baseCtx <- case targetCtx of
        ProjectContext -> return ctx
        GlobalContext -> return ctx
        ScriptContext path exemeta -> updateContextAndWriteProjectFile ctx path exemeta

      let projectRoot = distProjectRootDirectory (distDirLayout baseCtx)
      checkBuck2Prelude verbosity projectRoot

      buildCtx <- buildDependencies verbosity mode baseCtx targetSelectors

      ensureBuckconfigAndPackage verbosity projectRoot
      configureCache verbosity projectRoot cache

      localPkgs <- builtLocalPackages verbosity mode (distDirLayout baseCtx) (elaboratedPlanOriginal buildCtx)

      (externalBuildTools, resolvedDeps) <-
        generatePrebuilt
          verbosity
          projectRoot
          (cabalDirLayout baseCtx)
          (elaboratedShared buildCtx)
          (elaboratedPlanToExecute buildCtx)
          (localToolTargets projectRoot localPkgs)
          (wantedBuildTools localPkgs)

      -- 'generatePrebuilt' already found and parsed every real @.conf@
      -- file of the resolved dependency closure.
      componentLBIs <- configureComponents verbosity mode baseCtx buildCtx (PackageIndex.fromList resolvedDeps)

      writeAllPackages
        verbosity
        projectRoot
        componentLBIs
        externalBuildTools
        (projectTestOptions mode (elaboratedPlanOriginal buildCtx))
        localPkgs

      notice verbosity $
        unlines
          [ "cabal buck2: done. You can now:"
          , "    buck2 build //...          # build everything"
          , "    buck2 test //...           # test everything"
          , "    buck2 build //... -m opt   # build everything in opt mode"
          ]
  where
    verbosity = cfgVerbosity normal flags
    mode = dependencyMode (extraFlags flags)
    depsFlags = flags{installFlags = (installFlags flags){installOnlyDeps = toFlag True}}
