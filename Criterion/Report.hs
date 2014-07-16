{-# LANGUAGE DeriveDataTypeable, DeriveGeneric, OverloadedStrings,
    RecordWildCards, ScopedTypeVariables #-}

-- |
-- Module      : Criterion.Report
-- Copyright   : (c) 2009-2014 Bryan O'Sullivan
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Reporting functions.

module Criterion.Report
    (
      Report(..)
    , formatReport
    , report
    -- * Rendering helper functions
    , TemplateException(..)
    , loadTemplate
    , includeFile
    , templateDir
    , vector
    , vector2
    ) where

import Control.Exception (Exception, IOException, throwIO)
import Control.Monad (mplus)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Criterion.Analysis (Outliers(..), SampleAnalysis(..))
import Criterion.Config (cfgReport, cfgTemplate, fromLJ)
import Criterion.Monad (Criterion, getConfig)
import Criterion.Types (Measured(..), measure, rescale)
import Data.Aeson.Encode (encodeToTextBuilder)
import Data.Aeson.Types (FromJSON, ToJSON(..))
import Data.Data (Data, Typeable)
import Data.Monoid (Last(..))
import GHC.Generics (Generic)
import Paths_criterion (getDataFileName)
import Statistics.Sample.KernelDensity (kde)
import System.Directory (doesFileExist)
import System.FilePath ((</>), (<.>), isPathSeparator)
import System.IO.Unsafe (unsafePerformIO)
import Text.Hastache (MuType(..))
import Text.Hastache.Context (mkGenericContext, mkStrContext, mkStrContextM)
import qualified Control.Exception as E
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as TL
import qualified Data.Text.Lazy.IO as TL
import qualified Data.Vector.Generic as G
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Text.Hastache as H

data Report = Report {
      reportNumber   :: Int
    , reportName     :: String
    , reportKeys     :: [String]
    , reportMeasured :: V.Vector Measured
    , reportAnalysis :: SampleAnalysis
    , reportOutliers :: Outliers
    } deriving (Eq, Read, Show, Typeable, Data, Generic)

instance FromJSON Report
instance ToJSON Report

-- | The path to the template and other files used for generating
-- reports.
templateDir :: FilePath
templateDir = unsafePerformIO $ getDataFileName "templates"
{-# NOINLINE templateDir #-}

-- | Write out a series of 'Report' values to a single file, if
-- configured to do so.
report :: [Report] -> Criterion ()
report reports = do
  cfg <- getConfig
  case cfgReport cfg of
    Last Nothing -> return ()
    Last (Just name) -> liftIO $ do
      tpl <- loadTemplate [".",templateDir] (fromLJ cfgTemplate cfg)
      TL.writeFile name =<< formatReport reports tpl

-- | Format a series of 'Report' values using the given Hastache
-- template.
formatReport :: [Report]
             -> T.Text    -- ^ Hastache template.
             -> IO TL.Text
formatReport reports template = do
  templates <- getDataFileName "templates"
  let context "report"  = return $ MuList $ map inner reports
      context "json"    = return $ MuVariable (encode reports)
      context "include" = return $ MuLambdaM $ includeFile [templateDir]
      context _         = return $ MuNothing
      encode v = TL.toLazyText . encodeToTextBuilder . toJSON $ v
      inner r@Report{..} = mkStrContextM $ \nym ->
                         case nym of
                           "name"     -> return . MuVariable . H.htmlEscape .
                                         TL.pack $ reportName
                           "json"     -> return $ MuVariable (encode r)
                           "number"   -> return $ MuVariable reportNumber
                           "iters"    -> return $ vector "x" iters
                           "times"    -> return $ vector "x" times
                           "cycles"   -> return $ vector "x" cycles
                           "kdetimes" -> return $ vector "x" kdeTimes
                           "kdepdf"   -> return $ vector "x" kdePDF
                           "kde"      -> return $ vector2 "time" "pdf" kdeTimes kdePDF
                           ('a':'n':_)-> mkGenericContext reportAnalysis $
                                         H.encodeStr nym
                           _          -> mkGenericContext reportOutliers $
                                         H.encodeStr nym
          where (kdeTimes,kdePDF) = kde 128 scaledTimes
                iters       = measure measIters reportMeasured
                times       = measure measTime reportMeasured
                scaledTimes = measure (measTime . rescale) reportMeasured
                cycles      = measure measCycles reportMeasured
      config = H.defaultConfig {
                 H.muEscapeFunc = H.emptyEscape
               , H.muTemplateFileDir = Just templates
               , H.muTemplateFileExt = Just ".tpl"
               }
  H.hastacheStr config template context

-- | Render the elements of a vector.
--
-- For example, given this piece of Haskell:
--
-- @'mkStrContext' $ \\name ->
-- case name of
--   \"foo\" -> 'vector' \"x\" foo@
--
-- It will substitute each value in the vector for @x@ in the
-- following Hastache template:
--
-- > {{#foo}}
-- >  {{x}}
-- > {{/foo}}
vector :: (Monad m, G.Vector v a, H.MuVar a) =>
          String                -- ^ Name to use when substituting.
       -> v a
       -> MuType m
{-# SPECIALIZE vector :: String -> U.Vector Double -> MuType IO #-}
vector name v = MuList . map val . G.toList $ v
    where val i = mkStrContext $ \nym ->
                  if nym == name
                  then MuVariable i
                  else MuNothing

-- | Render the elements of two vectors.
vector2 :: (Monad m, G.Vector v a, G.Vector v b, H.MuVar a, H.MuVar b) =>
           String               -- ^ Name for elements from the first vector.
        -> String               -- ^ Name for elements from the second vector.
        -> v a                  -- ^ First vector.
        -> v b                  -- ^ Second vector.
        -> MuType m
{-# SPECIALIZE vector2 :: String -> String -> U.Vector Double -> U.Vector Double
                       -> MuType IO #-}
vector2 name1 name2 v1 v2 = MuList $ zipWith val (G.toList v1) (G.toList v2)
    where val i j = mkStrContext $ \nym ->
                    case undefined of
                      _| nym == name1 -> MuVariable i
                       | nym == name2 -> MuVariable j
                       | otherwise    -> MuNothing

-- | Attempt to include the contents of a file based on a search path.
-- Returns 'B.empty' if the search fails or the file could not be read.
--
-- Intended for use with Hastache's 'MuLambdaM', for example:
--
-- @context \"include\" = 'MuLambdaM' $ 'includeFile' ['templateDir']@
--
-- Hastache template expansion is /not/ performed within the included
-- file.  No attempt is made to ensure that the included file path is
-- safe, i.e. that it does not refer to an unexpected file such as
-- \"@/etc/passwd@\".
includeFile :: (MonadIO m) =>
               [FilePath]       -- ^ Directories to search.
            -> T.Text          -- ^ Name of the file to search for.
            -> m T.Text
{-# SPECIALIZE includeFile :: [FilePath] -> T.Text -> IO T.Text #-}
includeFile searchPath name = liftIO $ foldr go (return T.empty) searchPath
    where go dir next = do
            let path = dir </> H.decodeStr name
            T.readFile path `E.catch` \(_::IOException) -> next

-- | A problem arose with a template.
data TemplateException =
    TemplateNotFound FilePath   -- ^ The template could not be found.
    deriving (Eq, Read, Show, Typeable, Data, Generic)

instance Exception TemplateException

-- | Load a Hastache template file.
--
-- If the name is an absolute or relative path, the search path is
-- /not/ used, and the name is treated as a literal path.
--
-- This function throws a 'TemplateException' if the template could
-- not be found, or an 'IOException' if no template could be loaded.
loadTemplate :: [FilePath]      -- ^ Search path.
             -> FilePath        -- ^ Name of template file.
             -> IO T.Text
loadTemplate paths name
    | any isPathSeparator name = T.readFile name
    | otherwise                = go Nothing paths
  where go me (p:ps) = do
          let cur = p </> name <.> "tpl"
          x <- doesFileExist cur
          if x
            then T.readFile cur `E.catch` \e -> go (me `mplus` Just e) ps
            else go me ps
        go (Just e) _ = throwIO (e::IOException)
        go _        _ = throwIO . TemplateNotFound $ name
