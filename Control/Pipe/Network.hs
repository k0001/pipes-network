{-# LANGUAGE ScopedTypeVariables #-}
module Control.Pipe.Network (
  Application,
  socketReader,
  socketWriter,
  ServerSettings(..),
  runTCPServer,
  ClientSettings(..),
  runTCPClient,
  ) where

import qualified Network.Socket as NS
import Network.Socket (Socket)
import Network.Socket.ByteString (sendAll, recv)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Control.Concurrent (forkIO)
import Control.Exception (bracketOnError, IOException, bracket, finally)
import Control.Monad (forever)
import Control.Monad.Trans (MonadIO, lift, liftIO)
import Control.Pipe

-- adapted from conduit

-- | Stream data from the socket.
socketReader :: MonadIO m => Socket -> Pipe x ByteString m ()
socketReader socket = go
  where
    go = do
      bs <- lift . liftIO $ recv socket 4096
      if B.null bs
        then return ()
        else yield bs >> go

-- | Stream data to the socket.
socketWriter :: MonadIO m => Socket -> Consumer ByteString m r
socketWriter socket = forever $ await >>= lift . liftIO . sendAll socket

-- | A simple TCP application. It takes two arguments: the 'Producer' to read
-- input data from, and the 'Consumer' to send output data to.
type Application m r = Producer ByteString m ()
                    -> Consumer ByteString m ()
                    -> IO r

-- | Settings for a TCP server. It takes a port to listen on, and an optional
-- hostname to bind to.
data ServerSettings = ServerSettings
    { serverPort :: Int
    , serverHost :: Maybe String -- ^ 'Nothing' indicates no preference
    }

-- | Run an @Application@ with the given settings. This function will create a
-- new listening socket, accept connections on it, and spawn a new thread for
-- each connection.
runTCPServer :: MonadIO m => ServerSettings -> Application m r -> IO r
runTCPServer (ServerSettings port host) app = bracket
    (bindPort host port)
    NS.sClose
    (forever . serve)
  where
    serve lsocket = do
      (socket, _addr) <- NS.accept lsocket
      forkIO $ do
        finally
          (app (socketReader socket) (socketWriter socket))
          (NS.sClose socket)
        return ()

-- | Settings for a TCP client, specifying how to connect to the server.
data ClientSettings = ClientSettings
    { clientPort :: Int
    , clientHost :: String
    }

-- | Run an 'Application' by connecting to the specified server.
runTCPClient :: MonadIO m => ClientSettings -> Application m r -> IO r
runTCPClient (ClientSettings port host) app = bracket
    (getSocket host port)
    NS.sClose
    (\s -> app (socketReader s) (socketWriter s))

-- | Attempt to connect to the given host/port.
getSocket :: String -> Int -> IO NS.Socket
getSocket host' port' = do
    let hints = NS.defaultHints {
                          NS.addrFlags = [NS.AI_ADDRCONFIG]
                        , NS.addrSocketType = NS.Stream
                        }
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host') (Just $ show port')
    bracketOnError
      (NS.socket (NS.addrFamily addr)
                 (NS.addrSocketType addr)
                 (NS.addrProtocol addr))
      NS.sClose
      (\sock -> NS.connect sock (NS.addrAddress addr) >> return sock)

-- | Attempt to bind a listening @Socket@ on the given host/port. If no host is
-- given, will use the first address available.
bindPort :: Maybe String -> Int -> IO Socket
bindPort host p = do
    let hints = NS.defaultHints
            { NS.addrFlags =
                [ NS.AI_PASSIVE
                , NS.AI_NUMERICSERV
                , NS.AI_NUMERICHOST
                ]
            , NS.addrSocketType = NS.Stream
            }
        port = Just . show $ p
    addrs <- NS.getAddrInfo (Just hints) host port
    let
        tryAddrs (addr1:rest@(_:_)) =
                                      catch
                                      (theBody addr1)
                                      (\(_ :: IOException) -> tryAddrs rest)
        tryAddrs (addr1:[])         = theBody addr1
        tryAddrs _                  = error "bindPort: addrs is empty"
        theBody addr =
          bracketOnError
          (NS.socket
            (NS.addrFamily addr)
            (NS.addrSocketType addr)
            (NS.addrProtocol addr))
          NS.sClose
          (\sock -> do
              NS.setSocketOption sock NS.ReuseAddr 1
              NS.bindSocket sock (NS.addrAddress addr)
              NS.listen sock NS.maxListenQueue
              return sock
          )
    tryAddrs addrs
