{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Quail.GUI where

import SDL (($=))
import qualified SDL
import qualified SDL.Image as I
import SDL.Raw.Video as V
import Linear (V4(..))
import Control.Monad (void, unless)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Extra (whileM)
import Data.Text (Text)
import Data.Maybe (fromJust)
import Data.IORef (newIORef)
import Quail.Utils
import Quail.Audio
import Quail.Types
import Debug.Trace (trace)

(width, height) = (600,480)

withSDL :: (MonadIO m) => m a -> m ()
withSDL op = do
    SDL.initialize []
    void op
    SDL.quit

withWindow :: (MonadIO m) => Text -> (Int, Int) -> (SDL.Window -> m a) -> m ()
withWindow title (x, y) op = do
    w <- SDL.createWindow title p
    SDL.showWindow w
    void $ op w
    SDL.destroyWindow w
    where
      p = SDL.defaultWindow { SDL.windowInitialSize = z }
      z = SDL.V2 (fromIntegral x) (fromIntegral y)

rendererConfig :: SDL.RendererConfig
rendererConfig = SDL.RendererConfig
  { SDL.rendererType = SDL.AcceleratedVSyncRenderer
  , SDL.rendererTargetTexture = False
  }

startGUI :: IO ()
startGUI = do
    SDL.initializeAll
    withSDL $ withWindow "うずら" (width,height) $
        \w -> do
            sampleSound <- newIORef sinSamples
            audio <- openAudio sampleSound
            r <- SDL.createRenderer w (-1) rendererConfig
            ts <- loadNoteTextures r
            void $ renderLoop audio r ts initMusicalScore
            SDL.destroyRenderer r

drawClipped r t (w,h) (w',h') (px,py) = SDL.copyEx r t
    (Just $ SDL.Rectangle (SDL.P $ SDL.V2 0 0) (SDL.V2 w h))
    (Just $ SDL.Rectangle (SDL.P $ SDL.V2 px py) (SDL.V2 w' h'))
    0
    Nothing
    (pure False) -- x,y軸方向に反転する時は使用

renderLoop audio r ts mscore = do
    staff <- I.loadTexture r "imgs/staffpaper.png"
    SDL.rendererDrawColor r $= V4 200 200 200 30
    event <- getEvent <$> SDL.pollEvent
    mscore' <- dealEvent event audio r mscore
    -- draw objects
    SDL.clear r
    drawClipped r staff (900,150) (450,75) (20,20)
    drawMusicalScore r ts mscore'

    SDL.destroyTexture staff
    -- mapM_ (SDL.destroyTexture.(\(_,_,t) -> t)) $ ts -- 使われていないtextureがあると落ちるので要修正
    SDL.present r
    unless (event == Quit) $ renderLoop audio r ts mscore'


loadNoteTextures :: SDL.Renderer -> IO [(Scale, Length, SDL.Texture)]
loadNoteTextures r = do
    t1  <- (C,Full,) <$> I.loadTexture r "imgs/notefull.png"
    t2  <- (C,L2,)  <$> I.loadTexture r "imgs/note2.png"
    t3  <- (C,L4,) <$> I.loadTexture r "imgs/note4.png"
    t4  <- (C,L8,) <$> I.loadTexture r "imgs/note8.png"
    t5  <- (C,L16,) <$> I.loadTexture r "imgs/note16.png"
    t6  <- (C,L32,) <$> I.loadTexture r "imgs/note32.png"
    t7  <- (Rest,Full,) <$>I.loadTexture r "imgs/restfull.png"
    t8  <- (Rest,L2,) <$> I.loadTexture r "imgs/rest2.png"
    t9  <- (Rest,L4,) <$> I.loadTexture r "imgs/rest4.png"
    t10 <- (Rest,L8,) <$> I.loadTexture r "imgs/rest8.png"
    t11 <- (Rest,L16,) <$> I.loadTexture r "imgs/rest16.png"
    return [t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11]

drawMusicalScore :: SDL.Renderer -> [(Scale, Length, SDL.Texture)] -> MusicalScore -> IO ()
drawMusicalScore r ts (MusicalScore metro keys bars) = drawBars bars
    where
    drawBars :: [Bar] -> IO ()
    drawBars [] = return ()
    drawBars (bar:bars) = foldlM_ drawNotes (30,30) (notes bar) >> drawBars bars
    drawNotes (x,y) n = do
        SDL.copyEx r (findTexture n ts)
                (Just $ SDL.Rectangle (SDL.P $ SDL.V2 0 0) (SDL.V2 960 960))
                (Just $ SDL.Rectangle (SDL.P $ SDL.V2 x (posY n y)) (SDL.V2 70 70))
                0
                Nothing
                (pure False) -- x,y軸方向に反転する時は使用
        return (x+30, y)

--posY :: Note -> Int -> Int
posY n y = (+) y $ fromJust . lookup (scale n) $ zip [C ..] [0,8..]

foldlM_ f _ [] = return ()
foldlM_ f a (n:ns) = f a n >>= \a' -> foldlM_ f a' ns

findTexture :: Note -> [(Scale, Length, SDL.Texture)] -> SDL.Texture
findTexture _ [(_,_,a)] = a
findTexture n ((s,l,t):ts) = if scale n == s && fst (len n) == l then t else findTexture n ts


getEvent :: Maybe SDL.Event -> QuailEvent
getEvent Nothing = NotImplemented
getEvent (Just e) = case SDL.eventPayload e of
    SDL.KeyboardEvent keyEvent -> getEventType keyEvent
    SDL.MouseMotionEvent ev -> MousePos 0 0
    ev -> trace (show ev) NotImplemented


dealEvent :: QuailEvent -> SDL.AudioDevice -> SDL.Renderer -> MusicalScore -> IO MusicalScore
dealEvent ev audio r ms = case ev of
    PlaySound   -> playAudio audio >> return ms
    StopSound   -> lockAudio audio >> return ms
    ResumeSound -> resumeAudio audio >> return ms
    AddNote s   -> return $ addNote (initNote{scale=s}) ms
    AddSharp -> return $ addSharp 0 ms
    AddFlat -> return $ addFlat 0 ms
    AddNatural -> return $ addNatural 0 ms
    _ -> return ms


addNote :: Note -> MusicalScore -> MusicalScore
addNote n ms = ms{bars = init (bars ms) ++ addNote' n (last $ bars ms)}
    where
    addNote' :: Note -> Bar -> [Bar]
    addNote' n bar = if barLen bar + noteLen n <= 4
        then [ bar{notes=notes bar ++ [n]}]
        else [bar, bar {notes = [n]}]


getEventType :: SDL.KeyboardEventData -> QuailEvent
getEventType event
    | catchOn event (Nothing,                       SDL.KeycodeQ,   SDL.Pressed) = Quit
    | catchOn event (Nothing,                       SDL.KeycodeA,   SDL.Pressed) = AddNote C
    | catchOn event (Nothing,                       SDL.KeycodeP,   SDL.Pressed) = PlaySound
    | catchOn event (Nothing,                       SDL.KeycodeS,   SDL.Pressed) = StopSound
    | catchOn event (Nothing,                       SDL.KeycodeR,   SDL.Pressed) = ResumeSound
    | catchOn event (Nothing,                       SDL.KeycodeUp,  SDL.Pressed) = AddSharp
    | catchOn event (Nothing,                       SDL.KeycodeDown,SDL.Pressed) = AddFlat
    | catchOn event (Just SDL.keyModifierLeftShift, SDL.KeycodeUp,  SDL.Pressed) = AddNatural
    | otherwise = NotImplemented

-- キーの入力検知
catchOn event (Nothing,key,mode) = SDL.keyboardEventKeyMotion event == mode
    && SDL.keysymKeycode (SDL.keyboardEventKeysym event) == key
catchOn event (Just modifierF,key,mode) = catchOn event (Nothing, key,mode) && catchOn' modifierF mode
    where
    -- 特殊キーの入力検知
    catchOn' modifierF mode = SDL.keyboardEventKeyMotion event == mode
        && modifierF (SDL.keysymModifier (SDL.keyboardEventKeysym event))


