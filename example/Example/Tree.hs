-- | A module in an import cycle with "Example.Forest", broken by
-- @Tree.hs-boot@: the build has to compile the boot file first, then
-- Forest against it, then this module (checking it agrees with the boot
-- file).
module Example.Tree (Tree (..), size, forestSize) where

import Example.Forest (Forest (..))

data Tree = Leaf | Node Forest

size :: Tree -> Int
size Leaf = 1
size (Node f) = 1 + forestSize f

forestSize :: Forest -> Int
forestSize (Forest ts) = sum (map size ts)
