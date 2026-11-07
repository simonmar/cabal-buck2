-- | Configure the components of the packages that buck2 builds from
-- source, to get the 'LocalBuildInfo'.
module Distribution.Client.Buck2.Configure
  ( configureComponents
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import qualified Data.Map as Map
import qualified Data.Map.Strict as Map.Strict

import Control.Concurrent (MVar, getNumCapabilities, modifyMVar, newMVar, setNumCapabilities)
import Control.Concurrent.STM
  ( atomically
  , modifyTVar'
  , newTVarIO
  , readTVarIO
  )

import Distribution.Client.JobControl (newLock)
import Distribution.Client.Setup (filterConfigureFlags)
import Distribution.Client.SetupWrapper (InLibraryArgs (..), InLibraryLBI (..), SetupRunnerArgs (..), setupWrapper)
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

import Distribution.Package (PackageName, packageId, packageName, packageVersion)
import Distribution.PackageDescription (PackageDescription)
import qualified Distribution.PackageDescription as PD
import Distribution.Simple.Compiler (PackageDBX (GlobalPackageDB))
import Distribution.Simple.PackageIndex (InstalledPackageIndex)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Simple.Program.Builtin (builtinPrograms)
import Distribution.Simple.Program.Db (ProgramDb, configureAllKnownPrograms, configuredPrograms, modifyProgramSearchPath, prependProgramSearchPathNoLogging, restoreProgramDb, updateConfiguredProgs, updateProgram, userSpecifyArgss)
import Distribution.Simple.Program.Find (ProgramSearchPathEntry (ProgramSearchPathDefault, ProgramSearchPathDir))
import Distribution.Simple.Program.Types (ProgramLocation (FoundOnSystem), ConfiguredProgram (programMonitorFiles, programOverrideEnv, programVersion), simpleConfiguredProgram)
import Distribution.Simple.Register (generateRegistrationInfo)
import qualified Distribution.Simple.Setup as Cabal
import Distribution.Simple.Program (defaultProgramDb)
import Distribution.Simple.Utils (die', info)
import Distribution.Types.InstalledPackageInfo (InstalledPackageInfo)
import Distribution.Types.LocalBuildInfo
  ( LocalBuildInfo
  , componentNameCLBIs
  , distPrefLBI
  , relocatable
  , withPrograms
  )
import Distribution.Types.UnitId (UnitId)
import Distribution.Types.UnqualComponentName (unUnqualComponentName)
import Distribution.Utils.Path (makeSymbolicPath)
import Distribution.Verbosity (defaultVerbosityHandles)

import System.Directory (canonicalizePath)
import System.Environment (lookupEnv)
import System.FilePath (splitSearchPath, (</>))

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
  -> [FilePath]
  -- ^ The directories of the @PATH@.
  -> ProgramsCache
  -> ElaboratedConfiguredPackage
  -> IO LocalBuildInfo
localBuildInfoFor verbosity mode distDirLayout plan shared ipi pathDirs programs elab = do
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
      userProgDb =
        userSpecifyArgss programArgs $
          prependProgramSearchPathNoLogging
            extraPaths
            []
            (withPathDirs pathDirs (restoreProgramDb builtinPrograms (pkgConfigCompilerProgs shared)))
      builtTools =
        [ (simpleConfiguredProgram name (FoundOnSystem name)){programVersion = Just (packageVersion depElab)}
        | uid <- elabOrderExeDependencies elab
        , Just depElab <- [InstallPlan.lookup plan uid >>= planElab]
        , isBuiltLocally mode depElab
        , Just (CExeName exe) <- [elabComponentName depElab]
        , let name = unUnqualComponentName exe
        ]
      extraPaths = elabExeDependencyPaths elab ++ elabProgramPathExtra elab
      programArgs = Map.toList (elabProgramArgs elab)
  configured <- configureProgramsOnce verbosity programs (extraPaths, programArgs) userProgDb
  -- A tool that buck2 is going to build (an alex built from source, say)
  -- doesn't exist yet when the component is configured. Cabal still wants to
  -- know that the tool is there and that its version is suitable, so we tell
  -- it the tool has been found, with the version of the package that buck2
  -- will build it from. buck2 later puts the tool on the @PATH@ of the
  -- compile actions that use it.
  --
  -- This is done after 'configureProgramsOnce', rather than before, because
  -- each component has its own built tools, and they don't need searching for.
  let progDb = foldr updateProgram configured builtTools
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
  if buildType == PD.Hooks
    then configureWithHooks verbosity distDirLayout plan shared ipi elab pkgDir cfg
    else InLibrary.configure inputs cfg

-- | Configure a package with a @Hooks@ build type: its hooks are in an
-- executable that is built from its @SetupHooks.hs@ first, which is what
-- 'setupWrapper' does.
configureWithHooks
  :: Verbosity
  -> DistDirLayout
  -> ElaboratedInstallPlan
  -> ElaboratedSharedConfig
  -> InstalledPackageIndex
  -> ElaboratedConfiguredPackage
  -> FilePath
  -> Cabal.ConfigFlags
  -> IO LocalBuildInfo
configureWithHooks verbosity distDirLayout plan shared ipi elab pkgDir cfg = do
  lock <- newLock
  ipiVar <- newTVarIO ipi
  let srcdir = makeSymbolicPath pkgDir
      builddir = makeSymbolicPath (distBuildDirectory distDirLayout (elabDistDirParams shared elab) </> "build")
      options = setupHsScriptOptions (ReadyPackage elab) plan shared distDirLayout srcdir builddir lock
  res <-
    setupWrapper
      verbosity
      options
      (Just (elabPkgDescription elab))
      (Cabal.configureCommand defaultProgramDb)
      Cabal.configCommonFlags
      (return . filterConfigureFlags cfg)
      (const [])
      (InLibraryArgs (InLibraryConfigureArgs shared (ReadyPackage elab) ipiVar))
  case res of
    InLibraryLBI lbi -> return lbi
    NotInLibraryNoLBI ->
      die' verbosity $
        "cabal buck2: the Cabal library of "
          ++ prettyShow (packageId elab)
          ++ "'s setup dependencies doesn't match the one cabal-buck2 uses, so its hooks can't be run: it needs Cabal-hooks "
          ++ "from the same release (add a lower bound on Cabal-hooks in its setup-depends)"

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

  pathDirs <- maybe [] splitSearchPath <$> lookupEnv "PATH"
  programs <- newMVar Map.empty
  indexVar <- newTVarIO installedIndex
  componentLBIsVar <- newTVarIO Map.empty

  runDependencyGraph numJobs (Map.map elabOrderLibDependencies localElabs) $ \uid -> do
    let elab = localElabs Map.! uid
        pkgDesc = elabPkgDescription elab
    idx <- readTVarIO indexVar
    lbi <- withoutSearchState =<< localBuildInfoFor verbosity mode distDirLayout plan shared idx pathDirs programs elab
    for_ (componentNamesFor elab pkgDesc) $ \cname -> do
      mipi <- libraryInstalledPackageInfo verbosity lbi pkgDesc cname
      for_ mipi $ \ipi -> atomically $ modifyTVar' indexVar (PackageIndex.insert ipi)
      atomically $ modifyTVar' componentLBIsVar (Map.insert (packageName pkgDesc, cname) lbi)

  readTVarIO componentLBIsVar

-- | The program db sets @PATH@ for all of its programs. We switch it from using
-- @ProgramSearchPathDefault@, which re-does the lookup for every program, to
-- using an explicit list of directories which we already know.
-- 
-- The primary reason for this is memory: re-reading @PATH@ every time leaves
-- us with many copies of it in memory, significantly increasing allocation on
-- large projects.
withPathDirs :: [FilePath] -> ProgramDb -> ProgramDb
withPathDirs pathDirs = modifyProgramSearchPath (concatMap expand)
  where
    expand ProgramSearchPathDefault = map ProgramSearchPathDir pathDirs
    expand entry = [entry]

-- | A cache of 'ProgramDb's whose programs have all been configured, shared by
-- every component that this run of @cabal buck2@ configures (see
-- 'configureProgramsOnce'). Each entry is keyed by the extra search path and
-- the user-specified program arguments that the 'ProgramDb' was made with,
-- since those are the only parts of it that differ between components.
type ProgramsCache = MVar (Map ([FilePath], [(String, [String])]) ProgramDb)

-- | Configure every program that a 'ProgramDb' knows about, reusing an
-- earlier result from the cache when there is one.
--
-- Without this, Cabal's configure would configure the programs separately
-- for each component. For every known program, it searches the @PATH@ and
-- then runs the program to find out its version. In a project with many
-- components that adds up to a lot of processes, and nearly all of the work
-- is repeated: the result depends only on the extra search path and the
-- program arguments, and almost every component has the same ones. So the
-- programs are configured once for each distinct key, and the other
-- components get the cached result.
--
-- The cache stays locked while a 'ProgramDb' is being configured. That way,
-- when several components that need the same configuration are configured
-- concurrently, the first one does the work and the others wait for its
-- result, rather than all configuring it at the same time. The cost is that
-- components with different keys can't configure their programs in
-- parallel either, but there are very few distinct keys.
configureProgramsOnce :: Verbosity -> ProgramsCache -> ([FilePath], [(String, [String])]) -> ProgramDb -> IO ProgramDb
configureProgramsOnce verbosity cache key progDb =
  modifyMVar cache $ \dbs -> case Map.lookup key dbs of
    Just db -> return (dbs, db)
    Nothing -> do
      db <- configureAllKnownPrograms verbosity progDb
      return (Map.insert key db dbs, db)

-- | The 'LocalBuildInfo' without what each configured program keeps of its
-- search: the @PATH@ it was found on, as an environment override, and every
-- place it was looked for, as files to monitor. @cabal buck2@ uses neither,
-- and each program has its own copy, made when the component is configured:
-- with the @PATH@ of a large development shell, that comes to tens of
-- megabytes for every component, all kept until the build is generated.
withoutSearchState :: LocalBuildInfo -> IO LocalBuildInfo
withoutSearchState lbi = do
  let progs = updateConfiguredProgs (Map.Strict.map forget) (withPrograms lbi)
      forget prog = prog{programOverrideEnv = [], programMonitorFiles = []}
  -- Forced now, or the new 'LocalBuildInfo' would keep the old programs
  -- until something looked at them.
  _ <- evaluate (length (configuredPrograms progs))
  evaluate lbi{withPrograms = progs}

-- | How many jobs a parallel strategy allows to run at once: @-j@ with no
-- number means one per processor, @-jsem N@ is treated as @-jN@.
parStratNumJobs :: ParStratInstall -> Int
parStratNumJobs Serial = 1
parStratNumJobs (NumJobs n) = fromMaybe numberOfProcessors n
parStratNumJobs (UseSem n) = n
