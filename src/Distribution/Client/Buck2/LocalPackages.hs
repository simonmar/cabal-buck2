-- | Which packages of a project @cabal buck2@ builds from source with buck2
-- (rather than leaving to cabal), and facts about them that come from the
-- elaborated install plan rather than from their @.cabal@ files.
module Distribution.Client.Buck2.LocalPackages
  ( DependencyMode (..)
  , isBuiltLocally
  , planElab
  , builtLocalElabs
  , packageSourceDir
  , componentNamesFor
  , BuiltPackage (..)
  , builtLocalPackages
  , rootRelativeDir
  , ToolTarget (..)
  , localToolTargets
  , wantedBuildTools
  , projectTestOptions
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import qualified Data.Map as Map
import qualified Data.Set as Set
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory, removeDirectoryRecursive)
import System.FilePath (makeRelative, (</>))

import Distribution.Client.DistDirLayout (DistDirLayout (distUnpackedSrcDirectory, distUnpackedSrcRootDirectory))
import qualified Distribution.Client.InstallPlan as InstallPlan
import Distribution.Client.ProjectPlanning
  ( ElaboratedConfiguredPackage (..)
  , ElaboratedInstallPlan
  )
import Distribution.Client.ProjectPlanning.Types
  ( BuildStyle (BuildAndInstall)
  , ElaboratedPackageOrComponent (ElabComponent, ElabPackage)
  , elabComponentName
  , elabLibDependencies
  , elabOrderExeDependencies
  )
import Distribution.Client.Types (confInstId)
import Distribution.Client.Types.PackageLocation (PackageLocation (..))
import Distribution.Types.UnitId (newSimpleUnitId)

import Distribution.Package (PackageName, packageId, packageName)
import Distribution.PackageDescription (PackageDescription)
import qualified Distribution.PackageDescription as PD
import Distribution.Simple.InstallDirs (PathTemplate)
import Distribution.Simple.Utils (die', info, ordNub)
import Distribution.Types.Component (componentBuildInfo, componentName)
import Distribution.Types.ComponentName (ComponentName (CTestName))
import Distribution.Types.Dependency (depPkgName)
import Distribution.Types.ExeDependency (ExeDependency (..))
import Distribution.Types.UnqualComponentName (UnqualComponentName, unUnqualComponentName)


-- | Does buck2 (rather than cabal) build this package from source? True
-- for every genuinely local package, *plus* every non-local one whose own
-- build was forced 'inplace' by depending on one - when a non-local
-- package is forced inplace it must be built by buck2 from source too,
-- otherwise the build would contain multiple incompatible versions of the
-- local dependency. A real-world example is hackage-security in the cabal
-- project, which is not a local package but depends on the local
-- Cabal-syntax.
--
-- With 'DependenciesFromSource' that is every package that GHC doesn't come
-- with: the dependencies are unpacked from their tarballs and built like the
-- project's own packages, and nothing is left to the cabal store.
isBuiltLocally :: DependencyMode -> ElaboratedConfiguredPackage -> Bool
isBuiltLocally DependenciesFromSource _ = True
isBuiltLocally DependenciesFromStore elab = elabLocalToProject elab || elabBuildStyle elab /= BuildAndInstall

-- | The package of a plan node that is not a package of GHC's. One that is
-- already in the cabal store has been 'Installed', so is not 'Configured',
-- but its source is what buck2 builds with @--source-deps@.
planElab :: InstallPlan.GenericPlanPackage ipkg srcpkg -> Maybe srcpkg
planElab (InstallPlan.Configured spkg) = Just spkg
planElab (InstallPlan.Installed spkg) = Just spkg
planElab InstallPlan.PreExisting{} = Nothing

-- | The packages that buck2 builds from source: those 'isBuiltLocally' says
-- it does, that the project's packages need to be built or to be built
-- with. A package that is only a dependency of a package's @Setup.hs@
-- (@setup-depends@) is not needed, as nothing here runs a @Setup.hs@.
builtLocalElabs :: DependencyMode -> ElaboratedInstallPlan -> [ElaboratedConfiguredPackage]
builtLocalElabs mode plan =
  [ elab
  | Just elab <- map planElab (InstallPlan.toList plan)
  , isBuiltLocally mode elab
  , elabUnitId elab `Set.member` needed
  ]
  where
    needed = closure Set.empty [elabUnitId elab | Just elab <- map planElab (InstallPlan.toList plan), elabLocalToProject elab]
    closure seen [] = seen
    closure seen (uid : rest)
      | uid `Set.member` seen = closure seen rest
      | otherwise = case InstallPlan.lookup plan uid >>= planElab of
          Just elab ->
            closure (Set.insert uid seen) (libDependencies elab ++ elabOrderExeDependencies elab ++ rest)
          _ -> closure (Set.insert uid seen) rest
    -- Not 'elabOrderLibDependencies', which for a package that is elaborated
    -- as a whole (one with a @Custom@ build type) also has the dependencies
    -- of its @Setup.hs@.
    libDependencies elab = [newSimpleUnitId (confInstId dep) | (dep, _) <- elabLibDependencies elab]

-- | How the dependencies of the project are built.
data DependencyMode
  = -- | By cabal, into its store, which the buck2 build then uses.
    DependenciesFromStore
  | -- | By buck2, like the project's own packages.
    DependenciesFromSource
  deriving (Eq)

-- | Real on-disk source directory for any package buck2 builds from
-- source - a genuinely local one (always 'LocalUnpackedPackage') or an
-- inplace non-local one, resolved the same way
-- 'Distribution.Client.ProjectPlanning.Types.dataDirEnvVarForPackage'
-- does for the same 'BuildInplaceOnly' case: a plain source checkout
-- uses its own path directly, anything fetched as a tarball\/repo was
-- already unpacked to 'distUnpackedSrcDirectory' to be built inplace in
-- the first place.
packageSourceDir :: Verbosity -> DistDirLayout -> ElaboratedConfiguredPackage -> IO FilePath
packageSourceDir verbosity distDirLayout elab = case elabPkgSourceLocation elab of
  LocalUnpackedPackage dir -> return dir
  _ | elabLocalToProject elab -> unsupported
  LocalTarballPackage{} -> return unpackedPath
  RemoteTarballPackage{} -> return unpackedPath
  RepoTarballPackage{} -> return unpackedPath
  RemoteSourceRepoPackage _ (Just localCheckout) -> return localCheckout
  RemoteSourceRepoPackage{} -> unsupported
  where
    unpackedPath = distUnpackedSrcDirectory distDirLayout (elabPkgSourceId elab)
    unsupported =
      die' verbosity $
        "cabal buck2: local package "
          ++ prettyShow (packageId elab)
          ++ " isn't an unpacked local directory - can't generate a BUCK file for it."

-- | The buildable component names for one elaborated node - either the
-- single component 'elabComponentName' itself names (per-component
-- elaboration, @ElabComponent@), or *every* buildable component of the
-- whole package it configured (whole-package elaboration,
-- @ElabPackage@ - see 'elabComponentName's own haddock, "there could be
-- more, but default this": one @configureFinal@ call in that mode
-- genuinely produces a 'ComponentLocalBuildInfo' for every component of
-- the package internally, regardless of which single one
-- 'elabComponentName' defaults to).
componentNamesFor :: ElaboratedConfiguredPackage -> PackageDescription -> [ComponentName]
componentNamesFor elab pkgDesc = case elabPkgOrComp elab of
  ElabComponent _ -> maybeToList (elabComponentName elab)
  ElabPackage _ -> [componentName comp | comp <- PD.pkgBuildableComponents pkgDesc]

-- | A package that buck2 builds from source.
data BuiltPackage = BuiltPackage
  { bpDir :: FilePath
  , bpDescription :: PackageDescription
  -- ^ Of the whole package.
  , bpInProject :: Bool
  -- ^ A package of the project, as opposed to a dependency that is built
  -- like one.
  }

-- | Every package buck2 builds from source. Per-component elaboration gives
-- each such package one 'ElaboratedConfiguredPackage' per component, all
-- sharing the same directory and 'PackageDescription', so there is one
-- entry per directory here.
builtLocalPackages :: Verbosity -> DependencyMode -> DistDirLayout -> ElaboratedInstallPlan -> IO [BuiltPackage]
builtLocalPackages verbosity mode distDirLayout plan = do
  pkgs <-
    fmap (nubBy ((==) `on` bpDir)) . sequenceA $
      [ do
        dir <- packageSourceDir verbosity distDirLayout elab
        return BuiltPackage{bpDir = dir, bpDescription = elabPkgDescription elab, bpInProject = elabLocalToProject elab}
      | elab <- builtLocalElabs mode plan
      ]
  -- Everything that refers to a package does so by its name (a dependency in
  -- a .cabal file is one), so two versions of one package can't both be
  -- built: a component would be given the wrong one.
  let versionsOf = Map.fromListWith (++) [(PD.package (bpDescription pkg), [bpDir pkg]) | pkg <- pkgs]
      byName = Map.fromListWith (++) [(packageName pkgId, [pkgId]) | pkgId <- Map.keys versionsOf]
      duplicates = [map prettyShow ids | ids@(_ : _ : _) <- Map.elems byName]
  unless (null duplicates) $
    die' verbosity $
      unlines $
        "cabal buck2: the build plan needs more than one version of some packages, which --source-deps can't build:"
          : ["  " ++ intercalate ", " ids | ids <- duplicates]
  removeStaleSources verbosity distDirLayout (map bpDir pkgs)
  return pkgs

-- | Remove the unpacked sources of packages that an earlier run built with
-- buck2 but this one doesn't: their generated @BUCK@ files would otherwise
-- still be part of @//...@, referring to packages that are no longer there.
removeStaleSources :: Verbosity -> DistDirLayout -> [FilePath] -> IO ()
removeStaleSources verbosity distDirLayout current = do
  let root = distUnpackedSrcRootDirectory distDirLayout
  rootExists <- doesDirectoryExist root
  when rootExists $ do
    entries <- map (root </>) <$> listDirectory root
    for_ entries $ \dir -> do
      generated <- doesFileExist (dir </> "BUCK.cabal.bzl")
      when (generated && dir `notElem` current) $ do
        info verbosity $ "cabal buck2: removing " ++ dir ++ ", which is no longer in the build plan"
        removeDirectoryRecursive dir

-- | A directory relative to the project root, @.@ for the root itself.
rootRelativeDir :: FilePath -> FilePath -> FilePath
rootRelativeDir projectRoot dir = case makeRelative projectRoot dir of
  "" -> "."
  rel -> rel

-- | A preprocessor that buck2 builds, as the target that is the executable
-- and the one that holds the files it reads when it runs (its templates).
data ToolTarget = ToolTarget
  { toolLabel :: String
  , toolData :: Maybe (String, String)
  -- ^ The environment variable the tool finds its data directory by, and
  -- the target that is that directory.
  }

-- | The targets of @alex@ and @happy@, when they are among the packages built
-- from source: the rules that preprocess @.x@ and @.y@ files run those
-- instead of one in the cabal store.
localToolTargets :: FilePath -> [BuiltPackage] -> Map String ToolTarget
localToolTargets projectRoot pkgs =
  Map.fromList
    [ (tool, ToolTarget{toolLabel = label pkg tool, toolData = dataFor (packageName desc : map depPkgName (PD.targetBuildDepends (PD.buildInfo exe)))})
    | pkg <- pkgs
    , let desc = bpDescription pkg
    , tool <- ["alex", "happy"]
    , prettyShow (packageName desc) == tool
    , exe <- take 1 [e | e <- PD.executables desc, unUnqualComponentName (PD.exeName e) == tool]
    ]
  where
    label pkg name = "//" ++ dirPart (rootRelativeDir projectRoot (bpDir pkg)) ++ ":" ++ name
    dirPart dir = if dir == "." then "" else dir
    -- The tool's templates are the data files of its own package or, as
    -- with happy, of the library it is the front end of.
    dataFor names =
      listToMaybe
        [ (map underscore name ++ "_datadir", label pkg (name ++ "-data"))
        | pkg <- pkgs
        , let desc = bpDescription pkg
              name = prettyShow (packageName desc)
        , not (null (PD.dataFiles desc))
        , packageName desc `elem` names
        ]
    underscore c = if c == '-' then '_' else c

-- | Every @pkg:exe@ named in any component's @build-tool-depends:@ across
-- the given packages.
wantedBuildTools :: [BuiltPackage] -> [(PackageName, UnqualComponentName)]
wantedBuildTools pkgs =
  ordNub
    [ (pn, exeName)
    | pkg <- pkgs
    , comp <- PD.pkgBuildableComponents (bpDescription pkg)
    , ExeDependency pn exeName _ <- PD.buildToolDepends (componentBuildInfo comp)
    ]

-- | The project's @test-options:@ for each test-suite that has any - only
-- the elaborated package knows them (they aren't part of the @.cabal@ file
-- or the 'LocalBuildInfo').
projectTestOptions :: DependencyMode -> ElaboratedInstallPlan -> Map (PackageName, ComponentName) [PathTemplate]
projectTestOptions mode plan =
  Map.fromList
    [ ((packageName elab, cname), elabTestTestOptions elab)
    | elab <- builtLocalElabs mode plan
    , not (null (elabTestTestOptions elab))
    , cname@CTestName{} <- componentNamesFor elab (elabPkgDescription elab)
    ]
