-- | Register all the external packages and tools that the project
-- depends on for buck2 under @third-party/haskell@.
--
-- Here's what we generate:
--
--  * @third-party/haskell/ghc-bin@: symlink to the GHC bin dir
--
--  * @third-party/haskell/ghc-<version>@: a symlink to the GHC lib dir
--
--  * @third-party/haskell/cabal-store@: symlink to the Cabal store
--
--  * @third-party/haskell/build-tools@: contains symlinks to all the build
--    tools this project depends on
--
--  * @third-party/haskell/BUCK@: all the @haskell_prebuilt_library()@ rules
--    for every external package that this project depends on. These
--    are either GHC built-in packages in @ghc-<version>@ or Cabal store
--    packages in @cabal-store@.
--
--  * @third-party/haskell/tools.bzl@: paths and constants for tools we
--    depend on.
module Distribution.Client.Buck2.Prebuilt
  ( generatePrebuilt
  , RepoPaths (..)
  , externalDirs
  , prebuiltLinkerFlags
  , toRepoRelative
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.List (stripPrefix)
import qualified Data.Map as Map
import qualified Data.Set as Set

import System.Directory
  ( createDirectoryIfMissing
  , createFileLink
  , doesFileExist
  , doesPathExist
  , removeDirectoryRecursive
  , removeFile
  )
import System.FilePath
  ( isAbsolute
  , isPathSeparator
  , joinPath
  , makeRelative
  , normalise
  , pathSeparator
  , splitDirectories
  , splitPath
  , takeDirectory
  , takeFileName
  , (<.>)
  , (</>)
  )

import qualified Distribution.Client.InstallPlan as InstallPlan

import Distribution.Client.DistDirLayout
  ( CabalDirLayout (cabalStoreDirLayout)
  , StoreDirLayout (storeDirectory, storePackageDBPath)
  )
import Distribution.Client.ProjectPlanning
  ( ElaboratedConfiguredPackage (elabInstallDirs)
  , ElaboratedInstallPlan
  , ElaboratedSharedConfig (pkgConfigCompiler, pkgConfigCompilerProgs, pkgConfigPlatform)
  )
import Distribution.Client.ProjectPlanning.Types (elabComponentName)
import Distribution.Types.ComponentName (ComponentName (CExeName))

import Distribution.InstalledPackageInfo (parseInstalledPackageInfo)
import Distribution.Package (HasUnitId (installedUnitId), packageName, packageVersion)
import Distribution.Simple.BuildPaths (dllExtension, exeExtension)
import Distribution.Simple.Compiler
  ( Compiler (compilerProperties)
  , compilerVersion
  )
import Distribution.Simple.GHC (getGlobalPackageDB)
import qualified Distribution.Simple.InstallDirs as InstallDirs
import Distribution.Simple.Program.Builtin (ghcProgram)
import Distribution.Simple.Program.Db (lookupProgram)
import Distribution.Simple.Program.Types (programPath)
import Distribution.Simple.Utils (die', notice, ordNub, warn)
import Distribution.System (OS (..), Platform (..))
import Distribution.Utils.MD5 (md5, showMD5)
import Distribution.Types.InstalledPackageInfo
  ( InstalledPackageInfo
      ( depends
      , extraLibraries
      , hsLibraries
      , includeDirs
      , libraryDirs
      , libraryDynDirs
      , sourceLibName
      )
  )
import Distribution.Types.LibraryName (LibraryName (LMainLibName, LSubLibName))
import Distribution.Types.PackageName (PackageName, unPackageName)
import Distribution.Types.UnitId (UnitId, unUnitId)
import Distribution.Types.UnqualComponentName (UnqualComponentName, unUnqualComponentName)

import Distribution.Client.Buck2.Fingerprint (ccFingerprint, ghcFingerprint)
import Distribution.Client.Buck2.LocalPackages (ToolTarget (..), planElab)
import Distribution.Client.Buck2.Version (cabalBuck2Version)
import Distribution.Client.Buck2.Starlark

-- | Generate\/refresh @third-party\/haskell@ from the dependency closure
-- of an already-built, already-pruned install plan. Returns:
--
--   * The name of every @wantedBuildTools@ pair this project's own
--     dependency closure resolved a real binary for - each one also
--     gets a real @export_file()@ target in the generated
--     @third-party\/haskell\/BUCK@ (@\/\/third-party\/haskell:\<name\>-exe@),
--     for "Distribution.Client.Buck2.Generate" to reference from a
--     component's own @build_tool_depends@ (see that module's own
--     @buildToolDependsArg@) - a real buck2 dependency edge, not a
--     host-filesystem symlink farm resolved once at generation time (the
--     wanted pair's own *local*-package half, if any, is a completely
--     separate case handled entirely by "Distribution.Client.Buck2.Generate" itself, referencing
--     that package's own real, already-generated @haskell_binary()@
--     target directly - this function only ever sees, and only needs to
--     handle, already-installed *external* dependencies).
--   * The real, already-parsed 'InstalledPackageInfo' for every resolved
--     dependency - callers that need a real
--     'Distribution.Simple.PackageIndex.InstalledPackageIndex' (e.g. to
--     build a genuine 'LocalBuildInfo' via "Distribution.Client.InLibrary",
--     the way "Distribution.Client.Buck2.Configure" does) can build one directly
--     from this via 'PackageIndex.fromList' without a second, independent
--     walk of the same @.conf@ files.
generatePrebuilt
  :: Verbosity
  -> FilePath
  -- ^ project root (the buck2 cell root)
  -> CabalDirLayout
  -> ElaboratedSharedConfig
  -> ElaboratedInstallPlan
  -- ^ 'elaboratedPlanToExecute': already pruned to exactly the (test\/
  -- benchmark-flag-aware) dependency closure that was just built. Never
  -- contains a package buck2 builds from source itself (a local package,
  -- or a non-local one built @inplace@ because it depends on one - see
  -- 'Distribution.Client.Buck2.LocalPackages.isBuiltLocally'): those get a real @haskell_library()@ from
  -- "Distribution.Client.Buck2.Generate" instead, and are excluded from
  -- this plan before it's even built. So every unit id here is either a
  -- GHC global\/boot package or one installed to the cabal store.
  -> Set UnitId
  -- ^ The packages that buck2 needs (see 'prebuiltUnits'), from those in the plan.
  -> Map String ToolTarget
  -- ^ The preprocessors (@alex@, @happy@) that buck2 builds itself.
  -> Map String String
  -- ^ The tools that buck2 builds itself (see 'localBuildTools').
  -> [(PackageName, UnqualComponentName)]
  -- ^ Every @pkg:exe@ named in any local component's own
  -- @build-tool-depends:@, across the whole project - see this
  -- function's own return-value haddock above.
  -> IO (Set String, [InstalledPackageInfo])
generatePrebuilt verbosity projectRoot cabalDirLayout shared depsPlan neededUnits toolTargets localTools wantedBuildTools = do
  ghcProg <-
    maybe (die' verbosity "cabal buck2: no 'ghc' program configured for this project - internal error.") return $
      lookupProgram ghcProgram (pkgConfigCompilerProgs shared)
  let compiler = pkgConfigCompiler shared
      ghcVersionStr = prettyShow (compilerVersion compiler)
      ghcDynamic = Map.lookup "GHC Dynamic" (compilerProperties compiler) == Just "YES"
      storeLayout = cabalStoreDirLayout cabalDirLayout
      storeDB = storePackageDBPath storeLayout compiler
      storeRootAbs = storeDirectory storeLayout compiler
      targetDir = projectRoot </> "third-party" </> "haskell"
      ghcBinAbs = takeDirectory (programPath ghcProg)

  globalDB <- getGlobalPackageDB verbosity ghcProg
  let globalRootAbs = takeDirectory globalDB

      allUnitIds = ordNub [installedUnitId pkg | pkg <- InstallPlan.toList depsPlan, installedUnitId pkg `Set.member` neededUnits]
      paths =
        RepoPaths
          { rpGhcVersion = ghcVersionStr
          , rpGlobalRootAbs = globalRootAbs
          , rpStoreRootAbs = storeRootAbs
          , rpStoreDbRel = makeRelative storeRootAbs storeDB
          , rpDllExtension = dllExtension (pkgConfigPlatform shared)
          , rpPicByDefault = case pkgConfigPlatform shared of
              Platform _ OSX -> True
              _ -> False
          , rpExternal = []
          }

  createDirectoryIfMissing True targetDir
  ensureSymlink (targetDir </> ("ghc-" ++ ghcVersionStr)) globalRootAbs
  ensureSymlink (targetDir </> "ghc-bin") ghcBinAbs

  notice verbosity "cabal buck2: resolving prebuilt dependency closure"
  packages <- catMaybes <$> traverse (readPackage verbosity paths storeDB) allUnitIds
  let alexPath = findToolBinary paths shared depsPlan "alex"
      happyPath = findToolBinary paths shared depsPlan "happy"
      -- Every @build-tool-depends: pkg:exe@ pair the *external*
      -- (already-installed) dependency closure can resolve a real
      -- binary for - a local-package pair is never in `depsPlan` at all
      -- (see this function's own haddock on that parameter), so this
      -- silently, correctly resolves to nothing for one; entirely
      -- 'Distribution.Client.Buck2.Generate's own job to notice that case and reference the
      -- local package's real target directly instead.
      buildToolPaths =
        Map.fromList
          [ (unUnqualComponentName exeName, path)
          | (pn, exeName) <- ordNub wantedBuildTools
          , Just path <- [findExeBinaryAbs shared depsPlan pn exeName]
          ]

  -- Needed by any package's own library files, *and* independently by
  -- alex/happy's/any build-tool-depends executable's own binary path -
  -- a build-tool-only dependency (an executable, no library)
  -- contributes no ResolvedPackage at all (see readPackage), so
  -- checking `packages` alone would miss a project that needs alex/
  -- happy/a preprocessor tool but nothing else store-installed.
  when
    ( any ((== StoreDb) . rpDbKind) packages
        || any inStore (alexPath : happyPath : map (toRepoRelative paths) (Map.elems buildToolPaths))
    )
    $ ensureSymlink (targetDir </> "cabal-store") storeRootAbs

  -- An earlier version generated a filtered copy of the store's package db here.
  removeStaleStoreDB (targetDir </> "store-db")

  -- Where GHC's package db isn't next to its libraries (a Nix @ghcWithPackages@,
  -- say, in which every package is in a store path of its own), they are
  -- reached through a symlink for each directory.
  let external = externalDirs paths (map (takeDirectory . snd) (concatMap libraryFiles packages))
      paths' = paths{rpExternal = external}
  removeStaleExternal (targetDir </> externalDirName)
  unless (null external) $ do
    notice verbosity $ "cabal buck2: linking " ++ show (length external) ++ " library director" ++ (if length external == 1 then "y" else "ies") ++ " outside GHC's libdir and the cabal store"
    createDirectoryIfMissing True (targetDir </> externalDirName)
    for_ external $ \(dir, link) -> ensureSymlink (targetDir </> link) dir
  for_ packages $ \p ->
    when (not (null (hsLibraries (rpInfo p))) && null (libraryFiles p)) $
      warn verbosity $
        "cabal buck2: found no library files for "
          ++ unUnitId (rpUnitId p)
          ++ " (hs-libraries: "
          ++ unwords (hsLibraries (rpInfo p))
          ++ ", in "
          ++ unwords (libraryDirs (rpInfo p) ++ libraryDynDirs (rpInfo p))
          ++ "): linking against it will fail"

  notice verbosity "cabal buck2: generating third-party/haskell/BUCK"
  writeBuckFile targetDir paths' packages buildToolPaths localTools

  fingerprint <- ghcFingerprint compiler globalDB
  ccPrint <- ccFingerprint compiler
  writeToolsFile targetDir ghcVersionStr fingerprint ccPrint ghcDynamic toolTargets alexPath happyPath

  return (Map.keysSet buildToolPaths, map rpInfo packages)

-- | The repo-relative anchors every generated path is expressed against:
-- the symlinks 'generatePrebuilt' just created, plus the GHC version
-- string (needed for both the global db's own relative path and
-- shared-library sonames).
data RepoPaths = RepoPaths
  { rpGhcVersion :: String
  , rpGlobalRootAbs :: FilePath
  , rpStoreRootAbs :: FilePath
  , rpStoreDbRel :: FilePath
  -- ^ The store's package db, relative to 'rpStoreRootAbs'.
  , rpDllExtension :: String
  -- ^ The extension of a shared library, without the dot: @so@, or @dylib@ on macos.
  , rpPicByDefault :: Bool
  -- ^ Whether GHC's code is always position-independent (as on macOS).
  , rpExternal :: [(FilePath, FilePath)]
  -- ^ Directories that are neither under GHC's libdir nor the cabal store,
  -- and the symlinks (relative to @third-party\/haskell@) to them, which
  -- they are reached through. See 'externalDirs'.
  }

-- | Which of the two package dbs a unit id's @.conf@ lives in - found
-- by looking in the store's db first, then GHC's global one (see
-- 'readPackage'). The unit id's shape can't be relied on to tell them
-- apart: on macOS and Windows cabal shortens store unit ids (e.g.
-- LstLk-4.7.8.4-0e779db1). (An @-inplace@ id - a package buck2 builds
-- itself - never gets here: see 'generatePrebuilt's plan parameter.)
data PkgDbKind = GlobalDb | StoreDb
  deriving (Eq)

-- | A resolved package: its metadata plus which package db it came from
-- (needed to pick the right @db =@ value in the generated rule, and to
-- know where to find its @.conf@ file).
data ResolvedPackage = ResolvedPackage
  { rpInfo :: InstalledPackageInfo
  , rpUnitId :: UnitId
  , rpDbKind :: PkgDbKind
  , rpStaticLibs :: [FilePath]
  -- ^ Absolute paths, like 'rpProfiledLibs' and 'rpSharedLibs'.
  , rpProfiledLibs :: [FilePath]
  , rpSharedLibs :: [(String, FilePath)]
  }

-- | Every library file found for the package, and what to call it.
libraryFiles :: ResolvedPackage -> [(String, FilePath)]
libraryFiles p =
  [("static", f) | f <- rpStaticLibs p]
    ++ [("profiled", f) | f <- rpProfiledLibs p]
    ++ [("shared", f) | (_, f) <- rpSharedLibs p]

confPath :: FilePath -> FilePath -> PkgDbKind -> UnitId -> FilePath
confPath globalRootAbs storeDB kind uid = case kind of
  GlobalDb -> globalRootAbs </> "package.conf.d" </> unUnitId uid <.> "conf"
  StoreDb -> storeDB </> unUnitId uid <.> "conf"

readPackage :: Verbosity -> RepoPaths -> FilePath -> UnitId -> IO (Maybe ResolvedPackage)
readPackage verbosity paths storeDB uid = do
  let storePath = confPath (rpGlobalRootAbs paths) storeDB StoreDb uid
      globalPath = confPath (rpGlobalRootAbs paths) storeDB GlobalDb uid
  storeHas <- doesFileExist storePath
  globalHas <- doesFileExist globalPath
  case (storeHas, globalHas) of
    (True, _) -> parseFrom StoreDb storePath
    (_, True) -> parseFrom GlobalDb globalPath
    _ -> do
      warn verbosity $
        "cabal buck2: no .conf file for "
          ++ unUnitId uid
          ++ " (looked in "
          ++ storePath
          ++ " and "
          ++ globalPath
          ++ "); packages are only found in GHC's global package db and the cabal store, not in other package dbs"
      return Nothing
  where
    parseFrom dbKind path = do
      contents <- BS.readFile path
      case parseInstalledPackageInfo contents of
        Left errs -> do
          warn verbosity $ "cabal buck2: couldn't parse " ++ path ++ ": " ++ intercalate "; " (toList errs)
          return Nothing
        Right (_warnings, ipi0) -> do
          -- '${pkgroot}' is the directory *containing* the package db (one
          -- level above the .conf file's own db directory, e.g.
          -- ".../lib" for a ".../lib/package.conf.d/<uid>.conf" file) -
          -- not the db directory itself.
          let ipi = mungePkgroot (takeDirectory (takeDirectory path)) ipi0
              isRts = prettyShow (packageName ipi) == "rts"
          staticLibs <- findLibs paths (libraryDirs ipi) ["lib" ++ stem <.> "a" | stem <- hsLibraries ipi]
          -- GHC doesn't build profiled RTS libraries the normal way - see
          -- gen-haskell-prebuilt.py's own note on this, which this
          -- inherits without fully understanding why either.
          profiledLibs <-
            if isRts
              then return []
              else findLibs paths (libraryDirs ipi) ["lib" ++ stem ++ "_p" <.> "a" | stem <- hsLibraries ipi]
          -- A Haskell shared library mustn't be linked against the
          -- RTS: which RTS (threaded or not) is only decided when the
          -- final executable is, and on macOS, where each symbol is
          -- bound to the library it was linked against, one loaded
          -- into a process already running another RTS (GHC itself,
          -- running a Template Haskell splice) uses its own,
          -- uninitialized, RTS. Cabal doesn't link against it either.
          sharedLibs <-
            if isRts
              then return []
              else findSharedLibs paths ipi
          return $ Just (ResolvedPackage ipi uid dbKind staticLibs profiledLibs sharedLibs)

-- | Resolve each candidate filename against @dirs@ in turn, keeping only
-- the ones that actually exist on disk (unlike gen-haskell-prebuilt.py's
-- Python predecessor, this doesn't assume every @hs-libraries@ stem has a
-- library of every flavour - e.g. rts's second stem, \"Cffi\", only ever
-- ships as a static archive, never as a @.so@).
findLibs :: RepoPaths -> [FilePath] -> [String] -> IO [FilePath]
findLibs paths dirs fnames = catMaybes <$> traverse (findOne paths dirs) fnames

-- | The absolute path of the file; it is made relative to @third-party\/haskell@
-- by 'toRepoRelative' when it is written, as the directories it is in
-- may need a symlink first (see 'externalDirs').
findOne :: RepoPaths -> [FilePath] -> String -> IO (Maybe FilePath)
findOne _paths dirs fname = go dirs
  where
    go [] = return Nothing
    go (d : ds) = do
      let absPath = d </> fname
      exists <- doesFileExist absPath
      if exists
        then return (Just absPath)
        else go ds

findSharedLibs :: RepoPaths -> InstalledPackageInfo -> IO [(String, FilePath)]
findSharedLibs paths ipi = catMaybes <$> traverse oneStem (hsLibraries ipi)
  where
    dirs = libraryDynDirs ipi ++ libraryDirs ipi
    oneStem stem = do
      let soname = "lib" ++ stem ++ "-ghc" ++ rpGhcVersion paths <.> rpDllExtension paths
      mpath <- findOne paths dirs soname
      return ((,) soname <$> mpath)

-- | @.conf@ files use @${pkgroot}@ (the directory containing the package
-- db) as a portable stand-in for their own absolute location - GHC's own
-- @ghc-pkg@ expands this when it serves package info, but reading the
-- file directly (as 'parseInstalledPackageInfo' does here) doesn't, so
-- library-dirs\/include-dirs come back as literal, unusable
-- @"${pkgroot}/..."@ strings unless expanded by hand. Mirrors
-- 'Distribution.Simple.Program.HcPkg.mungePackagePaths', which isn't
-- exported.
mungePkgroot :: FilePath -> InstalledPackageInfo -> InstalledPackageInfo
mungePkgroot pkgroot ipi =
  ipi
    { libraryDirs = map munge (libraryDirs ipi)
    , libraryDynDirs = map munge (libraryDynDirs ipi)
    , includeDirs = map munge (includeDirs ipi)
    }
  where
    munge p = maybe p collapseDotDot (stripPkgroot p)
    stripPkgroot p = case splitPath p of
      (root : rest) -> case stripPrefix "${pkgroot}" root of
        Just [sep] | isPathSeparator sep -> Just (pkgroot </> joinPath rest)
        _ -> Nothing
      _ -> Nothing

-- | @${pkgroot}@ substitution routinely produces a @.../package.conf.d/
-- ../lib/...@ path (since @${pkgroot}@ is the db directory, and the real
-- libraries live next to it, not under it) - harmless as a real filesystem
-- path, but buck2 rejects any @attrs.source()@ containing a literal
-- @".."@ component ("expected a normalized path"), so it has to be
-- collapsed before it ever reaches a generated rule. Unlike
-- 'System.FilePath.normalise' (which only tidies separators\/dots, not
-- @".."@ segments - not safe in general with symlinks in play, but safe
-- here since every path this is applied to is already fully resolved:
-- real, non-symlink directories under GHC's own libdir or the cabal
-- store).
collapseDotDot :: FilePath -> FilePath
collapseDotDot = joinPath . reverse . foldl' step [] . splitDirectories
  where
    step (top : rest) ".." | top /= ".." && top /= [pathSeparator] = rest
    step stack "." = stack
    step stack seg = seg : stack

-- | Point @link@ at @target@, creating or repointing it as needed.
ensureSymlink :: FilePath -> FilePath -> IO ()
ensureSymlink link target = do
  exists <- doesPathExist link
  when exists $ removeFile link
  createFileLink target link

-- | Remove the filtered package db that earlier versions generated.
removeStaleStoreDB :: FilePath -> IO ()
removeStaleStoreDB dir = do
  exists <- doesPathExist dir
  when exists $ removeDirectoryRecursive dir

writeBuckFile :: FilePath -> RepoPaths -> [ResolvedPackage] -> Map String FilePath -> Map String String -> IO ()
writeBuckFile targetDir paths packages buildToolPaths localTools =
  writeFile (targetDir </> "BUCK") (renderFile header [] calls)
  where
    header = "@generated by `cabal buck2` - do not edit by hand.\nRe-run `cabal buck2` to update."
    uidToTarget = Map.fromList [(rpUnitId p, targetName p) | p <- packages]
    calls =
      [prebuiltCall paths uidToTarget p | p <- packages]
        ++ [buildToolExportCall name relPath | (name, relPath) <- Map.toList (Map.mapMaybe (toRepoRelative paths) buildToolPaths)]
        ++ [ call "alias" [("name", str (name ++ "-exe")), ("actual", str label), ("visibility", strList ["PUBLIC"])]
           | (name, label) <- Map.toList localTools
           ]

-- | One @export_file()@ per resolved @build-tool-depends@ executable -
-- gives it a real buck2 target ('DefaultInfo' with a single default
-- output, basename forced to the tool's own bare name, executable bit
-- forced on regardless of whatever @copy_file@'s own default happens to
-- preserve) that any component's own @build_tool_depends@ can reference
-- directly, the same @export_file()@ primitive this project already
-- uses for autogen files - see "Distribution.Client.Buck2.Generate"'s
-- own @buildToolDependsArg@ for the consuming side, and
-- @buck2\/prelude\/decls\/haskell_common.bzl@'s own comment on the attr
-- for why this needs to be a real target at all (not a host-filesystem
-- symlink, superseded by this).
buildToolExportCall :: String -> FilePath -> Call
buildToolExportCall name relPath =
  call
    "export_file"
    [ ("name", str (name ++ "-exe"))
    , ("src", str relPath)
    , ("out", str name)
    , ("mode", str "copy")
    , ("executable_bit_override", VBool True)
    , ("visibility", strList ["PUBLIC"])
    ]

-- | The target of a prebuilt library: the package name for its main library,
-- and for a named one the package name too, as the name of a library is
-- only unique within its package (see 'sourceLibName', which is parsed
-- from the @.conf@ file).
targetName :: ResolvedPackage -> String
targetName p = case sourceLibName (rpInfo p) of
  LMainLibName -> unPackageName (packageName (rpInfo p))
  -- Named libraries of different packages share their names (@testlib@ is
  -- common), and all of these targets are in one place. A package name can't
  -- contain two hyphens in a row.
  LSubLibName n -> unPackageName (packageName (rpInfo p)) ++ "--" ++ unUnqualComponentName n

prebuiltCall :: RepoPaths -> Map UnitId String -> ResolvedPackage -> Call
prebuiltCall paths uidToTarget p =
  call
    "haskell_prebuilt_library"
    ( [ ("name", str (targetName p))
      , ("version", str (prettyShow (packageVersion (rpInfo p))))
      , ("id", str (unUnitId (rpUnitId p)))
      , ("db", str (if rpDbKind p == GlobalDb then globalDbRel else "cabal-store" </> rpStoreDbRel paths))
      , ("static_libs", strList (rel (rpStaticLibs p)))
      ]
        ++ [("pic_static_libs", strList (rel (rpStaticLibs p))) | rpPicByDefault paths]
        ++ [("profiled_static_libs", strList profiled) | not (null profiled)]
        ++ [("pic_profiled_static_libs", strList profiled) | not (null profiled)]
        ++ [("shared_libs", VDict [(soname, str sopath) | (soname, abs') <- rpSharedLibs p, Just sopath <- [toRepoRelative paths abs']])]
        ++ [("cxx_header_dirs", strList headerDirs) | not (null headerDirs)]
        ++ [("exported_linker_flags", strList extraLinkerFlags) | not (null extraLinkerFlags)]
        ++ [("deps", strList depTargets) | not (null depTargets)]
        ++ [("visibility", strList ["PUBLIC"])]
    )
  where
    info = rpInfo p
    rel = mapMaybe (toRepoRelative paths)
    profiled = rel (rpProfiledLibs p)
    globalDbRel = ("ghc-" ++ rpGhcVersion paths) </> "package.conf.d"
    headerDirs = mapMaybe (toRepoRelative paths) (includeDirs info)
    extraLinkerFlags = prebuiltLinkerFlags info
    depTargets = ordNub [":" ++ t | d <- depends info, Just t <- [Map.lookup d uidToTarget]]

-- | The linker flags a package's @.conf@ file asks for: its @extra-libraries@,
-- and where to find them. The @library-dirs@ of a package that needs a
-- system library are also where that library is, when it isn't on the
-- linker's default path: Cabal records the directory it was found in at
-- configure time (@extra-lib-dirs@, or a Nix store path), and GHC passes
-- them all as @-L@ when it links against the package. Without them the
-- @-l@ flag alone can't be satisfied.
prebuiltLinkerFlags :: InstalledPackageInfo -> [String]
prebuiltLinkerFlags info =
  ["-L" ++ dir | not (null libs), dir <- ordNub (libraryDirs info)]
    ++ ["-l" ++ lib | lib <- libs]
  where
    libs = extraLibraries info

-- | Convert an absolute path under GHC's libdir, the cabal store or one of the
-- 'externalDirs' into one relative to @third-party\/haskell@, via whichever
-- symlink 'generatePrebuilt' pointed there actually contains it - the same
-- translation gen-haskell-prebuilt.py's own @abs_to_rel@ did.
toRepoRelative :: RepoPaths -> FilePath -> Maybe FilePath
toRepoRelative paths path
  | not (isAbsolute path) = Nothing
  | otherwise =
      relTo (rpGlobalRootAbs paths) ("ghc-" ++ rpGhcVersion paths) path
        <|> relTo (rpStoreRootAbs paths) "cabal-store" path
        <|> listToMaybe (mapMaybe (\(dir, link) -> relTo dir link path) (rpExternal paths))

-- | The directory of the symlinks to the 'externalDirs'.
externalDirName :: FilePath
externalDirName = "external"

-- | The directories with the library files of packages that are
-- neither under GHC's libdir nor in the cabal store, which buck2 can only get at
-- through a symlink in the project, with the name (relative to
-- @third-party\/haskell@) of the symlink to each. The headers of a package are
-- found through those too, when they are in them (as they are for a Nix
-- package); a directory of headers on its own, like @\/usr\/include@, gets
-- no symlink: it would be the system's headers in the project.
--
-- GHC's package db isn't always next to the libraries of its packages. In a
-- Nix @ghcWithPackages@, say, the library files of each package are in a store
-- path of their own (@\/nix\/store\/<hash>-aeson-...\/lib\/...@). A path in a
-- rule has to be relative and inside the project, so it can't be given as
-- it is.
--
-- A symlinked directory is part of the project as far as buck2's file watcher
-- is concerned, so no more is linked than needed. That is each directory with
-- library files, except one that is inside another such directory (the
-- directory of the static libraries of a package, which is in the
-- directory with its shared libraries, say). The symlink is named after the
-- directory and a hash of its path, which makes the name the same every time.
externalDirs :: RepoPaths -> [FilePath] -> [(FilePath, FilePath)]
externalDirs paths dirs = [(dir, externalDirName </> linkName dir) | dir <- sort maximal]
  where
    outside = ordNub [d | d <- map normalise dirs, isAbsolute d, isNothing (relTo (rpGlobalRootAbs paths) "" d <|> relTo (rpStoreRootAbs paths) "" d)]
    maximal = [d | d <- outside, not (any (`isProperAncestor` d) outside)]
    isProperAncestor a d = a /= d && makeRelative a d /= d
    linkName dir = takeFileName dir ++ "-" ++ take 12 (showMD5 (md5 (BS8.pack dir)))

-- | Remove the symlinks that an earlier run made.
removeStaleExternal :: FilePath -> IO ()
removeStaleExternal dir = do
  exists <- doesPathExist dir
  when exists $ removeDirectoryRecursive dir

relTo :: FilePath -> FilePath -> FilePath -> Maybe FilePath
relTo root repoRelPrefix path =
  let r = makeRelative root path
   in if r /= path then Just (repoRelPrefix </> r) else Nothing

-- | The store-installed binary path (repo-relative, like everything else
-- 'toRepoRelative' produces) for a build-tool dependency package - e.g.
-- @alex@\/@happy@, needed by buck2/alex_happy.bzl to preprocess @.x@\/@.y@
-- sources - or 'Nothing' if the project doesn't need it at all. A
-- simplified 'CmdListBin.elaboratedPackage'\/@bin_file'@: alex\/happy are
-- always external Hackage dependencies, never a local package, so the
-- inplace-build-style branch that logic also has to handle never applies
-- here, and (being plain, single-executable packages) their own
-- executable is always named after the package itself, with no need to
-- resolve a target selector to find out which component that is.
findToolBinary :: RepoPaths -> ElaboratedSharedConfig -> ElaboratedInstallPlan -> String -> Maybe FilePath
findToolBinary paths shared plan toolName =
  listToMaybe
    [ rel
    | pkg <- InstallPlan.toList plan
    , Just elab <- [planElab pkg]
    , prettyShow (packageName elab) == toolName
    , let absPath = InstallDirs.bindir (elabInstallDirs elab) </> toolName <.> exeExtension (pkgConfigPlatform shared)
    , Just rel <- [toRepoRelative paths absPath]
    ]

-- | The real, absolute binary path for one @pkg:exe@ pair - 'Nothing' if
-- that package isn't in the resolved dependency closure at all, or has
-- no matching executable
-- component. Unlike 'findToolBinary' (which assumes the executable is
-- named after its own package - true for alex\/happy, both self-named
-- single-executable packages), this matches the package and executable
-- names independently, since a @build-tool-depends: pkg:exe@ entry can
-- legitimately name them differently.
--
-- A package brought in purely as a @build-tool-depends@ needs commonly
-- elaborate to *two* distinct plan nodes for the same package name - a
-- whole-package one (@elabComponentName@ @Nothing@ or some other
-- component) and a real per-executable one (@elabComponentName ==
-- Just (CExeName exeName)@) - and only the latter's own
-- 'elabInstallDirs' has a real, populated @bindir@ (confirmed the hard
-- way: the former's own @bindir@ computes to a real-looking but
-- entirely empty directory, no error, just @createProcess: posix_spawnp:
-- does not exist@ at the point of actually trying to run it). Preferring
-- an exact component-name match - falling back to any match sharing the
-- package name only if none exists, the same as 'findToolBinary' always
-- did - fixes this without needing to know in advance which shape a
-- given package's own plan happens to take.
findExeBinaryAbs :: ElaboratedSharedConfig -> ElaboratedInstallPlan -> PackageName -> UnqualComponentName -> Maybe FilePath
findExeBinaryAbs shared plan pn exeName =
  listToMaybe (exact ++ fallback)
  where
    candidates =
      [ elab
      | pkg <- InstallPlan.toList plan
      , Just elab <- [planElab pkg]
      , packageName elab == pn
      ]
    binPathFor elab = InstallDirs.bindir (elabInstallDirs elab) </> unUnqualComponentName exeName <.> exeExtension (pkgConfigPlatform shared)
    exact = [binPathFor elab | elab <- candidates, elabComponentName elab == Just (CExeName exeName)]
    fallback = [binPathFor elab | elab <- candidates]

inStore :: Maybe FilePath -> Bool
inStore = maybe False ("cabal-store" `isPrefixOf`)

writeToolsFile :: FilePath -> String -> String -> String -> Bool -> Map String ToolTarget -> Maybe FilePath -> Maybe FilePath -> IO ()
writeToolsFile targetDir ghcVersionStr fingerprint ccPrint ghcDynamic toolTargets alexPath happyPath =
  writeFile (targetDir </> "tools.bzl") $
    unlines
      [ "# @generated by `cabal buck2` - do not edit by hand."
      , "# Re-run `cabal buck2` to update."
      , ""
      , -- Checked by buck2/cabal.bzl before it loads anything else from
        -- here, so that tools.bzl written by another release of cabal-buck2
        -- is reported as that, not as a missing symbol.
        "CABAL_BUCK2_VERSION = " ++ show cabalBuck2Version
      , "GHC_VERSION = " ++ show ghcVersionStr
      , "GHC_FINGERPRINT = " ++ show fingerprint
      , "CC_FINGERPRINT = " ++ show ccPrint
      , "GHC_BIN_DIR = \"third-party/haskell/ghc-bin\""
      , "GHC_DYNAMIC = " ++ (if ghcDynamic then "True" else "False")
      , -- The persistent worker of the per-module compiles
        -- (buck2/tools/ghc-worker), when the project builds it: what
        -- `[haskell] per_module_worker = local` uses.
        "GHC_WORKER_TARGET = " ++ starlarkMaybe (toolLabel <$> Map.lookup "ghc-worker" toolTargets)
      , ""
      , "ALEX = " ++ show ("third-party/haskell/" ++ fromMaybe "missing" alexPath)
      , "HAPPY = " ++ show ("third-party/haskell/" ++ fromMaybe "missing" happyPath)
      , ""
      , "# If buck2 builds them, the targets of the tools and of their data files."
      , "ALEX_TARGET = " ++ starlarkMaybe (toolLabel <$> Map.lookup "alex" toolTargets)
      , "ALEX_DATA = " ++ starlarkMaybe (snd <$> (Map.lookup "alex" toolTargets >>= toolData))
      , "ALEX_DATA_ENV = " ++ starlarkMaybe (fst <$> (Map.lookup "alex" toolTargets >>= toolData))
      , "HAPPY_TARGET = " ++ starlarkMaybe (toolLabel <$> Map.lookup "happy" toolTargets)
      , "HAPPY_DATA = " ++ starlarkMaybe (snd <$> (Map.lookup "happy" toolTargets >>= toolData))
      , "HAPPY_DATA_ENV = " ++ starlarkMaybe (fst <$> (Map.lookup "happy" toolTargets >>= toolData))
      ]
  where
    starlarkMaybe = maybe "None" show
