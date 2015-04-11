{-# LANGUAGE OverloadedStrings #-}
module FuncTorrent.Tracker
    (TrackerResponse(..),
     connect,
     mkArgs,
     mkParams,
     mkTrackerResponse,
     urlEncodeHash
    ) where

import Prelude hiding (lookup, concat, replicate, splitAt)

import Data.ByteString (ByteString)
import Data.ByteString.Char8 as BC (pack, unpack, splitAt, concat, intercalate)
import Data.Char (chr)
import Data.List (intercalate)
import Data.Map as M (lookup)
import Network.HTTP (simpleHTTP, defaultGETRequest_, getResponseBody)
import Network.HTTP.Base (urlEncode)
import Network.URI (parseURI)
import qualified Data.ByteString.Base16 as B16 (encode)

import FuncTorrent.Bencode (BVal(..))
import FuncTorrent.Peer (Peer(..))
import FuncTorrent.Utils (splitN)
import FuncTorrent.Metainfo (Info(..), Metainfo(..))


-- | Tracker response
data TrackerResponse = TrackerResponse {
      interval :: Maybe Integer
    , peers :: [Peer]
    , complete :: Maybe Integer
    , incomplete :: Maybe Integer
    } deriving (Show, Eq)

-- | Deserialize tracker response
mkTrackerResponse :: BVal -> Either ByteString TrackerResponse
mkTrackerResponse resp =
    case lookup "failure reason" body of
      Just (Bstr err) -> Left err
      Just _ -> Left "Unknown failure"
      Nothing ->
          let (Just (Bint i)) = lookup "interval" body
              (Just (Bstr peersBS)) = lookup "peers" body
              pl = map makePeer (splitN 6 peersBS)
          in Right TrackerResponse {
                   interval = Just i
                 , peers = pl
                 , complete = Nothing
                 , incomplete = Nothing
                 }
    where
      (Bdict body) = resp

      toInt :: String -> Integer
      toInt = read

      toPort :: ByteString -> Integer
      toPort = read . ("0x" ++) . unpack . B16.encode

      toIP :: ByteString -> String
      toIP = Data.List.intercalate "." .
             map (show . toInt . ("0x" ++) . unpack) .
                 splitN 2 . B16.encode

      makePeer :: ByteString -> Peer
      makePeer peer = Peer (toIP ip') (toPort port')
          where (ip', port') = splitAt 4 peer

-- | Connect to a tracker and get peer info
connect :: Metainfo -> String -> IO ByteString
connect m peer_id = get (head . announceList $ m) $ mkArgs m peer_id

--- | URL encode hash as per RFC1738
--- TODO: Add tests
--- REVIEW: Why is this not written in terms of `Network.HTTP.Base.urlEncode` or
--- equivalent library function?
urlEncodeHash :: ByteString -> String
urlEncodeHash bs = concatMap (encode' . unpack) (splitN 2 bs)
  where encode' b@[c1, c2] = let c =  chr (read ("0x" ++ b))
                            in escape c c1 c2
        encode' _ = ""
        escape i c1 c2 | i `elem` nonSpecialChars = [i]
                       | otherwise = "%" ++ [c1] ++ [c2]

        nonSpecialChars = ['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "-_.~"

-- | Make arguments that should be posted to tracker.
-- This is a separate pure function for testability.
mkArgs :: Metainfo -> String -> [(String, ByteString)]
mkArgs m peer_id = [("info_hash", pack . urlEncodeHash . B16.encode . infoHash $ m),
                    ("peer_id", pack . urlEncode $ peer_id),
                    ("port", "6881"),
                    ("uploaded", "0"),
                    ("downloaded", "0"),
                    ("left", pack . show . lengthInBytes $ info m),
                    ("compact", "1"),
                    ("event", "started")]

-- | Make a query string from a alist of k, v
-- TODO: Url encode each argument
mkParams :: [(String, ByteString)] -> ByteString
mkParams params = BC.intercalate "&" [concat [pack f, "=", s] | (f,s) <- params]

get :: String -> [(String, ByteString)] -> IO ByteString
get url args = simpleHTTP (defaultGETRequest_ url') >>= getResponseBody
    where url' = case parseURI $ unpack $ concat [pack url, "?", qstr] of
                   Just x -> x
                   _ -> error "Bad tracker URL"
          qstr = mkParams args
