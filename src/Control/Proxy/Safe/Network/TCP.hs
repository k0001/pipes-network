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
  -- * Server side
  -- $server-side
  withServer,
  accept,
  acceptFork,
  -- ** Quick one-time servers
  serverP,
  serverC,
  serverS,
  -- * Client side
  -- $client-side
  withClient,
  -- ** Quick one-time clients
  clientP,
  clientC,
  clientS,
  -- * Socket proxies
  -- $socket-proxies
  socketP,
  socketC,
  socketS,
  -- * Low level support
  -- $low-level
  listen,
  connect,
  close,
  -- * Exports
  HostPreference(..)
  ) where

import           Control.Concurrent                        (forkIO, ThreadId)
import qualified Control.Exception                         as E
import           Control.Monad
import qualified Control.Proxy                             as P
import           Control.Proxy.Network
import qualified Control.Proxy.Network.TCP                 as T
import qualified Control.Proxy.Safe                        as P
import qualified Data.ByteString                           as B
import qualified Network.Socket                            as NS
import           Network.Socket.ByteString                 (sendAll, recv)


--------------------------------------------------------------------------------

-- $client-side
--
-- The following functions allow you to obtain 'NS.Socket's useful to the
-- client side of a TCP connection.


-- | Connect to a TCP server and use the connection.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- If you would like to close the socket yourself, then use the 'connect' and
-- 'close' instead.
withClient
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.HostName                   -- ^Server hostname.
  -> NS.ServiceName                -- ^Server service name (port).
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Guarded computation taking the
                                   --  communication socket and the server
                                   --  address.
  -> P.ExceptionP p a' a b' b m r
withClient morph host port =
    P.bracket morph connect' close'
  where
    connect' = T.connect host port
    close' (s,_) = NS.sClose s


--------------------------------------------------------------------------------

-- | Connect to a TCP server and send downstream the bytes received from the
-- remote end.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- prints whatever is received from a single TCP connection to a given server
-- listening locally on port 9000:
--
-- > let session = clientP "127.0.0.1" "9000" >-> tryK printD
-- > runSafeIO . runProxy . runEitherK $ session
clientP
  :: P.Proxy p
  => Int                         -- ^Maximum number of bytes to receive at once.
  -> NS.HostName                 -- ^Server host name.
  -> NS.ServiceName              -- ^Server service name (port).
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
clientP nbytes host port () = do
   withClient id host port $ \(csock,_) -> do
     socketP nbytes csock ()


-- | Connect to a TCP server and send to the remote end the bytes received from
-- upstream.
--
-- The connection socket is closed when done or in case of exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- greets a TCP client listening locally at port 9000:
--
-- > let session = fromListS ["He","llo\r\n"] >-> clientC "127.0.0.1" "9000"
-- > runSafeIO . runProxy . runEitherK $ session
clientC
  :: P.Proxy p
  => NS.HostName                 -- ^Server host name.
  -> NS.ServiceName              -- ^Server service name (port).
  -> () -> P.Consumer (P.ExceptionP p) B.ByteString P.SafeIO ()
clientC hp port () = do
   withClient id hp port $ \(csock,_) ->
     socketC csock ()


-- | Connect to a TCP server and optionally send to the remote end any bytes
-- received from downstream, and then send downstream the bytes received from
-- the remote end.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
--
-- Both the listening and connection socket are closed when done or in case of
-- exceptions.
clientS
  :: P.Proxy p
  => Int                         -- ^Maximum number of bytes to receive at once.
  -> NS.HostName                 -- ^Server host name.
  -> NS.ServiceName              -- ^Server service name (port).
  -> Maybe B.ByteString
  -> P.Server (P.ExceptionP p) (Maybe B.ByteString) B.ByteString P.SafeIO ()
clientS nbytes host port b' = do
   withClient id host port $ \(csock,_) -> do
     socketS nbytes csock b'

--------------------------------------------------------------------------------

-- $server-side
--
-- The following functions allow you to obtain 'NS.Socket's useful to the
-- server side of a TCP connection.

-- | Start a TCP server and use it.
--
-- The listening socket is closed when done or in case of exceptions.
--
-- If you would like to close the socket yourself, then use the 'listen' and
-- 'close' instead.
withServer
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> HostPreference                -- ^Preferred host to bind to.
  -> NS.ServiceName                -- ^Service name (port) to bind to.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Guarded computation taking the listening
                                   --  socket and the address it's bound to.
  -> P.ExceptionP p a' a b' b m r
withServer morph hp port =
    P.bracket morph bind close'
  where
    bind = T.listen hp port
    close' (s,_) = NS.sClose s


-- | Accept an incomming connection and use it.
--
-- The connection socket is closed when done or in case of exceptions.
accept
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b m r)
                                   -- ^Computation to run once an incomming
                                   --  connection is accepted. Takes the
                                   --  connection socket and remote end address.
  -> P.ExceptionP p a' a b' b m r
accept morph lsock k = do
    conn@(csock,_) <- P.hoist morph . P.tryIO $ NS.accept lsock
    P.finally morph (NS.sClose csock) (k conn)


-- | Accept an incomming connection and use it on a different thread.
--
-- The connection socket is closed when done or in case of exceptions.
acceptFork
  :: (P.Proxy p, Monad m)
  => (forall x. P.SafeIO x -> m x) -- ^Monad morphism.
  -> NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                   -- ^Computatation to run on a different
                                   --  thread once an incomming connection is
                                   --  accepted. Takes the connection socket
                                   --  and remote end address.
  -> P.ExceptionP p a' a b' b m ThreadId
acceptFork morph lsock f = P.hoist morph . P.tryIO $ do
    client@(csock,_) <- NS.accept lsock
    forkIO $ E.finally (f client) (NS.sClose csock)


--------------------------------------------------------------------------------

-- | Bind a listening socket and accept a single connection, sending downstream
-- the bytes received from the remote end.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
--
-- Both the listening and connection socket are closed when done or in case of
-- exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- prints whatever is received from a single TCP connection to port 9000:
--
-- > let session = serverP 4096 "127.0.0.1" "9000" >-> tryK printD
-- > runSafeIO . runProxy . runEitherK $ session
serverP
  :: P.Proxy p
  => Int                         -- ^Maximum number of bytes to receive at once.
  -> HostPreference              -- ^Preferred host to bind to.
  -> NS.ServiceName              -- ^Service name (port) to bind to.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
serverP nbytes hp port () = do
   withServer id hp port $ \(lsock,_) -> do
     accept id lsock $ \(csock,_) -> do
       socketP nbytes csock ()


-- | Bind a listening socket and accept a single connection, sending to the
-- remote end the bytes received from upstream.
--
-- Both the listening and connection socket are closed when done or in case of
-- exceptions.
--
-- Using this proxy you can write straightforward code like the following, which
-- greets a TCP client connecting to port 9000:
--
-- > let session = fromListS ["He","llo\r\n"] >-> serverC "127.0.0.1" "9000"
-- > runSafeIO . runProxy . runEitherK $ session
serverC
  :: P.Proxy p
  => HostPreference                -- ^Preferred host to bind to.
  -> NS.ServiceName                -- ^Service name (port) to bind to.
  -> () -> P.Consumer (P.ExceptionP p) B.ByteString P.SafeIO ()
serverC hp port () = do
   withServer id hp port $ \(lsock,_) -> do
     accept id lsock $ \(csock,_) -> do
       socketC csock ()


-- | Bind a listening socket and accept a single connection, optionally sending
-- to the remote end any bytes received from downstream, and then sending
-- downstream the bytes received from the remote end.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
--
-- Both the listening and connection socket are closed when done or in case of
-- exceptions.
serverS
  :: P.Proxy p
  => Int
  -> HostPreference
  -> NS.ServiceName
  -> Maybe B.ByteString
  -> P.Server (P.ExceptionP p) (Maybe B.ByteString) B.ByteString P.SafeIO ()
serverS nbytes hp port b' = do
   withServer id hp port $ \(lsock,_) -> do
     accept id lsock $ \(csock,_) -> do
       socketS nbytes csock b'


--------------------------------------------------------------------------------

-- $socket-proxies
--
-- Once you have a connected 'NS.Socket', you can use the following 'P.Proxy's
-- to send to and receive from the other connection end.


-- | Socket proxy 'P.Producer'. Receives bytes from the 'NS.Socket' remote end
-- and sends them downstream.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
socketP
  :: P.Proxy p
  => Int                -- ^Maximum number of bytes to receive at once.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
socketP nbytes sock () = loop where
    loop = do bs <- P.tryIO $ recv sock nbytes
              unless (B.null bs) $ P.respond bs >> loop


-- | Socket proxy 'P.Consumer'. Sends to a the 'NS.Socket' remote end the bytes
-- received from upstream.
socketC
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> () -> P.Consumer (P.ExceptionP p) B.ByteString P.SafeIO r
socketC sock = P.foreverK $ loop where
    loop = P.request >=> P.tryIO . sendAll sock


-- | Socket proxy 'P.Server' (do not confuse with a TCP server).
--
-- If a 'Just' value is received from downstream, then send such value to
-- the 'NS.Socket' remote end, and finally, receive bytes from the remote end
-- and send them downstream.
--
-- If 'Nothing' is received from downstream, then only receive bytes from the
-- remote end and send them downstream.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- If the remote peer closes its side of the connection, this proxy returns.
socketS
  :: P.Proxy p
  => Int                -- ^Maximum number of bytes to receive at once.
  -> NS.Socket          -- ^Connected socket.
  -> Maybe B.ByteString
  -> P.Server (P.ExceptionP p) (Maybe B.ByteString) B.ByteString P.SafeIO ()
socketS nbytes sock = loop where
    loop Nothing   = recv'
    loop (Just b') = send' b' >> recv'
    send' = P.tryIO . sendAll sock
    recv' = do bs <- P.tryIO $ recv sock nbytes
               unless (B.null bs) $ P.respond bs >>= loop


--------------------------------------------------------------------------------

-- $low-level
--
-- The following functions are provided for your convenience. They simply
-- compose 'P.tryIO' with their "Control.Proxy.Network.TCP" counterparts, so
-- that you don't need to do it.


-- | Attempt to connect to the given host name and service name (port).
--
-- The obtained 'NS.Socket' should be closed manually using 'close' when it's
-- not needed anymore, otherwise it will remain open.
--
-- Prefer to use 'withClient' if you will be using the socket within a limited
-- scope and would like it to be closed immediately after its usage, or in case
-- of exceptions.
--
-- > connect host port = tryIO $ Control.Proxy.Network.TCP.connect host port
connect
  :: P.Proxy p
  => NS.HostName                   -- ^Server hostname.
  -> NS.ServiceName                -- ^Server service name (port).
  -> P.ExceptionP p a' a b' b P.SafeIO (NS.Socket, NS.SockAddr)
connect host port = P.tryIO $ T.connect host port


-- | Attempt to bind a listening 'NS.Socket' on the given host preference and
-- service port.
--
-- The obtained 'NS.Socket' should be closed manually using 'close' when it's
-- not needed anymore, otherwise it will remain open.
--
-- Prefer to use 'withServer' if you will be using the socket within a limited
-- scope and would like it to be closed immediately after its usage, or in case
-- of exceptions.
--
-- 'N.maxListenQueue' is tipically 128, which is too small for high performance
-- servers. So, we use the maximum between 'N.maxListenQueue' and 2048 as the
-- default size of the listening queue.
--
-- > listen hp port = tryIO $ Control.Proxy.Network.TCP.listen hp port
listen
  :: P.Proxy p
  => HostPreference                -- ^Preferred host to bind to.
  -> NS.ServiceName                -- ^Service name (port) to bind to.
  -> P.ExceptionP p a' a b' b P.SafeIO (NS.Socket, NS.SockAddr)
listen hp port = P.tryIO $ T.listen hp port

-- | Close the socket. All future operations on the socket object will fail. The
-- remote end will receive no more data (after queued data is flushed).
--
-- > close sock = tryIO $ Control.Proxy.Network.TCP.close sock
close :: P.Proxy p => NS.Socket -> P.ExceptionP p a' a b' b P.SafeIO ()
close = P.tryIO . T.close


