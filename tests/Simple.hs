{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind -fno-warn-missing-signatures #-}

module Main where

import           Control.Concurrent             (forkIO, threadDelay)
import           Control.Concurrent.MVar        (newEmptyMVar, putMVar, takeMVar)
import qualified Control.Exception       as E
import qualified Data.ByteString.Char8   as B
import qualified Network.Socket          as NS
import           Test.Framework                 (Test, defaultMain, testGroup)
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit                     (Assertion, (@=?))
import           Control.Proxy           ((>->))
import qualified Control.Proxy           as P
import qualified Control.Proxy.Safe      as P
import qualified Control.Proxy.TCP       as T
import qualified Control.Proxy.TCP.Safe  as T'

host1  = "127.0.0.1"                        :: String
host1p = T.Host host1                       :: T.HostPreference
ports  = fmap show [14000..14010]           :: [NS.ServiceName]
msg1   = take 1000 $ cycle ["Hell","o\r\n"] :: [B.ByteString]
msg1b  = B.concat msg1                      :: B.ByteString

test_safe_serveWriteD_then_connectReadS :: Assertion
test_safe_serveWriteD_then_connectReadS = do
    done <- newEmptyMVar
    forkIO $ server >> putMVar done ()
    -- we sleep 200ms hoping that the server has started.
    threadDelay 200000 >> client
    takeMVar done
  where
    port = ports !! 0
    server = do
      let p = P.fromListS msg1 >-> T'.serveWriteD Nothing host1p port
      P.runSafeIO . P.runProxy .P.runEitherK $ p
    client = do
      let p = P.raiseK (T'.connectReadS Nothing 4096 host1 port) >-> P.toListD
      (eex,out) <- P.trySafeIO . P.runWriterT . P.runProxy .P.runEitherK $ p
      case eex of
        Left ex  -> E.throw ex
        Right () -> B.concat out @=? msg1b

test_safe_serveReadS_then_connectWriteD :: Assertion
test_safe_serveReadS_then_connectWriteD = do
    done <- newEmptyMVar
    forkIO $ server >> putMVar done ()
    -- we sleep 200ms hoping that the server has started.
    threadDelay 200000 >> client
    takeMVar done
  where
    port = ports !! 1
    client = do
       let p = P.fromListS msg1 >-> T'.connectWriteD Nothing host1 port
       P.runSafeIO . P.runProxy .P.runEitherK $ p
    server = do
      let p = P.raiseK (T'.serveReadS Nothing 4096 host1p port) >-> P.toListD
      (eex,out) <- P.trySafeIO . P.runWriterT . P.runProxy .P.runEitherK $ p
      case eex of
        Left ex  -> E.throw ex
        Right () -> B.concat out @=? msg1b

test_listen_accept_socketReadS_then_connect_socketWriteD :: Assertion
test_listen_accept_socketReadS_then_connect_socketWriteD = do
    listening <- newEmptyMVar
    done <- newEmptyMVar
    forkIO $ server listening >> putMVar done ()
    takeMVar listening >> client
    takeMVar done
  where
    port = ports !! 2
    server listening = do
      T.listen host1p port $ \(lsock, laddr) -> do
        putMVar listening ()
        T.accept lsock $ \(csock, caddr) -> do
          let p = P.raiseK (T.socketReadS 4096 csock) >-> P.toListD
          ((), out) <- P.runWriterT . P.runProxy $ p
          B.concat out @=? msg1b
    client = do
      T.connect host1 port $ \(csock, caddr) -> do
        let p = P.fromListS msg1 >-> T.socketWriteD csock
        P.runProxy p

test_listen_accept_socketWriteD_then_connect_socketReadD :: Assertion
test_listen_accept_socketWriteD_then_connect_socketReadD = do
    listening <- newEmptyMVar
    done <- newEmptyMVar
    forkIO $ server listening >> putMVar done ()
    takeMVar listening >> client
    takeMVar done
  where
    port = ports !! 3
    server listening = do
      T.listen host1p port $ \(lsock, laddr) -> do
        putMVar listening ()
        T.accept lsock $ \(csock, caddr) -> do
          let p = P.fromListS msg1 >-> T.socketWriteD csock
          P.runProxy p
    client = do
      T.connect host1 port $ \(csock, caddr) -> do
        let p = P.raiseK (T.socketReadS 4096 csock) >-> P.toListD
        ((), out) <- P.runWriterT . P.runProxy $ p
        B.concat out @=? msg1b

tests :: [Test]
tests =
  [ testGroup "TCP"
    [ testGroup "{listen+accept,connect} + {socketReadS,socketWriteD}"
      [ testCase "test_listen_accept_socketReadS_then_connect_socketWriteD"
                  test_listen_accept_socketReadS_then_connect_socketWriteD
      , testCase "test_listen_accept_socketWriteD_then_connect_socketReadD"
                  test_listen_accept_socketWriteD_then_connect_socketReadD
      ]
    ]
 , testGroup "TCP.Safe"
   [ testGroup "{serve,connect}{WriteD,ReadS}"
     [ testCase "test_safe_serveWriteD_then_connectReadS"
                test_safe_serveWriteD_then_connectReadS
     , testCase "test_safe_serveReadS_then_connectWriteD"
                test_safe_serveReadS_then_connectWriteD
     ]
   ]
  ]

main :: IO ()
main = NS.withSocketsDo $ defaultMain tests