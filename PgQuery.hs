{-# LANGUAGE OverloadedStrings #-}

-- {{{ Imports

module PgQuery where

import Data.Functor ( (<$>) )
import Data.Maybe (fromMaybe)
import Data.List (intersperse, intercalate)
import Data.Monoid ((<>), mconcat)

import qualified RangeQuery as R
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BL

import Database.HDBC hiding (colType, colNullable)
import Database.HDBC.PostgreSQL

import qualified Network.HTTP.Types.URI as Net

-- }}}

data RangedResult = RangedResult {
  rrFrom  :: Int
, rrTo    :: Int
, rrTotal :: Int
, rrBody  :: BL.ByteString
}

type QuotedSql = (String, [SqlValue])

getRows :: String -> String -> Net.Query -> Maybe R.NonnegRange -> Connection -> IO RangedResult
getRows schema table qq range conn = do
  query <- populateSql conn
    $ globalAndLimitedCounts schema table qq <>
      jsonArrayRows
      (selectStarClause schema table
        <> whereClause qq
        <> limitClause range)
  r <- quickQuery conn query []

  return $ case r of
           [[_, _, SqlNull]] -> RangedResult 0 0 0 ""
           [[total, limited_total, json]] ->
            RangedResult offset (offset + fromSql limited_total - 1)
                         (fromSql total) (fromSql json)
           _ -> RangedResult 0 0 0 ""

  where
    offset = fromMaybe 0 $ R.offset <$> range

whereClause :: Net.Query -> QuotedSql
whereClause qs =
  if null qs then ("", []) else (" where ", []) <> conjunction

  where
    conjunction = mconcat $ intersperse (" and ", []) (map wherePred qs)


wherePred :: Net.QueryItem -> QuotedSql
wherePred (column, predicate) =
  ("%I " <> op <> "%L", map toSql [column, value])

  where
    opCode:rest = BS.split ':' $ fromMaybe "" predicate
    value = BS.intercalate ":" rest
    op = case opCode of
              "eq"  -> "="
              "gt"  -> ">"
              "lt"  -> "<"
              "gte" -> ">="
              "lte" -> "<="
              "neq" -> "<>"
              _     -> "="


limitClause :: Maybe R.NonnegRange -> QuotedSql
limitClause range =
  (" LIMIT %s OFFSET %s ", [toSql limit, toSql offset])

  where
    limit  = fromMaybe "ALL" $ show <$> (R.limit =<< range)
    offset = fromMaybe 0     $ R.offset <$> range

globalAndLimitedCounts :: String -> String -> Net.Query -> QuotedSql
globalAndLimitedCounts schema table qq =
  (" select ", [])
  <> ("(select count(1) from %I.%I ", map toSql [schema, table])
  <> whereClause qq
  <> ("), count(t), ", [])

selectStarClause :: String -> String -> QuotedSql
selectStarClause schema table =
  (" select * from %I.%I ", map toSql [schema, table])

selectCountClause :: String -> String -> QuotedSql
selectCountClause schema table =
  (" select count(1) from %I.%I ", map toSql [schema, table])

jsonArrayRows :: QuotedSql -> QuotedSql
jsonArrayRows q =
  ("array_to_json(array_agg(row_to_json(t))) from (", []) <> q <> (") t", [])

populateSql :: Connection -> QuotedSql -> IO String
populateSql conn sql = do
  [[escaped]] <- quickQuery conn q (snd sql)
  return $ fromSql escaped

  where
    q = concat [ "select format('", fst sql, "', ", placeholders (snd sql), ")" ]

    placeholders :: [a] -> String
    placeholders = intercalate ", " . map (const "?::varchar")
