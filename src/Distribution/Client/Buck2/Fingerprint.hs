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
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import Data.Char (isSpace)
import Data.List (isPrefixOf, sort)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (mapMaybe)
import System.Directory (listDirectory)
import System.FilePath (isExtensionOf, (</>))

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
