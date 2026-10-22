-- llm-transcript -- render Claude Code session transcripts as labelled Markdown,
-- and emit a cleaned training corpus from the raw session files.
--
-- Claude Code stores each session as newline-delimited JSON under
-- ~/.claude/projects/<slug>/<sessionId>.jsonl, with subagent conversations in
-- <sessionId>/subagents/agent-<id>.jsonl.  `render` turns one such file into a
-- document that says plainly who said what, and -- for commands that were run
-- -- whether they compiled something or executed it, with stdout and stderr
-- kept apart.  `corpus` walks every session and emits JSONL {id, text}
-- documents: prompts, prose, commands with capped output, edit diffs and
-- subagent answers -- scrubbed of secrets, deduplicated, with a few whole
-- sessions held out for evaluation.
--
-- On reasoning: the `thinking` blocks in these files are always empty.  Claude
-- Code keeps only the opaque server-side `signature`, and strips the text from
-- the debug log and the stream-json output too.  So reasoning is rendered as
-- metadata -- how many thinking tokens, at what effort -- never as prose.
--
--   llm-transcript render <session.jsonl> [outDir]
--   llm-transcript backfill [projectsDir] [outDir]
--   llm-transcript corpus [projectsDir] [out.jsonl] [--segment-bytes=N]

{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Exception          (SomeException, try)
import           Control.Monad              (forM, forM_, unless)
import qualified Data.Aeson                 as A
import           Data.Aeson                 (Value (..), (.=))
import qualified Data.Aeson.Key             as K
import qualified Data.Aeson.KeyMap          as KM
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Base64     as B64
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.List                  (isInfixOf, isPrefixOf, isSuffixOf,
                                             nub, partition, sortOn,
                                             stripPrefix)
import qualified Data.Map.Strict            as M
import           Data.Maybe                 (fromMaybe, mapMaybe)
import qualified Data.Set                   as S
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import qualified Data.Text.IO               as TIO
import qualified Data.Vector                as V
import           System.Directory           (createDirectoryIfMissing,
                                             doesDirectoryExist, doesFileExist,
                                             listDirectory)
import           System.Environment         (getArgs, lookupEnv)
import           System.Exit                (exitFailure)
import           System.FilePath            (takeBaseName, takeDirectory,
                                             takeFileName, (</>))
import           System.IO                  (hPutStrLn, stderr)
import           Text.Regex.TDFA            (AllMatches (..), MatchLength,
                                             MatchOffset, getAllMatches, (=~))
import           Text.Regex.TDFA.Text       ()

-- ---------------------------------------------------------------- entry point

main :: IO ()
main = getArgs >>= \case
  ["render", f]         -> defaultOut >>= renderFile f
  ["render", f, o]      -> renderFile f o
  ["backfill"]          -> do p <- defaultProjects; o <- defaultOut; backfill p o
  ["backfill", p]       -> defaultOut >>= backfill p
  ["backfill", p, o]    -> backfill p o
  ("corpus":rest)       -> corpusMain rest
  _                     -> usage

corpusMain :: [String] -> IO ()
corpusMain rest = do
  let (opts, pos) = partition ("--" `isPrefixOf`) rest
      seg = case mapMaybe (stripPrefix "--segment-bytes=") opts of
              (n:_) -> read n
              []    -> 4096
  case pos of
    []     -> do p <- defaultProjects; o <- defaultCorpusOut; corpus seg p o
    [p]    -> defaultCorpusOut >>= corpus seg p
    [p, o] -> corpus seg p o
    _      -> usage

usage :: IO ()
usage = do
  hPutStrLn stderr "usage: llm-transcript render <session.jsonl> [outDir]"
  hPutStrLn stderr "       llm-transcript backfill [projectsDir] [outDir]"
  hPutStrLn stderr "       llm-transcript corpus [projectsDir] [out.jsonl] [--segment-bytes=N]"
  exitFailure

home :: IO FilePath
home = fromMaybe "/root" <$> lookupEnv "HOME"

defaultOut :: IO FilePath
defaultOut = (</> "src/llm-transcript") <$> home

defaultProjects :: IO FilePath
defaultProjects = (</> ".claude/projects") <$> home

defaultCorpusOut :: IO FilePath
defaultCorpusOut = (</> "src/llm-transcript/corpus.jsonl") <$> home

-- ------------------------------------------------------------- the line model

-- | One decoded JSONL record.  Everything is optional because the file mixes
-- conversation lines with bookkeeping lines of a dozen other shapes.
data Line = Line
  { lType      :: T.Text
  , lUuid      :: Maybe T.Text
  , lParent    :: Maybe T.Text
  , lTime      :: Maybe T.Text
  , lSession   :: Maybe T.Text
  , lCwd       :: Maybe T.Text
  , lBranch    :: Maybe T.Text
  , lMessage   :: Maybe Value
  , lToolRes   :: Maybe Value
  , lMeta      :: Bool
  , lCompact   :: Bool
  , lPromptSrc :: Maybe T.Text
  , lEffort    :: Maybe T.Text
  , lRaw       :: Value
  }

field :: T.Text -> KM.KeyMap Value -> Maybe Value
field k = KM.lookup (K.fromText k)

txt :: T.Text -> KM.KeyMap Value -> Maybe T.Text
txt k o = case field k o of Just (String s) -> Just s; _ -> Nothing

bool :: T.Text -> KM.KeyMap Value -> Bool
bool k o = case field k o of Just (Bool b) -> b; _ -> False

decodeLine :: BLC.ByteString -> Maybe Line
decodeLine bs = case A.decode bs of
  Just v@(Object o) -> Just Line
    { lType      = fromMaybe "" (txt "type" o)
    , lUuid      = txt "uuid" o
    , lParent    = txt "parentUuid" o
    , lTime      = txt "timestamp" o
    , lSession   = txt "sessionId" o
    , lCwd       = txt "cwd" o
    , lBranch    = txt "gitBranch" o
    , lMessage   = field "message" o
    , lToolRes   = field "toolUseResult" o
    , lMeta      = bool "isMeta" o
    , lCompact   = bool "isCompactSummary" o
    , lPromptSrc = txt "promptSource" o
    , lEffort    = txt "effort" o
    , lRaw       = v
    }
  _ -> Nothing

-- | Content blocks of a message, if it has an array body.
blocks :: Line -> [KM.KeyMap Value]
blocks l = case lMessage l of
  Just (Object m) -> case field "content" m of
    Just (Array a) -> [o | Object o <- V.toList a]
    _              -> []
  _ -> []

-- | A message whose body is a bare string (typed prompts, compact summaries).
bodyString :: Line -> Maybe T.Text
bodyString l = case lMessage l of
  Just (Object m) -> case field "content" m of
    Just (String s) -> Just s
    _               -> Nothing
  _ -> Nothing

modelOf :: Line -> Maybe T.Text
modelOf l = case lMessage l of
  Just (Object m) -> txt "model" m
  _               -> Nothing

-- | Was this line typed (or queued, or accepted from a suggestion) by the
-- human?  Tool results are also type "user", but they carry
-- sourceToolAssistantUUID/toolUseResult and an array body.  Lines injected by
-- the harness carry promptSource "system" and are NOT the human.
isHuman :: Line -> Bool
isHuman l = lType l == "user"
         && lPromptSrc l /= Nothing
         && lPromptSrc l /= Just "system"
         && not (lMeta l)
         && not (lCompact l)
         && bodyString l /= Nothing

-- | Harness-injected turns: task notifications, reminders.  promptSource is
-- "system"; the body is a plain string.
isSystemTurn :: Line -> Bool
isSystemTurn l = lType l == "user"
              && lPromptSrc l == Just "system"
              && not (lCompact l)
              && bodyString l /= Nothing

-- | Slash-command bookkeeping (/compact records, <command-name> blocks,
-- <local-command-stdout>).  Typed by nobody; promptSource is null.
isCommandRecord :: Line -> Bool
isCommandRecord l = lType l == "user"
                 && lPromptSrc l == Nothing
                 && not (lMeta l)
                 && not (lCompact l)
                 && bodyString l /= Nothing

-- | "[Request interrupted by user]" markers: null promptSource, array body of
-- text blocks, no tool_result.
isInterrupt :: Line -> Bool
isInterrupt l = lType l == "user"
             && lPromptSrc l == Nothing
             && not (lMeta l)
             && not (lCompact l)
             && bodyString l == Nothing
             && not (null bs')
             && all (\b -> txt "type" b == Just "text") bs'
  where bs' = blocks l

interruptText :: Line -> T.Text
interruptText l = T.intercalate "\n" [fromMaybe "" (txt "text" b) | b <- blocks l]

thinkingTokens :: Line -> Maybe Int
thinkingTokens l = case lMessage l of
  Just (Object m) -> case field "usage" m of
    Just (Object u) -> case field "output_tokens_details" u of
      Just (Object d) -> case field "thinking_tokens" d of
        Just (Number n) -> Just (round n)
        _               -> Nothing
      _ -> Nothing
    _ -> Nothing
  _ -> Nothing

-- ----------------------------------------------------- conversation ordering

-- | The file is a DAG, not a list: retries, rewinds and compaction all create
-- branches, and timestamps are not monotonic.  Walk parentUuid back from the
-- newest leaf to recover the surviving conversation; anything left over is
-- reported separately rather than silently interleaved.
mainBranch :: [Line] -> ([Line], [Line])
mainBranch ls =
  let byUuid  = M.fromList [(u, l) | l <- ls, Just u <- [lUuid l]]
      conv    = [l | l <- ls, lType l `elem` ["user", "assistant"], lUuid l /= Nothing]
      leaf    = case reverse [u | l <- ls, lType l == "last-prompt"
                               , Object o <- [lRaw l], Just u <- [txt "leafUuid" o]] of
                  (u:_) -> Just u
                  []    -> case reverse conv of (l:_) -> lUuid l; [] -> Nothing
      walk acc Nothing  = acc
      walk acc (Just u) = case M.lookup u byUuid of
        Nothing -> acc
        Just l  -> walk (l : acc) (lParent l)
      chain   = walk [] leaf
      keep    = S.fromList (mapMaybe lUuid chain)
      orphans = [l | l <- conv, Just u <- [lUuid l], not (S.member u keep)]
  in if null chain then (conv, []) else (chain, orphans)

-- ------------------------------------------------------------ tool call index

-- | tool_use_id -> (result block content, structured toolUseResult)
type Results = M.Map T.Text (Maybe Value, Maybe Value)

indexResults :: [Line] -> Results
indexResults ls = M.fromList
  [ (tid, (field "content" b, lToolRes l))
  | l <- ls, b <- blocks l
  , txt "type" b == Just "tool_result"
  , Just tid <- [txt "tool_use_id" b]
  ]

-- ------------------------------------------------------------------ rendering

renderFile :: FilePath -> FilePath -> IO ()
renderFile path outDir = do
  raw <- BLC.readFile path
  let ls = mapMaybe decodeLine (BLC.lines raw)
  if null ls
    then hPutStrLn stderr ("llm-transcript: no parsable lines in " ++ path)
    else do
      subs <- loadSubagents path
      let out = outPath outDir path ls
      createDirectoryIfMissing True outDir
      let assetDir = outDir </> (takeBaseName out ++ ".files")
      body <- renderSession path ls subs assetDir (takeBaseName out ++ ".files")
      TIO.writeFile out body
      putStrLn out

-- | Subagent transcripts live beside the session as
-- <sessionId>/subagents/agent-<id>.jsonl, joined to the parent's Agent tool
-- call through agent-<id>.meta.json's toolUseId.
loadSubagents :: FilePath -> IO (M.Map T.Text (T.Text, [Line]))
loadSubagents path = do
  let dir = takeDirectory path </> takeBaseName path </> "subagents"
  ok <- doesDirectoryExist dir
  if not ok then pure M.empty else do
    names <- listDirectory dir
    pairs <- forM [n | n <- names, ".jsonl" `isSuffixOf` n] $ \n -> do
      body <- BLC.readFile (dir </> n)
      let ls   = mapMaybe decodeLine (BLC.lines body)
          meta = dir </> (take (length n - 6) n ++ ".meta.json")
      hasMeta <- doesFileExist meta
      info <- if hasMeta then BLC.readFile meta else pure "{}"
      let (tid, ty) = case A.decode info of
            Just (Object o) -> ( fromMaybe "" (txt "toolUseId" o)
                               , fromMaybe "agent" (txt "agentType" o) )
            _               -> ("", "agent")
      pure (tid, (ty, ls))
    pure (M.fromList [p | p@(t, _) <- pairs, not (T.null t)])

outPath :: FilePath -> FilePath -> [Line] -> FilePath
outPath outDir path ls =
  let sid   = takeBaseName path
      stamp = case mapMaybe lTime ls of
                (t:_) -> T.unpack (T.map dash (T.take 16 t))
                []    -> "unknown"
      dash c = if c == ':' then '-' else c
      (d, rest) = splitAt 10 stamp
      hhmm  = filter (/= '-') (drop 1 rest)
      proj  = case mapMaybe lCwd ls of
                (c:_) -> takeFileName (T.unpack c)
                []    -> "unknown"
  in outDir </> (d ++ "_" ++ hhmm ++ "_" ++ proj ++ "_" ++ take 8 sid ++ ".md")

renderSession :: FilePath -> [Line] -> M.Map T.Text (T.Text, [Line])
              -> FilePath -> String -> IO T.Text
renderSession path ls subs assetDir assetRel = do
  let (branch, orphans) = mainBranch ls
      results           = indexResults ls
      sid               = T.pack (takeBaseName path)
      proj              = case mapMaybe lCwd ls of
                            (c:_) -> c
                            []    -> "unknown"
      title             = lastOf [t | l <- ls, lType l == "ai-title"
                                    , Object o <- [lRaw l], Just t <- [txt "aiTitle" o]]
      models            = nub [m | l <- ls, lType l == "assistant"
                                 , Just m <- [modelOf l], m /= "<synthetic>"]
      branches          = nub [b | l <- ls, Just b <- [lBranch l], not (T.null b)]
      header = T.unlines $
        [ "# " <> fromMaybe ("Session " <> T.take 8 sid) title
        , ""
        , "| | |"
        , "|---|---|"
        , "| Project | `" <> proj <> "` |"
        , "| Session | `" <> sid <> "` |"
        , "| Source | `" <> T.pack path <> "` |"
        , "| Started | " <> fromMaybe "?" (lastOf (take 1 (mapMaybe lTime ls))) <> " |"
        ] ++
        [ "| Model | " <> T.intercalate ", " (map (\m -> "`" <> m <> "`") models)
            <> " |" | not (null models) ] ++
        [ "| Branch | " <> T.intercalate ", " (map (\b -> "`" <> b <> "`") branches)
            <> " |" | not (null branches) ] ++
        [ "| Messages | " <> tshow (length branch) <> " on the surviving branch"
            <> (if null orphans then "" else ", " <> tshow (length orphans)
                                              <> " on abandoned branches") <> " |"
        , ""
        , "> Reasoning text is not recoverable: Claude Code stores only an opaque"
        , "> signature for `thinking` blocks. Where the model reasoned, this"
        , "> transcript records the token count and effort level instead."
        , ""
        , "---"
        , ""
        ]
  chunks <- forM (zip [0 :: Int ..] branch) $ \(i, l) ->
              renderLine results subs assetDir assetRel i l
  extra <- if null orphans then pure "" else do
    xs <- forM (zip [10000 :: Int ..] orphans) $ \(i, l) ->
            renderLine results subs assetDir assetRel i l
    pure (T.unlines ["", "---", "", "## Abandoned branches",
                     "", "*Turns superseded by a retry, rewind or compaction.*", ""]
          <> T.concat xs)
  pure (header <> T.concat chunks <> extra)

lastOf :: [a] -> Maybe a
lastOf xs = case reverse xs of (x:_) -> Just x; [] -> Nothing

tshow :: Show a => a -> T.Text
tshow = T.pack . show

renderLine :: Results -> M.Map T.Text (T.Text, [Line]) -> FilePath -> String
           -> Int -> Line -> IO T.Text
renderLine results subs assetDir assetRel ix l
  | isHuman l = pure $ T.unlines
      [ "## 👤 User" <> stampOf l, "", fromMaybe "" (bodyString l), "" ]
  | isSystemTurn l = pure $ T.unlines
      [ "## ⚙️ System" <> stampOf l, ""
      , elideMiddle 40 (fromMaybe "" (bodyString l)), "" ]
  | isCommandRecord l = pure $ T.unlines
      [ "## ⌨️ Command" <> stampOf l, ""
      , fence "" (elideMiddle 40 (fromMaybe "" (bodyString l))), "" ]
  | isInterrupt l = pure $ T.unlines
      [ "## ⚙️ Interrupt" <> stampOf l, "", "*" <> interruptText l <> "*", "" ]
  | lCompact l = pure $ T.unlines
      [ "## ⚙️ Context compaction" <> stampOf l
      , ""
      , "*Earlier conversation was summarised to free context. The summary that"
      , "became the new starting point:*"
      , ""
      , blockquote (fromMaybe "" (bodyString l))
      , ""
      ]
  | lType l == "assistant" = T.concat <$>
      mapM (renderBlock results subs assetDir assetRel ix l) (blocks l)
  | otherwise = pure ""   -- tool_result lines are rendered with their call

stampOf :: Line -> T.Text
stampOf l = case lTime l of
  Just t  -> " · " <> T.take 19 (T.replace "T" " " t) <> " UTC"
  Nothing -> ""

blockquote :: T.Text -> T.Text
blockquote = T.unlines . map ("> " <>) . T.lines

renderBlock :: Results -> M.Map T.Text (T.Text, [Line]) -> FilePath -> String
            -> Int -> Line -> KM.KeyMap Value -> IO T.Text
renderBlock results subs assetDir assetRel ix l b = case txt "type" b of

  Just "text" -> pure $ T.unlines
    [ "## 🤖 Claude" <> stampOf l, "", fromMaybe "" (txt "text" b), "" ]

  Just "thinking" -> pure $ T.unlines
    [ "*💭 " <> tokens <> effort <> " — text not persisted by Claude Code.*", "" ]
    where tokens = case thinkingTokens l of
            Just n | n > 0 -> tshow n <> " thinking tokens"
            _              -> "reasoning step"
          effort = case lEffort l of
            Just e  -> ", effort " <> e
            Nothing -> ""

  Just "tool_use" -> do
    let name = fromMaybe "?" (txt "name" b)
        tid  = fromMaybe "" (txt "id" b)
        inp  = case field "input" b of Just (Object o) -> o; _ -> KM.empty
        (rc, rs) = fromMaybe (Nothing, Nothing) (M.lookup tid results)
    sub <- case M.lookup tid subs of
      Nothing        -> pure ""
      Just (ty, sls) -> renderSubagent results assetDir assetRel ty sls
    pure (renderTool name inp rc rs <> sub)

  Just "image" -> do
    let dat = case field "source" b of
                Just (Object s) -> fromMaybe "" (txt "data" s)
                _               -> ""
        mime = case field "source" b of
                Just (Object s) -> fromMaybe "image/png" (txt "media_type" s)
                _               -> "image/png"
        ext  = T.unpack (T.takeWhileEnd (/= '/') mime)
        fn   = "image-" ++ show ix ++ "." ++ ext
    unless (T.null dat) $ do
      createDirectoryIfMissing True assetDir
      case B64.decode (TE.encodeUtf8 dat) of
        Right raw -> BS.writeFile (assetDir </> fn) raw
        Left _    -> BS.writeFile (assetDir </> (fn ++ ".b64")) (TE.encodeUtf8 dat)
    pure $ T.unlines
      [ "### 🖼️ Image", ""
      , "![image](" <> T.pack (assetRel </> fn) <> ")", "" ]

  _ -> pure ""

-- | Whether a shell command builds something, runs something, or is ordinary
-- shell housekeeping.  A label for the command's kind -- never a claim about
-- its exit status, which Claude Code does not record.
data RunKind = Compile | Runtime | Shell

kindLabel :: RunKind -> T.Text
kindLabel = \case
  Compile -> "compile"
  Runtime -> "runtime"
  Shell   -> "shell"

classify :: T.Text -> RunKind
classify cmd
  | any (`isInfixOf` c) compileWords = Compile
  | any (`isInfixOf` c) runWords     = Runtime
  | otherwise                        = Shell
  where
    c = T.unpack (T.toLower cmd)
    compileWords =
      [ "nix build", "nix-build", "nixos-rebuild", "ghc ", "runghc", "cabal build"
      , "cabal install", "stack build", "make", "gcc ", "g++ ", "clang", "agda "
      , "cargo build", "tsc ", "javac", "nix flake check", "nix-instantiate" ]
    runWords =
      [ "nix run", "./result", "cabal run", "stack run", "cargo run"
      , "runhaskell", "node ", "python", "pytest", "cabal test", "stack test"
      , "nix develop", "./dist", "systemctl", "journalctl" ]

-- | The structured toolUseResult object, when there is one.
resObj :: Maybe Value -> Maybe (KM.KeyMap Value)
resObj (Just (Object o)) = Just o
resObj _                 = Nothing

-- | Bash's returnCodeInterpretation, when Claude Code recorded one
-- ("No matches found", "Files differ", ...).
interpretation :: Maybe Value -> Maybe T.Text
interpretation rs = resObj rs >>= txt "returnCodeInterpretation"

renderTool :: T.Text -> KM.KeyMap Value -> Maybe Value -> Maybe Value -> T.Text
renderTool "Bash" inp rc rs =
  let cmd  = fromMaybe "" (txt "command" inp)
      desc = case txt "description" inp of
               Just d | not (T.null d) -> " — " <> d
               _                       -> ""
      kind = classify cmd
      (out, err) = case rs of
        Just (Object o) -> (fromMaybe "" (txt "stdout" o), fromMaybe "" (txt "stderr" o))
        _               -> (resultText rc, "")
      failed = case rs of
        Just (Object o) -> case field "interrupted" o of Just (Bool True) -> True; _ -> False
        _               -> False
  in T.unlines
     [ "### 🔧 Bash" <> desc
     , ""
     , "#### Ran · " <> kindLabel kind
     , ""
     , fence "sh" cmd
     , stream "stdout" (elideMiddle 100 out)
     , stream "stderr" (elideMiddle 100 err)
     , if failed then "*(interrupted)*\n" else ""
     , case interpretation rs of
         Just s  -> "*(" <> s <> ")*\n"
         Nothing -> ""
     ]

renderTool n inp rc rs
  | n `elem` ["Edit", "Write"] =
      let fp = fromMaybe (fromMaybe "?" (txt "file_path" inp)) $
                 case rs of Just (Object o) -> txt "filePath" o; _ -> Nothing
          patch = case rs of Just (Object o) -> field "structuredPatch" o; _ -> Nothing
          diff  = case patch of
                    Just p@(Array a) | not (V.null a) -> renderPatch p
                    _                                 -> editFallbackDiff inp
          whole = case (n, txt "content" inp) of
                    ("Write", Just c) | T.null diff -> fence "" (elideMiddle 100 c)
                    _                               -> ""
      in T.unlines
         [ "### 🔧 " <> n <> " — `" <> fp <> "`", "", diff, whole ]

  | n == "Read" =
      let fp = fromMaybe "?" (txt "file_path" inp)
          finfo = resObj rs >>= \o -> case field "file" o of
                    Just (Object f) -> Just f
                    _               -> Nothing
          info = case finfo of
            Just f -> " (" <> maybe "?" tshowV (field "numLines" f) <> " lines of "
                           <> maybe "?" tshowV (field "totalLines" f) <> ")"
            Nothing -> ""
          excerpt = case finfo >>= txt "content" of
            Just c | not (T.null (T.strip c)) -> fence "" (headLines 30 c)
            _                                 -> ""
      in T.unlines ["### 🔧 Read — `" <> fp <> "`" <> info, "", excerpt]

  | n == "Agent" =
      let a = resultText rc
          answer
            | T.null (T.strip a) = ""
            | otherwise = T.unlines
                [ "**Subagent's answer:**", ""
                , blockquote (elideMiddle 100 a) ]
      in T.unlines
        [ "### 🤝 Subagent — " <> fromMaybe "" (txt "description" inp)
            <> " (`" <> fromMaybe "general" (txt "subagent_type" inp) <> "`)"
        , ""
        , "**Prompt given to the subagent:**"
        , ""
        , blockquote (fromMaybe "" (txt "prompt" inp))
        , ""
        , answer
        ]

  | otherwise =
      T.unlines
        [ "### 🔧 " <> n
        , ""
        , fence "json" (prettyKM inp)
        , stream "result" (elideMiddle 100 (resultText rc))
        ]

-- | When there is no structuredPatch (interrupted edits, some error paths),
-- reconstruct a minimal diff from the tool input's old/new strings.
editFallbackDiff :: KM.KeyMap Value -> T.Text
editFallbackDiff inp =
  case (txt "old_string" inp, txt "new_string" inp) of
    (Just o, Just nw) -> fence "diff" $ elideMiddle 60 $
      T.intercalate "\n" (map ("- " <>) (T.lines o) ++ map ("+ " <>) (T.lines nw))
    _ -> ""

tshowV :: Value -> T.Text
tshowV (Number x) = tshow (round x :: Int)
tshowV (String s) = s
tshowV v          = T.pack (show v)

prettyKM :: KM.KeyMap Value -> T.Text
prettyKM = T.pack . BLC.unpack . A.encode . Object

renderPatch :: Value -> T.Text
renderPatch (Array hs) = T.unlines
  [ fence "diff" (T.intercalate "\n" (concatMap hunk (V.toList hs))) ]
  where
    hunk (Object h) =
      let n k = case field k h of Just (Number x) -> tshow (round x :: Int); _ -> "?"
          hdr = "@@ -" <> n "oldStart" <> "," <> n "oldLines"
                <> " +" <> n "newStart" <> "," <> n "newLines" <> " @@"
          ls' = case field "lines" h of
                  Just (Array a) -> [s | String s <- V.toList a]
                  _              -> []
      in hdr : ls'
    hunk _ = []
renderPatch _ = ""

resultText :: Maybe Value -> T.Text
resultText = \case
  Just (String s) -> s
  Just (Array a)  -> T.intercalate "\n"
                       [ fromMaybe "" (txt "text" o) | Object o <- V.toList a ]
  Just v          -> T.pack (show v)
  Nothing         -> ""

-- | A labelled output stream.  Empty streams are still named, so the reader can
-- tell "produced nothing" from "not captured".
stream :: T.Text -> T.Text -> T.Text
stream name body
  | T.null (T.strip body) = "\n**" <> name <> "** — empty\n"
  | otherwise =
      "\n**" <> name <> "** — " <> plural (length (T.lines body)) "line" <> "\n\n"
      <> fence "" body

plural :: Int -> T.Text -> T.Text
plural n w = tshow n <> " " <> w <> (if n == 1 then "" else "s")

-- | Keep the first and last lines of an over-long text, eliding the middle.
elideMiddle :: Int -> T.Text -> T.Text
elideMiddle cap t =
  let ls = T.lines t
      n  = length ls
      h  = cap `div` 2
  in if n <= cap then t
     else T.intercalate "\n" $
            take h ls
            ++ ["… (" <> tshow (n - cap) <> " lines elided) …"]
            ++ drop (n - (cap - h)) ls

-- | Keep only the first N lines, with a trailing marker when truncated.
headLines :: Int -> T.Text -> T.Text
headLines cap t =
  let ls = T.lines t
      n  = length ls
  in if n <= cap then t
     else T.intercalate "\n" (take cap ls ++ ["… (" <> tshow (n - cap) <> " more lines)"])

-- | Fence with enough backticks to survive fenced content verbatim.
fence :: T.Text -> T.Text -> T.Text
fence lang body =
  let runOf t = T.length (T.takeWhile (== '`') (T.stripStart t))
      longest = maximum (0 : map runOf (T.lines body))
      bars    = T.replicate (max 3 (longest + 1)) "`"
  in bars <> lang <> "\n" <> stripTrailing body <> "\n" <> bars <> "\n"
  where stripTrailing = T.dropWhileEnd (== '\n')

renderSubagent :: Results -> FilePath -> String -> T.Text -> [Line] -> IO T.Text
renderSubagent _ assetDir assetRel ty sls = do
  let (branch, _) = mainBranch sls
      res         = indexResults sls
  parts <- forM (zip [20000 :: Int ..] branch) $ \(i, l) ->
             renderLine res M.empty assetDir assetRel i l
  pure $ T.unlines
    [ "<details><summary>Subagent transcript (" <> ty <> ", "
        <> tshow (length branch) <> " messages)</summary>", "" ]
    <> T.concat parts
    <> T.unlines ["", "</details>", ""]

-- ------------------------------------------------------------------- backfill

backfill :: FilePath -> FilePath -> IO ()
backfill projects outDir = do
  files <- findSessions projects
  hPutStrLn stderr ("llm-transcript: rendering " ++ show (length files) ++ " sessions")
  forM_ files $ \f -> do
    r <- try (renderFile f outDir) :: IO (Either SomeException ())
    case r of
      Left e  -> hPutStrLn stderr ("  FAILED " ++ f ++ ": " ++ show e)
      Right _ -> pure ()

-- | Top-level session files only; subagent transcripts are pulled in by the
-- session that spawned them.
findSessions :: FilePath -> IO [FilePath]
findSessions root = do
  ok <- doesDirectoryExist root
  if not ok then pure [] else do
    dirs <- listDirectory root
    fmap concat . forM dirs $ \d -> do
      let p = root </> d
      isDir <- doesDirectoryExist p
      if not isDir then pure [] else do
        ns <- listDirectory p
        pure [p </> n | n <- ns, ".jsonl" `isSuffixOf` n]

-- --------------------------------------------------------------- corpus mode

-- | Emit training documents from every session: JSONL {id, text}, the format
-- ana's `deploy plan-corpus` consumes.  Cleaned (capped output, no
-- Read bodies, no bookkeeping), scrubbed (secrets to stable placeholders,
-- with a printed per-class report), exact-deduplicated, and with a few whole
-- sessions held out to <out>.holdout.jsonl so a later split cannot put
-- neighbouring segments of one session on both sides.
corpus :: Int -> FilePath -> FilePath -> IO ()
corpus segBytes projects out = do
  files <- findSessions projects
  hPutStrLn stderr ("llm-transcript: corpus from " ++ show (length files) ++ " sessions")
  perSession <- forM files $ \f -> do
    r <- try (sessionDocs segBytes f) :: IO (Either SomeException [(T.Text, T.Text)])
    case r of
      Left e   -> do hPutStrLn stderr ("  FAILED " ++ f ++ ": " ++ show e)
                     pure (takeBaseName f, [])
      Right ds -> pure (takeBaseName f, ds)
  let sess = sortOn fst [(s, d) | (s, d) <- perSession, not (null d)]
      n    = length sess
      -- Hold out four whole sessions, spread across the id ordering; skip the
      -- holdout entirely when there are too few sessions to spare any.
      holdIdx = if n >= 8 then S.fromList [i * n `div` 4 | i <- [0 .. 3]] else S.empty
      (holdS, mainS) = partition (\(i, _) -> S.member i holdIdx) (zip [0 ..] sess)
      holdDocs = concatMap (snd . snd) holdS
      mainDocs = concatMap (snd . snd) mainS
      -- Scrub before dedup so normalised placeholders can collide and merge.
      -- Box IPs are harvested globally first: an address that ever occurs as
      -- root@<ip> is a rented box, and its bare occurrences (log paths like
      -- pulled-root-<ip>-<port>) must go too, not just the root@ form.
      boxIps = harvestBoxIps (map snd (holdDocs ++ mainDocs))
      (holdCounts, holdScrubbed) = scrubDocs boxIps holdDocs
      (mainCounts, mainScrubbed) = scrubDocs boxIps mainDocs
      counts = M.unionWith (+) holdCounts mainCounts
      -- Exact dedup; holdout claims its texts first so nothing leaks across.
      dedup _    acc [] = reverse acc
      dedup seen acc ((i, t) : rest)
        | S.member t seen = dedup seen acc rest
        | otherwise       = dedup (S.insert t seen) ((i, t) : acc) rest
      holdKept = dedup S.empty [] holdScrubbed
      mainKept = dedup (S.fromList (map snd holdKept)) [] mainScrubbed
      encode (i, t) = A.encode (A.object ["id" .= i, "text" .= t])
      holdOut = out ++ ".holdout.jsonl"
      dupsDropped = (length holdScrubbed - length holdKept)
                  + (length mainScrubbed - length mainKept)
      ids = map fst (holdKept ++ mainKept)
      report = T.unlines $
        [ "sessions: " <> tshow n
            <> " (" <> tshow (length holdS) <> " held out: "
            <> T.intercalate ", " [T.pack (take 8 s) | (_, (s, _)) <- holdS] <> ")"
        , "documents: " <> tshow (length mainKept) <> " main, "
            <> tshow (length holdKept) <> " holdout, "
            <> tshow dupsDropped <> " exact duplicates dropped"
        , "scrubbed:" ] ++
        [ "  " <> c <> ": " <> tshow k | (c, k) <- M.toList counts ]
  unless (length ids == S.size (S.fromList ids)) $ do
    hPutStrLn stderr "llm-transcript: BUG: duplicate document ids"
    exitFailure
  BLC.writeFile out       (BLC.unlines (map encode mainKept))
  BLC.writeFile holdOut   (BLC.unlines (map encode holdKept))
  TIO.writeFile (out ++ ".scrub-report.txt") report
  TIO.hPutStr stderr report
  putStrLn out
  putStrLn holdOut

-- | One session -> segmented, id-stamped documents (not yet scrubbed).
sessionDocs :: Int -> FilePath -> IO [(T.Text, T.Text)]
sessionDocs segBytes f = do
  raw <- BLC.readFile f
  let ls = mapMaybe decodeLine (BLC.lines raw)
  if null ls then pure [] else do
    -- Subagent transcripts are not read here: the Agent call's tool_result in
    -- the parent session already carries the subagent's final answer.
    --
    -- Unlike render mode, this does NOT walk the DAG from the newest leaf:
    -- compaction restarts the parentUuid chain, so on a long session the
    -- surviving branch holds a few percent of the conversation and everything
    -- earlier is orphaned.  The file is append-ordered, so taking the
    -- conversation lines in file order preserves the whole chronology; the
    -- rare retried turn shows up twice, which exact dedup and training both
    -- tolerate far better than losing 90+% of every compacted session.
    let conv    = [l | l <- ls, lType l `elem` ["user", "assistant"]]
        results = indexResults ls
        pieces  = filter (not . T.null . T.strip)
                    (map (sanitize . corpusLine results) conv)
        sid8        = T.pack (take 8 (takeBaseName f))
        docs        = segment segBytes pieces
    pure [ (sid8 <> "-" <> pad4 i, d) | (i, d) <- zip [0 :: Int ..] docs ]
  where
    pad4 i = let s = show i in T.pack (replicate (4 - length s) '0' ++ s)

-- | Captured terminal output is full of things that are poison in a training
-- document and fatal to the NUL-framed corpus pipeline downstream: ANSI
-- escape sequences, carriage-return overwrites, and (in sessions that discuss
-- NUL-delimited pipelines) literal NUL bytes.  Strip escapes, turn \r into
-- newlines, and drop every other control character except \n and \t.
sanitize :: T.Text -> T.Text
sanitize = T.filter keep . T.replace "\r" "\n" . stripAnsi
  where
    keep c = (c >= ' ' && c /= '\DEL') || c == '\n' || c == '\t'
    stripAnsi t =
      let ms = getAllMatches (t =~ ("\ESC\\[[0-9;?]*[@-~]" :: T.Text)
                                :: AllMatches [] (MatchOffset, MatchLength))
          cut pos acc [] = T.concat (reverse (T.drop pos t : acc))
          cut pos acc ((off, len) : rest) =
            cut (off + len) (T.take (off - pos) (T.drop pos t) : acc) rest
      in cut 0 [] ms

-- | Pack per-turn texts into documents of roughly the target byte size,
-- splitting only at turn boundaries.
segment :: Int -> [T.Text] -> [T.Text]
segment segBytes = go [] 0
  where
    go acc _ [] = flush acc
    go acc sz (p : rest)
      | sz > 0 && sz + bytes p > segBytes = flush acc ++ go [p] (bytes p) rest
      | otherwise                         = go (p : acc) (sz + bytes p) rest
    bytes = BS.length . TE.encodeUtf8
    flush [] = []
    flush ps = [T.intercalate "\n" (reverse ps)]

-- | The training-corpus rendering of one conversation line.  Leaner than the
-- human-facing renderer: plain ASCII headings, tighter caps, no bookkeeping,
-- no Read file bodies (large, duplicated, and the worst secret vector).
corpusLine :: Results -> Line -> T.Text
corpusLine results l
  | isHuman l = "## User\n\n" <> fromMaybe "" (bodyString l) <> "\n"
  | lType l == "assistant" =
      let parts = filter (not . T.null) (map block (blocks l))
      in if null parts then "" else "## Assistant\n\n" <> T.concat parts
  | otherwise = ""   -- system turns, command records, compaction, tool results
  where
    block b = case txt "type" b of
      Just "text"     -> fromMaybe "" (txt "text" b) <> "\n"
      Just "thinking" -> case thinkingTokens l of
        Just n | n > 0 -> "*(thought for " <> tshow n <> " tokens)*\n"
        _              -> ""
      Just "tool_use" ->
        let name = fromMaybe "?" (txt "name" b)
            tid  = fromMaybe "" (txt "id" b)
            inp  = case field "input" b of Just (Object o) -> o; _ -> KM.empty
            (rc, rs) = fromMaybe (Nothing, Nothing) (M.lookup tid results)
        in corpusTool name inp rc rs
      _ -> ""

corpusTool :: T.Text -> KM.KeyMap Value -> Maybe Value -> Maybe Value -> T.Text
corpusTool "Bash" inp rc rs =
  let cmd = fromMaybe "" (txt "command" inp)
      (out, err) = case rs of
        Just (Object o) -> (fromMaybe "" (txt "stdout" o), fromMaybe "" (txt "stderr" o))
        _               -> (resultText rc, "")
      part name body
        | T.null (T.strip body) = ""
        | otherwise = "**" <> name <> ":**\n\n" <> fence "" (elideMiddle 40 body)
  in fence "sh" cmd
     <> part "stdout" out
     <> part "stderr" err
     <> case interpretation rs of
          Just s  -> "*(" <> s <> ")*\n"
          Nothing -> ""

corpusTool n inp rc rs
  | n `elem` ["Edit", "Write"] =
      let fp = fromMaybe "?" (txt "file_path" inp)
          patch = case rs of Just (Object o) -> field "structuredPatch" o; _ -> Nothing
          diff  = case patch of
                    Just p@(Array a) | not (V.null a) -> renderPatch p
                    _                                 -> editFallbackDiff inp
          whole = case (n, txt "content" inp) of
                    ("Write", Just c) | T.null diff -> fence "" (elideMiddle 40 c)
                    _                               -> ""
      in "### " <> n <> " — `" <> fp <> "`\n\n"
         <> (if T.null diff then whole else elideFence 60 diff)

  | n == "Read" =
      "### Read — `" <> fromMaybe "?" (txt "file_path" inp) <> "`\n"

  | n == "Agent" =
      let answer = resultText rc
      in "### Subagent — " <> fromMaybe "" (txt "description" inp) <> "\n\n"
         <> blockquote (elideMiddle 40 (fromMaybe "" (txt "prompt" inp)))
         <> (if T.null (T.strip answer) then ""
             else "\n**Answer:**\n\n" <> blockquote (elideMiddle 60 answer))

  | otherwise =
      let res = resultText rc
      in "### " <> n <> "\n"
         <> (if T.null (T.strip res) then ""
             else "\n" <> fence "" (elideMiddle 40 res))

-- | Cap an already-fenced block by eliding the body, keeping the fences.
elideFence :: Int -> T.Text -> T.Text
elideFence cap t =
  let ls = T.lines (T.dropWhileEnd (== '\n') t)
  in case ls of
       (open : rest@(_ : _)) ->
         let body  = init rest
             close = last rest
         in T.unlines ([open] ++ T.lines (elideMiddle cap (T.intercalate "\n" body)) ++ [close])
       _ -> t

-- ------------------------------------------------------------------ scrubbing

-- | Secrets go to stable placeholders, and every replacement is counted per
-- class: a scrubber that reports nothing is more likely broken than lucky.
-- Order matters -- box addresses before the email pattern, or root@<ip> would
-- be half-eaten as an email.
scrubDoc :: S.Set T.Text -> T.Text -> (M.Map T.Text Int, T.Text)
scrubDoc boxIps = go (classes ++ [bareIpClass ip | ip <- S.toList boxIps])
  where
    go [] t       = (M.empty, t)
    go (c : cs) t = let (k, t')   = c t
                        (m, t'')  = go cs t'
                    in (M.unionWith (+) k m, t'')
    -- Bare occurrences of a known box IP, after the root@ class has run.
    bareIpClass ip t =
      let n = T.count ip t
      in if n == 0 then (M.empty, t)
         else (M.singleton "box-ip-bare" n, T.replace ip "[BOX_IP]" t)
    classes =
      [ regexClass "crypt-hash"  "\\$6\\$[A-Za-z0-9./$]+"                          (const "[CRYPT_HASH]")
      , pemClass
      , regexClass "sk-key"      "sk-[A-Za-z0-9_-]{16,}"                           (const "[API_KEY]")
      , regexClass "ghp-token"   "ghp_[A-Za-z0-9]{20,}"                            (const "[GITHUB_TOKEN]")
      , regexClass "apikey"      "[Aa][Pp][Ii]_?[Kk][Ee][Yy]=[A-Za-z0-9_-]{8,}"    (const "apikey=[REDACTED]")
      , regexClass "aws-key"     "AKIA[A-Z0-9]{16}"                                (const "[AWS_KEY]")
      , regexClass "box-address" "root@[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}" (const "root@[BOX_IP]")
      , regexClass "email"       "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+"
          (\m -> if m `elem` allowedEmails then m else "[EMAIL]")
      ]
    allowedEmails = ["hhefesto@rdataa.com"]

scrubDocs :: S.Set T.Text -> [(T.Text, T.Text)] -> (M.Map T.Text Int, [(T.Text, T.Text)])
scrubDocs boxIps docs =
  let scrubbed = [ (cs, (i, t')) | (i, t) <- docs, let (cs, t') = scrubDoc boxIps t ]
  in (M.unionsWith (+) (map fst scrubbed), map snd scrubbed)

-- | Every address that ever appears as root@<ip> anywhere in the corpus.
harvestBoxIps :: [T.Text] -> S.Set T.Text
harvestBoxIps ts = S.fromList
  [ T.drop 5 m
  | t <- ts
  , (off, len) <- getAllMatches
      (t =~ ("root@[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}" :: T.Text)
         :: AllMatches [] (MatchOffset, MatchLength))
  , let m = T.take len (T.drop off t)
  ]

-- | One scrub class: name it, match it, count it, replace it.  The replacer
-- sees the matched text so a class can allow-list (emails).  A replacement
-- identical to the match does not count.
regexClass :: T.Text -> T.Text -> (T.Text -> T.Text) -> T.Text -> (M.Map T.Text Int, T.Text)
regexClass name pat repl t =
  let ms = getAllMatches (t =~ pat :: AllMatches [] (MatchOffset, MatchLength))
      splice pos acc cnt [] = (cnt, T.concat (reverse (T.drop pos t : acc)))
      splice pos acc cnt ((off, len) : rest) =
        let m = T.take len (T.drop off t)
            r = repl m
            keep = T.take (off - pos) (T.drop pos t)
        in if r == m
             then splice pos acc cnt rest
             else splice (off + len) (r : keep : acc) (cnt + 1) rest
      (n, t') = splice 0 [] (0 :: Int) ms
  in (if n == 0 then M.empty else M.singleton name n, t')

-- | PEM blocks span lines, which POSIX ERE handles badly; walk them by hand.
pemClass :: T.Text -> (M.Map T.Text Int, T.Text)
pemClass = go 0 []
  where
    go cnt acc t = case T.breakOn "-----BEGIN " t of
      (before, rest)
        | T.null rest -> ( if cnt == 0 then M.empty else M.singleton "pem-block" cnt
                         , T.concat (reverse (before : acc)) )
        | otherwise -> case T.breakOn "-----END" (T.drop 11 rest) of
            (_, rest') | T.null rest' ->
              -- Unterminated header: scrub to end of line and stop scanning.
              let after = T.dropWhile (/= '\n') rest
              in go (cnt + 1) ("[PEM_BLOCK]" : before : acc) after
            (_, rest') ->
              let after = T.dropWhile (/= '\n') rest'
              in go (cnt + 1) ("[PEM_BLOCK]" : before : acc) after
