{-# LANGUAGE Rank2Types #-}
{-# OPTIONS_HADDOCK prune #-}

-- | This module exports functions that allow you safely use 'NS.Socket'
-- resources acquired and release within a 'P.Proxy' pipeline, using the
-- facilities provided by the @pipes-safe@ library.
--
-- Instead, if want to just want to safely acquire and release resources outside
-- a 'P.Proxy' pipeline, then you should use the similar functions exported by
-- "Control.Proxy.Network.TCP".


module Control.Proxy.Safe.Network.TCP (
  -- * Socket proxies
  socketP,
  socketC,
  -- * Server side
  withServer,
  accept,
  acceptFork,
  -- * Client side
  withClient,
  -- * Exports
  HostPreference(..)
  ) where

import           Control.Concurrent                        (forkIO, ThreadId)
import qualified Control.Exception                         as E
import           Control.Monad
import qualified Control.Proxy                             as P
import           Control.Proxy.Network
import           Control.Proxy.Network.TCP                 (listen, connect)
import qualified Control.Proxy.Safe                        as P
import qualified Data.ByteString                           as B
import qualified Network.Socket                            as NS
import           Network.Socket.ByteString                 (sendAll, recv)



-- | Connect to a TCP server and use the connection.
--
-- The connection socket is closed when done.
withClient
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.HostName                   -- ^Server hostname.
  -> Int                           -- ^Server port number.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Guarded computation taking the
                                   --  communication socket and the server
                                   --  address.
  -> P.ExceptionP p a' a b' b m r
withClient morph host port =
    P.bracket morph connect' close
  where
    connect' = connect host port
    close (s,_) = NS.sClose s


-- | Start a TCP server and use it.
--
-- The listening socket is closed when done.
withServer
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> HostPreference                -- ^Preferred host to bind to.
  -> Int                           -- ^Port number to bind to.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Guarded computation taking the listening
                                   --  socket and the address it's bound to.
  -> P.ExceptionP p a' a b' b m r
withServer morph hp port =
    P.bracket morph bind close
  where
    bind = listen hp port
    close (s,_) = NS.sClose s


-- | Accept an incomming connection and use it.
--
-- The connection socket is closed when done.
accept
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Computation to run once an incomming
                                   --  connection is accepted. Takes the
                                   --  connection socket and remote end address.
  -> P.EitherP P.SomeException p a' a b' b m r
accept morph lsock k = do
    conn@(csock,_) <- P.hoist morph . P.tryIO $ NS.accept lsock
    P.finally morph (NS.sClose csock) (k conn)


-- | Accept an incomming connection and use it on a different thread.
--
-- The connection socket is closed when done.
acceptFork
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                   -- ^Computatation to run on a different
                                   --  thread once an incomming connection is
                                   --  accepted. Takes the connection socket
                                   --  and remote end address.
  -> P.EitherP P.SomeException p a' a b' b m ThreadId
acceptFork morph lsock f = P.hoist morph . P.tryIO $ do
    client@(csock,_) <- NS.accept lsock
    forkIO $ E.finally (f client) (NS.sClose csock)


-- | Socket 'P.Producer'. Receives bytes from a 'NS.Socket'.
--
-- Less than the specified maximum number of bytes might be received.
--
-- If the remote peer closes its side of the connection, this proxy stops
-- producing.
socketP
  :: P.Proxy p
  => Int                -- ^Maximum number of bytes to receive.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
socketP nbytes sock () = loop where
    loop = do bs <- P.tryIO $ recv sock nbytes
              unless (B.null bs) $ P.respond bs >> loop


-- | Socket 'P.Consumer'. Sends bytes to a 'NS.Socket'.
socketC
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> () -> P.Consumer (P.ExceptionP p) B.ByteString P.SafeIO ()
socketC sock = P.foreverK $ loop where
    loop = P.request >=> P.tryIO . sendAll sock


