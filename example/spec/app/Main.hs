-- | Not the main module: the executable is built with `-main-is Run.main`,
-- so this is an ordinary other-module that happens to be called Main, as
-- Cabal allows.
module Main (helper) where

helper :: String
helper = "helper"
