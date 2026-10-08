module Dep (message) where

import Paths_dep (version)

message :: String
message = "dep " ++ show version
