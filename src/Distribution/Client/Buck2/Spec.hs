-- | The build spec: a description of a package's components from
-- which buck2\/cabal.bzl creates the buck2 rules.
-- "Distribution.Client.Buck2.Write" writes the spec into the
-- @BUCK.cabal.bzl@ file.
module Distribution.Client.Buck2.Spec
  ( BuildSpec (..)
  , ComponentKind (..)
  , kindName
  , SpecComponent (..)
  , Src (..)
  , SpecDep (..)
  , SpecReexport (..)
  , SpecBuildTool (..)
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

-- | A package's build spec: everything the generated rules are built from
-- that comes from Cabal rather than from buck2 conventions.
data BuildSpec = BuildSpec
  { specPackageName :: String
  , specPackageVersion :: String
  , specGhcOptions :: [String]
  -- ^ Supplied by the project, not the @.cabal@ file.
  , specDataDir :: FilePath
  -- ^ The package's @data-dir@, relative to its directory.
  , specDataFiles :: [FilePath]
  -- ^ Its @data-files@, as patterns, relative to 'specDataDir'.
  , specExtraSourceFiles :: [FilePath]
  -- ^ Its @extra-source-files@, as patterns, relative to its directory:
  -- what its build needs, other than its sources, which something
  -- elsewhere in the project may need too (a generator, say).
  , specComponents :: [SpecComponent]
  , specPackageSet :: Maybe String
  -- ^ The later stage that the package is of, if any (see
  -- "Distribution.Client.Buck2.LaterStage"): its dependencies are the
  -- packages of the same stage.
  }

data ComponentKind = Library | Executable | TestSuite | Benchmark
  deriving (Eq)

-- | As it appears in the spec and in messages: @library@, @executable@,
-- @test-suite@ or @benchmark@.
kindName :: ComponentKind -> String
kindName Library = "library"
kindName Executable = "executable"
kindName TestSuite = "test-suite"
kindName Benchmark = "benchmark"

-- | One component of a build spec. List fields are empty when the
-- corresponding @.cabal@ field is.
data SpecComponent = SpecComponent
  { scKind :: ComponentKind
  , scName :: String
  , scExeName :: Maybe String
  -- ^ The name of an executable, when it isn't the name of its target.
  -- ^ Also the name of the buck2 target.
  , scMainIs :: Maybe Src
  -- ^ The main module's source; not for a library.
  , scSrcs :: [(String, Src)]
  -- ^ Every other module (by module name) and its source.
  , scBootSrcs :: [(String, FilePath)]
  -- ^ The @.hs-boot@ file of each module that has one, next to its source.
  , scProvidedSources :: [(FilePath, String)]
  -- ^ The C\/C++\/Cmm\/assembler sources that don't exist, which the project
  -- provides (see 'SrcProvided'), each with the spec key of its kind
  -- (@c_sources@, say). They are not in the lists of their kind.
  , scTestArgs :: [String]
  -- ^ The project's @test-options@ for a test-suite, with template variables
  -- expanded.
  , scGhcOptions :: [String]
  , scCppOptions :: [String]
  , scLanguage :: Maybe String
  , scExtensions :: [String]
  , scExtraLibraries :: [String]
  , scLdOptions :: [String]
  -- ^ The @ld-options@, as configured: so including the other linker flags of
  -- the @pkgconfig-depends@, such as an rpath.
  , scExtraLibDirs :: [FilePath]
  -- ^ Where to look for the 'scExtraLibraries': the component's
  -- @extra-lib-dirs@, as configured, so including the directories of its
  -- @pkgconfig-depends@ (Cabal adds those at configure time).
  , scDeps :: [SpecDep]
  , scReexports :: [SpecReexport]
  -- ^ Modules a library re-exports from the library of another package (or
  -- another library of its own).
  , scBuildTools :: [SpecBuildTool]
  , scCSources :: [FilePath]
  , scCcOptions :: [String]
  , scCxxSources :: [FilePath]
  , scCxxOptions :: [String]
  , scCmmSources :: [FilePath]
  , scAsmSources :: [FilePath]
  , scAsmOptions :: [String]
  , scIncludeDirs :: [FilePath]
  , scIncludes :: [FilePath]
  -- ^ The headers that what is compiled against the library includes
  -- (Cabal's @includes@).
  , scHscOptions :: [String]
  -- ^ Defines for the C compiler of @hsc2hs@, which say what the code is
  -- compiled for (GHC does this itself for Haskell code).
  , scGeneratedIncludeDirs :: [FilePath]
  -- ^ Directories, relative to the project root, with headers that the
  -- package's @configure@ script generated (the build directory's version of
  -- each relative 'scIncludeDirs').
  , scPkgconfig :: [String]
  }

-- | A source file of a component: either a real file in the package
-- (relative to its directory), or one generated into the package's
-- @cabal-buck2\/autogen@ directory, named by its @export_file()@ entry there
-- (see 'Distribution.Client.Buck2.Generate.AutogenFile'), or a module that
-- the package's @Setup.hs@ would have generated, which the project must
-- provide (@--enable-custom-setup@).
data Src = SrcFile FilePath | SrcAutogen String | SrcProvided

-- | A library a component depends on.
data SpecDep = SpecDep
  { depPackage :: String
  , depLibrary :: Maybe String
  -- ^ The sub-library, if the main library isn't the one depended on.
  }
  -- A dependency doesn't say whether the package is built by this project or
  -- is a prebuilt one: that is whether it has an entry in @packages.bzl@ (see
  -- "Distribution.Client.Buck2.Packages").

-- | A module that a library re-exports (@reexported-modules@) from a library
-- it depends on.
data SpecReexport = SpecReexport
  { reModule :: String
  , reOriginal :: String
  , reFrom :: Maybe SpecDep
  -- ^ The library of another package or of its own that has the module, or
  -- none if it is one of the library's own.
  }

-- | An executable that a component's @build-tool-depends@ needs on @PATH@.
data SpecBuildTool
  = -- | Built by this project, as the given target of the given package.
    LocalTool {toolExe :: String, toolPackage :: String}
  | -- | An already-installed binary, exported from @third-party\/haskell@.
    ExternalTool {toolExe :: String}
