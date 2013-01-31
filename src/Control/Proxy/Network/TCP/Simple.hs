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


-- | Run a simple TCP 'Application' client connecting to the specified server.
runClient
  :: P.Proxy p
  => NS.HostName       -- ^Server hostname.
  -> Int               -- ^Server port number.
  -> Application p r   -- ^Applicatoin
  -> IO r
runClient host port app = E.bracket connect close use
  where
    connect = PNT.connect host port
    close (sock,_) = NS.sClose sock
    use (sock,addr) = app addr (PNT.socketP 4096 sock, PNT.socketC sock)


-- | Run a simple 'Application' TCP server handling each incomming connection
-- in a different thread.
runServer
  :: P.Proxy p
  => Maybe NS.HostName       -- ^Preferred hostname to bind to.
  -> Int                     -- ^Port number to bind to.
  -> (NS.SockAddr -> IO ())  -- ^Computation to run once after the listening
                             --  socket has been bound.
  -> Application p r         -- ^Application handling an incomming connection.
  -> IO r
runServer host port afterBind app = E.bracket bind close use
  where
    bind = PNT.listen host port
    close (lsock,_) = NS.sClose lsock
    use (lsock,laddr) = do
      afterBind laddr
      forever . PNT.acceptFork lsock $ \(csock,caddr) -> do
        void $ app caddr (PNT.socketP 4096 csock, PNT.socketC csock)

