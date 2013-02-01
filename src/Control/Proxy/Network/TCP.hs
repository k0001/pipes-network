{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types #-}

{-# OPTIONS_HADDOCK not-home, prune #-}

-- | Utilities to use TCP connections together with the @pipes@ and @pipes-safe@
-- libraries.

-- Some code in this file was adapted from the @network-conduit@ library by
-- Michael Snoyman. Copyright (c) 2011. See its licensing terms (BSD3) at:
--   https://github.com/snoyberg/conduit/blob/master/network-conduit/LICENSE


module Control.Proxy.Network.TCP (
   -- * Safe sockets usage
   -- $safe-socketing
   withClient,
   withServer,
   accept,
   acceptFork,
   socketP,
   socketC,
   -- * Low-level utils
   listen,
   connect,
   -- ** Unsafe sockets usage
   -- $unsafe-socketing
   withClientIO,
   withServerIO,
   acceptIO,
   acceptForkIO,
   socketPIO,
   socketCIO,
   -- * Settings
   HostPreference(..),
   ) where

import           Control.Concurrent                        (forkIO, ThreadId)
import qualified Control.Exception                         as E
import           Control.Monad
import           Control.Monad.Trans.Class
import qualified Control.Proxy                             as P
import           Control.Proxy.Network
import qualified Control.Proxy.Safe                        as P
import qualified Data.ByteString                           as B
import           Data.List                                 (partition)
import qualified Network.Socket                            as NS
import           Network.Socket.ByteString                 (sendAll, recv)


--------------------------------------------------------------------------------

-- $safe-socketing
--
-- 'Proxy's that properly handle finalization of 'NS.Socket's using
-- 'P.ExceptionP'.


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
-- If the remote peer closes its side of the connection, this proxy sends an
-- empty 'B.ByteString' downstream and then stops producing more values.
socketP
  :: P.Proxy p
  => Int                -- ^Maximum number of bytes to receive.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer (P.ExceptionP p) B.ByteString P.SafeIO ()
socketP nbytes sock () = loop where
    loop = do bs <- P.tryIO $ recv sock nbytes
              P.respond bs >> unless (B.null bs) loop


-- | Socket 'P.Consumer'. Sends bytes to a 'NS.Socket'.
socketC
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> () -> P.Consumer (P.ExceptionP p) B.ByteString P.SafeIO ()
socketC sock = P.foreverK $ loop where
    loop = P.request >=> P.tryIO . sendAll sock


--------------------------------------------------------------------------------

-- $unsafe-socketing
--
-- The following functions are similar than the safe proxies above, but they
-- don't properly handle 'NS.Socket's finalization within proxies using
-- 'P.ExceptionP'. They do, however, properly handle finalization within 'IO'.


-- | Start a TCP server and use it.
--
-- The listening socket is closed when done.
withServerIO
  :: HostPreference                -- ^Preferred host to bind to.
  -> Int                           -- ^Port number to bind to.
  -> ((NS.Socket, NS.SockAddr) -> IO r)
                                   -- ^Guarded computation taking the listening
                                   --  socket and the address it's bound to.
  -> IO r
withServerIO hp port =
    E.bracket bind close
  where
    bind = listen hp port
    close (s,_) = NS.sClose s


-- | Connect to a TCP server and use the connection.
--
-- The connection socket is closed when done.
withClientIO
  :: NS.HostName                   -- ^Server hostname.
  -> Int                           -- ^Server port number.
  -> ((NS.Socket, NS.SockAddr) -> IO r)
                                   -- ^Guarded computation taking the
                                   --  communication socket and the server
                                   --  address.
  -> IO r
withClientIO host port =
    E.bracket connect' close
  where
    connect' = connect host port
    close (s,_) = NS.sClose s


-- | Accept an incomming connection and use it.
--
-- The connection socket is closed when done.
acceptIO
  :: NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO b)
                                   -- ^Computation to run once an incomming
                                   --  connection is accepted. Takes the
                                   --  connection socket and remote end address.
  -> IO b
acceptIO lsock k = do
    conn@(csock,_) <- NS.accept lsock
    E.finally (k conn) (NS.sClose csock)


-- | Accept an incomming connection and use it on a different thread.
--
-- The connection socket is closed when done.
acceptForkIO
  :: NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                   -- ^Computatation to run on a different
                                   -- thread once an incomming connection is
                                   -- accepted. Takes the connection socket
                                   -- and remote end address.
  -> IO ThreadId
acceptForkIO lsock f = do
    client@(csock,_) <- NS.accept lsock
    forkIO $ E.finally (f client) (NS.sClose csock)


-- | Socket 'P.Producer'. Receives bytes from a 'NS.Socket'.
--
-- Less than the specified maximum number of bytes might be received.
--
-- If the remote peer closes its side of the connection, this proxy sends an
-- empty 'B.ByteString' downstream and then stops producing more values.
socketPIO
  :: P.Proxy p
  => Int                -- ^Maximum number of bytes to receive.
  -> NS.Socket          -- ^Connected socket.
  -> () -> P.Producer p B.ByteString IO ()
socketPIO nbytes sock () = P.runIdentityP loop where
    loop = do bs <- lift $ recv sock nbytes
              P.respond bs >> unless (B.null bs) loop


-- | Socket 'P.Consumer'. Sends bytes to a 'NS.Socket'.
socketCIO
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> () -> P.Consumer p B.ByteString IO ()
socketCIO sock = P.runIdentityK . P.foreverK $ loop where
    loop = P.request >=> lift . sendAll sock


--------------------------------------------------------------------------------

-- | Attempt to connect to the given host name and port number.
connect :: NS.HostName -> Int -> IO (NS.Socket, NS.SockAddr)
-- TODO Abstract away socket type.
connect host port = do
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host) (Just $ show port)
    E.bracketOnError (newSocket addr) NS.sClose $ \sock -> do
       let sockAddr = NS.addrAddress addr
       NS.connect sock sockAddr
       return (sock, sockAddr)
  where
    hints = NS.defaultHints { NS.addrFlags = [NS.AI_ADDRCONFIG]
                            , NS.addrSocketType = NS.Stream }


-- | Attempt to bind a listening 'NS.Socket' on the given host preference and
-- port number.
--
-- 'N.maxListenQueue' is tipically 128, which is too small for high performance
-- servers. So, we use the maximum between 'N.maxListenQueue' and 2048 as the
-- default size of the listening queue.
listen :: HostPreference -> Int -> IO (NS.Socket, NS.SockAddr)
-- TODO Abstract away socket type.
listen hp port = do
    addrs <- NS.getAddrInfo (Just hints) (hpHostName hp) (Just $ show port)
    let addrs' = case hp of
          HostIPv4 -> prioritize isIPv4addr addrs
          HostIPv6 -> prioritize isIPv6addr addrs
          _        -> addrs
    tryAddrs addrs'
  where
    hints = NS.defaultHints
      { NS.addrFlags = [NS.AI_PASSIVE, NS.AI_NUMERICSERV, NS.AI_NUMERICHOST]
      , NS.addrSocketType = NS.Stream }

    tryAddrs [x]    = useAddr x
    tryAddrs (x:xs) = E.catch (useAddr x) $ \(_ :: E.IOException) -> tryAddrs xs
    tryAddrs _      = error "listen: addrs is empty"

    useAddr addr = E.bracketOnError (newSocket addr) NS.sClose $ \sock -> do
      let sockAddr = NS.addrAddress addr
      NS.setSocketOption sock NS.NoDelay 1
      NS.setSocketOption sock NS.ReuseAddr 1
      NS.bindSocket sock sockAddr
      NS.listen sock (max 2048 NS.maxListenQueue)
      return (sock, sockAddr)


-- Misc

newSocket :: NS.AddrInfo -> IO NS.Socket
newSocket addr = NS.socket (NS.addrFamily addr)
                           (NS.addrSocketType addr)
                           (NS.addrProtocol addr)

isIPv4addr, isIPv6addr :: NS.AddrInfo -> Bool
isIPv4addr x = NS.addrFamily x == NS.AF_INET
isIPv6addr x = NS.addrFamily x == NS.AF_INET6

-- | Move the elements that match the predicate closer to the head of the list.
-- Preserve relative order.
prioritize :: (a -> Bool) -> [a] -> [a]
prioritize p = uncurry (++) . partition p

