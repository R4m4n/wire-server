module API.User.RichInfo (tests) where

import Imports
import API.Team.Util (createUserWithTeam, createTeamMember)
import API.User.Util
import API.RichInfo.Util
import Bilge hiding (accept, timeout)
import Bilge.Assert
import Brig.Types
import Brig.Options
import Test.Tasty hiding (Timeout)
import Test.Tasty.HUnit
import Util

import qualified Brig.Options                as Opt
import qualified Data.List1                  as List1
import qualified Data.Text                   as Text
import qualified Galley.Types.Teams          as Team

tests :: ConnectionLimit -> Opt.Timeout -> Maybe Opt.Opts -> Manager -> Brig -> Cannon -> Galley -> TestTree
tests _cl _at conf p b _c g = testGroup "rich info"
    [ test p "there is default empty rich info" $ testDefaultRichInfo b g
    , test p "missing fields in an update are deleted" $ testDeleteMissingFieldsInUpdates b g
    , test p "fields with empty strings are deleted" $ testDeleteEmptyFields b g
    , test p "duplicate field names are forbidden" $ testForbidDuplicateFieldNames b g
    , test p "exceeding rich info size limit is forbidden" $ testRichInfoSizeLimit b g conf
    , test p "non-team members don't have rich info" $ testNonTeamMembersDoNotHaveRichInfo b g
    , test p "non-members / other membes / guests cannot see rich info" $ testGuestsCannotSeeRichInfo b g
    ]

-- | Test that for team members there is rich info set by default, and that it's empty.
testDefaultRichInfo :: Brig -> Galley -> Http ()
testDefaultRichInfo brig galley = do
    -- Create a team with two users
    (owner, tid) <- createUserWithTeam brig galley
    member1 <- userId <$> createTeamMember brig galley owner tid Team.noPermissions
    member2 <- userId <$> createTeamMember brig galley owner tid Team.noPermissions
    -- The first user should see the second user's rich info and it should be empty
    richInfo <- getRichInfo brig member1 member2
    liftIO $ assertEqual "rich info is not empty, or not present"
        (Right (RichInfo {richInfoFields = []}))
        richInfo

testDeleteMissingFieldsInUpdates :: Brig -> Galley -> Http ()
testDeleteMissingFieldsInUpdates brig galley = do
    (owner, tid) <- createUserWithTeam brig galley
    member1 <- userId <$> createTeamMember brig galley owner tid Team.noPermissions
    member2 <- userId <$> createTeamMember brig galley owner tid Team.noPermissions
    let superset = RichInfo
            [ RichField "department" "blue"
            , RichField "relevance" "meh"
            ]
        subset = RichInfo
            [ RichField "relevance" "meh"
            ]
    putRichInfo brig member2 superset !!! const 200 === statusCode
    putRichInfo brig member2 subset   !!! const 200 === statusCode
    subset' <- getRichInfo brig member1 member2
    liftIO $ assertEqual "dangling rich info fields" (Right subset) subset'

testDeleteEmptyFields :: Brig -> Galley -> Http ()
testDeleteEmptyFields brig galley = do
    (owner, tid) <- createUserWithTeam brig galley
    member1 <- userId <$> createTeamMember brig galley owner tid Team.noPermissions
    member2 <- userId <$> createTeamMember brig galley owner tid Team.noPermissions
    let withEmpty = RichInfo
            [ RichField "department" ""
            ]
    putRichInfo brig member2 withEmpty !!! const 200 === statusCode
    withoutEmpty <- getRichInfo brig member1 member2
    liftIO $ assertEqual "dangling rich info fields" (Right $ RichInfo []) withoutEmpty

testForbidDuplicateFieldNames :: Brig -> Galley -> Http ()
testForbidDuplicateFieldNames brig galley = do
    (owner, _) <- createUserWithTeam brig galley
    let bad = RichInfo
            [ RichField "department" "blue"
            , RichField "department" "green"
            ]
    putRichInfo brig owner bad !!! const 400 === statusCode

testRichInfoSizeLimit :: HasCallStack => Brig -> Galley -> Maybe Opt.Opts -> Http ()
testRichInfoSizeLimit _ _ Nothing = error "this test needs a config file"
testRichInfoSizeLimit brig galley (Just conf) = do
    let maxSize :: Int = setRichInfoLimit $ optSettings conf
    (owner, _) <- createUserWithTeam brig galley
    let bad1 = RichInfo
            [ RichField "department" (Text.replicate (fromIntegral maxSize) "#")
            ]
        bad2 = RichInfo $ [0 .. ((maxSize `div` 2))] <&>
            \i -> RichField (Text.pack $ show i) "#"
    putRichInfo brig owner bad1 !!! const 413 === statusCode
    putRichInfo brig owner bad2 !!! const 413 === statusCode

-- | Test that rich info of non-team members can not be queried.
--
-- Note: it would be nice to also test that non-team members can not set rich info, but for
-- now there's no public endpoint for setting it in Brig, so we can't do anything.
testNonTeamMembersDoNotHaveRichInfo :: Brig -> Galley -> Http ()
testNonTeamMembersDoNotHaveRichInfo brig galley = do
    -- Create a user
    targetUser <- userId <$> randomUser brig
    -- Another user should get a 'Nothing' when querying their info
    do nonTeamUser <- userId <$> randomUser brig
       richInfo <- getRichInfo brig nonTeamUser targetUser
       liftIO $ assertEqual "rich info is present" (Left 403) richInfo
    -- A team member should also get a 'Nothing' when querying their info
    do (teamUser, _) <- createUserWithTeam brig galley
       richInfo <- getRichInfo brig teamUser targetUser
       liftIO $ assertEqual "rich info is present" (Left 403) richInfo

testGuestsCannotSeeRichInfo :: Brig -> Galley -> Http ()
testGuestsCannotSeeRichInfo brig galley = do
    -- Create a team
    (owner, _) <- createUserWithTeam brig galley

    -- A non-team user should get "forbidden" when querying rich info for team user.
    do nonTeamUser <- userId <$> randomUser brig
       richInfo <- getRichInfo brig nonTeamUser owner
       liftIO $ assertEqual "rich info status /= 403" (Left 403) richInfo

    -- ...  even if she's a guest in the team...
    do guest <- userId <$> randomUser brig
       connectUsers brig owner (List1.singleton guest)
       richInfo <- getRichInfo brig guest owner
       liftIO $ assertEqual "rich info status /= 403" (Left 403) richInfo

    -- ...  or if she's in another team.
    do (otherOwner, _) <- createUserWithTeam brig galley
       richInfo <- getRichInfo brig otherOwner owner
       liftIO $ assertEqual "rich info status /= 403" (Left 403) richInfo
