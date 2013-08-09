{-# LANGUAGE DeriveDataTypeable #-}

-- | This module doesn't belong to this namespace, but really, I don't
-- know where it belongs. Suggestions welcome.
--
-- There's a @data-timeout@ package, maybe we should depend on that.

module Pipes.Network.Internal (
    Timeout(..)
  ) where

import           Control.Exception             (Exception)
import           Control.Monad.Trans.Error     (Error)
import           Data.Data                     (Data, Typeable)


-- |Exception thrown when a timeout has elapsed.
data Timeout
  = Timeout String -- ^Timeouted with an additional explanatory message.
  deriving (Eq, Show, Data, Typeable)

instance Exception Timeout where
instance Error     Timeout where
