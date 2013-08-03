{-# LANGUAGE RankNTypes #-}

-- | This module exports functions that allow you to safely use 'NS.Socket'
-- resources acquired and released outside a 'P.Proxy' pipeline.
--
-- Instead, if want to safely acquire and release resources within the
-- pipeline itself, then you should use the functions exported by
-- "Pipes.Network.TCP.Safe".
--
-- This module re-exports many functions from "Network.Simple.TCP"
-- module in the @network-simple@ package. You might refer to that
-- module for more documentation.


module Pipes.Network.TCP (
  -- * Client side
  -- $client-side
    S.connect

  -- * Server side
  -- $server-side
  , S.serve
  -- ** Listening
  , S.listen
  -- ** Accepting
  , S.accept
  , S.acceptFork

  -- * Socket streams
  -- $socket-streaming
  , recv
  , recv'
  , send
  -- ** Timeouts
  -- $socket-streaming-timeout
  , recvTimeout
  , sendTimeout

  -- * Note to Windows users
  -- $windows-users
  , NS.withSocketsDo

  -- * Types
  , S.HostPreference(..)
  , I.Timeout(..)
  ) where

import qualified Control.Monad.Trans.Error      as E
import qualified Data.ByteString                as B
import           Data.Function                  (fix)
import           Data.Monoid
import qualified Network.Socket                 as NS
import qualified Network.Simple.TCP             as S
import           Pipes
import           Pipes.Core
import qualified Pipes.Network.Internal         as I
import           System.Timeout                 (timeout)


--------------------------------------------------------------------------------

-- $windows-users
--
-- If you are running Windows, then you /must/ call 'NS.withSocketsDo', just
-- once, right at the beginning of your program. That is, change your program's
-- 'main' function from:
--
-- @
-- main = do
--   print \"Hello world\"
--   -- rest of the program...
-- @
--
-- To:
--
-- @
-- main = 'NS.withSocketsDo' $ do
--   print \"Hello world\"
--   -- rest of the program...
-- @
--
-- If you don't do this, your networking code won't work and you will get many
-- unexpected errors at runtime. If you use an operating system other than
-- Windows then you don't need to do this, but it is harmless to do it, so it's
-- recommended that you do for portability reasons.

--------------------------------------------------------------------------------

-- $client-side
--
-- Here's how you could run a TCP client:
--
-- @
-- 'S.connect' \"www.example.org\" \"80\" $ \(connectionSocket, remoteAddr) -> do
--   putStrLn $ \"Connection established to \" ++ show remoteAddr
--   -- Now you may use connectionSocket as you please within this scope,
--   -- possibly using 'recv', 'send' or similar proxies
--   -- explained below.
-- @

--------------------------------------------------------------------------------

-- $server-side
--
-- Here's how you can run a TCP server that handles in different threads each
-- incoming connection to port @8000@ at IPv4 address @127.0.0.1@:
--
-- @
-- 'S.serve' ('S.Host' \"127.0.0.1\") \"8000\" $ \(connectionSocket, remoteAddr) -> do
--   putStrLn $ \"TCP connection established from \" ++ show remoteAddr
--   -- Now you may use connectionSocket as you please within this scope,
--   -- possibly using 'recv', 'send' or similar proxies
--   -- explained below.
-- @
--
-- If you need more control on the way your server runs, then you can use more
-- advanced functions such as 'listen', 'accept' and 'acceptFork'.

--------------------------------------------------------------------------------

-- $socket-streaming
--
-- Once you have a connected 'NS.Socket', you can use the following 'P.Proxy's
-- to interact with the other connection end using streams.

-- | Receives bytes from the remote end sends them downstream.
--
-- Less than the specified maximum number of bytes might be received at once.
--
-- This proxy returns if the remote peer closes its side of the connection or
-- EOF is received.
recv
  :: NS.Socket          -- ^Connected socket.
  -> Int                -- ^Maximum number of bytes to receive and send
                        -- dowstream at once. Any positive value is fine, the
                        -- optimal value depends on how you deal with the
                        -- received data. Try using @4096@ if you don't care.
  -> Producer B.ByteString IO ()
recv sock nbytes = fix $ \loop -> do
    mbs <- lift (S.recv sock nbytes)
    case mbs of
      Just bs -> respond bs >> loop
      Nothing -> return ()
{-# INLINABLE recv #-}


-- | Like 'recv', except the downstream consumer can specify the maximum
-- number of bytes to receive at once.
recv' :: NS.Socket -> Int -> Server Int B.ByteString IO ()
recv' sock = fix $ \loop nbytes -> do
    mbs <- lift (S.recv sock nbytes)
    case mbs of
      Just bs -> respond bs >>= loop
      Nothing -> return ()
{-# INLINABLE recv' #-}


-- | Sends to the remote end the bytes received from upstream.
send
  :: NS.Socket          -- ^Connected socket.
  -> B.ByteString       -- ^Bytes to send to the remote end.
  -> Effect' IO ()
send sock = lift . S.send sock
{-# INLINABLE send #-}

--------------------------------------------------------------------------------

-- $socket-streaming-timeout
--
-- These proxies behave like the similarly named ones above, except support for
-- timing out the interaction with the remote end is added.

-- | Like 'recv', except it throws 'I.Timeout' in the 'E.ErrorT' monad
-- transformer if receiving data from the remote end takes more time than
-- specified.
recvTimeout
  :: Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> Int                -- ^Maximum number of bytes to receive and send
                        -- dowstream at once. Any positive value is fine, the
                        -- optimal value depends on how you deal with the
                        -- received data. Try using @4096@ if you don't care.
  -> Producer B.ByteString (E.ErrorT I.Timeout IO) ()
recvTimeout wait sock nbytes = fix $ \loop -> do
    mmbs <- lift . lift $ timeout wait (S.recv sock nbytes)
    case mmbs of
      Just (Just bs) -> yield bs >> loop
      Just Nothing   -> return ()
      Nothing        -> lift . E.throwError $
        I.Timeout $ "recvTimeout: " <> show wait <> " microseconds."
{-# INLINABLE recvTimeout #-}


-- | Like 'send', except it throws 'I.Timeout' in the 'E.ErrorT' monad
-- transformer if sending data to the remote end takes more time than specified.
sendTimeout
  :: Int                -- ^Timeout in microseconds (1/10^6 seconds).
  -> NS.Socket          -- ^Connected socket.
  -> B.ByteString       -- ^Bytes to send to the remote end.
  -> Effect' (E.ErrorT I.Timeout IO) ()
sendTimeout wait sock = \bs -> do
    m <- lift . lift . timeout wait . S.send sock $ bs
    case m of
      Just () -> return ()
      Nothing -> lift . E.throwError $
        I.Timeout $ "sendTimeout: " <> show wait <> " microseconds."
{-# INLINABLE sendTimeout #-}
