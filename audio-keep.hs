-- audio-keep: the sound goes back to the output it was on before the screen
-- blanked.
--
-- olimpo's BenQ drops HDMI when DPMS powers it off with the screensaver
-- (X's 600 s): its HDMI sink node goes away and WirePlumber falls back to
-- another sink (S/PDIF, "Digital Output", or the dock). WirePlumber brings
-- HDMI back by itself only while default.configured.audio.sink still names
-- it, and an open gnome-control-center Sound panel overwrites that key with
-- the fallback the moment the HDMI row vanishes (investigated 2026-08-21).
--
-- So this looks at the default sink every 2 s and remembers the one in use.
-- When that sink goes away the remembered one is kept, whatever the default
-- falls back to; when it comes back it is written to
-- default.configured.audio.sink again (pw-metadata), which WirePlumber
-- follows. A change of the default while the remembered sink is still
-- there is a choice (the panel, wpctl), and becomes the remembered one.
--
--   audio-keep PW-METADATA PW-CLI
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, evaluate, try)
import Data.List (isInfixOf, isPrefixOf, stripPrefix)
import Data.Maybe (listToMaybe, mapMaybe)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hFlush, hPutStrLn, stderr)
import System.Process (callProcess, readProcess)

-- What is kept: the sink in use, while it is there; the sink that went
-- away; the sink that came back and was configured, with the looks left
-- for the default to follow it.
data Keep
  = Following (Maybe String)
  | Away String
  | Back String Int
  deriving (Eq, Show)

data Act = Configure String | Say String

-- One look: the default sink now, and which sinks exist. No default at all
-- (pipewire restarting, the moment between two sinks) changes nothing.
step :: Keep -> Maybe String -> (String -> Bool) -> (Keep, [Act])
step (Following Nothing) d _ = (Following d, maybe [] (\s -> [Say ("following " ++ s)]) d)
step k Nothing _ = (k, [])
step k@(Following (Just c)) (Just d) there
  | d == c = (k, [])
  | there c = (Following (Just d), [Say ("now on " ++ d ++ ", chosen while " ++ c ++ " was there")])
  | otherwise = (Away c, [Say (c ++ " went away (default fell back to " ++ d ++ "); keeping it")])
step k@(Away c) _ there
  | there c = (Back c backLooks, [Configure c, Say (c ++ " is back; restoring it")])
  | otherwise = (k, [])
step (Back c n) (Just d) there
  | d == c = (Following (Just c), [Say (c ++ " restored")])
  | not (there c) = (Away c, [])
  | n <= 0 = (Following (Just d), [Say ("gave up on " ++ c ++ "; now on " ++ d)])
  | otherwise = (Back c (n - 1), [Configure c | n `mod` 3 == 0])

-- 20 s for WirePlumber to follow the configured sink, configuring it again
-- every 6 s (the Sound panel may write its own choice once more)
backLooks :: Int
backLooks = 10

-- `pw-metadata 0`'s line for a key: update: id:0 key:'K' value:'{"name":"N"}' type:'...'
nameOf :: String -> [String] -> Maybe String
nameOf key ls = listToMaybe (mapMaybe pick ls)
  where
    pick l
      | ("key:'" ++ key ++ "'") `isInfixOf` l = quoted =<< afterColon =<< after "\"name\"" l
      | otherwise = Nothing
    afterColon s = case dropWhile (`elem` " \t") s of
      ':' : r -> Just (dropWhile (`elem` " \t") r)
      _ -> Nothing
    quoted ('"' : r) = Just (takeWhile (/= '"') r)
    quoted _ = Nothing

after :: String -> String -> Maybe String
after p s
  | Just r <- stripPrefix p s = Just r
  | otherwise = case s of
      [] -> Nothing
      _ : t -> after p t

-- `pw-cli ls Node`'s node.name = "N" lines
nodeNames :: [String] -> [String]
nodeNames = mapMaybe (\l -> quoted =<< stripPrefix "node.name = " (dropWhile (`elem` " \t") l))
  where
    quoted ('"' : r) = Just (takeWhile (/= '"') r)
    quoted _ = Nothing

say :: String -> IO ()
say s = hPutStrLn stderr ("audio-keep: " ++ s) >> hFlush stderr

look :: FilePath -> FilePath -> IO (Maybe (Maybe String, [String]))
look meta cli = do
  r <- try $ do
    m <- readProcess meta ["0"] ""
    n <- readProcess cli ["ls", "Node"] ""
    let d = nameOf "default.audio.sink" (lines m)
        ns = nodeNames (lines n)
    _ <- evaluate (length ns)
    pure (d, ns)
  pure (either (\e -> const Nothing (e :: SomeException)) Just r)

act :: FilePath -> Act -> IO ()
act _ (Say s) = say s
act meta (Configure s) = do
  r <- try (callProcess meta ["0", "default.configured.audio.sink", "{ \"name\": \"" ++ s ++ "\" }", "Spa:String:JSON"])
  either (\e -> say ("could not configure " ++ s ++ ": " ++ show (e :: SomeException))) pure r

loop :: FilePath -> FilePath -> Keep -> IO ()
loop meta cli k = do
  got <- look meta cli
  k' <- case got of
    Nothing -> pure k
    Just (d, ns) -> do
      let (k2, as) = step k d (`elem` ns)
      mapM_ (act meta) as
      pure k2
  threadDelay 2000000
  loop meta cli k'

main :: IO ()
main = do
  args <- getArgs
  case args of
    [meta, cli] | not ("-" `isPrefixOf` meta) -> loop meta cli (Following Nothing)
    _ -> die "usage: audio-keep PW-METADATA PW-CLI"
