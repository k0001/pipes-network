{-# LANGUAGE RankNTypes #-}

-- | This minimal module exports facilities that ease the usage of TCP
-- 'Socket's in the /Pipes ecosystem/. It is meant to be used together with
-- the "Network.Simple.TCP" module from the @network-simple@ package, which is
-- completely re-exported from this module.
--
-- This module /does not/ export facilities that would allow you to acquire new
-- 'Socket's within a pipeline. If you need to do so, then you should use
-- "Pipes.Network.TCP.Safe" instead, which exports a similar API to the one
-- exported by this module.

module Pipes.Network.TCP (
  -- * Receiving
  -- $receiving
    fromSocket
  , fromSocketN
  , fromSocketTimeout
  , fromSocketTimeoutN
  -- * Sending
  -- $sending
  , toSocket
  , toSocketTimeout
  -- * Exports
  -- $exports
  , module Network.Simple.TCP
  ) where

import           Control.Monad.IO.Class         (MonadIO(liftIO))
import           Control.Monad.Trans.Maybe      (MaybeT)
import qualified Data.ByteString                as B
import qualified Network.Socket.ByteString      as NSB
import           Network.Simple.TCP
                  (connect, serve, listen, accept, acceptFork,
                   bindSock, connectSock, recv, send, withSocketsDo,
                   HostName, HostPreference(HostAny, HostIPv4, HostIPv6, Host),
                   ServiceName, SockAddr, Socket)
import           Pipes
import           Pipes.Core
import qualified Pipes.Lift                     as P
import           System.Timeout                 (timeout)

--------------------------------------------------------------------------------

-- $receiving
--
-- The following pipes allow you to receive bytes from the remote end.
--
-- Besides the pipes below, you might want to use "Network.Simple.TCP"'s
-- 'Network.Simple.TCP.recv', which happens to be an 'Effect'':
--
-- @
-- 'Network.Simple.TCP.recv' :: 'MonadIO' m => 'Socket' -> 'Int' -> 'Effect'' m ('Maybe' 'B.ByteString')
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
  => Socket     -- ^Connected socket.
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
fromSocketN :: MonadIO m => Socket -> Int -> Server Int B.ByteString m ()
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
-- 'Network.Simple.TCP.send' :: 'MonadIO' m => 'Socket' -> 'B.ByteString' -> 'Effect'' m ()
-- @

-- | Sends to the remote end each 'B.ByteString' received from upstream.
toSocket
  :: MonadIO m
  => Socket  -- ^Connected socket.
  -> Consumer B.ByteString m r
toSocket sock = cat //> send sock
{-# INLINE toSocket #-}

--------------------------------------------------------------------------------

-- | Like 'fromSocket', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then fail in the 'MaybeT' monad
-- transformer. The time is specified in microseconds (10e6).
fromSocketTimeout
  :: MonadIO m
  => Int -> Socket -> Int -> Producer B.ByteString (MaybeT m) ()
fromSocketTimeout wait sock nbytes = P.maybeP loop where
    loop = do
       mbs <- liftIO (timeout wait (NSB.recv sock nbytes))
       case mbs of
          Nothing -> return Nothing
          Just bs -> yield bs >> loop
{-# INLINABLE fromSocketTimeout #-}

-- | Like 'fromSocketN', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then fail in the 'MaybeT' monad
-- transformer. The time is specified in microseconds (10e6).
fromSocketTimeoutN
  :: MonadIO m
  => Int -> Socket -> Int -> Server Int B.ByteString (MaybeT m) ()
fromSocketTimeoutN wait sock = P.maybeP . loop where
    loop = \nbytes -> do
       mbs <- liftIO (timeout wait (NSB.recv sock nbytes))
       case mbs of
          Nothing -> return Nothing
          Just bs -> respond bs >>= loop
{-# INLINABLE fromSocketTimeoutN #-}

-- | Like 'toSocket', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then fail in the 'MaybeT' monad
-- transformer. The time is specified in microseconds (10e6).
toSocketTimeout
  :: MonadIO m
  => Int -> Socket -> Consumer B.ByteString (MaybeT m) r
toSocketTimeout wait sock =
    for cat (\a -> P.maybeP (liftIO (timeout wait (NSB.sendAll sock a))))
{-# INLINE toSocketTimeout #-}

--------------------------------------------------------------------------------

-- $exports
--
-- [From "Network.Simple.TCP"]
--     'accept',
--     'acceptFork',
--     'bindSock',
--     'connect',
--     'connectSock',
--     'HostName',
--     'HostPreference'('HostAny','HostIPv4','HostIPv6','Host'),
--     'listen',
--     'recv',
--     'send',
--     'serve',
--     'ServiceName',
--     'SockAddr',
--     'Socket',
--     'withSocketsDo'.
