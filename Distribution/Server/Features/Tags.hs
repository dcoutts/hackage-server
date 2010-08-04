module Distribution.Server.Features.Tags (
    TagsFeature(..),
    TagsResource(..),
    initTagsFeature,

    withTagPath,
    putTags
  ) where

import Distribution.Server.Feature
import Distribution.Server.Features.Core
import Distribution.Server.Features.Packages (categorySplit)
import Distribution.Server.Resource
import Distribution.Server.Types
import Distribution.Server.Hook
import Distribution.Server.Error
import Distribution.Server.Packages.Tag

import qualified Distribution.Server.PackageIndex as PackageIndex
import Distribution.Server.PackageIndex (PackageIndex)
import Distribution.Server.Packages.State (GetPackagesState(..), packageList)
import Distribution.Server.Packages.Types
import Distribution.Server.Backup.Import
import qualified Distribution.Server.Cache as Cache

import Distribution.Text
import Distribution.Package
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration
import Distribution.License

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Function (fix)
import Data.List (intercalate, foldl')
import Data.Char (toLower)
import Control.Monad (mzero)

import Happstack.State
import Happstack.Server

data TagsFeature = TagsFeature {
    tagsResource :: TagsResource,
    -- All package names that were modified, and all tags that were modified
    -- In almost all cases, one of these will be a singleton. Happstack
    -- functions should be used to query the resultant state.
    tagsUpdated :: Hook (Set PackageName -> Set Tag -> IO ()),
    -- Calculated tags are used so that other features can reserve a
    -- tag for their own use (a calculated, rather than freely
    -- assignable, tag). It is a subset of the main mapping.
    --
    -- This feature itself defines a few such tags: libary, executable,
    -- and license tags, as well as package categories on
    -- initial import.
    calculatedTags :: Cache.Cache PackageTags,
    setCalculatedTag :: Tag -> Set PackageName -> IO ()
}

-- TODO: registry for calculated tags
data TagsResource = TagsResource {
    tagsListing :: Resource,
    tagListing :: Resource,
    packageTagsListing :: Resource,

    tagUri :: String -> Tag -> String,
    tagsUri :: String -> String,
    packageTagsUri :: String -> PackageName -> String
    -- /packages/tags/.:format
    -- /packages/tag/:tag.:format
    -- /package/:package/tags.:format
    -- /package/:package/tags/edit (HTML)
}

instance HackageFeature TagsFeature where
    getFeature tags = HackageModule
      { featureName = "tags"
      , resources   = map ($tagsResource tags) [tagsListing, tagListing, packageTagsListing]
      , dumpBackup    = Nothing
      , restoreBackup = Just $ \_ -> fix $ \r -> RestoreBackup
              { restoreEntry    = \_ -> return $ Right r
              , restoreFinalize = return $ Right r
              , restoreComplete = do
                    putStrLn "Creating tag index"
                    index <- fmap packageList $ query GetPackagesState
                    -- TODO: move this to a separate feature for calculated tags
                    let tagIndex = constructTagIndex index
                    update $ ReplacePackageTags tagIndex
              }
      }
    initHooks tags = [initImmutableTags]
      where initImmutableTags = do
                index <- fmap packageList $ query GetPackagesState
                Cache.putCache (calculatedTags tags) (constructImmutableTagIndex index)

initTagsFeature :: Config -> CoreFeature -> IO TagsFeature
initTagsFeature _ _ = do
    specials <- Cache.newCacheable emptyPackageTags
    updateTag <- newHook
    return TagsFeature
      { tagsResource = fix $ \r -> TagsResource
          { tagsListing = resourceAt "/packages/tags/.:format"
          , tagListing = resourceAt "/packages/tag/:tag.:format"
          , packageTagsListing = resourceAt "/package/:package/tags.:format"
          , tagUri = \format tag -> renderResource (tagListing r) [display tag, format]
          , tagsUri = \format -> renderResource (tagsListing r) [format]
          , packageTagsUri = \format pkgname -> renderResource (packageTagsListing r) [display pkgname, format]
            -- for more fine-tuned tag manipulation, could also define:
            -- * DELETE /package/:package/tag/:tag (remove single tag)
            -- * POST /package/:package\/tags (add single tag)
          }
      , tagsUpdated = updateTag
      , calculatedTags = specials
      , setCalculatedTag = \tag pkgs -> do
            Cache.modifyCache specials (setTag tag pkgs)
            update $ SetTagPackages tag pkgs
            runHook'' updateTag pkgs (Set.singleton tag)
      }
-- { resourceGet = [("txt", textPackageTags)], resourcePut = [("txt", textPutTags)] }
{-  
    textPutTags dpath = textResponse $ withPackageName dpath $ \pkgname ->
                        responseWith (putTags pkgname) $ \_ ->
        returnOk . toResponse $ "Set the tags for " ++ display pkgname
    textPackageTags dpath = textResponse $ withPackageAllPath dpath $ \pkgname _ -> do
        tags <- query $ TagsForPackage pkgname
        returnOk . toResponse $ display (TagList $ Set.toList tags)-}

withTagPath :: DynamicPath -> (Tag -> Set PackageName -> ServerPart a) -> ServerPart a
withTagPath dpath func = case simpleParse =<< lookup "tag" dpath of
    Nothing -> mzero
    Just tag -> do
        pkgs <- query $ PackagesForTag tag
        func tag pkgs

putTags :: TagsFeature -> PackageName -> MServerPart ()
putTags tagf pkgname = withPackageAll pkgname $ \_ -> do
    -- let anyone edit tags for the moment. otherwise, we can do:
    -- users <- query GetUserDb; withHackageAuth users Nothing Nothing $ \_ _ -> do
    mtags <- getDataFn $ look "tags"
    case simpleParse =<< mtags of
        Just (TagList tags) -> do
            let tagSet = Set.fromList tags
            calcTags <- fmap (packageToTags pkgname) $ Cache.getCache $ calculatedTags tagf
            update $ SetPackageTags pkgname (tagSet `Set.union` calcTags)
            runHook'' (tagsUpdated tagf) (Set.singleton pkgname) tagSet
            returnOk ()
        Nothing -> returnError 400 "Tags not recognized" [MText "Couldn't parse your tag list. It should be comma separated with any number of alphanumerical tags. Tags can also also have -+#*."]

-- initial tags, on import
constructTagIndex :: PackageIndex PkgInfo -> PackageTags
constructTagIndex = foldl' addToTags emptyPackageTags . PackageIndex.allPackagesByName
  where addToTags pkgTags pkgList =
            let info = pkgDesc $ last pkgList
                pkgname = packageName info
                categoryTags = Set.fromList . constructCategoryTags . packageDescription $ info
                immutableTags = Set.fromList . constructImmutableTags $ info
            in setTags pkgname (Set.union categoryTags immutableTags) pkgTags

-- tags on startup
constructImmutableTagIndex :: PackageIndex PkgInfo -> PackageTags
constructImmutableTagIndex = foldl' addToTags emptyPackageTags . PackageIndex.allPackagesByName
  where addToTags calcTags pkgList =
            let info = pkgDesc $ last pkgList
            in setTags (packageName info) (Set.fromList $ constructImmutableTags info) calcTags

constructCategoryTags :: PackageDescription -> [Tag]
constructCategoryTags = map (tagify . map toLower) . fillMe . categorySplit . category
  where
    fillMe [] = ["unclassified"]
    fillMe xs = xs

constructImmutableTags :: GenericPackageDescription -> [Tag]
constructImmutableTags genDesc =
    let desc = flattenPackageDescription genDesc
    in licenseToTag (license desc)
    ++ (if hasLibs desc then [Tag "library"] else [])
    ++ (if hasExes desc then [Tag "program"] else [])
  where
    licenseToTag :: License -> [Tag]
    licenseToTag l = case l of
        GPL  _ -> [Tag "gpl"]
        LGPL _ -> [Tag "lgpl"]
        BSD3 -> [Tag "bsd3"]
        BSD4 -> [Tag "bsd4"]
        MIT  -> [Tag "mit"]
        PublicDomain -> [Tag "public-domain"]
        AllRightsReserved -> [Tag "all-rights-reserved"]
        _ -> []

