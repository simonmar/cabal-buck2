module Example.Forest (Forest (..), trees) where

import {-# SOURCE #-} Example.Tree (Tree)

newtype Forest = Forest [Tree]

trees :: Forest -> [Tree]
trees (Forest ts) = ts
