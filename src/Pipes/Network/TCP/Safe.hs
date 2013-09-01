{-# LANGUAGE Rank2Types, TypeFamilies #-}

-- | This module exports facilities allowing you to safely obtain, use and
-- release 'Socket' resources within a /Pipes/ pipeline, by relying on
-- @pipes-safe@.
--
-- This module is meant to be used as a replacement of "Pipes.Network.TCP",
-- and as such it overrides some functions from "Network.Simple.TCP" so that
-- they use 'Ps.MonadSafe' instead of 'IO' as their base monad. Additionally,
-- It also exports pipes that establish a TCP connection and interact with
-- it in a streaming fashion at once.
--
-- If you just want to use 'Socket' obtained outside the /Pipes/ pipeline,
-- then you can just ignore this module and use the simpler module
-- "Pipes.Network.TCP" instead.

module Pipes.Network.TCP.Safe (
  -- * Streaming
  -- ** Client side
  -- $client-streaming
    fromConnect
  , toConnect
  -- ** Server side
  -- $server-streaming
  , fromServe
  , toServe
  -- * @MonadSafe@-compatible upgrades
  -- $network-simple-upgrades
  , connect
  , serve
  , listen
  , accept
  -- * Exports
  -- $exports
  , module Pipes.Network.TCP
  , module Network.Simple.TCP
  , module Pipes.Safe
  ) where

import           Control.Monad
import           Control.Monad.IO.Class (MonadIO(liftIO))
import qualified Data.ByteString        as B
import           Network.Simple.TCP
                  (acceptFork, bindSock, connectSock, recv, send, withSocketsDo,
                   HostName, HostPreference(HostAny, HostIPv4, HostIPv6, Host),
                   ServiceName, SockAddr, Socket)
import qualified Network.Socket         as NS
import           Pipes
import           Pipes.Network.TCP
                  (fromSocket, fromSocketTimeout, fromSocketN,
                   fromSocketTimeoutN, toSocket, toSocketTimeout)
import qualified Pipes.Safe             as Ps
import           Pipes.Safe             (runSafeT)

--------------------------------------------------------------------------------

-- $network-simple-upgrades
--
-- The following functions are analogous versions of those exported by
-- "Network.Simple.TCP", but compatible with 'Ps.MonadSafe'.

connect
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => HostName -> ServiceName -> ((Socket, SockAddr) -> m r) -> m r
connect host port = Ps.bracket (connectSock host port)
                               (NS.sClose . fst)

serve
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => HostPreference -> ServiceName -> ((Socket, SockAddr) -> IO ()) -> m r
serve hp port k = do
   listen hp port $ \(lsock,_) -> do
      forever $ acceptFork lsock k

listen
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => HostPreference -> ServiceName -> ((Socket, SockAddr) -> m r) -> m r
listen hp port = Ps.bracket listen' (NS.sClose . fst)
  where
    listen' = do x@(bsock,_) <- bindSock hp port
                 NS.listen bsock (max 2048 NS.maxListenQueue)
                 return x

accept
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => Socket -> ((Socket, SockAddr) -> m r) -> m r
accept lsock k = do
    conn@(csock,_) <- liftIO (NS.accept lsock)
    Ps.finally (k conn) (NS.sClose csock)
{-# INLINABLE accept #-}

--------------------------------------------------------------------------------

-- $client-streaming
--
-- The following pipes allow you to easily connect to a TCP server and
-- immediately interact with it in a streaming fashion, all at once, instead of
-- having to perform the individual steps separately.

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
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => Int             -- ^Maximum number of bytes to receive and send
                     -- dowstream at once. Any positive value is fine, the
                     -- optimal value depends on how you deal with the
                     -- received data. Try using @4096@ if you don't care.
  -> HostName        -- ^Server host name.
  -> ServiceName     -- ^Server service port.
  -> Producer' B.ByteString m ()
fromConnect nbytes host port = do
   connect host port $ \(csock,_) -> do
      fromSocket csock nbytes

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
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => HostName        -- ^Server host name.
  -> ServiceName     -- ^Server service port.
  -> Consumer' B.ByteString m r
toConnect hp port = do
   connect hp port $ \(csock,_) -> do
      toSocket csock

--------------------------------------------------------------------------------

-- $server-streaming
--
-- The following pipes allow you to easily run a TCP server and immediately
-- interact with incoming connections in a streaming fashion, all at once,
-- instead of having to perform the individual steps separately.

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
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => Int             -- ^Maximum number of bytes to receive and send
                     -- dowstream at once. Any positive value is fine, the
                     -- optimal value depends on how you deal with the
                     -- received data. Try using @4096@ if you don't care.
  -> HostPreference  -- ^Preferred host to bind.
  -> ServiceName     -- ^Service port to bind.
  -> Producer' B.ByteString m ()
fromServe nbytes hp port = do
   listen hp port $ \(lsock,_) -> do
      accept lsock $ \(csock,_) -> do
         fromSocket csock nbytes

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
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => HostPreference  -- ^Preferred host to bind.
  -> ServiceName     -- ^Service port to bind.
  -> Consumer' B.ByteString m r
toServe hp port = do
   listen hp port $ \(lsock,_) -> do
      accept lsock $ \(csock,_) -> do
         toSocket csock

--------------------------------------------------------------------------------

-- $exports
--
-- [From "Pipes.Network.TCP"]
--    'fromSocket',
--    'fromSocketN',
--    'fromSocketTimeout',
--    'fromSocketTimeoutN',
--    'toSocket',
--    'toSocketTimeout'.
--
-- [From "Network.Simple.TCP"]
--    'acceptFork',
--    'bindSock',
--    'connectSock',
--    'HostName',
--    'HostPreference'('HostAny','HostIPv4','HostIPv6','Host'),
--    'recv',
--    'send',
--    'ServiceName',
--    'SockAddr',
--    'Socket',
--    'withSocketsDo'.
--
-- [From "Pipes.Safe"]
--    'Ps.runSafeT'.

