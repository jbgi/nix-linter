{-# LANGUAGE ApplicativeDo         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}

{-# OPTIONS_GHC -Wno-missing-signatures -Wno-name-shadowing #-}

module Main where

import           Prelude                hiding (log)

import           Control.Arrow          ((&&&), (>>>))
import           Control.Monad          (join)
import           Control.Monad.Trans    (MonadIO, liftIO)
import           Data.Foldable          (foldMap, for_)
import           Data.Function          ((&))
import           Data.List              (isSuffixOf)
import           Data.Text              (Text)

import           Data.Text.IO
import           Path.Internal          (toFilePath)
import           Path.IO                (getCurrentDir, listDir, resolveDir')
import           System.Exit
import           System.IO              (IOMode (..), stderr, stdout, withFile)

import qualified Data.ByteString.Lazy   as B

import           Nix.Parser

import qualified Data.Set               as Set

import           Streamly
import           Streamly.Prelude       ((.:))
import qualified Streamly.Prelude       as S

import           Data.Aeson             (encode)

import           Opts

import           Nix.Linter
import           Nix.Linter.Types
import           Nix.Linter.Utils

import           System.Console.CmdArgs

getChecks :: NixLinter -> Either [String] [OffenseCategory]
getChecks (NixLinter {..}) = let
    defaults = Set.fromList $ category <$> filter defaultEnabled checks
    parsedArgs = sequenceEither $ parseCheckArg <$> check
    categories = (\fs -> foldl (flip ($)) defaults fs) <$> parsedArgs
  in Set.toList <$> categories

getCombined :: NixLinter -> IO Check
getCombined opts = do
  enabled <- case getChecks opts of
    Right cs -> pure cs
    Left err -> do
      for_ err print
      exitFailure

  whenLoud $ do
    log "Enabled checks:"
    if null enabled
      then log "  (None)"
      else for_ enabled $ \check -> do
        log $ "- " <> pShow check

  pure $ checkCategories enabled

main :: IO ()
main =  cmdArgs nixLinter >>= runChecks

log :: Text -> IO ()
log = hPutStrLn stderr

-- Example from https://hackage.haskell.org/package/streamly
listDirRecursive :: (IsStream t, MonadIO m, MonadIO (t m), Monoid (t m FilePath)) => FilePath -> t m FilePath
listDirRecursive path = resolveDir' path >>= readDir
  where
    readDir dir = do
      (dirs, files) <- listDir dir
      S.fromList (toFilePath <$> files) `serial` foldMap readDir dirs

parseFiles = S.mapMaybeM $ (\path ->
  parseNixFileLoc path >>= \case
    Success parse -> do
      pure $ Just parse
    Failure why -> do
      liftIO $ whenNormal $ log $ "Failure when parsing:\n" <> pShow why
      pure Nothing)

pipeline (NixLinter {..}) combined = let
    exitLog x = S.yieldM . liftIO . const (log x >> exitFailure)
    walker = if recursive
      then (>>= listDirRecursive)
      else id

    walk = case (recursive, null files) of
      (False, True) -> exitLog "No files to parse, quitting..."
      (True, True)  -> ("." .:) >>> walker
      (_, _)        -> walker

  in
    S.fromList files
    & walk
    & S.filter (isSuffixOf ".nix")
    & aheadly . parseFiles
    & aheadly . (S.map (combined >>> S.fromList) >>> join)

runChecks :: NixLinter -> IO ()
runChecks (opts@NixLinter{..}) = do
  combined <- getCombined opts

  let withOutHandle = if null out
      then ($ stdout)
      else withFile out WriteMode

      printer = \handle -> if
        | json_stream -> \w -> B.hPut handle (encode w) >> hPutStr handle "\n"
        | json -> B.hPutStr handle . encode
        | otherwise -> hPutStrLn handle . prettyOffense

      results = pipeline opts combined

  noIssues <- S.null results
  withOutHandle $ \handle -> S.mapM_ (liftIO . printer handle) results

  if noIssues then exitSuccess else exitFailure
