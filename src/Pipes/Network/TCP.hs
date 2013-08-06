{-# LANGUAGE RankNTypes #-}

-- | This minimal module exports facilities that ease the usage of TCP
-- 'NS.Socket's in the /Pipes ecosystem/.
--
-- You are encouraged to use this module in conjunction with the
-- "Network.Simple.TCP" module from the 'network-simple' package:
--
-- @
-- import qualified Network.Simple.TCP as NT
-- import qualified Pipes.Network.TCP  as NT
-- @
--
-- Besides the 'Producer's and 'Consumer's exported by this module, you may want
-- to 'lift' the functions 'Network.Simple.TCP.send' and
-- 'Network.Simple.TCP.recv' to be used as 'Effect's.
--
-- This module /does not/ export facilities that would allow you to acquire new
-- 'NS.Socket's within a 'Proxy' pipeline. If you need to do so, then you should
-- use the similar "Pipes.Network.TCP.Safe" module instead.

module Pipes.Network.TCP (
    fromSocket
  , fromSocketN
  , toSocket
  ) where

import qualified Data.ByteString                as B
import qualified Network.Socket                 as NS
import qualified Network.Socket.ByteString      as NSB
import           Pipes
import           Pipes.Core

--------------------------------------------------------------------------------

-- | Receives bytes from the remote end sends them downstream.
--
-- The number of bytes received at once is always in the interval
-- /[1 .. specified maximum]/.
--
-- This 'Producer' returns if the remote peer closes its side of the connection
-- or EOF is received.
fromSocket :: NS.Socket  -- ^Connected socket.
           -> Int        -- ^Maximum number of bytes to receive and send
                         -- dowstream at once. Any positive value is fine, the
                         -- optimal value depends on how you deal with the
                         -- received data. Try using @4096@ if you don't care.
           -> Producer B.ByteString IO ()
fromSocket sock nbytes = loop where
    loop = do
        bs <- lift (NSB.recv sock nbytes)
        if B.null bs
           then return ()
           else respond bs >> loop
{-# INLINABLE fromSocket #-}


-- | Like 'fromSocket', except the downstream 'Proxy' can specify the maximum
-- number of bytes to receive at once using 'request'.
fromSocketN :: NS.Socket -> Int -> Server Int B.ByteString IO ()
fromSocketN sock = loop where
    loop = \nbytes -> do
        bs <- lift (NSB.recv sock nbytes)
        if B.null bs
           then return ()
           else respond bs >>= loop
{-# INLINABLE fromSocketN #-}


-- | Sends to the remote end each 'B.ByteString' received from upstream.
toSocket :: NS.Socket  -- ^Connected socket.
         -> Consumer B.ByteString IO r
toSocket sock = cat //> lift . NSB.sendAll sock
{-# INLINABLE toSocket #-}

