{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind -fno-warn-missing-signatures #-}

module Main where

import           Control.Concurrent             (forkIO, threadDelay)
import           Control.Concurrent.MVar        (newEmptyMVar, putMVar, takeMVar)
import qualified Control.Exception              as E
import qualified Data.ByteString.Char8          as B
import qualified Network.Socket                 as NS
import           Test.Framework                 (Test, defaultMain, testGroup)
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit                     (Assertion, (@=?))
import           Control.Proxy                  ((>->))
import qualified Control.Proxy                  as P
import qualified Control.Proxy.Safe             as P
import qualified Control.Proxy.TCP              as T
import qualified Control.Proxy.TCP.Safe         as T'
import qualified Control.Proxy.Trans.Writer     as P

host1  = "127.0.0.1"                        :: NS.HostName
host1p = T.Host host1                       :: T.HostPreference
ports  = fmap show [14000..14010::Int]      :: [NS.ServiceName]
msg1   = take 1000 $ cycle ["Hell","o\r\n"] :: [B.ByteString]
msg1b  = B.concat msg1                      :: B.ByteString


-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
-- The following 4 IO actions are used throughout the various tests as the
-- default implementations for reading/writing a server/client. They themselves
-- are also tested below.

-- tested by 'test_listen_accept_socketWriteD_then_connect_socketReadD'
connectAndRead :: NS.HostName -> NS.ServiceName -> IO [B.ByteString]
connectAndRead host port = do
    T.connect host port $ \(csock, _caddr) -> do
       let p = T.socketReadS 4096 csock >-> P.toListD
       fmap snd . P.runProxy . P.runWriterK $ p

-- tested by 'test_listen_accept_socketReadS_then_connect_socketWriteD'
connectAndWrite :: NS.HostName -> NS.ServiceName -> [B.ByteString] -> IO ()
connectAndWrite host port msg = do
    T.connect host port $ \(csock, _caddr) -> do
       P.runProxy $ P.fromListS msg >-> T.socketWriteD csock

-- tested by 'test_listen_accept_socketWriteD_then_connect_socketReadD'
serveOnceAndRead :: T.HostPreference -> NS.ServiceName -> IO [B.ByteString]
serveOnceAndRead hp port = do
    T.listen hp port $ \(lsock, _laddr) -> do
       T.accept lsock $ \(csock, _caddr) -> do
         let p = T.socketReadS 4096 csock >-> P.toListD
         fmap snd . P.runProxy . P.runWriterK $ p

-- tested by 'test_listen_accept_socketWriteD_then_connect_socketReadD'
serveOnceAndWrite :: T.HostPreference -> NS.ServiceName -> [B.ByteString] -> IO ()
serveOnceAndWrite hp port msg = do
    T.listen hp port $ \(lsock, _laddr) -> do
       T.accept lsock $ \(csock, _caddr) -> do
         P.runProxy $ P.fromListS msg >-> T.socketWriteD csock
-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --

-- Note: In all the tests below we wait a bit before starting the
-- client, hoping that by then the server has already started.
-- Yes, I know, it's not the best approach. Hopefully it will be enough.
waitTime :: Int -- in microseconds (1e6)
waitTime = 200000

test_listen_accept_socketReadS_then_connect_socketWriteD :: Assertion
test_listen_accept_socketReadS_then_connect_socketWriteD = do
    let port = ports !! 0
    mvout <- newEmptyMVar
    forkIO $ putMVar mvout =<< serveOnceAndRead host1p port
    threadDelay waitTime
    connectAndWrite host1 port msg1
    out <- takeMVar mvout
    B.concat out @=? msg1b

test_listen_accept_socketWriteD_then_connect_socketReadD :: Assertion
test_listen_accept_socketWriteD_then_connect_socketReadD = do
    let port = ports !! 1
    forkIO $ serveOnceAndWrite host1p port msg1
    threadDelay waitTime
    out <- connectAndRead host1 port
    B.concat out @=? msg1b

test_safe_serveWriteD :: Assertion
test_safe_serveWriteD = do
    let port = ports !! 2
        serveOnceAndWrite' = do
          let p = P.fromListS msg1 >-> T'.serveWriteD Nothing host1p port
          eu <- P.runSafeIO . P.runProxy . P.runEitherK . P.runSafeK id $ p
          either E.throwIO return eu
    forkIO serveOnceAndWrite'
    threadDelay waitTime
    out <- connectAndRead host1 port
    B.concat out @=? msg1b

test_safe_serveReadS :: Assertion
test_safe_serveReadS = do
    let port = ports !! 3
        serveOnceAndRead' = do
          let p = T'.serveReadS Nothing 4096 host1p port >-> P.liftP . P.toListD
          (eex,out) <- P.runSafeIO . P.runProxy . P.runWriterK . P.runEitherK
                                   . P.runSafeK id $ p
          case eex of
            Left ex  -> E.throw ex
            Right () -> return out
    mvout <- newEmptyMVar
    forkIO $ putMVar mvout =<< serveOnceAndRead'
    threadDelay waitTime
    connectAndWrite host1 port msg1
    out <- takeMVar mvout
    B.concat out @=? msg1b


tests :: [Test]
tests =
  [ testGroup "TCP"
    [ testGroup "{listen*accept,connect}*{socketReadS,socketWriteD}"
      [ testCase "test_listen_accept_socketReadS_then_connect_socketWriteD"
                  test_listen_accept_socketReadS_then_connect_socketWriteD
      , testCase "test_listen_accept_socketWriteD_then_connect_socketReadD"
                  test_listen_accept_socketWriteD_then_connect_socketReadD
      ]
    ]
 , testGroup "TCP.Safe"
   [ testGroup "{serve,connect}{WriteD,ReadS}"
     [ testCase "test_safe_serveWriteD" test_safe_serveWriteD
     , testCase "test_safe_serveReadS"  test_safe_serveReadS
     ]
   ]
  ]

main :: IO ()
main = NS.withSocketsDo $ defaultMain tests