{-# LANGUAGE KindSignatures #-}

-- | This module exports an API for simple TCP applications in which the entire
-- life-cycle of a TCP server or client runs as a single IO action.

module Control.Proxy.Network.TCP.Simple (
   -- * Simple TCP Application API
   Application,
   -- ** Client side
   runClient,
   -- ** Server side
   runServer,
   ) where

import qualified Control.Exception         as E
import           Control.Monad             (forever, void)
import qualified Control.Proxy             as P
import qualified Control.Proxy.Network.TCP as PNT
import qualified Data.ByteString           as B
import qualified Network.Socket            as NS


-- | A simple TCP application in which the entire life-cycle of a TCP server or
-- client runs as a single 'IO' action.
--
-- It takes a continuation that recieves the other connection endpoint address,
-- a 'Producer' to read input data from and a 'Consumer' to send output data to.
type Application (p :: * -> * -> * -> * -> (* -> *) -> * -> *) r
  = NS.SockAddr
  -> (() -> P.Producer p B.ByteString IO (),
      () -> P.Consumer p B.ByteString IO ())
  -> IO r


-- | Run a TCP 'Application' by connecting to the specified server.
--
-- This function will connect to a TCP server specified in the given settings
-- and run the given 'Application'.
runClient :: P.Proxy p => NS.HostName -> Int -> Application p r -> IO r
runClient host port app = E.bracket
    (PNT.connect host port)
    (NS.sClose . fst)
    (\(sock,addr) -> app addr (PNT.socketP 4096 sock, PNT.socketC sock))


-- | Run a TCP 'Application' with the given settings.
--
-- This function will create a new listening socket using the given settings,
-- accept connections on it, and handle each incomming connection running the
-- given 'Application' on a new thread.
runServer :: P.Proxy p => Maybe NS.HostName -> Int -> Application p r -> IO r
runServer host port app = E.bracket
    (PNT.listen host port)
    (NS.sClose . fst)
    (forever . serve)
  where
    serve (listeningSock,_) = do
      PNT.acceptFork listeningSock $ \(sock,addr) -> do
        void $ app addr (PNT.socketP 4096 sock, PNT.socketC sock)

