-- | The flags of @cabal buck2@ that @cabal build@ doesn't have.
module Distribution.Client.Buck2.Flags
  ( Buck2Flags (..)
  , defaultBuck2Flags
  , buck2FlagOptions
  , dependencyMode
  ) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import Distribution.ReadE (succeedReadE)
import Distribution.Simple.Command (OptionField, ShowOrParseArgs, option, reqArg)
import Distribution.Simple.Flag (Flag, flagToList, fromFlagOrDefault, toFlag)
import Distribution.Simple.Setup (trueArg)

import Distribution.Client.Buck2.LocalPackages (DependencyMode (..))

data Buck2Flags = Buck2Flags
  { buck2CacheAddress :: Flag String
  , buck2NoCache :: Flag Bool
  , buck2SourceDeps :: Flag Bool
  }

defaultBuck2Flags :: Buck2Flags
defaultBuck2Flags = Buck2Flags{buck2CacheAddress = mempty, buck2NoCache = mempty, buck2SourceDeps = mempty}

buck2FlagOptions :: ShowOrParseArgs -> [OptionField Buck2Flags]
buck2FlagOptions _ =
  [ option
      []
      ["cache"]
      "Use the remote action cache at ADDRESS (grpc://host:port), only to look up and store results: nothing is run remotely. Written to .buckconfig; later runs keep using it."
      buck2CacheAddress
      (\v f -> f{buck2CacheAddress = v})
      (reqArg "ADDRESS" (succeedReadE toFlag) flagToList)
  , option
      []
      ["no-cache"]
      "Stop using a remote action cache (removes what --cache added to .buckconfig)."
      buck2NoCache
      (\v f -> f{buck2NoCache = v})
      trueArg
  , option
      []
      ["source-deps"]
      "Build the dependencies with buck2, from their sources (unpacked under dist-newstyle), like the packages of the project, instead of having cabal build them into its store. Nothing is then taken from the store."
      buck2SourceDeps
      (\v f -> f{buck2SourceDeps = v})
      trueArg
  ]

-- | How the dependencies are to be built.
dependencyMode :: Buck2Flags -> DependencyMode
dependencyMode flags
  | fromFlagOrDefault False (buck2SourceDeps flags) = DependenciesFromSource
  | otherwise = DependenciesFromStore
