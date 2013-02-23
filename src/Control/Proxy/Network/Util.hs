{-# LANGUAGE DeriveDataTypeable #-}

-- Some code in this file was adapted from the @network-conduit@ library by
-- Michael Snoyman. Copyright (c) 2011. See its licensing terms (BSD3) at:
--   https://github.com/snoyberg/conduit/blob/master/network-conduit/LICENSE

module Control.Proxy.Network.Util (
  HostPreference(..),
  hpHostName,
  Timeout(..)
  ) where

import qualified Control.Exception             as E
import           Data.String                   (IsString (fromString))
import           Data.Typeable                 (Typeable)
import qualified Network.Socket as             NS

-- | Which host to bind to.
data HostPreference
  = HostAny          -- ^Any avaiable host.
  | HostIPv4         -- ^Any avaiable IPv4 host.
  | HostIPv6         -- ^Any avaiable IPv6 host.
  | Host NS.HostName -- ^Prefer an explicit host name.
  deriving (Eq, Ord, Show, Read)


-- | The following special values are recognized:
--
-- * @*@ means 'HostAny'
--
-- * @*4@ means 'HostIPv4'
--
-- * @*6@ means 'HostIPv6'
--
-- * Any other string is 'Host'
instance IsString HostPreference where
  fromString "*"  = HostAny
  fromString "*4" = HostIPv4
  fromString "*6" = HostIPv6
  fromString s    = Host s


-- | Extract the 'NS.HostName' from a 'Host' preference, or 'Nothing' otherwise.
hpHostName:: HostPreference -> Maybe NS.HostName
hpHostName (Host s) = Just s
hpHostName _        = Nothing


-- | Exception thrown when a timeout has elapsed.
data Timeout = Timeout deriving (Eq, Show, Typeable)
instance E.Exception Timeout where
