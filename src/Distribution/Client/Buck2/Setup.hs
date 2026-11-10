-- | Set up the project for building with @buck2@
module Distribution.Client.Buck2.Setup
  ( ensureBuck2Dir
  , ensureBuckconfigAndPackage
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import qualified Data.ByteString.Char8 as BS
import Data.List (stripPrefix)
import System.Directory
  ( copyFile
  , createDirectory
  , doesDirectoryExist
  , doesFileExist
  , getPermissions
  , listDirectory
  , removeDirectoryRecursive
  , renameDirectory
  , setOwnerExecutable
  , setPermissions
  )
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)

import Distribution.Simple.Utils (die', notice)

import Distribution.Client.Buck2.Version (cabalBuck2Version)

import Paths_cabal_buck2 (getDataDir)


-- | Make sure that the @buck2@ support code for this release of @cabal-buck2@
-- is at @buck2\/@. The files that @cabal-buck2@ generates are only understood
-- by the support code of the same release.
--
-- If there is no @buck2\/@, this copies the support code that was installed
-- with @cabal-buck2@ into the project. A @buck2\/@ that was copied like this
-- is replaced when a different release of @cabal-buck2@ runs. Any other
-- @buck2\/@ (a git checkout of haskell-buck2, for example) is left alone, and
-- it is an error if it is for a different release.
ensureBuck2Dir :: Verbosity -> FilePath -> IO ()
ensureBuck2Dir verbosity projectRoot = do
  exists <- doesDirectoryExist buck2Dir
  if not exists
    then unpackBuck2Dir verbosity buck2Dir
    else do
      found <- readBuck2Version buck2Dir
      unpacked <- doesFileExist (buck2Dir </> unpackedMarker)
      case found of
        Just v | v == cabalBuck2Version -> return ()
        _ | unpacked -> do
              notice verbosity $ "cabal buck2: replacing buck2/, which is for " ++ maybe "no release" ("cabal-buck2 " ++) found ++ ", with the copy for cabal-buck2 " ++ cabalBuck2Version
              removeDirectoryRecursive buck2Dir
              unpackBuck2Dir verbosity buck2Dir
        _ ->
          die' verbosity $
            unlines
              [ "The 'buck2/' directory is not for this release of cabal-buck2."
              , ""
              , "This is cabal-buck2 " ++ cabalBuck2Version ++ ", and buck2/ is for " ++ maybe "no release (it is from an earlier one)" ("cabal-buck2 " ++) found ++ "."
              , ""
              , "cabal-buck2 " ++ cabalBuck2Version ++ " needs the " ++ cabalBuck2Version ++ " branch of https://github.com/simonmar/haskell-buck2. If buck2/ is a git checkout, switch it with:"
              , ""
              , "    git -C buck2 fetch && git -C buck2 checkout " ++ cabalBuck2Version
              , ""
              , "Or remove buck2/, and 'cabal buck2' will put the copy that comes with it there instead."
              ]
  where
    buck2Dir = projectRoot </> "buck2"

-- | The file in @buck2\/@ that says 'unpackBuck2Dir' made it.
unpackedMarker :: FilePath
unpackedMarker = ".cabal-buck2-unpacked"

-- | Copy the support code that was installed with @cabal-buck2@ (its data
-- files) to @dest@. It is copied to a temporary directory first and then
-- renamed, so that a copy that fails part of the way doesn't leave a
-- @buck2\/@ behind.
unpackBuck2Dir :: Verbosity -> FilePath -> IO ()
unpackBuck2Dir verbosity dest = do
  src <- (</> "buck2") <$> getDataDir
  installed <- doesFileExist (src </> "version.bzl")
  unless installed $
    die' verbosity $
      unlines
        [ "No 'buck2/' directory found in the project root, and the copy of it that should have been installed with cabal-buck2 is missing (from " ++ src ++ ")."
        , "Clone the buck2 prelude and support scripts with:"
        , ""
        , "    git clone --branch " ++ cabalBuck2Version ++ " https://github.com/simonmar/haskell-buck2 buck2"
        , ""
        , "then re-run 'cabal buck2'."
        ]
  let tmp = dest ++ ".unpacking"
  tmpExists <- doesDirectoryExist tmp
  when tmpExists $ removeDirectoryRecursive tmp
  copyTree src tmp
  writeFile (tmp </> unpackedMarker) $
    unlines
      [ "cabal-buck2 copied this directory from its own installed copy of the buck2"
      , "support code. When a different release of cabal-buck2 runs, it replaces the"
      , "directory with its own copy. To keep the directory as it is, delete this file."
      ]
  renameDirectory tmp dest
  notice verbosity $ "cabal buck2: created " ++ dest ++ " (from " ++ src ++ ")"

-- | Copy the directory tree at @from@ to @to@. Cabal installs data files
-- without their executable permission, so a file that starts with @#!@ is made
-- executable again. When @cabal-buck2@ runs from its source tree (with @cabal
-- run@, say), the data files are in the haskell-buck2 submodule, whose @.git@
-- file must not be copied.
copyTree :: FilePath -> FilePath -> IO ()
copyTree from to = do
  createDirectory to
  names <- listDirectory from
  for_ (filter (/= ".git") names) $ \name -> do
    let src = from </> name
        dst = to </> name
    isDir <- doesDirectoryExist src
    if isDir
      then copyTree src dst
      else do
        copyFile src dst
        script <- withBinaryFile dst ReadMode $ \h -> (== BS.pack "#!") <$> BS.hGet h 2
        when script $ do
          perms <- getPermissions dst
          setPermissions dst (setOwnerExecutable True perms)

-- | The release of @cabal-buck2@ that a checkout of @haskell-buck2@ is for,
-- from its @version.bzl@ (@CABAL_BUCK2_VERSION = "..."@).
readBuck2Version :: FilePath -> IO (Maybe String)
readBuck2Version buck2Dir = do
  let path = buck2Dir </> "version.bzl"
  exists <- doesFileExist path
  if not exists
    then return Nothing
    else do
      contents <- readFile path
      return $ listToMaybe [takeWhile (/= '"') rest | l <- lines contents, Just rest <- [stripPrefix "CABAL_BUCK2_VERSION = \"" l]]

-- | Copy @.buckconfig@ and @PACKAGE@ if they don't exist
ensureBuckconfigAndPackage :: Verbosity -> FilePath -> IO ()
ensureBuckconfigAndPackage verbosity projectRoot = do
  copyIfMissing verbosity (templateDir </> ".buckconfig") (projectRoot </> ".buckconfig")
  copyIfMissing verbosity (templateDir </> "PACKAGE") (projectRoot </> "PACKAGE")
  where
    templateDir = projectRoot </> "buck2" </> "template"

copyIfMissing :: Verbosity -> FilePath -> FilePath -> IO ()
copyIfMissing verbosity src dest = do
  exists <- doesFileExist dest
  unless exists $ do
    contents <- readFile src
    writeFile dest contents
    notice verbosity $ "cabal buck2: created " ++ dest ++ " (from " ++ src ++ ")"
