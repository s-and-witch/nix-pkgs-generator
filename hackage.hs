-- 
-- This script was written by Alexey Khudyakov @shimuuar
-- during his work as Sirius.Courses
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost        #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}
import Control.Monad (when)
import Control.Monad.IO.Class
import Control.DeepSeq
import Development.Shake
import Development.Shake.FilePath
import Data.Aeson
import Data.Maybe
import Data.List.Split (splitWhen)
import Data.Yaml qualified as YAML
import Data.Foldable
import Data.Hashable (Hashable(..))
import Data.Binary (Binary)
import Data.Version
import Data.Map.Strict qualified as Map
import PyF (fmt)
import Text.ParserCombinators.ReadP (readP_to_S)
import GHC.Generics (Generic)

import Debug.Trace


----------------------------------------------------------------
--
----------------------------------------------------------------

newtype PkgName = PkgName String
  deriving stock   (Show, Eq, Generic)
  deriving newtype (Hashable, Binary, NFData)

type instance RuleResult PkgName = Source

newtype Repository = Repository String
  deriving stock   (Show, Eq, Generic)
  deriving newtype (Hashable, Binary, FromJSON, NFData)

type instance RuleResult Repository = Git


-- | Source for package
data Source
  = SourceCabal Version                   -- ^ Fetch package from hackage
  | SourceGit   Git        (Maybe String) -- ^ Fetch package from git
  | SourceRef   Repository (Maybe String) -- ^ Use git repository referenced by name
  deriving stock    (Show, Eq, Generic)
  deriving anyclass (Hashable, Binary, NFData)

-- | Information about git repository
data Git = Git
  { gitURL     :: String -- ^ URI of git repository
  , gitRev     :: String -- ^ Revision to fetch
  }
  deriving stock    (Show, Eq, Generic)
  deriving anyclass (Hashable, Binary, NFData)

instance FromJSON Source where
  parseJSON v@String{}   = SourceCabal <$> parseJSON v
  parseJSON v@(Object o) = asum
    [ SourceGit <$> parseJSON v   <*> (o .:? "subpath")
    , SourceRef <$> (o .: "repo") <*> (o .:? "subpath")
    ]
  parseJSON _ = fail "Cannot parse package source"

instance FromJSON Git where
  parseJSON = withObject "Git" $ \o -> do
    gitURL     <- o .: "git"
    gitRev     <- o .: "rev"
    pure Git{..}


main :: IO ()
main = do
  shakeArgs shakeOptions $ do
    -- Read list of packages to build and create necessary oracles
    pkgs_set :: Map.Map String Source <- YAML.decodeFileThrow "packages.yaml"
    repo_set :: Map.Map String Git    <- YAML.decodeFileThrow "repo.yaml"
    get_source <- addOracle $ \(PkgName nm) -> do
      case nm `Map.lookup` pkgs_set of
        Just s  -> pure s
        Nothing -> error $ "No such package: " ++ nm
    get_git <- addOracle $ \(Repository nm) -> do
      case nm `Map.lookup` repo_set of
        Just s  -> pure s
        Nothing -> error $ "No such repository: " ++ nm
    -- Phony targets
    phony "list-new" $ listNewPackages pkgs_set
    -- Show diff for package in set and latest version
    forM_ [(k,v) | (k, SourceCabal v) <- Map.toList pkgs_set] $ \(pkg, v) -> do
      phony ("diff@"<>pkg) $ do
        liftIO $ do putStrLn pkg
                    print v
        withTempDir $ \dir_latest ->
          withTempDir $ \dir_current -> do
            command_ [] "cabal" [ "unpack"
                                , pkg
                                , "-d", dir_latest]
            command_ [] "cabal" [ "unpack"
                                , [fmt|{pkg}-{showVersion v}|]
                                , "-d", dir_current
                                ]
            [latest]  <- getDirectoryContents dir_latest
            [current] <- getDirectoryContents dir_current
            Exit _ <- command [] "colordiff" ["-u", "-r", "-Z"
                                             , dir_current</>current
                                             , dir_latest</>latest
                                             ]
            return ()
    -- Generate files for each package
    for_ (Map.keys pkgs_set) $ \pkg -> do
      let fname = "nix" </> packageNixName pkg
      fname %%> \_ -> do
        let patch_name = "./patches" </> pkg <.> "nix" <.> "patch"
        exists <- doesFileExist patch_name
        when (exists) $ need [patch_name]
        let andPatch = when (exists) $ command_ [FileStdin patch_name] "patch" [fname]
        get_source (PkgName pkg) >>= \case
          SourceCabal v           -> do
            mrevision <- listToMaybe <$> readFileLines "hackage-revision.txt" -- FIXME !!
            cabal2nixHackage fname pkg v mrevision
            andPatch
          SourceGit git  msubpath -> do
            cabal2nixGit fname git msubpath
            andPatch
          SourceRef repo msubpath -> do
            git <- get_git repo
            cabal2nixGit fname git msubpath >> andPatch
    -- Building nix overlay
    "nix/default.nix" %%> \overlay -> do
      need $ (\x -> "nix" </> packageNixName x) <$> Map.keys pkgs_set
      need ["packages.yaml", "repo.yaml"]
      liftIO $ writeFile overlay $ unlines $ concat
        [ [ "lib: prev: {" ]
        , [ [fmt|  {nm} = lib.doJailbreak (lib.disableLibraryProfiling (lib.dontCheck (prev.callPackage ./{packageNixName nm} {{}})));|]
          | nm <- Map.keys pkgs_set
          ]
        , ["}"]
        ]
    -- Default action
    want $ (\x -> "nix" </> packageNixName x) <$> Map.keys pkgs_set
    want ["nix/default.nix"]

cabal2nixHackage :: FilePath -> String -> Version -> Maybe String -> Action ()
cabal2nixHackage fname pkg v mrevision = command_ [FileStdout fname] "cabal2nix" $
  [ [fmt|cabal://{pkg}-{showVersion v}|] ]
     <> maybe [] (\revision  -> ["--hackage-snapshot", revision]) mrevision

cabal2nixGit :: FilePath -> Git -> Maybe String -> Action ()
cabal2nixGit fname Git{..} msubpath = command_ [FileStdout fname] "cabal2nix" $
  [ gitURL
  , "--revision", gitRev
  ] ++
  case msubpath of
    Nothing -> []
    Just s  -> ["--subpath", s]


----------------------------------------------------------------
-- List package which we fetch from hackage and which are older than
-- latest version
----------------------------------------------------------------

listNewPackages :: Map.Map String Source -> Action ()
listNewPackages pkgs = do
  StdoutTrim str <- command [] "bash" ["-c", "tar tf ~/.cabal/packages/hackage.haskell.org/01-index.tar.gz"]
  let hackage_ver = Map.fromListWith max $ mapMaybe parseIndexLine $ lines str
      local_ver   = Map.mapMaybe (\x -> do { SourceCabal v <- Just x; pure v }) pkgs
      -- Select only versions that are newer on hackage
      (patch_new, newer) = Map.partition (uncurry onlyPatchVersionDiff)
                         $ Map.filter    (uncurry (<))
                         $ Map.intersectionWith (,) local_ver hackage_ver
  liftIO $ putStrLn "== Patch upgrades =="
  liftIO $ mapM_ reportVersionDifference $ Map.toList patch_new
  liftIO $ putStrLn "== Upgrades =="
  liftIO $ mapM_ reportVersionDifference $ Map.toList newer

reportVersionDifference :: (String, (Version,Version)) -> IO ()
reportVersionDifference (nm, (v1,v2)) = putStrLn [fmt|{nm:30s} {showVersion v1} -> {showVersion v2}|]

onlyPatchVersionDiff :: Version -> Version -> Bool
onlyPatchVersionDiff (Version (smaj1:maj1:min1:_) _) (Version (smaj2:maj2:min2:_) _)
  = smaj1 == smaj2 && maj1 == maj2 && min1 == min2
onlyPatchVersionDiff _ _ = False

-- Parse file name from index.tar.gz file
parseIndexLine :: String -> Maybe (String,Version)
parseIndexLine str = case splitWhen (=='/') str of
  [_,"preferred-versions"] -> Nothing
  [nm,v,_] -> Just (nm, parseV v)
  _        -> failed
  where
    failed :: a
    failed = error $ "Cannot parse cabal file name: " ++ str
    parseV s = case [ v | (v,"") <- readP_to_S parseVersion s ] of
      [v] -> v
      _   -> failed


----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

packageNixName :: String -> FilePath
packageNixName nm = "pkgs" </> "haskell" </> nm <.> "nix"

-- Same as  %> but removes target in case of exception
(%%>) :: FilePattern -> (FilePath -> Action ()) -> Rules ()
pat %%> callback = pat %> \nm -> callback nm `actionOnException` removeFiles "." [nm]