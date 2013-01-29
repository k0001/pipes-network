{-# LANGUAGE ScopedTypeVariables #-}

module Control.Proxy.Network.TCP (
   -- * Settings
   ServerSettings(..),
   ClientSettings(..),
   -- * Socket proxies
   socketP,
   socketC,
   -- * Safe socket usage
   withClient,
   withServer,
   accept,
   acceptFork,
   -- * Low level API
   listen,
   connect,
   ) where

import           Control.Concurrent                        (forkIO, ThreadId)
import qualified Control.Exception                         as E
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.IO.Class
import qualified Control.Proxy                             as P
import qualified Control.Proxy.Safe                        as P
import qualified Data.ByteString                           as B
import qualified Network.Socket                            as NS
import           Network.Socket.ByteString                 (sendAll, recv)



-- | Settings for a TCP server.
--
-- TODO IPv6 stuff.
-- TODO Named ports.
data ServerSettings = ServerSettings
    { serverHost :: Maybe NS.HostName
                    -- ^ Host to bind to. 'Nothing' indicates no preference
    , serverPort :: Int
                    -- ^ Port to bind to.
    } deriving (Eq, Show)


-- | Settings for a TCP client.
--
-- TODO IPv6 stuff.
-- TODO Named ports.
data ClientSettings = ClientSettings
    { clientHost :: NS.HostName -- ^ Remote server host.
    , clientPort :: Int         -- ^ Remote server port.
    } deriving (Eq, Show)


--------------------------------------------------------------------------------

-- | Start a TCP client and run the given continuation, which takes the
-- connection socket and the other endpoint's address.
--
-- The connection socket is safely closed when done.
withClient
  :: P.Proxy p
  => ClientSettings
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b P.SafeIO r)
  -> P.ExceptionP p a' a b' b P.SafeIO r
-- TODO: check wether this type makes more sense:
-- withClient
--   :: P.Proxy p
--   => ClientSettings
--   -> ((NS.Socket, NS.SockAddr) -> b' -> P.ExceptionP p a' a b' b P.SafeIO r)
--   -> b' -> P.ExceptionP p a' a b' b P.SafeIO r
withClient (ClientSettings host port) =
    P.bracket id connect' close
  where
    connect' = connect host port
    close (s,_) = NS.sClose s


-- | Start a TCP server and run the given continuation, which takes the
-- listening socket and the bound address.
--
-- The listening socket is safely closed when done.
withServer
  :: P.Proxy p
  => ServerSettings
  -> ((NS.Socket, NS.SockAddr) -> P.ExceptionP p a' a b' b P.SafeIO r)
  -> P.ExceptionP p a' a b' b P.SafeIO r
-- TODO: check wether this type makes more sense:
-- withServer
--   :: P.Proxy p
--   => ServerSettings
--   -> ((NS.Socket, NS.SockAddr) -> b' -> P.ExceptionP p a' a b' b P.SafeIO r)
--   -> b' -> P.ExceptionP p a' a b' b P.SafeIO r
withServer (ServerSettings host port) =
    P.bracket id bind close
  where
    bind = listen host port
    close (s,_) = NS.sClose s


--------------------------------------------------------------------------------

-- | Socket Producer. Stream data from the socket.
socketP :: (P.Proxy p, MonadIO m)
             => Int -> NS.Socket -> () -> P.Producer p B.ByteString m ()
socketP bufsize socket () = P.runIdentityP loop
  where loop = do bs <- lift . liftIO $ recv socket bufsize
                  unless (B.null bs) $ P.respond bs >> loop


-- | Socket Consumer. Stream data to the socket.
socketC :: (P.Proxy p, MonadIO m)
             => NS.Socket -> () -> P.Consumer p B.ByteString m ()
socketC socket = P.runIdentityK . P.foreverK $ loop
  where loop = P.request >=> lift . liftIO . sendAll socket


--------------------------------------------------------------------------------

-- | Accept a connection and run an action on the resulting connection socket
-- and remote address pair, safely closing the connection socket when done. The
-- given socket must be bound to an address and listening for connections.
accept :: NS.Socket -> ((NS.Socket, NS.SockAddr) -> IO b) -> IO b
accept listeningSock f = do
    client@(cSock,_) <- NS.accept listeningSock
    E.finally (f client) (NS.sClose cSock)


-- | Accept a connection and, on a different thread, run an action on the
-- resulting connection socket and remote address pair, safely closing the
-- connection socket when done. The given socket must be bound to an address and
-- listening for connections.
acceptFork :: NS.Socket -> ((NS.Socket, NS.SockAddr) -> IO ()) -> IO ThreadId
acceptFork listeningSock f = do
    client@(cSock,_) <- NS.accept listeningSock
    forkIO $ E.finally (f client) (NS.sClose cSock)


--------------------------------------------------------------------------------

-- | Attempt to connect to the given host/port.
connect :: NS.HostName -> Int -> IO (NS.Socket, NS.SockAddr)
-- TODO Abstract away socket type.
connect host port = do
    let hints = NS.defaultHints {
                          NS.addrFlags = [NS.AI_ADDRCONFIG]
                        , NS.addrSocketType = NS.Stream
                        }
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host) (Just $ show port)
    E.bracketOnError
      (NS.socket (NS.addrFamily addr)
                 (NS.addrSocketType addr)
                 (NS.addrProtocol addr))
      NS.sClose
      (\sock -> do let sockAddr = NS.addrAddress addr
                   NS.connect sock sockAddr
                   return (sock, sockAddr))



-- | Attempt to bind a listening @Socket@ on the given host and port.
-- If no explicit host is given, will use the first address available.
listen :: Maybe NS.HostName -> Int -> IO (NS.Socket, NS.SockAddr)
-- TODO Abstract away socket type.
listen host port = do
    let hints = NS.defaultHints
            { NS.addrFlags =
                [ NS.AI_PASSIVE
                , NS.AI_NUMERICSERV
                , NS.AI_NUMERICHOST
                ]
            , NS.addrSocketType = NS.Stream
            }
        port' = Just . show $ port
    addrs <- NS.getAddrInfo (Just hints) host port'
    let
        tryAddrs (addr1:rest@(_:_)) = E.catch
                                      (theBody addr1)
                                      (\(_ :: E.IOException) -> tryAddrs rest)
        tryAddrs (addr1:[])         = theBody addr1
        tryAddrs _                  = error "listen: addrs is empty"
        theBody addr =
          E.bracketOnError
          (NS.socket
            (NS.addrFamily addr)
            (NS.addrSocketType addr)
            (NS.addrProtocol addr))
          NS.sClose
          (\sock -> do
              let sockAddr = NS.addrAddress addr
              NS.setSocketOption sock NS.ReuseAddr 1
              NS.bindSocket sock sockAddr
              NS.listen sock NS.maxListenQueue
              return (sock, sockAddr)
          )
    tryAddrs addrs

