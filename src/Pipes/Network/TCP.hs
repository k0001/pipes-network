{-# LANGUAGE RankNTypes #-}

-- | This minimal module exports facilities that ease the usage of TCP

-- 'Socket's in the /Pipes ecosystem/. It is meant to be used together with
-- the "Network.Simple.TCP" module from the @network-simple@ package, which is
-- completely re-exported from this module.
--
-- This module /does not/ export facilities that would allow you to acquire new
-- 'Socket's within a pipeline. If you need to do so, then you should use
-- "Pipes.Network.TCP.Safe" instead, which exports a similar API to the one
-- exported by this module. However, don't be confused by the word “safe” in
-- that module; this module is equally safe to use as long as you don't try to
-- acquire resources within the pipeline.

module Pipes.Network.TCP (
  -- * Receiving
  -- $receiving
    fromSocket
  , fromSocketTimeout
  -- ** Bidirectional pipes
  -- $bidirectional
  , fromSocketN
  , fromSocketTimeoutN
  -- * Sending
  -- $sending
  , toSocket
  , toSocketLazy
  , toSocketMany
  , toSocketTimeout
  , toSocketTimeoutLazy
  , toSocketTimeoutMany
  -- * Exports
  -- $exports
  , module Network.Simple.TCP
  ) where

import qualified Data.ByteString                as B
import qualified Data.ByteString.Lazy           as BL
import           Foreign.C.Error                (errnoToIOError, eTIMEDOUT)
import qualified Network.Socket.ByteString      as NSB
import           Network.Simple.TCP
                  (connect, serve, listen, accept, acceptFork,
                   bindSock, connectSock, closeSock, recv, send, sendLazy,
                   sendMany, withSocketsDo, HostName,
                   HostPreference(HostAny, HostIPv4, HostIPv6, Host),
                   ServiceName, SockAddr, Socket)
import           Pipes
import           Pipes.Core
import           System.Timeout                 (timeout)

--------------------------------------------------------------------------------

-- $receiving
--
-- The following producers allow you to receive bytes from the remote end.
--
-- Besides the producers below, you might want to use "Network.Simple.TCP"'s
-- 'recv', which happens to be an 'Effect'':
--
-- @
-- 'recv' :: 'MonadIO' m => 'Socket' -> 'Int' -> 'Effect'' m ('Maybe' 'B.ByteString')
-- @

--------------------------------------------------------------------------------

-- | Receives bytes from the remote end and sends them downstream.
--
-- The number of bytes received at once is always in the interval
-- /[1 .. specified maximum]/.
--
-- This 'Producer'' returns if the remote peer closes its side of the connection
-- or EOF is received.
fromSocket
  :: MonadIO m
  => Socket     -- ^Connected socket.
  -> Int        -- ^Maximum number of bytes to receive and send
                -- dowstream at once. Any positive value is fine, the
                -- optimal value depends on how you deal with the
                -- received data. Try using @4096@ if you don't care.
  -> Producer' B.ByteString m ()
fromSocket sock nbytes = loop where
    loop = do
        bs <- liftIO (NSB.recv sock nbytes)
        if B.null bs
           then return ()
           else yield bs >> loop
{-# INLINABLE fromSocket #-}

-- | Like 'fromSocket', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then an 'IOError' exception is
-- thrown. The time is specified in microseconds (1 second = 1e6 microseconds).
fromSocketTimeout
  :: MonadIO m
  => Int -> Socket -> Int -> Producer' B.ByteString m ()
fromSocketTimeout wait sock nbytes = loop where
    loop = do
       mbs <- liftIO (timeout wait (NSB.recv sock nbytes))
       case mbs of
          Just bs
           | B.null bs -> return ()
           | otherwise -> yield bs >> loop
          Nothing -> liftIO $ ioError $ errnoToIOError
             "Pipes.Network.TCP.fromSocketTimeout" eTIMEDOUT Nothing Nothing
{-# INLINABLE fromSocketTimeout #-}

--------------------------------------------------------------------------------

-- $bidirectional
--
-- The following pipes are bidirectional, which means useful data can flow
-- through them upstream and downstream. If you don't care about bidirectional
-- pipes, just skip this section.

--------------------------------------------------------------------------------

-- | Like 'fromSocket', except the downstream pipe can specify the maximum
-- number of bytes to receive at once using 'request'.
fromSocketN :: MonadIO m => Socket -> Int -> Server' Int B.ByteString m ()
fromSocketN sock = loop where
    loop = \nbytes -> do
        bs <- liftIO (NSB.recv sock nbytes)
        if B.null bs
           then return ()
           else respond bs >>= loop
{-# INLINABLE fromSocketN #-}


-- | Like 'fromSocketN', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then an 'IOError' exception is
-- thrown. The time is specified in microseconds (1 second = 1e6 microseconds).
fromSocketTimeoutN
  :: MonadIO m
  => Int -> Socket -> Int -> Server' Int B.ByteString m ()
fromSocketTimeoutN wait sock = loop where
    loop = \nbytes -> do
       mbs <- liftIO (timeout wait (NSB.recv sock nbytes))
       case mbs of
          Just bs
           | B.null bs -> return ()
           | otherwise -> respond bs >>= loop
          Nothing -> liftIO $ ioError $ errnoToIOError
             "Pipes.Network.TCP.fromSocketTimeoutN" eTIMEDOUT Nothing Nothing
{-# INLINABLE fromSocketTimeoutN #-}

--------------------------------------------------------------------------------

-- $sending
--
-- The following consumers allow you to send bytes to the remote end.
--
-- Besides the consumers below, you might want to use "Network.Simple.TCP"'s
-- 'send', 'sendLazy' or 'sendMany' which happen to be 'Effect''s:
--
-- @
-- 'send'     :: 'MonadIO' m => 'Socket' ->  'B.ByteString'  -> 'Effect'' m ()
-- 'sendLazy' :: 'MonadIO' m => 'Socket' ->  'BL.ByteString'  -> 'Effect'' m ()
-- 'sendMany' :: 'MonadIO' m => 'Socket' -> ['B.ByteString'] -> 'Effect'' m ()
-- @

-- | Sends to the remote end each 'B.ByteString' received from upstream.
toSocket
  :: MonadIO m
  => Socket  -- ^Connected socket.
  -> Consumer' B.ByteString m r
toSocket sock = for cat (\a -> send sock a)
{-# INLINABLE toSocket #-}

-- | Like 'toSocket' but takes a lazy 'BL.ByteSring' and sends it in a more
-- efficient manner (compared to converting it to a strict 'B.ByteString' and
-- sending it).
toSocketLazy
  :: MonadIO m
  => Socket  -- ^Connected socket.
  -> Consumer' BL.ByteString m r
toSocketLazy sock = for cat (\a -> sendLazy sock a)
{-# INLINABLE toSocketLazy #-}

-- | Like 'toSocket' but takes a @['BL.ByteSring']@ and sends it in a more
-- efficient manner (compared to converting it to a strict 'B.ByteString' and
-- sending it).
toSocketMany
  :: MonadIO m
  => Socket  -- ^Connected socket.
  -> Consumer' [B.ByteString] m r
toSocketMany sock = for cat (\a -> sendMany sock a)
{-# INLINABLE toSocketMany #-}

-- | Like 'toSocket', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then an 'IOError' exception is
-- thrown. The time is specified in microseconds (1 second = 1e6 microseconds).
toSocketTimeout :: MonadIO m => Int -> Socket -> Consumer' B.ByteString m r
toSocketTimeout = _toSocketTimeout send "Pipes.Network.TCP.toSocketTimeout"
{-# INLINABLE toSocketTimeout #-}

-- | Like 'toSocketTimeout' but takes a lazy 'BL.ByteSring' and sends it in a
-- more efficient manner (compared to converting it to a strict 'B.ByteString'
-- and sending it).
toSocketTimeoutLazy :: MonadIO m => Int -> Socket -> Consumer' BL.ByteString m r
toSocketTimeoutLazy =
    _toSocketTimeout sendLazy "Pipes.Network.TCP.toSocketTimeoutLazy"
{-# INLINABLE toSocketTimeoutLazy #-}

-- | Like 'toSocketTimeout' but takes a @['BL.ByteSring']@ and sends it in a
-- more efficient manner (compared to converting it to a strict 'B.ByteString'
-- and sending it).
toSocketTimeoutMany
  :: MonadIO m => Int -> Socket -> Consumer' [B.ByteString] m r
toSocketTimeoutMany =
    _toSocketTimeout sendMany "Pipes.Network.TCP.toSocketTimeoutMany"
{-# INLINABLE toSocketTimeoutMany #-}

_toSocketTimeout
  :: MonadIO m
  => (Socket -> a -> IO ())
  -> String
  -> Int
  -> Socket
  -> Consumer' a m r
_toSocketTimeout send' nm = \wait sock -> for cat $ \a -> do
    mu <- liftIO (timeout wait (send' sock a))
    case mu of
      Just () -> return ()
      Nothing -> liftIO $ ioError $ errnoToIOError nm eTIMEDOUT Nothing Nothing
{-# INLINABLE _toSocketTimeout #-}

--------------------------------------------------------------------------------

-- $exports
--
-- [From "Network.Simple.TCP"]
--     'accept',
--     'acceptFork',
--     'bindSock',
--     'connect',
--     'connectSock',
--     'closeSock',
--     'HostPreference'('HostAny','HostIPv4','HostIPv6','Host'),
--     'listen',
--     'recv',
--     'send',
--     'sendLazy',
--     'sendMany',
--     'serve'.
--
-- [From "Network.Socket"]
--    'HostName',
--    'ServiceName',
--    'SockAddr',
--    'Socket',
--    'withSocketsDo'.
