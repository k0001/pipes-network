{-# LANGUAGE Rank2Types, TypeFamilies #-}

-- | This module exports facilities allowing you to safely obtain, use and
-- release 'NS.Socket' resources within a /Pipes/ pipeline, by relying on
-- @pipes-safe@.
--
-- This module is meant to be used together with "Pipes.Network.TCP", and as
-- such it overrides some functions from "Network.Simple.TCP" so that they use
-- 'Ps.MonadSafe' instead of 'IO' as their base monad. It also exports
-- 'Producer's and 'Consumer's that establish a TCP connection and interact
-- with it in a streaming fashion at once.
--
-- If you just want to use 'NS.Socket' obtained outside the /Pipes/ pipeline,
-- then you can just ignore this module and use the simpler functions exported
-- by "Pipes.Network.TCP" directly.

module Pipes.Network.TCP.Safe (
  -- * 'Ps.MonadSafe'-aware versions of some "Pipes.Network.TCP" functions
  -- ** Client side
    connect
  -- ** Server side
  , serve
  -- *** Listening
  , listen
  -- *** Accepting
  , accept
  , acceptFork

  -- * Streaming
  -- ** Client side
  -- $client-streaming
  , connectRead
  , connectWrite
  -- ** Server side
  -- $server-streaming
  , serveRead
  , serveWrite
  ) where

import           Control.Concurrent             (ThreadId)
import           Control.Monad
import           Control.Monad.IO.Class         (MonadIO(liftIO))
import qualified Data.ByteString                as B
import qualified Network.Socket                 as NS
import qualified Network.Simple.TCP             as S
import           Pipes
import qualified Pipes.Safe                     as Ps
import qualified Pipes.Network.TCP              as PNT

--------------------------------------------------------------------------------

-- | Like 'S.connect' from "Network.Simple.TCP", except using 'Ps.MonadSafe'.
connect
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => NS.HostName                   -- ^Server hostname.
  -> NS.ServiceName                -- ^Server service port.
  -> ((NS.Socket, NS.SockAddr) -> m r)
                                   -- ^Computation taking the
                                   -- communication socket and the server
                                   -- address.
  -> m r
connect host port = Ps.bracket (S.connectSock host port) (NS.sClose . fst)

--------------------------------------------------------------------------------

-- | Like 'S.serve' from "Network.Simple.TCP", except using 'Ps.MonadSafe'.
serve
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => S.HostPreference              -- ^Preferred host to bind.
  -> NS.ServiceName                -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                   -- ^Computation to run in a different thread
                                   -- once an incoming connection is accepted.
                                   -- Takes the connection socket and remote end
                                   -- address.
  -> m r
serve hp port k = do
   listen hp port $ \(lsock,_) -> do
      forever $ acceptFork lsock k

--------------------------------------------------------------------------------

-- | Like 'S.listen' from "Network.Simple.TCP", except using 'Ps.MonadSafe'.
listen
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => S.HostPreference              -- ^Preferred host to bind.
  -> NS.ServiceName                -- ^Service port to bind.
  -> ((NS.Socket, NS.SockAddr) -> m r)
                                   -- ^Computation taking the listening
                                   -- socket and the address it's bound to.
  -> m r
listen hp port = Ps.bracket listen' (NS.sClose . fst)
  where
    listen' = do x@(bsock,_) <- S.bindSock hp port
                 NS.listen bsock (max 2048 NS.maxListenQueue)
                 return x

--------------------------------------------------------------------------------

-- | Like 'S.accept' from "Network.Simple.TCP", except using 'Ps.MonadSafe'.
accept
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> m r)
                                   -- ^Computation to run once an incoming
                                   -- connection is accepted. Takes the
                                   -- connection socket and remote end address.
  -> m r
accept lsock k = do
    conn@(csock,_) <- liftIO (NS.accept lsock)
    Ps.finally (k conn) (NS.sClose csock)
{-# INLINABLE accept #-}

-- | Like 'S.acceptFork' from "Network.Simple.TCP", except using 'Ps.MonadSafe'.
acceptFork
  :: Ps.MonadSafe m
  => NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                  -- ^Computation to run in a different thread
                                  -- once an incoming connection is accepted.
                                  -- Takes the connection socket and remote end
                                  -- address.
  -> m ThreadId
acceptFork lsock k = liftIO (S.acceptFork lsock k)
{-# INLINE acceptFork #-}

--------------------------------------------------------------------------------

-- $client-streaming
--
-- The following proxies allow you to easily connect to a TCP server and
-- immediately interact with it in a streaming fashion, all at once, instead of
-- having to perform the individual steps separately.

--------------------------------------------------------------------------------

-- | Connect to a TCP server and send downstream the bytes received from the
-- remote end.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- prints whatever is received from a single TCP connection to a given server
-- listening locally on port 9000, in chunks of up to 4096 bytes:
--
-- >>> runSafeIO . runProxy . runEitherK $ connectRead Nothing 4096 "127.0.0.1" "9000" >-> tryK printD
connectRead
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => Int                -- ^Maximum number of bytes to receive and send
                        -- dowstream at once. Any positive value is fine, the
                        -- optimal value depends on how you deal with the
                        -- received data. Try using @4096@ if you don't care.
  -> NS.HostName        -- ^Server host name.
  -> NS.ServiceName     -- ^Server service port.
  -> Producer B.ByteString m ()
connectRead nbytes host port = do
   connect host port $ \(csock,_) -> do
      PNT.fromSocket csock nbytes

-- | Connects to a TCP server, sends to the remote end the bytes received from
-- upstream.
--
-- The connection socket is closed in case of exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- greets a TCP client listening locally at port 9000:
--
-- >>> :set -XOverloadedStrings
-- >>> runSafeIO . runProxy . runEitherK $ fromListS ["He","llo\r\n"] >-> connectWrite Nothing "127.0.0.1" "9000"
connectWrite
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => NS.HostName        -- ^Server host name.
  -> NS.ServiceName     -- ^Server service port.
  -> () -> Consumer B.ByteString m r
connectWrite hp port = \() -> do
   connect hp port $ \(csock,_) -> do
      PNT.toSocket csock

--------------------------------------------------------------------------------

-- $server-streaming
--
-- The following proxies allow you to easily run a TCP server and immediately
-- interact with incoming connections in a streaming fashion, all at once,
-- instead of having to perform the individual steps separately.

--------------------------------------------------------------------------------

-- | Binds a listening socket, accepts a single connection and sends downstream
-- any bytes received from the remote end.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- This proxy returns if the remote peer closes its side of the connection or
-- EOF is received.
--
-- Both the listening and connection sockets are closed when done or in case of
-- exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- prints whatever is received from a single TCP connection to port 9000, in
-- chunks of up to 4096 bytes.
--
-- >>> :set -XOverloadedStrings
-- >>> runSafeIO . runProxy . runEitherK $ serveRead Nothing 4096 "127.0.0.1" "9000" >-> tryK printD
serveRead
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => Int                -- ^Maximum number of bytes to receive and send
                        -- dowstream at once. Any positive value is fine, the
                        -- optimal value depends on how you deal with the
                        -- received data. Try using @4096@ if you don't care.
  -> S.HostPreference   -- ^Preferred host to bind.
  -> NS.ServiceName     -- ^Service port to bind.
  -> () -> Producer B.ByteString m ()
serveRead nbytes hp port () = do
   listen hp port $ \(lsock,_) -> do
      accept lsock $ \(csock,_) -> do
         PNT.fromSocket csock nbytes

-- | Binds a listening socket, accepts a single connection, sends to the remote
-- end the bytes received from upstream.
--
-- Both the listening and connection sockets are closed when done or in case of
-- exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- greets a TCP client connecting to port 9000:
--
-- >>> :set -XOverloadedStrings
-- >>> runSafeIO . runProxy . runEitherK $ fromListS ["He","llo\r\n"] >-> serveWrite Nothing "127.0.0.1" "9000"
serveWrite
  :: (Ps.MonadSafe m, Ps.Base m ~ IO)
  => S.HostPreference   -- ^Preferred host to bind.
  -> NS.ServiceName     -- ^Service port to bind.
  -> () -> Consumer B.ByteString m r
serveWrite hp port = \() -> do
   listen hp port $ \(lsock,_) -> do
      accept lsock $ \(csock,_) -> do
         PNT.toSocket csock


