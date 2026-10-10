-- | The build spec: a description of a package's components from
-- which buck2\/cabal.bzl creates the buck2 rules.
-- "Distribution.Client.Buck2.Write" writes the spec into the
-- @BUCK.cabal.bzl@ file.
module Distribution.Client.Buck2.Spec
  ( specSchemaVersion
  , BuildSpec (..)
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

-- | The version of the build spec format; must match @SCHEMA_VERSION@ in
-- buck2\/cabal.bzl.
specSchemaVersion :: Int
specSchemaVersion = 1

-- | A package's build spec: everything the generated rules are built from
-- that comes from Cabal rather than from buck2 conventions.
data BuildSpec = BuildSpec
  { specPackageName :: String
  , specPackageVersion :: String
  , specPackageDir :: FilePath
  -- ^ Relative to the buck2 cell root, @.@ at the root.
  , specGhcOptions :: [String]
  -- ^ Supplied by the project, not the @.cabal@ file.
  , specDataDir :: FilePath
  -- ^ The package's @data-dir@, relative to its directory.
  , specDataFiles :: [FilePath]
  -- ^ Its @data-files@, as patterns, relative to 'specDataDir'.
  , specComponents :: [SpecComponent]
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
  , scTestArgs :: [String]
  -- ^ The project's @test-options@ for a test-suite, with template variables
  -- expanded.
  , scGhcOptions :: [String]
  , scCppOptions :: [String]
  , scLanguage :: Maybe String
  , scExtensions :: [String]
  , scExtraLibraries :: [String]
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
-- (see 'Distribution.Client.Buck2.Generate.AutogenFile').
data Src = SrcFile FilePath | SrcAutogen String

-- | A library a component depends on.
data SpecDep = SpecDep
  { depPackage :: String
  , depLibrary :: Maybe String
  -- ^ The sub-library, if the main library isn't the one depended on.
  , depDir :: Maybe FilePath
  -- ^ The package's directory (relative to the cell root) if it's built by
  -- this project.
  }

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
  = -- | Built by this project, in the given directory.
    LocalTool {toolExe :: String, toolDir :: FilePath}
  | -- | An already-installed binary, exported from @third-party\/haskell@.
    ExternalTool {toolExe :: String}
