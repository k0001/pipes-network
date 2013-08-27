{-# LANGUAGE RankNTypes #-}

-- | This minimal module exports facilities that ease the usage of TCP
-- 'NS.Socket's in the /Pipes ecosystem/. It is meant to be used together with
-- the "Network.Simple.TCP" module from the @network-simple@ package, which is
-- completely re-exported from this module.
--
-- This module /does not/ export facilities that would allow you to acquire new
-- 'NS.Socket's within a pipeline. If you need to do so, then you should use
-- "Pipes.Network.TCP.Safe" instead, which exports a similar API to the one
-- exported by this module.

module Pipes.Network.TCP (
  -- * Receiving
  -- $receiving
    fromSocket
  , fromSocketN
  -- * Sending
  -- $sending
  , toSocket
  -- * Exports
  , module Network.Simple.TCP
  ) where

import           Control.Monad.IO.Class         (MonadIO(liftIO))
import qualified Data.ByteString                as B
import qualified Network.Socket                 as NS
import qualified Network.Socket.ByteString      as NSB
import           Network.Simple.TCP
import           Pipes
import           Pipes.Core

--------------------------------------------------------------------------------

-- $receiving
--
-- The following pipes allow you to receive bytes from the remote end.
--
-- Besides the pipes below, you might want to use "Network.Simple.TCP"'s
-- 'Network.Simple.TCP.recv', which happens to be an 'Effect'':
--
-- @
-- 'Network.Simple.TCP.recv' :: 'MonadIO' m => 'NS.Socket' -> 'Int' -> 'Effect'' m ('Maybe' 'B.ByteString')
-- @


-- | Receives bytes from the remote end sends them downstream.
--
-- The number of bytes received at once is always in the interval
-- /[1 .. specified maximum]/.
--
-- This 'Producer' returns if the remote peer closes its side of the connection
-- or EOF is received.
fromSocket
  :: MonadIO m
  => NS.Socket  -- ^Connected socket.
  -> Int        -- ^Maximum number of bytes to receive and send
                -- dowstream at once. Any positive value is fine, the
                -- optimal value depends on how you deal with the
                -- received data. Try using @4096@ if you don't care.
  -> Producer B.ByteString m ()
fromSocket sock nbytes = loop where
    loop = do
        bs <- liftIO (NSB.recv sock nbytes)
        if B.null bs
           then return ()
           else yield bs >> loop
{-# INLINABLE fromSocket #-}


-- | Like 'fromSocket', except the downstream pipe can specify the maximum
-- number of bytes to receive at once using 'request'.
fromSocketN :: MonadIO m => NS.Socket -> Int -> Server Int B.ByteString m ()
fromSocketN sock = loop where
    loop = \nbytes -> do
        bs <- liftIO (NSB.recv sock nbytes)
        if B.null bs
           then return ()
           else respond bs >>= loop
{-# INLINABLE fromSocketN #-}

--------------------------------------------------------------------------------

-- $sending
--
-- The following pipes allow you to send bytes to the remote end.
--
-- Besides the pipes below, you might want to use "Network.Simple.TCP"'s
-- 'Network.Simple.TCP.send', which happens to be an 'Effect'':
--
-- @
-- 'Network.Simple.TCP.send' :: 'MonadIO' m => 'NS.Socket' -> 'B.ByteString' -> 'Effect'' m ()
-- @

-- | Sends to the remote end each 'B.ByteString' received from upstream.
toSocket
  :: MonadIO m
  => NS.Socket  -- ^Connected socket.
  -> Consumer B.ByteString m r
toSocket sock = cat //> send sock
{-# INLINE toSocket #-}

