-- | Configure the components of the packages that buck2 builds from
-- source, to get the 'LocalBuildInfo'.
module Distribution.Client.Buck2.Configure
  ( configureComponents
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import qualified Data.Map as Map

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Control.Concurrent.STM
  ( atomically
  , modifyTVar'
  , newTVarIO
  , readTVarIO
  )

import Distribution.Client.DistDirLayout
  ( DistDirLayout (distBuildDirectory)
  )
import qualified Distribution.Client.InLibrary as InLibrary
import qualified Distribution.Client.InstallPlan as InstallPlan
import Distribution.Client.ProjectOrchestration
import Distribution.Client.ProjectPlanning hiding (pruneInstallPlanToTargets)
import Distribution.Client.ProjectPlanning.Types
  ( elabComponentName
  , elabDistDirParams
  , elabExeDependencyPaths
  , elabOrderExeDependencies
  , elabOrderLibDependencies
  )
import Distribution.Client.Types.ReadyPackage (GenericReadyPackage (ReadyPackage))
import Distribution.Client.Utils (numberOfProcessors)
import Distribution.Types.ParStrat (ParStratInstall, ParStratX (..))

import Distribution.Package (PackageName, packageName, packageVersion)
import Distribution.PackageDescription (PackageDescription)
import qualified Distribution.PackageDescription as PD
import Distribution.Simple.Compiler (PackageDBX (GlobalPackageDB))
import Distribution.Simple.PackageIndex (InstalledPackageIndex)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Simple.Program.Builtin (builtinPrograms)
import Distribution.Simple.Program.Db (prependProgramSearchPathNoLogging, restoreProgramDb, updateProgram, userSpecifyArgss)
import Distribution.Simple.Program.Types (ProgramLocation (FoundOnSystem), ConfiguredProgram (programVersion), simpleConfiguredProgram)
import Distribution.Simple.Register (generateRegistrationInfo)
import Distribution.Simple.Utils (info)
import Distribution.Types.InstalledPackageInfo (InstalledPackageInfo)
import Distribution.Types.LocalBuildInfo
  ( LocalBuildInfo
  , componentNameCLBIs
  , distPrefLBI
  , relocatable
  )
import Distribution.Types.UnitId (UnitId)
import Distribution.Types.UnqualComponentName (unUnqualComponentName)
import Distribution.Utils.Path (makeSymbolicPath)
import Distribution.Verbosity (defaultVerbosityHandles)

import System.Directory (canonicalizePath)
import System.FilePath ((</>))

import Distribution.Client.Buck2.LocalPackages (DependencyMode, builtLocalElabs, componentNamesFor, isBuiltLocally, packageSourceDir, planElab)
import Distribution.Client.Buck2.Schedule (runDependencyGraph)

-- | Get a real 'LocalBuildInfo' for every component in the
-- 'ProjectBuildContext', keyed by package and component name.  Only
-- components actually selected by the build targets (and whatever
-- they depend on) are configured.
--
-- @installedIndex@ must cover the whole resolved dependency closure of the
-- project. Each library is added to it, configured and registered in-place,
-- before the components that depend on it are configured.
--
-- Configuration happens concurrently as far as possible, because
-- this can take a while for projects with a lot of components to build.
configureComponents
  :: Verbosity
  -> DependencyMode
  -> ProjectBaseContext
  -> ProjectBuildContext
  -> InstalledPackageIndex
  -> IO (Map (PackageName, ComponentName) LocalBuildInfo)
configureComponents verbosity mode baseCtx buildCtx installedIndex =
  configureComponentsConcurrently
    verbosity
    mode
    (distDirLayout baseCtx)
    (parStratNumJobs (buildSettingNumJobs (buildSettings baseCtx)))
    (pruneInstallPlanToTargets TargetActionBuild (targetsMap buildCtx) (elaboratedPlanOriginal buildCtx))
    (elaboratedShared buildCtx)
    installedIndex

-- | A real 'LocalBuildInfo' for one local (or quasi-local) *component*.
localBuildInfoFor
  :: Verbosity
  -> DependencyMode
  -> DistDirLayout
  -> ElaboratedInstallPlan
  -> ElaboratedSharedConfig
  -> InstalledPackageIndex
  -> ElaboratedConfiguredPackage
  -> IO LocalBuildInfo
localBuildInfoFor verbosity mode distDirLayout plan shared ipi elab = do
  -- Real Cabal's own 'InLibrary.configure' falls back to *searching* the
  -- working directory for a @<pkgname>.cabal@ file whenever
  -- 'Cabal.configCabalFilePath' isn't set (see its own use of
  -- 'tryFindPackageDesc') - so this has to be the package's own source
  -- directory, matching 'setupHsScriptOptions''s own @srcdir@ in the
  -- real build path ("Distribution.Client.ProjectBuilding.UnpackedPackage"),
  -- not the buck2 command's actual cwd (the project root), or this fails
  -- outright with "No cabal file found" for every package but one that
  -- happens to be sitting at the project root itself.
  pkgDir <- packageSourceDir verbosity distDirLayout elab
  let verbHandles = defaultVerbosityHandles
      -- Builtin preprocessors (alex, happy, hsc2hs, ...) restored as
      -- known-but-unconfigured programs, and the compiler's own
      -- already-configured programs - the same starting point a real
      -- build's own 'Distribution.Client.SetupWrapper' constructs (see
      -- its own comment "Note [Constructing the ProgramDb]") - plus
      -- 'elabExeDependencyPaths'\/'elabProgramPathExtra' prepended onto
      -- its search path. That part isn't optional the way the rest of
      -- "Note [Constructing the ProgramDb]"'s extra layering is: a
      -- component with e.g. @build-tool-depends: alex:alex@ needs
      -- 'InLibrary.configure' below to be able to find *this* build's
      -- own just-built @alex@ (never on a bare @$PATH@ - it only exists
      -- under @dist-newstyle@) and query its version, the same way real
      -- Cabal's own subprocess-based configure does via
      -- 'setupHsScriptOptions''s @useExtraPathEnv@ - just via a search
      -- path prepend instead of a subprocess's environment, since this
      -- runs in-process.
      -- The user-specified program arguments (@ghc-options:@ from
      -- cabal.project, @--ghc-options@, ...) are applied by Cabal's own
      -- top-level @configure@, which 'InLibrary.configure' skips - so
      -- without this the 'LocalBuildInfo' wouldn't have them, unlike one
      -- from a real @Setup configure@.
      --
      -- A tool that buck2 is going to build doesn't exist yet when the
      -- component is configured, but Cabal wants to know that it is there
      -- and of a version that suits: it is told so (the tool is put on the
      -- @PATH@ of the compile actions that use it by buck2).
      progDb =
        foldr updateProgram userProgDb builtTools
      userProgDb =
        userSpecifyArgss (Map.toList (elabProgramArgs elab)) $
          prependProgramSearchPathNoLogging
            (elabExeDependencyPaths elab ++ elabProgramPathExtra elab)
            []
            (restoreProgramDb builtinPrograms (pkgConfigCompilerProgs shared))
      builtTools =
        [ (simpleConfiguredProgram name (FoundOnSystem name)){programVersion = Just (packageVersion depElab)}
        | uid <- elabOrderExeDependencies elab
        , Just depElab <- [InstallPlan.lookup plan uid >>= planElab]
        , isBuiltLocally mode depElab
        , Just (CExeName exe) <- [elabComponentName depElab]
        , let name = unUnqualComponentName exe
        ]
      buildType = PD.buildType (elabPkgDescription elab)
      inputs =
        InLibrary.libraryConfigureInputsFromElabPackage
          verbHandles
          buildType
          progDb
          shared
          (ReadyPackage elab)
          ipi
          []
      builddir = makeSymbolicPath (distBuildDirectory distDirLayout (elabDistDirParams shared elab) </> "build")
      commonFlags = setupHsCommonFlags verbosity (Just (makeSymbolicPath pkgDir)) builddir [] False
  cfg <-
    setupHsConfigureFlags
      (fmap makeSymbolicPath . canonicalizePath)
      plan
      (ReadyPackage elab)
      shared
      commonFlags
  InLibrary.configure inputs cfg

-- | If @cname@ names a library component, produce the real, in-place
-- 'InstalledPackageInfo' for it.
libraryInstalledPackageInfo :: Verbosity -> LocalBuildInfo -> PackageDescription -> ComponentName -> IO (Maybe InstalledPackageInfo)
libraryInstalledPackageInfo verbosity lbi pkgDesc cname = case cname of
  CLibName ln
    | Just lib <- listToMaybe [l | l <- PD.allLibraries pkgDesc, PD.libName l == ln]
    , (clbi : _) <- componentNameCLBIs lbi cname ->
        Just <$> generateRegistrationInfo verbosity pkgDesc lib lbi clbi True (relocatable lbi) (distPrefLBI lbi) GlobalPackageDB
  _ -> return Nothing

-- | Obtain the 'LocalBuildInfo' for all the components by configuring
-- them concurrently as far as possible, respecting dependency constraints
-- and the @-jNUM@ flag.
configureComponentsConcurrently
  :: Verbosity
  -> DependencyMode
  -> DistDirLayout
  -> Int
  -- ^ Maximum number of components to configure at once (from
  -- @-j@\/@jobs:@, like a @cabal build@ would use).
  -> ElaboratedInstallPlan
  -> ElaboratedSharedConfig
  -> InstalledPackageIndex
  -> IO (Map (PackageName, ComponentName) LocalBuildInfo)
configureComponentsConcurrently verbosity mode distDirLayout numJobs plan shared installedIndex = do
  numCaps <- getNumCapabilities
  info verbosity $ "cabal buck2: configuring components with up to " ++ show numJobs ++ " job(s)"
  let wantedCaps = min numJobs numberOfProcessors
  when (numCaps < wantedCaps) $
    setNumCapabilities wantedCaps

  let localElabs :: Map UnitId ElaboratedConfiguredPackage
      localElabs =
        Map.fromList
          [ (elabUnitId elab, elab)
          | elab <- builtLocalElabs mode plan
          ]

  indexVar <- newTVarIO installedIndex
  componentLBIsVar <- newTVarIO Map.empty

  runDependencyGraph numJobs (Map.map elabOrderLibDependencies localElabs) $ \uid -> do
    let elab = localElabs Map.! uid
        pkgDesc = elabPkgDescription elab
    idx <- readTVarIO indexVar
    lbi <- localBuildInfoFor verbosity mode distDirLayout plan shared idx elab
    for_ (componentNamesFor elab pkgDesc) $ \cname -> do
      mipi <- libraryInstalledPackageInfo verbosity lbi pkgDesc cname
      for_ mipi $ \ipi -> atomically $ modifyTVar' indexVar (PackageIndex.insert ipi)
      atomically $ modifyTVar' componentLBIsVar (Map.insert (packageName pkgDesc, cname) lbi)

  readTVarIO componentLBIsVar

-- | How many jobs a parallel strategy allows to run at once: @-j@ with no
-- number means one per processor, @-jsem N@ is treated as @-jN@.
parStratNumJobs :: ParStratInstall -> Int
parStratNumJobs Serial = 1
parStratNumJobs (NumJobs n) = fromMaybe numberOfProcessors n
parStratNumJobs (UseSem n) = n
