-- | The packages of a later stage of a bootstrapped compiler: packages built
-- by a compiler that the project builds itself (the libraries of GHC's stage1,
-- built by the stage1 GHC). That compiler doesn't exist when @cabal buck2@
-- runs, so the packages are configured for a stand-in for it: the compiler
-- that @cabal buck2@ uses, with the version of the later one, and claiming to
-- support every language extension (the real compiler checks them when it
-- compiles the code).
--
-- Nothing is solved or built beforehand: the packages of a stage are those of
-- its project file, with the flags given there, and they may depend only on
-- each other.
module Distribution.Client.Buck2.LaterStage
  ( LaterStage (..)
  , parseLaterStage
  , configureLaterStage
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import qualified Data.ByteString as BS
import qualified Data.Map as Map
import qualified Data.Set as Set
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.FilePath ((</>))

import qualified Distribution.Compat.Graph as Graph
import Distribution.Client.ProjectConfig (PackageConfig (packageConfigFlagAssignment), ProjectConfig (..))
import Distribution.Client.ProjectConfig.Legacy (convertLegacyProjectConfig, parseLegacyProjectConfig)
import Distribution.Client.ProjectConfig.Types (MapMappend (getMapMappend))
import Distribution.Client.ProjectPlanning (setupHsCommonFlags)
import qualified Distribution.Deprecated.ParseUtils as ParseUtils
import Distribution.Compiler (AbiTag (NoAbiTag), CompilerFlavor (GHC), CompilerId (..))
import Distribution.Package (PackageName, packageId, packageName, packageVersion)
import qualified Distribution.PackageDescription as PD
import Distribution.PackageDescription.Configuration (finalizePD)
import Distribution.Simple (autoconfSetupHooks)
import Distribution.Simple.Compiler (Compiler (..), DebugInfoLevel (NoDebugInfo), OptimisationLevel (NormalOptimisation), PackageDBX (GlobalPackageDB), ProfDetailLevel (ProfDetailDefault), compilerInfo)
import qualified Distribution.Simple.Configure as Cabal
import Distribution.Simple.PackageDescription (readGenericPackageDescription)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Simple.Program.Db (ProgramDb)
import qualified Distribution.Simple.Setup as Cabal
import Distribution.Simple.SetupHooks.Internal (ConfigureHooks (preConfPackageHook), SetupHooks (configureHooks), noSetupHooks)
import Distribution.Simple.Utils (die', notice, ordNub, tryFindPackageDesc)
import Distribution.System (Platform)
import Distribution.Types.Component (componentName)
import Distribution.Types.ComponentId (mkComponentId)
import Distribution.Types.ComponentName (ComponentName (CLibName))
import Distribution.Types.ComponentRequestedSpec (ComponentRequestedSpec (..))
import Distribution.Types.Dependency (depPkgName)
import Distribution.Types.DependencySatisfaction (DependencySatisfaction (..))
import Distribution.Types.MissingDependency (MissingDependency (..))
import Distribution.Types.MissingDependencyReason (MissingDependencyReason (MissingPackage))
import Distribution.Types.Flag (FlagAssignment)
import Distribution.Types.GivenComponent (GivenComponent (..))
import Distribution.Types.HookedBuildInfo (emptyHookedBuildInfo)
import Distribution.Types.LibraryName (LibraryName (LMainLibName))
import qualified Distribution.Types.LocalBuildConfig as LBC
import Distribution.Types.LocalBuildInfo (LocalBuildInfo)
import Distribution.Utils.Path (makeSymbolicPath, relativeSymbolicPath)
import Distribution.Verbosity (defaultVerbosityHandles)
import Distribution.Version (Version, withinRange)
import Language.Haskell.Extension (Extension (..), KnownExtension, knownLanguages)

import Distribution.Client.Buck2.Configure (libraryInstalledPackageInfo)
import Distribution.Client.Buck2.LocalPackages (BuiltPackage (..), customSetupBuildType, warnCustomSetup)

-- | A later stage, from @--later-stage=NAME:VERSION:PROJECT_FILE@.
data LaterStage = LaterStage
  { lsName :: String
  -- ^ Names the stage's packages in the generated files.
  , lsCompilerVersion :: Version
  -- ^ Of the compiler that builds the stage's packages.
  , lsProjectFile :: FilePath
  }

parseLaterStage :: String -> Either String LaterStage
parseLaterStage s = case splitOn ':' s of
  [name, version, file]
    | not (null name)
    , Just v <- simpleParsec version ->
        Right LaterStage{lsName = name, lsCompilerVersion = v, lsProjectFile = file}
  _ -> Left ("--later-stage: expected NAME:VERSION:PROJECT_FILE, not " ++ show s)
  where
    splitOn c xs = case break (== c) xs of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitOn c rest

-- | Configure the packages of a later stage, given the compiler, platform and
-- programs of @cabal buck2@'s own compiler.
configureLaterStage
  :: Verbosity
  -> FilePath
  -- ^ The project root.
  -> Bool
  -- ^ @--enable-custom-setup@: see 'translateCustomSetups'.
  -> (Compiler, Platform, ProgramDb)
  -> LaterStage
  -> IO ([BuiltPackage], Map (PackageName, ComponentName) LocalBuildInfo)
configureLaterStage verbosity projectRoot customSetup (comp0, platform, progDb) stage = do
  (dirs, flags) <- readStageProject verbosity (projectRoot </> lsProjectFile stage)
  pkgs <- for dirs $ \dir0 -> do
    dir <- makeAbsolute (projectRoot </> dir0)
    cabalFile <- relativeSymbolicPath <$> tryFindPackageDesc verbosity (Just (makeSymbolicPath dir))
    gpd0 <- readGenericPackageDescription verbosity (Just (makeSymbolicPath dir)) cabalFile
    let desc = PD.packageDescription gpd0
    gpd <-
      if customSetup && PD.buildType desc == PD.Custom
        then do
          buildType <- customSetupBuildType dir
          warnCustomSetup verbosity (PD.package desc) buildType
          return gpd0{PD.packageDescription = desc{PD.buildTypeRaw = Just buildType}}
        else return gpd0
    return (dir, cabalFile, gpd, PD.buildType desc == PD.Custom)
  let versions = Map.fromList [(packageName gpd, packageVersion gpd) | (_, _, gpd, _) <- pkgs]
      customSetups = Set.fromList [packageName gpd | (_, _, gpd, custom) <- pkgs, custom, customSetup]
  finalized <- for pkgs $ \(dir, cabalFile, gpd, _) -> do
    let fa = Map.findWithDefault mempty (packageName gpd) flags
        -- What a dependency is satisfied by is the stage's package of its
        -- name, which an automatic flag can choose the version of.
        available d = case Map.lookup (depPkgName d) versions of
          Just v | withinRange v (PD.depVerRange d) -> Satisfied
          _ -> Unsatisfied MissingPackage
    case finalizePD fa (ComponentRequestedSpec False False) available platform (compilerInfo comp) [] gpd of
      Left missing ->
        die' verbosity $
          "cabal buck2: package "
            ++ prettyShow (packageName gpd)
            ++ " of stage "
            ++ lsName stage
            ++ " depends on packages that aren't in it: "
            ++ intercalate ", " [prettyShow (depPkgName d) | MissingDependency d _ <- missing]
      Right (pd, fa') -> return (dir, cabalFile, gpd, pd, fa')
  let graph = Graph.fromDistinctList [Graph.N p (packageName pd) (libraryDeps pd) | p@(_, _, _, pd, _) <- finalized]
  ordered <- case Graph.revTopSort graph of
    sorted | null (Graph.cycles graph) -> return [p | Graph.N p _ _ <- sorted]
    _ -> die' verbosity ("cabal buck2: the packages of stage " ++ lsName stage ++ " depend on each other in a cycle")
  (_, lbis) <- foldM configureOne (mempty, Map.empty) ordered
  return
    ( [ BuiltPackage{bpDir = dir, bpDescription = pd, bpInProject = True, bpCustomSetup = packageName pd `Set.member` customSetups, bpPackageSet = Just (lsName stage)}
      | (dir, _, _, pd, _) <- ordered
      ]
    , lbis
    )
  where
    comp = laterCompiler comp0 (lsCompilerVersion stage)

    libraryDeps pd =
      ordNub
        [ depPkgName d
        | bi <- map PD.libBuildInfo (PD.allLibraries pd)
        , d <- PD.targetBuildDepends bi
        , depPkgName d /= packageName pd
        ]

    configureOne (index, lbis) (dir, cabalFile, gpd, pd, fa) = do
      let pkgId = PD.package pd
          unitId = prettyShow pkgId ++ "-inplace"
          distDir = projectRoot </> "dist-newstyle" </> "buck2" </> lsName stage </> prettyShow pkgId
          deps =
            [ GivenComponent (packageName dep) LMainLibName (mkComponentId (prettyShow (packageId dep) ++ "-inplace"))
            | dep <- PackageIndex.allPackages index
            , packageName dep `elem` libraryDeps pd
            ]
          common =
            (setupHsCommonFlags verbosity (Just (makeSymbolicPath dir)) (makeSymbolicPath distDir) [] False)
              { Cabal.setupCabalFilePath = Cabal.toFlag cabalFile
              }
          cfg =
            (Cabal.defaultConfigFlags progDb)
              { Cabal.configCommonFlags = common
              , Cabal.configIPID = Cabal.toFlag unitId
              , Cabal.configDependencies = deps
              , Cabal.configExactConfiguration = Cabal.toFlag True
              , Cabal.configConfigurationsFlags = fa
              , Cabal.configTests = Cabal.toFlag False
              , Cabal.configBenchmarks = Cabal.toFlag False
              }
          hooks = configureHooks $ case PD.buildType pd of
            PD.Configure -> autoconfSetupHooks
            _ -> noSetupHooks
          lbc0 = LBC.LocalBuildConfig{LBC.extraConfigArgs = [], LBC.withPrograms = progDb, LBC.withBuildOptions = buildOptions}
      createDirectoryIfMissing True distDir
      lbc <- maybe (return lbc0) (Cabal.runPreConfPackageHook cfg comp platform lbc0) (preConfPackageHook hooks)
      (_, pkgInfo) <- Cabal.computePackageInfoFromIndex defaultVerbosityHandles cfg gpd index
      lbi <- Cabal.configureFinal defaultVerbosityHandles hooks emptyHookedBuildInfo cfg lbc (gpd, pd) fa (ComponentRequestedSpec False False) comp platform [GlobalPackageDB] pkgInfo
      mipi <- libraryInstalledPackageInfo verbosity lbi pd (CLibName LMainLibName)
      let index' = maybe index (`PackageIndex.insert` index) mipi
          lbis' = Map.union lbis (Map.fromList [((packageName pd, componentName c), lbi) | c <- PD.pkgBuildableComponents pd])
      return (index', lbis')

-- | How the packages are built doesn't matter: the generated targets decide.
buildOptions :: LBC.BuildOptions
buildOptions =
  LBC.BuildOptions
    { LBC.withVanillaLib = True
    , LBC.withProfLib = False
    , LBC.withProfLibShared = False
    , LBC.withSharedLib = False
    , LBC.withStaticLib = False
    , LBC.withBytecodeLib = False
    , LBC.withDynExe = False
    , LBC.withFullyStaticExe = False
    , LBC.withProfExe = False
    , LBC.withProfLibDetail = ProfDetailDefault
    , LBC.withProfExeDetail = ProfDetailDefault
    , LBC.withOptimization = NormalOptimisation
    , LBC.withDebugInfo = NoDebugInfo
    , LBC.withGHCiLib = False
    , LBC.splitSections = False
    , LBC.splitObjs = False
    , LBC.stripExes = False
    , LBC.stripLibs = False
    , LBC.exeCoverage = False
    , LBC.libCoverage = False
    , LBC.relocatable = False
    , LBC.programPrefix = Nothing
    , LBC.programSuffix = Nothing
    }

-- | The stand-in for the compiler of a later stage.
laterCompiler :: Compiler -> Version -> Compiler
laterCompiler comp version =
  comp
    { compilerId = CompilerId GHC version
    , compilerAbiTag = NoAbiTag
    , compilerCompat = []
    , compilerLanguages = [(l, "-X" ++ prettyShow l) | l <- knownLanguages]
    , compilerExtensions = [(e, Just ("-X" ++ prettyShow e)) | k <- [minBound .. maxBound :: KnownExtension], e <- [EnableExtension k, DisableExtension k]]
    , compilerProperties = Map.insert "Project version" (prettyShow version) (Map.delete "Project Unit Id" (Map.delete "ghc-internal Unit Id" (compilerProperties comp)))
    , compilerWiredInUnitIds = Nothing
    }

-- | The package directories and flags of a stage's project file.
readStageProject :: Verbosity -> FilePath -> IO ([FilePath], Map PackageName FlagAssignment)
readStageProject verbosity file = do
  exists <- doesFileExist file
  unless exists $ die' verbosity ("cabal buck2: no project file " ++ file)
  contents <- BS.readFile file
  case parseLegacyProjectConfig file contents of
    ParseUtils.ParseFailed err -> die' verbosity ("cabal buck2: " ++ file ++ ": " ++ show err)
    ParseUtils.ParseOk _ legacy -> do
      let config = convertLegacyProjectConfig legacy
      notice verbosity ("cabal buck2: configuring the packages of " ++ file)
      return
        ( projectPackages config
        , Map.map packageConfigFlagAssignment (getMapMappend (projectConfigSpecificPackage config))
        )
