-- | A fingerprint of the GHC installation, for the buck2 action cache.
--
-- The cache key of a compile action covers its command line, environment and
-- inputs, but not the compiler itself: GHC is found on the @PATH@ by its
-- versioned name, and the files of its installation are not tracked. The
-- fingerprint makes it part of the key, so that the cache can be shared (and
-- kept across upgrades) without serving the output of a different GHC.
module Distribution.Client.Buck2.Fingerprint
  ( ghcFingerprint
  , fingerprintOf
  , ccFingerprint
  , ccFingerprintOf
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import Data.Char (isSpace)
import Data.List (isPrefixOf, sort)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (mapMaybe)
import Control.Exception (SomeException, try)
import System.Directory (canonicalizePath, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (isExtensionOf, takeFileName, (</>))
import System.Process (readProcessWithExitCode)

import Distribution.Simple.Compiler (Compiler, compilerProperties)
import Distribution.Utils.MD5 (md5, showMD5)

-- | The fingerprint of a GHC installation, given its global package db (the
-- @package.conf.d@ directory).
ghcFingerprint :: Compiler -> FilePath -> IO String
ghcFingerprint compiler globalDb = do
  names <- filter ("conf" `isExtensionOf`) <$> listDirectory globalDb
  confs <- mapM (\n -> (,) n <$> BS8.readFile (globalDb </> n)) names
  return (fingerprintOf (compilerProperties compiler) confs)

-- | The fingerprint is made of the GHC version, target platform and source
-- commit, which make it readable, and a hash of everything that identifies the
-- build: the properties that @ghc --info@ reports, and the @abi:@ hash that
-- every package of the global db records for its interface. Two installations
-- of the same bindist (ghcup's, say) have the same fingerprint, wherever they
-- are; a GHC of the same version built differently almost certainly does not.
fingerprintOf
  :: Map String String
  -- ^ What @ghc --info@ reports.
  -> [(FilePath, ByteString)]
  -- ^ The @.conf@ files of the global package db, with their names.
  -> String
fingerprintOf props confs =
  concat
    [ prop "Project version"
    , "-"
    , prop "Target platform"
    , "-"
    , take 8 (prop "Project Git commit id")
    , "-"
    , take 12 (showMD5 (md5 (BS8.pack (unlines (fields ++ abis)))))
    ]
  where
    prop k = Map.findWithDefault "" k props
    fields = [k ++ "=" ++ prop k | k <- hashedProps]
    abis = sort [name ++ " " ++ abi | (name, conf) <- confs, Just abi <- [abiOf conf]]

    hashedProps =
      [ "Project version"
      , "Project Git commit id"
      , "Build platform"
      , "Host platform"
      , "Target platform"
      , "GHC Dynamic"
      , "RTS ways"
      ]

    abiOf conf = case mapMaybe (stripKey . BS8.unpack) (BS8.lines conf) of
      (abi : _) -> Just abi
      [] -> Nothing
    stripKey line
      | "abi:" `isPrefixOf` line = Just (dropWhile isSpace (drop 4 line))
      | otherwise = Nothing

-- | A fingerprint of the C toolchain, for the same purpose as 'ghcFingerprint'.
-- It matters for more than the C and C++ code of a project: GHC runs the C
-- compiler to preprocess modules that use CPP and to link, and @hsc2hs@ runs
-- it too.
--
-- It is made from what the tools report about themselves, so it identifies
-- the versions in use and not the files: the C compiler @GHC@ is configured
-- with (@gcc@, normally) together with @cc@, @c++@, @g++@ and @ld@, the C
-- library, and the C++ standard library the compiler would link.
ccFingerprint :: Compiler -> IO String
ccFingerprint compiler = do
  let ghcCC = Map.findWithDefault "gcc" "C compiler command" (compilerProperties compiler)
      tools = ordNubOn id [ghcCC, "cc", "c++", "g++", "ld"]
  versions <- mapM (\t -> (,) t <$> firstLine ["--version"] t) tools
  target <- firstLine ["-dumpmachine"] "cc"
  libc <- firstLine ["--version"] "ldd"
  libcxx <- stdlibName
  return (ccFingerprintOf ([("target", target), ("libc", libc), ("libstdc++", libcxx)] ++ versions))
  where
    firstLine args cmd = do
      r <- try (readProcessWithExitCode cmd args "")
      return $ case r :: Either SomeException (ExitCode, String, String) of
        Right (ExitSuccess, out, _) | (l : _) <- lines out -> l
        _ -> "unavailable"
    -- The file that @libstdc++.so@ is, which has the library's version in its
    -- name.
    stdlibName = do
      r <- try (readProcessWithExitCode "c++" ["-print-file-name=libstdc++.so"] "")
      case r :: Either SomeException (ExitCode, String, String) of
        Right (ExitSuccess, out, _) | (l : _) <- lines out -> do
          real <- try (canonicalizePath l)
          return (either (const l) takeFileName (real :: Either SomeException FilePath))
        _ -> return "unavailable"
    ordNubOn f = go []
      where
        go _ [] = []
        go seen (x : xs)
          | f x `elem` seen = go seen xs
          | otherwise = x : go (f x : seen) xs

-- | The fingerprint, given what the tools reported, as @(name, report)@ pairs.
-- It starts with the target the C compiler reports, to be readable.
ccFingerprintOf :: [(String, String)] -> String
ccFingerprintOf reports =
  concat
    [ maybe "unknown" (map (\c -> if isSpace c then '_' else c)) (lookup "target" reports)
    , "-"
    , take 12 (showMD5 (md5 (BS8.pack (unlines [name ++ ": " ++ report | (name, report) <- sort reports]))))
    ]
