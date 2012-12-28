import           Control.Proxy
import           Control.Proxy.Network
import qualified Data.ByteString.Char8 as B8
import           Data.Char (toUpper)


echo src dst = runProxy $ src >-> printD >-> mapD (B8.map toUpper) >-> dst

main = do
  putStrLn "Listening on 127.0.0.1, TCP port 9999..."
  runTCPServer settings echo
  where settings = ServerSettings { serverPort = 9999
                                  , serverHost = Just "127.0.0.1" }
