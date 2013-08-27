{-# LANGUAGE RankNTypes #-}

-- | This minimal module exports facilities that ease the usage of TCP
-- 'NS.Socket's in the /Pipes ecosystem/. It is meant to be used together with
-- the "Network.Simple.TCP" module from the @network-simple@ package.
--
-- This module /does not/ export facilities that would allow you to acquire new
-- 'NS.Socket's within a pipeline. If you need to do so, then you'll need to
-- rely on additional features exported the "Pipes.Network.TCP.Safe" module,
-- which among other things, overrides some of the functions from
-- "Network.Simple.TCP".

module Pipes.Network.TCP (
  -- * Receiving
  -- $receiving
    fromSocket
  , fromSocketN
  -- * Sending
  -- $sending
  , toSocket
  ) where

import           Control.Monad.IO.Class         (MonadIO(liftIO))
import qualified Data.ByteString                as B
import qualified Network.Socket                 as NS
import qualified Network.Socket.ByteString      as NSB
import           Pipes
import           Pipes.Core

--------------------------------------------------------------------------------

-- $receiving
--
-- The following pipes allow you to receive bytes from the remote end.
--
-- Besides the pipes exported below, you might want to 'liftIO'
-- "Network.Simple.TCP"'s 'Network.Simple.TCP.recv' to be used as an 'Effect':
--
-- @
-- recv' :: 'MonadIO' m => 'NS.Socket' -> 'Int' -> 'Effect'' m ('Maybe' 'B.ByteString')
-- recv' sock nbytes = 'liftIO' $ 'Network.Simple.TCP.recv' sock nbytes
-- @
--
-- This module doesn't export this small function so that you can enjoy
-- composing it yourself whenever you need it.


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
           else respond bs >> loop
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
-- Besides the pipes below, you might want to 'liftIO' "Network.Simple.TCP"'s
-- 'Network.Simple.TCP.send' to be used as an 'Effect':
--
-- @
-- send' :: 'MonadIO' m => 'NS.Socket' -> 'B.ByteString' -> 'Effect'' m ()
-- send' sock bytes = 'liftIO' $ 'Network.Simple.TCP.send' sock bytes
-- @
--
-- This module doesn't export this small function so that you can enjoy
-- composing it yourself whenever you need it.

-- | Sends to the remote end each 'B.ByteString' received from upstream.
toSocket
  :: MonadIO m
  => NS.Socket  -- ^Connected socket.
  -> Consumer B.ByteString m r
toSocket sock = cat //> liftIO . NSB.sendAll sock
{-# INLINE toSocket #-}

