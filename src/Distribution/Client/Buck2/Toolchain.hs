-- | The tools that the buck2 toolchains run: GHC and the tools that come
-- with it, and the C and C++ compilers.
--
-- buck2 runs them from the PATH of its daemon, which is that of the shell
-- the daemon started in, and not the one @cabal buck2@ was last run in: after
-- a change of tools (a different Nix shell, say), it would go on running the
-- old ones. So each is found here, when @cabal buck2@ runs, and reached
-- through a symlink under @third-party\/haskell\/toolchain@ that each run
-- renews. The symlinks, rather than the paths they point at, are what the
-- toolchains run, so that the commands of the build actions, and so the keys
-- of the action cache, don't depend on where the tools are installed: the
-- fingerprints of the toolchains (see "Distribution.Client.Buck2.Fingerprint")
-- are what tells different tools apart. The C tools' symlinks are in a
-- directory named by the C toolchain's fingerprint, which so is part of the
-- command of every action that runs one (see 'linkToolchain'); GHC's
-- fingerprint is given to its actions in their environment instead (see
-- @buck2\/toolchains\/defaults.bzl@).
module Distribution.Client.Buck2.Toolchain
  ( Toolchain (..)
  , findToolchain
  , chooseCompilers
  , cxxCompilerFor
  , linkToolchain
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import Control.Exception (try)
import Control.Monad (mfilter)
import Data.List (isInfixOf, stripPrefix)
import qualified Data.Map as Map

import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , createFileLink
  , doesFileExist
  , findExecutable
  , listDirectory
  , makeAbsolute
  , removePathForcibly
  )
import System.FilePath (hasTrailingPathSeparator, isAbsolute, takeDirectory, takeFileName, (</>))
import System.Process (readProcessWithExitCode)

import Distribution.Simple.Compiler (Compiler (compilerProperties))
import Distribution.Simple.Program.Builtin (ghcPkgProgram, ghcProgram, haddockProgram, hsc2hsProgram)
import Distribution.Simple.Program.Db (ProgramDb, lookupProgram)
import Distribution.Simple.Program.Types (Program (programName), programPath)
import Distribution.Simple.Utils (die')

-- | Each tool, by its role: the absolute path that was found for it, or, if
-- none was, the name to look for on the PATH when the build runs.
data Toolchain = Toolchain
  { tcGhc :: FilePath
  , tcGhcPkg :: FilePath
  , tcHsc2hs :: FilePath
  , tcHaddock :: FilePath
  , tcCc :: FilePath
  , tcCxx :: FilePath
  , tcLinker :: FilePath
  -- ^ The C++ compiler that links C and C++ code (not Haskell, which GHC
  -- links).
  , tcCcType :: String
  -- ^ What kind of compiler 'tcCc' and 'tcCxx' are, as buck2 knows them:
  -- @clang@ or @gcc@.
  }

-- | Find the tools of the project's toolchain.
--
-- GHC is the configured one, by the file its path leads to through any
-- symlinks: ghcup's @~\/.ghcup\/bin\/ghc@, say, is a symlink that @ghcup set@
-- points at another GHC. (Cabal finds GHC's tools the same way.) GHC's own
-- tools are those Cabal found for it (next to it, normally), unless the user
-- gave others (@--with-hsc2hs@, say, or @hsc2hs-location:@ in
-- @program-locations@).
--
-- For the C and C++ compilers, see 'chooseCompilers'.
findToolchain
  :: Verbosity
  -> Map String FilePath
  -- ^ The program locations the user gave (@--with-PROG@, or the
  -- @program-locations@ of the project file), by program name.
  -> ProgramDb
  -- ^ The compiler's configured programs.
  -> Compiler
  -> IO Toolchain
findToolchain verbosity userPaths progdb compiler = do
  ghc <- maybe (die' verbosity "cabal buck2: no 'ghc' program configured for this project - internal error.") canonicalizePath (configured ghcProgram)
  ghcPkg <- haskellTool ghcPkgProgram ("ghc-pkg-" ++ ghcVersion)
  hsc2hs <- haskellTool hsc2hsProgram ("hsc2hs-" ++ ghcVersion)
  haddock <- haskellTool haddockProgram "haddock"
  -- Cabal has a g++ program, but no way for the user to give its location
  -- (no --with-g++, and g++-location isn't a valid field name), so the C++
  -- compiler that goes with the user's C compiler is found by its name.
  userCxx <- case Map.lookup "g++" userPaths <|> (Map.lookup "gcc" userPaths >>= cxxCompilerFor) of
    Nothing -> return Nothing
    Just c -> do
      path <- resolve c
      exists <- if isAbsolute path then doesFileExist path else return False
      return (if exists then Just path else Nothing)
  let (ccChoice, cxxChoice, linkerChoice) = chooseCompilers (Map.lookup "gcc" userPaths) userCxx (prop "C compiler command") (prop "C++ compiler command")
  cc <- resolve ccChoice
  cxx <- resolve cxxChoice
  linker <- resolve linkerChoice
  ccType <- compilerType cc
  return
    Toolchain
      { tcGhc = ghc
      , tcGhcPkg = ghcPkg
      , tcHsc2hs = hsc2hs
      , tcHaddock = haddock
      , tcCc = cc
      , tcCxx = cxx
      , tcLinker = linker
      , tcCcType = ccType
      }
  where
    prop k = Map.lookup k (compilerProperties compiler)
    ghcVersion = fromMaybe "" (prop "Project version")
    configured prog = programPath <$> lookupProgram prog progdb
    -- The user's location for the tool, else Cabal's, else the name it was
    -- looked for by before (on the PATH, when the build runs).
    haskellTool prog fallback = case Map.lookup (programName prog) userPaths of
      Just path -> resolve path
      Nothing -> return (fromMaybe fallback (configured prog))
    -- A name without a directory is looked for on the PATH, as Cabal does.
    -- If it isn't found, it is left to be looked for when the build runs:
    -- a tool that a project never uses (a C++ compiler, say) is no reason
    -- for `cabal buck2` to fail.
    resolve path
      | isAbsolute path = return path
      | any (`elem` "/\\") path || hasTrailingPathSeparator path = makeAbsolute path
      | otherwise = fromMaybe path <$> findExecutable path

-- | Which C compiler, C++ compiler and linker to use, given the user's C
-- compiler and the C++ compiler that goes with it (see 'cxxCompilerFor'), and
-- the C and C++ compilers that GHC is configured with (what @ghc --info@
-- reports). A name without a directory is looked for on the PATH.
--
--  * The user's, if they gave one (@--with-gcc@, or @gcc-location:@ in
--    @program-locations@): the same that Cabal uses for the C of the packages
--    it builds.
--
--  * Otherwise, GHC's, if it is an absolute path, which it is for a GHC
--    built by Nix: a toolchain that goes with the GHC, and which changes with
--    it.
--
--  * Otherwise clang, and clang++, linking with g++. GHC's are then names to
--    look for on the PATH (@gcc@, normally), and these are what the C and C++
--    of a project has always been built with.
--
-- The linker is the C++ compiler when it is the user's or GHC's, and g++
-- otherwise.
chooseCompilers
  :: Maybe FilePath
  -- ^ The user's @gcc@.
  -> Maybe FilePath
  -- ^ The C++ compiler that goes with the user's @gcc@.
  -> Maybe FilePath
  -- ^ GHC's C compiler.
  -> Maybe FilePath
  -- ^ GHC's C++ compiler.
  -> (FilePath, FilePath, FilePath)
chooseCompilers userCc userCxx ghcCc ghcCxx = (cc, cxx, linker)
  where
    cc = fromMaybe "clang" (userCc <|> mfilter isAbsolute ghcCc)
    (cxx, linker) = case userCxx <|> mfilter isAbsolute ghcCxx of
      Just c -> (c, c)
      Nothing -> ("clang++", "g++")

-- | The C++ compiler that goes with a C compiler, by the usual names: @gcc@
-- and @g++@, @clang@ and @clang++@, @cc@ and @c++@ (with any prefix or
-- version: @x86_64-linux-gnu-gcc-13@, @clang-18@), in the same directory.
cxxCompilerFor :: FilePath -> Maybe FilePath
cxxCompilerFor cc = inDir <$> cxxName (takeFileName cc)
  where
    inDir name
      | takeFileName cc == cc = name
      | otherwise = takeDirectory cc </> name
    cxxName name
      | name == "cc" = Just "c++"
      | otherwise = replaceFirst "clang" "clang++" name <|> replaceFirst "gcc" "g++" name
    replaceFirst _ _ [] = Nothing
    replaceFirst old new str@(c : rest)
      | Just after <- stripPrefix old str =
          if "++" `isPrefixOf` after then Nothing else Just (new ++ after)
      | otherwise = (c :) <$> replaceFirst old new rest

-- | Whether a C compiler is clang or gcc, by what it says it is: @gcc@ is
-- clang on macOS, and @cc@ either.
compilerType :: FilePath -> IO String
compilerType cc = do
  r <- try (readProcessWithExitCode cc ["--version"] "")
  return $ case r :: Either SomeException (ExitCode, String, String) of
    Right (_, out, _) | "clang" `isInfixOf` map toLower out -> "clang"
    _ -> "gcc"

-- | Point the symlinks under @dir@ (@third-party\/haskell\/toolchain@) at the
-- tools, and return the paths, relative to the project root, that the
-- toolchains are to run them by, by role. The symlink to each of GHC's tools
-- is @dir\/\<role\>\/\<name\>@, and to each C tool
-- @dir\/\<role\>\/\<fingerprint\>\/\<name\>@, with the C toolchain's
-- fingerprint: buck2 runs the C tools from a toolchain that knows nothing of
-- fingerprints, so it is in their paths, rather than in the environment of
-- the actions as GHC's is. Each has the tool's own file name, which some tools
-- act on (clang is a C++ compiler as clang++ or c++, say). A tool that wasn't
-- found is left to be looked for on the PATH by its name.
linkToolchain :: FilePath -> FilePath -> String -> Toolchain -> IO [(String, FilePath)]
linkToolchain dir dirRel ccPrint tc =
  traverse
    link
    [ ("ghc", [], tcGhc tc)
    , ("ghc-pkg", [], tcGhcPkg tc)
    , ("hsc2hs", [], tcHsc2hs tc)
    , ("haddock", [], tcHaddock tc)
    , ("cc", [ccPrint], tcCc tc)
    , ("cxx", [ccPrint], tcCxx tc)
    , ("linker", [ccPrint], tcLinker tc)
    ]
  where
    link (role, subdirs, path)
      | isAbsolute path = do
          let roleDir = dir </> role
              linkDir = foldl' (</>) roleDir subdirs
              name = takeFileName path
          createDirectoryIfMissing True roleDir
          -- The symlink of an earlier run, and the tool of one if it had
          -- another name (dangling, maybe: 'doesPathExist' would say it
          -- isn't there), or the directory of another fingerprint.
          olds <- listDirectory roleDir
          for_ olds $ \o -> removePathForcibly (roleDir </> o)
          createDirectoryIfMissing True linkDir
          createFileLink path (linkDir </> name)
          return (role, intercalate "/" ([dirRel, role] ++ subdirs ++ [name]))
      | otherwise = return (role, path)
