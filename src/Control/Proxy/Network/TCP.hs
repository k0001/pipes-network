{-# LANGUAGE Rank2Types #-}
{-# OPTIONS_HADDOCK prune #-}

-- | This module exports functions that allow you safely use 'NS.Socket'
-- resources acquired and release outside a 'P.Proxy' pipeline.
--
-- Instead, if want to safely acquire and release resources within a 'P.Proxy'
-- pipeline, then you should use the similar functions exported by
-- "Control.Proxy.Safe.Network.TCP".

-- Some code in this file was adapted from the @network-conduit@ library by
-- Michael Snoyman. Copyright (c) 2011. See its licensing terms (BSD3) at:
--   https://github.com/snoyberg/conduit/blob/master/network-conduit/LICENSE


module Control.Proxy.Network.TCP (
  -- * Socket proxies
  socketP,
  socketC,
  -- * Server side
  withServer,
  accept,
  acceptFork,
  -- * Client side
  withClient,
  -- * Low level support
  listen,
  connect,
  close,
  -- * Exports
  HostPreference(..)
  ) where

import           Control.Concurrent (ThreadId, forkIO)
import qualified Control.Exception as E
import           Control.Monad
import           Control.Monad.Trans.Class
import qualified Control.Proxy as P
import           Control.Proxy.Network
import qualified Data.ByteString as B
import           Data.List (partition)
import qualified Network.Socket as NS
import           Network.Socket.ByteString (recv, sendAll)


-- | Start a TCP server and use it.
--
-- The listening socket is closed when done.
withServer
  :: HostPreference                -- ^Preferred host to bind to.
  -> NS.ServiceName                -- ^Service name (port) to bind to.
  -> ((NS.Socket, NS.SockAddr) -> IO r)
                                   -- ^Guarded computation taking the listening
                                   --  socket and the address it's bound to.
  -> IO r
withServer hp port =
    E.bracket bind close'
  where
    bind = listen hp port
    close' (s,_) = NS.sClose s


-- | Connect to a TCP server and use the connection.
--
-- The connection socket is closed when done.
withClient
  :: NS.HostName                   -- ^Server hostname.
  -> NS.ServiceName                -- ^Server service name (port).
  -> ((NS.Socket, NS.SockAddr) -> IO r)
                                   -- ^Guarded computation taking the
                                   --  communication socket and the server
                                   --  address.
  -> IO r
withClient host port =
    E.bracket connect' close'
  where
    connect' = connect host port
    close' (s,_) = NS.sClose s


-- | Accept an incomming connection and use it.
--
-- The connection socket is closed when done.
accept
  :: NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO b)
                                   -- ^Computation to run once an incomming
                                   --  connection is accepted. Takes the
                                   --  connection socket and remote end address.
  -> IO b
accept lsock k = do
    conn@(csock,_) <- NS.accept lsock
    E.finally (k conn) (NS.sClose csock)


-- | Accept an incomming connection and use it on a different thread.
--
-- The connection socket is closed when done.
acceptFork
  :: NS.Socket                     -- ^Listening and bound socket.
  -> ((NS.Socket, NS.SockAddr) -> IO ())
                                   -- ^Computatation to run on a different
                                   -- thread once an incomming connection is
                                   -- accepted. Takes the connection socket
                                   -- and remote end address.
  -> IO ThreadId
acceptFork lsock f = do
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
  -> () -> P.Producer p B.ByteString IO ()
socketP nbytes sock () = P.runIdentityP loop where
    loop = do bs <- lift $ recv sock nbytes
              unless (B.null bs) $ P.respond bs >> loop


-- | Socket 'P.Consumer'. Sends bytes to a 'NS.Socket'.
socketC
  :: P.Proxy p
  => NS.Socket          -- ^Connected socket.
  -> () -> P.Consumer p B.ByteString IO ()
socketC sock = P.runIdentityK . P.foreverK $ loop where
    loop = P.request >=> lift . sendAll sock


--------------------------------------------------------------------------------

-- | Attempt to connect to the given host name and service name (port).
--
-- The obtained 'NS.Socket' should be closed manually using 'close' when it's
-- not needed anymore, otherwise it will remain open.
--
-- Prefer to use 'withClient' if you will be using the socket within a limited
-- scope and would like it to be closed immediately after its usage.
connect :: NS.HostName -> NS.ServiceName -> IO (NS.Socket, NS.SockAddr)
-- TODO Abstract away socket type.
connect host port = do
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host) (Just port)
    E.bracketOnError (newSocket addr) NS.sClose $ \sock -> do
       let sockAddr = NS.addrAddress addr
       NS.connect sock sockAddr
       return (sock, sockAddr)
  where
    hints = NS.defaultHints { NS.addrFlags = [NS.AI_ADDRCONFIG]
                            , NS.addrSocketType = NS.Stream }


-- | Attempt to bind a listening 'NS.Socket' on the given host preference and
-- service port.
--
-- The obtained 'NS.Socket' should be closed manually using 'close' when it's
-- not needed anymore, otherwise it will remain open.
--
-- Prefer to use 'withServer' if you will be using the socket within a limited
-- scope and would like it to be closed immediately after its usage.
--
-- 'N.maxListenQueue' is tipically 128, which is too small for high performance
-- servers. So, we use the maximum between 'N.maxListenQueue' and 2048 as the
-- default size of the listening queue.
listen :: HostPreference -> NS.ServiceName -> IO (NS.Socket, NS.SockAddr)
listen hp port = do
    addrs <- NS.getAddrInfo (Just hints) (hpHostName hp) (Just $ show port)
    let addrs' = case hp of
          HostIPv4 -> prioritize isIPv4addr addrs
          HostIPv6 -> prioritize isIPv6addr addrs
          _        -> addrs
    tryAddrs addrs'
  where
    hints = NS.defaultHints { NS.addrFlags = [NS.AI_PASSIVE]
                            , NS.addrSocketType = NS.Stream }

    tryAddrs [x]    = useAddr x
    tryAddrs (x:xs) = E.catch (useAddr x)
                              (\e -> let _ = e :: E.IOException in tryAddrs xs)
    tryAddrs _      = error "listen: addrs is empty"

    useAddr addr = E.bracketOnError (newSocket addr) NS.sClose $ \sock -> do
      let sockAddr = NS.addrAddress addr
      NS.setSocketOption sock NS.NoDelay 1
      NS.setSocketOption sock NS.ReuseAddr 1
      NS.bindSocket sock sockAddr
      NS.listen sock (max 2048 NS.maxListenQueue)
      return (sock, sockAddr)


-- | Close the socket. All future operations on the socket object will fail. The
-- remote end will receive no more data (after queued data is flushed).
close :: NS.Socket -> IO ()
close = NS.sClose


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
