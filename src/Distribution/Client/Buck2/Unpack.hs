-- | Unpacking the source of packages that buck2 builds, without building
-- anything.
module Distribution.Client.Buck2.Unpack
  ( unpackInplaceSources
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import System.Directory (doesDirectoryExist, doesFileExist, renameDirectory)
import System.FilePath ((<.>), (</>))

import Distribution.Client.DistDirLayout (DistDirLayout (..))
import Distribution.Client.FetchUtils (fetchPackage)
import Distribution.Client.ProjectPlanning
  ( ElaboratedConfiguredPackage (..)
  , ElaboratedSharedConfig
  )
import Distribution.Client.ProjectPlanning.Types (elabDistDirParams)
import qualified Distribution.Client.Tar as Tar
import Distribution.Client.GlobalFlags (RepoContext)
import Distribution.Client.Types (PackageLocation (..))

import Distribution.Package (PackageId, packageId, packageName)
import Distribution.Simple.Utils (createDirectoryIfMissingVerbose, die', info, writeFileAtomic)
import Distribution.Verbosity (Verbosity)

import qualified Data.ByteString.Lazy as LBS

-- | Fetch (if not already downloaded) and unpack the source of each given
-- package to where an inplace build of it would find it (under
-- 'distUnpackedSrcDirectory'). Packages whose source isn't a tarball (a
-- user-managed local directory, a source-repository checkout) need no
-- unpacking and are left alone.
unpackInplaceSources
  :: Verbosity
  -> DistDirLayout
  -> ElaboratedSharedConfig
  -> ((RepoContext -> IO ()) -> IO ())
  -> [ElaboratedConfiguredPackage]
  -> IO ()
unpackInplaceSources verbosity distDirLayout sharedConfig withRepoCtx pkgs =
  unless (null pkgs) $
    withRepoCtx $ \repoctx ->
      for_ pkgs $ \pkg -> do
        mtarball <- case elabPkgSourceLocation pkg of
          LocalTarballPackage tarball -> return (Just tarball)
          loc@RemoteTarballPackage{} -> fetched repoctx loc
          loc@RepoTarballPackage{} -> fetched repoctx loc
          _ -> return Nothing
        for_ mtarball $ \tarball ->
          unpackTarball
            verbosity
            distDirLayout
            tarball
            (packageId pkg)
            (elabPkgDescriptionOverride pkg)
            (distBuildDirectory distDirLayout (elabDistDirParams sharedConfig pkg))
  where
    fetched repoctx loc = do
      loc' <- fetchPackage verbosity repoctx loc
      return $ case loc' of
        RemoteTarballPackage _ tarball -> Just tarball
        RepoTarballPackage _ _ tarball -> Just tarball
        _ -> Nothing

-- | Unpack a package's tarball to 'distUnpackedSrcDirectory', unless that's
-- already been done. If the index has a newer revision of the @.cabal@ file
-- than the tarball, that's the one used.
unpackTarball
  :: Verbosity
  -> DistDirLayout
  -> FilePath
  -> PackageId
  -> Maybe LBS.ByteString
  -> FilePath
  -- ^ The package's build directory
  -> IO ()
unpackTarball verbosity distDirLayout tarball pkgid cabalFileOverride buildDir = do
  let srcdir = distUnpackedSrcDirectory distDirLayout pkgid
      srcrootdir = distUnpackedSrcRootDirectory distDirLayout
  exists <- doesDirectoryExist srcdir
  unless exists $ do
    createDirectoryIfMissingVerbose verbosity True srcrootdir
    info verbosity $ "Extracting " ++ tarball ++ " to " ++ srcrootdir ++ "..."
    Tar.extractTarGzFile srcrootdir (prettyShow pkgid) tarball

    let cabalFile = srcdir </> prettyShow (packageName pkgid) <.> "cabal"
    cabalFileExists <- doesFileExist cabalFile
    unless cabalFileExists $
      die' verbosity $
        "The package description file " ++ cabalFile ++ " was not found in " ++ tarball
    for_ cabalFileOverride $ \text -> do
      info verbosity $ "Updating " ++ cabalFile ++ " with the latest revision from the index."
      writeFileAtomic cabalFile text

    -- Some packages ship pre-processed files in a @dist@ directory inside the
    -- tarball: move it to where the build directory is.
    let shippedDist = srcdir </> "dist"
    shippedDistExists <- doesDirectoryExist shippedDist
    when shippedDistExists $ renameDirectory shippedDist buildDir
