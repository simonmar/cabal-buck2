module Example.Forest (Forest (..), trees) where

import {-# SOURCE #-} Example.Tree (Tree)

-- An annotation: GHC evaluates it with its interpreter at compile time, as
-- it runs a splice, so this module needs its dependencies' libraries.
{-# ANN module ("HLint: ignore Use newtype instead of data" :: String) #-}

newtype Forest = Forest [Tree]

trees :: Forest -> [Tree]
trees (Forest ts) = ts
