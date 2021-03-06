{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}

module Network.NTP.Config (
    -- * Types
      ServerConfig (..)
    , Priority (..)
    , Driver (..)
    , HostName
    , SerialPort
    , BaudRate (..)
    , Segment (..)
    , RefId (..)
    , TimeOffset

    -- * Reading / Writing
    , readConfig
    , writeConfig
    ) where

import           Control.Applicative ((<$>))
import           Data.Bits ((.&.))
import           Data.Maybe (catMaybes, isJust, fromJust)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Read as T
import           Prelude hiding (lines)
import           Text.Printf (printf)

------------------------------------------------------------------------
-- Types

data ServerConfig = ServerConfig {
      cfgPriority :: Priority
    , cfgDriver   :: Driver
    } deriving (Show)

data Priority = Prefer | Normal | NoSelect
  deriving (Show)

type HostName = T.Text
type SerialPort = Int
type TimeOffset = Double

data Driver = UDP HostName
            | NMEA SerialPort BaudRate TimeOffset
            | SharedMem Segment RefId TimeOffset
  deriving (Show)

data Segment = Seg0 | Seg1 | Seg2 | Seg3
  deriving (Show)

data RefId = RefId Char Char Char Char
  deriving (Show)

data BaudRate = B'4800 | B'9600 | B'19200 | B'38400 | B'57600 | B'115200
  deriving (Show)

------------------------------------------------------------------------
-- Reading

readConfig :: FilePath -> IO [ServerConfig]
readConfig path = parseConfig <$> T.readFile path

parseConfig :: T.Text -> [ServerConfig]
parseConfig txt = map fudges servers
  where
    servers = catMaybes (decode "server" server)
    fudges  = foldl (.) id (decode "fudge" fudge)

    lines = map T.stripStart (T.lines txt)
    decode typ go = map (go . fromJust)
                  $ filter isJust
                  $ map (T.stripPrefix typ)
                  $ lines

server :: T.Text -> Maybe ServerConfig
server (T.strip -> line)
    | T.null line          = Nothing
    | elem "prefer" mods   = Just $ cfg { cfgPriority = Prefer }
    | elem "noselect" mods = Just $ cfg { cfgPriority = NoSelect }
    | otherwise            = Just cfg
  where
    cfg = ServerConfig Normal (driver host mods)
    (host:mods) = T.words line

driver :: HostName -> [T.Text] -> Driver
driver host mods = case host of
    (T.stripPrefix "127.127.20." -> Just n) -> NMEA (decimal n) (baud mods) 0
    "127.127.28.0" -> SharedMem Seg0 shm 0
    "127.127.28.1" -> SharedMem Seg1 shm 0
    "127.127.28.2" -> SharedMem Seg2 shm 0
    "127.127.28.3" -> SharedMem Seg3 shm 0
    _              -> UDP host
  where
    baud = pairwiseLookup "mode" B'4800 (decodeBaud . decimal)
    shm  = RefId 'S' 'H' 'M' ' '

type Fudge = ServerConfig -> ServerConfig

fudge :: T.Text -> Fudge
fudge (T.strip -> line) cfg
    | T.null line   = cfg
    | host /= host' = cfg
    | otherwise     = cfg'
  where
    (host:mods) = T.words line

    host'  = driverHost (cfgDriver cfg)
    cfg'   = cfg { cfgDriver = update (cfgDriver cfg) }

    update (NMEA p b _) = NMEA p b offset
    update x            = x

    offset = pairwiseLookup "time2" 0 double mods

-- | Reads a decimal number from text or returns 0 if it can't.
decimal :: T.Text -> Int
decimal = either (const 0) fst . T.decimal

-- | Reads a rational number from text or returns 0 if it can't.
double :: T.Text -> Double
double = either (const 0) fst . T.double

-- | Performs a pairwise lookup of key/value pairs.
pairwiseLookup :: T.Text -> a -> (T.Text -> a) -> [T.Text] -> a
pairwiseLookup key n f = go
  where
    go []                 = n
    go (k:x:_) | k == key = f x
    go (_:xs)             = go xs

------------------------------------------------------------------------
-- Writing

writeConfig :: [ServerConfig] -> FilePath -> IO ()
writeConfig servers path = do
    file <- T.readFile path
    T.writeFile path (update file)
  where
    update = T.unlines . updateLines . map T.stripStart . T.lines

    updateLines xs =
        let (ys, zs) = break hasServerConfig xs
        in ys
        ++ concatMap serverConfig servers
        ++ filter (not . hasServerConfig) zs

    hasServerConfig x = "server" `T.isPrefixOf` x ||
                        "fudge"  `T.isPrefixOf` x

    nameWidth = maximum $ map (T.length . driverText . cfgDriver) servers
    padding xs = T.replicate (nameWidth - T.length xs) " "

    serverConfig cfg = catMaybes [Just (serverText cfg), fudgeText cfg]

    serverText ServerConfig{..} = T.concat
        [ "server "
        , driverText cfgDriver
        , padding (driverText cfgDriver)
        , " minpoll 3"
        , " maxpoll 3"
        , " iburst"
        , case cfgPriority of
            Prefer   -> " prefer"
            NoSelect -> " noselect"
            _        -> ""
        ]

    driverText x = driverHost x `T.append` driverMode x

    fudgeText ServerConfig{..} = case cfgDriver of
        UDP _           -> Nothing
        NMEA _ _ offset -> Just $ T.concat
            [ "fudge  "
            , driverHost cfgDriver
            , " flag1 1"
            , " time2 ", showMicro offset
            ]
        SharedMem _ refid offset -> Just $ T.concat
            [ "fudge  "
            , driverHost cfgDriver
            , " time1 ", showMicro offset
            , case showRefId refid of
                "" -> ""
                xs -> " refid " `T.append` xs
            ]

driverHost :: Driver -> HostName
driverHost (UDP x)              = x
driverHost (NMEA n _ _)         = "127.127.20." `T.append` tshow n
driverHost (SharedMem Seg0 _ _) = "127.127.28.0"
driverHost (SharedMem Seg1 _ _) = "127.127.28.1"
driverHost (SharedMem Seg2 _ _) = "127.127.28.2"
driverHost (SharedMem Seg3 _ _) = "127.127.28.3"

driverMode :: Driver -> T.Text
driverMode (UDP _)           = ""
driverMode (NMEA _ baud _)   = " mode " `T.append` (tshow . encodeBaud) baud
driverMode (SharedMem _ _ _) = ""

tshow :: Show a => a -> T.Text
tshow = T.pack . show

showMicro :: Double -> T.Text
showMicro x | T.last txt /= '.' = txt
            | otherwise         = txt `T.append` "0"
  where
    txt = T.dropWhileEnd (== '0') $ T.pack (printf "%.6f" x)

showRefId :: RefId -> T.Text
showRefId (RefId a b c d) = T.strip (T.pack [a,b,c,d])

------------------------------------------------------------------------
-- Utils

type Mode = Int

decodeBaud :: Mode -> BaudRate
decodeBaud x = case x .&. 0x70 of
    0x00 -> B'4800
    0x10 -> B'9600
    0x20 -> B'19200
    0x30 -> B'38400
    0x40 -> B'57600
    _    -> B'115200

encodeBaud :: BaudRate -> Mode
encodeBaud x = case x of
    B'4800   -> 0x00
    B'9600   -> 0x10
    B'19200  -> 0x20
    B'38400  -> 0x30
    B'57600  -> 0x40
    B'115200 -> 0x50
