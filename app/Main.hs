-- | @cabal buck2@, as an external command: @cabal@ runs @cabal-buck2@ with the
-- arguments after the command name.
module Main (main) where

import Distribution.Client.CmdBuck2 (buck2Action, buck2Command)
import Distribution.Client.Errors (CabalInstallException)
import Distribution.Client.Setup (defaultGlobalFlags)
import Distribution.Simple.Command
  ( CommandParse (..)
  , CommandUI (commandDefaultFlags)
  , commandParseArgs
  )
import Distribution.Simple.Utils (VerboseException, die', isUserException, topHandler)
import Distribution.Verbosity (defaultVerbosityHandles, mkVerbosity, normal)
import Data.Proxy (Proxy (..))
import System.Environment (getArgs)

main :: IO ()
main = topHandler (isUserException (Proxy @(VerboseException CabalInstallException))) $ do
  args <- getArgs
  -- `cabal help buck2` runs `cabal-buck2 buck2 --help`.
  let args' = case args of
        "buck2" : rest -> rest
        _ -> args
  case commandParseArgs buck2Command True args' of
    CommandHelp help -> putStr (help "cabal")
    CommandList opts -> putStr (unlines opts)
    CommandErrors errs -> die' (mkVerbosity defaultVerbosityHandles normal) (unlines errs)
    CommandReadyToGo (flags, extraArgs) -> buck2Action (flags (commandDefaultFlags buck2Command)) extraArgs defaultGlobalFlags
