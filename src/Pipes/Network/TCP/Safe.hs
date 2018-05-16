{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

-- | This module exports facilities allowing you to safely obtain, use and
-- release 'Socket' resources within a /Pipes/ pipeline, by relying on
-- @pipes-safe@.
--
-- This module is meant to be used as a replacement of "Pipes.Network.TCP",
-- and as such it overrides some functions from "Network.Simple.TCP" so that
-- they use 'MonadSafe' instead of 'IO' as their base monad. Additionally,
-- It also exports pipes that establish a TCP connection and interact with
-- it in a streaming fashion at once.
--
-- If you just want to use 'Socket' obtained outside the /Pipes/ pipeline,
-- then you can just ignore this module and use the simpler module
-- "Pipes.Network.TCP" instead.

module Pipes.Network.TCP.Safe (
  -- * @MonadSafe@-compatible upgrades
  -- $network-simple-upgrades
    connect
  , serve
  , listen
  , accept
  -- * Streaming
  -- ** Client side
  -- $client-streaming
  , fromConnect
  , toConnect
  , toConnectLazy
  , toConnectMany
  -- ** Server side
  -- $server-streaming
  , fromServe
  , toServe
  , toServeLazy
  , toServeMany
  -- * Exports
  -- $exports
  , module Pipes.Network.TCP
  , module Network.Simple.TCP
  , module Pipes.Safe
  ) where

import           Control.Monad
import qualified Control.Monad.Catch    as C
import qualified Data.ByteString        as B
import qualified Data.ByteString.Lazy   as BL
import qualified Network.Simple.TCP     as T
import           Network.Simple.TCP
                  (acceptFork, bindSock, connectSock, closeSock, recv, send,
                   sendLazy, sendMany, withSocketsDo, HostName,
                   HostPreference(HostAny, HostIPv4, HostIPv6, Host),
                   ServiceName, SockAddr, Socket)
import qualified Network.Socket         as NS
import           Pipes
import           Pipes.Network.TCP
                  (fromSocket, fromSocketTimeout, fromSocketN,
                   fromSocketTimeoutN, toSocket, toSocketLazy, toSocketMany,
                   toSocketTimeout, toSocketTimeoutLazy, toSocketTimeoutMany)
import qualified Pipes.Safe             as Ps
import           Pipes.Safe             (runSafeT, MonadSafe)

--------------------------------------------------------------------------------

-- $network-simple-upgrades
--
-- The following functions are analogous versions of those exported by
-- "Network.Simple.TCP", but compatible with 'MonadSafe'.

-- | Like 'Network.Simple.TCP.connect' from "Network.Simple.TCP", but compatible
-- with 'MonadSafe'.
connect
  :: MonadSafe m
  => HostName -> ServiceName -> ((Socket, SockAddr) -> m r) -> m r
connect host port = Ps.bracket (connectSock host port)
                               (T.closeSock . fst)

-- | Like 'Network.Simple.TCP.serve' from "Network.Simple.TCP", but compatible
-- with 'MonadSafe'.
serve
  :: MonadSafe m
  => HostPreference -> ServiceName -> ((Socket, SockAddr) -> IO ()) -> m r
serve hp port k = do
   listen hp port $ \(lsock,_) -> do
      forever $ acceptFork lsock k

-- | Like 'Network.Simple.TCP.listen' from "Network.Simple.TCP", but compatible
-- with 'MonadSafe'.
listen
  :: MonadSafe m
  => HostPreference -> ServiceName -> ((Socket, SockAddr) -> m r) -> m r
listen hp port = Ps.bracket listen' (T.closeSock . fst)
  where
    listen' = liftIO $ do
        x@(bsock,_) <- bindSock hp port
        NS.listen bsock (max 2048 NS.maxListenQueue)
        return x

-- | Like 'Network.Simple.TCP.accept' from "Network.Simple.TCP", but compatible
-- with 'MonadSafe'.
accept
  :: MonadSafe m
  => Socket -> ((Socket, SockAddr) -> m r) -> m r
accept lsock k = do
    conn@(csock,_) <- liftIO (NS.accept lsock)
    Ps.finally (k conn) (T.closeSock csock)
{-# INLINABLE accept #-}

--------------------------------------------------------------------------------

-- $client-streaming
--
-- The following pipes allow you to easily connect to a TCP server and
-- immediately interact with it in a streaming fashion, all at once, instead of
-- having to perform the individual steps separately. However, keep
-- in mind that you'll be able to interact with the remote end in only one
-- direction, that is, you'll either send or receive data, but not both.

--------------------------------------------------------------------------------

-- | Connect to a TCP server and send downstream the bytes received from the
-- remote end.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- Using this 'Producer'' you can write straightforward code like the following,
-- which prints whatever is received from a single TCP connection to a given
-- server listening locally on port 9000, in chunks of up to 4096 bytes:
--
-- >>> runSafeT . runEffect $ fromConnect 4096 "127.0.0.1" "9000" >-> P.print
fromConnect
  :: MonadSafe m
  => Int             -- ^Maximum number of bytes to receive and send
                     -- dowstream at once. Any positive value is fine, the
                     -- optimal value depends on how you deal with the
                     -- received data. Try using @4096@ if you don't care.
  -> HostName        -- ^Server host name.
  -> ServiceName     -- ^Server service port.
  -> Producer' B.ByteString m ()
fromConnect nbytes = _connect (\csock -> fromSocket csock nbytes)

-- | Connects to a TCP server, sends to the remote end the bytes received from
-- upstream.
--
-- The connection socket is closed in case of exceptions.
--
-- Using this 'Consumer'' you can write straightforward code like the following,
-- which greets a TCP client listening locally at port 9000:
--
-- >>> :set -XOverloadedStrings
-- >>> runSafeT . runEffect $ each ["He","llo\r\n"] >-> toConnect "127.0.0.1" "9000"
toConnect
  :: MonadSafe m
  => HostName        -- ^Server host name.
  -> ServiceName     -- ^Server service port.
  -> Consumer' B.ByteString m r
toConnect = _connect toSocket

-- | Like 'toConnect', but works more efficiently on lazy 'BL.ByteString's
-- (compared to converting them to a strict 'B.ByteString' and sending it)
toConnectLazy
  :: MonadSafe m
  => HostName        -- ^Server host name.
  -> ServiceName     -- ^Server service port.
  -> Consumer' BL.ByteString m r
toConnectLazy = _connect toSocketLazy

-- | Like 'toConnect', but works more efficiently on @['B.ByteString']@
-- (compared to converting them to a strict 'B.ByteString' and sending it)
toConnectMany
  :: MonadSafe m
  => HostName        -- ^Server host name.
  -> ServiceName     -- ^Server service port.
  -> Consumer' [B.ByteString] m r
toConnectMany = _connect toSocketMany

_connect
  :: MonadSafe m
  => (Socket -> m r) -- ^Action to perform on the connection socket.
  -> HostName        -- ^Server host name.
  -> ServiceName     -- ^Server service port.
  -> m r
_connect act hp port = do
    connect hp port $ \(csock,_) -> do
       act csock
{-# INLINABLE _connect #-}

--------------------------------------------------------------------------------

-- $server-streaming
--
-- The following pipes allow you to easily run a TCP server and immediately
-- interact with incoming connections in a streaming fashion, all at once,
-- instead of having to perform the individual steps separately. However, keep
-- in mind that you'll be able to interact with the remote end in only one
-- direction, that is, you'll either send or receive data, but not both.

--------------------------------------------------------------------------------

-- | Binds a listening socket, accepts a single connection and sends downstream
-- any bytes received from the remote end.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- This 'Producer'' returns if the remote peer closes its side of the connection
-- or EOF is received.
--
-- Both the listening and connection sockets are closed when done or in case of
-- exceptions.
--
-- Using this 'Producer'' you can write straightforward code like the following,
-- which prints whatever is received from a single TCP connection to port 9000,
-- in chunks of up to 4096 bytes.
--
-- >>> :set -XOverloadedStrings
-- >>> runSafeT . runEffect $ fromServe 4096 "127.0.0.1" "9000" >-> P.print
fromServe
  :: MonadSafe m
  => Int             -- ^Maximum number of bytes to receive and send
                     -- dowstream at once. Any positive value is fine, the
                     -- optimal value depends on how you deal with the
                     -- received data. Try using @4096@ if you don't care.
  -> HostPreference  -- ^Preferred host to bind.
  -> ServiceName     -- ^Service port to bind.
  -> Producer' B.ByteString m ()
fromServe nbytes = _serve (\csock -> fromSocket csock nbytes)

-- | Binds a listening socket, accepts a single connection, sends to the remote
-- end the bytes received from upstream.
--
-- Both the listening and connection sockets are closed when done or in case of
-- exceptions.
--
-- Using this 'Consumer'' you can write straightforward code like the following,
-- which greets a TCP client connecting to port 9000:
--
-- >>> :set -XOverloadedStrings
-- >>> runSafeT . runEffect $ each ["He","llo\r\n"] >-> toServe "127.0.0.1" "9000"
toServe
  :: MonadSafe m
  => HostPreference  -- ^Preferred host to bind.
  -> ServiceName     -- ^Service port to bind.
  -> Consumer' B.ByteString m r
toServe = _serve toSocket

-- | Like 'toServe', but works more efficiently on lazy 'BL.ByteString's
-- (compared to converting them to a strict 'B.ByteString' and sending it)
toServeLazy
  :: MonadSafe m
  => HostPreference  -- ^Preferred host to bind.
  -> ServiceName     -- ^Service port to bind.
  -> Consumer' BL.ByteString m r
toServeLazy = _serve toSocketLazy

-- | Like 'toServe', but works more efficiently on @['B.ByteString']@
-- (compared to converting them to a strict 'B.ByteString' and sending it)
toServeMany
  :: MonadSafe m
  => HostPreference  -- ^Preferred host to bind.
  -> ServiceName     -- ^Service port to bind.
  -> Consumer' [B.ByteString] m r
toServeMany = _serve toSocketMany

_serve
  :: MonadSafe m
  => (Socket -> m r) -- ^Action to perform on the connection socket.
  -> HostPreference  -- ^Preferred host to bind.
  -> ServiceName     -- ^Service port to bind.
  -> m r
_serve act hp port = do
   listen hp port $ \(lsock,_) -> do
      accept lsock $ \(csock,_) -> do
         -- We prevent further connection attempts while we deal with `csock`.
         C.catch (closeSock lsock) (\(_ :: IOError) -> pure ())
         act csock
{-# INLINABLE _serve #-}

--------------------------------------------------------------------------------

-- $exports
--
-- [From "Pipes.Network.TCP"]
--    'fromSocket',
--    'fromSocketN',
--    'fromSocketTimeout',
--    'fromSocketTimeoutN',
--    'toSocket',
--    'toSocketLazy',
--    'toSocketMany',
--    'toSocketTimeout',
--    'toSocketTimeoutLazy',
--    'toSocketTimeoutMany'.
--
-- [From "Network.Simple.TCP"]
--    'acceptFork',
--    'bindSock',
--    'connectSock',
--    'closeSock',
--    'HostPreference'('HostAny','HostIPv4','HostIPv6','Host'),
--    'recv',
--    'send',
--    'sendLazy',
--    'sendMany'.
--
-- [From "Network.Socket"]
--    'HostName',
--    'ServiceName',
--    'SockAddr',
--    'Socket',
--    'withSocketsDo'.
--
-- [From "Pipes.Safe"]
--    'runSafeT',
--    'MonadSafe'.
