{-# LANGUAGE ScopedTypeVariables #-}

import           System.IO
import           XMonad
import           XMonad.Hooks.DynamicLog
import           XMonad.Hooks.EwmhDesktops        (ewmh, ewmhFullscreen)
import           XMonad.Hooks.ManageDocks
import           XMonad.Hooks.ManageHelpers       (doFullFloat, isFullscreen)
import           XMonad.Layout.IndependentScreens
import           XMonad.Layout.MouseResizableTile
import           XMonad.Layout.NoBorders          (Ambiguity (OnlyScreenFloat), lessBorders)
import           XMonad.Layout.Spacing
import           XMonad.Util.EZConfig             (additionalKeysP)
import           XMonad.Util.Run                  (spawnPipe)
import           XMonad.Util.SpawnOnce            (spawnOnce)

myStartupHook :: X ()
myStartupHook = do
  spawnOnce "nautilus"
  spawnOnce "brave"
  spawnOnce "feh --bg-scale ~/Pictures/wallpaper.png &"
  spawnOnce "myterm"
  spawnOnce "emacs"
  spawnOnce "signal-desktop"
  spawnOnce "env XDG_CURRENT_DESKTOP=GNOME gnome-control-center"

myModMask            = mod4Mask                        -- Sets modkey to super/windows key
myTerminal           = "myterm"   -- gnome-terminal wrapped in tmux; see configuration-gui.nix
myTextEditor         = "emacs"                         -- Sets default text editor
myBorderWidth        = 2                               -- Sets border width for windows
myNormalBorderColor  = "#4a4a4a"
myFocusedBorderColor = "#7fff00"

mySpacing = spacingRaw True (Border 0 10 10 10) True (Border 10 10 10 10) True

myManageHook = composeAll
   [ className =? "Emacs" --> doShift "1"
   , className =? "brave-browser" --> doShift "2"
   , className =? "Org.gnome.Nautilus" --> doShift "3"
   , className =? "Gnome-control-center" --> doShift "4"
   , className =? "Signal" --> doShift "6"
   , isFullscreen --> doFullFloat   -- games (Proton) fight a tiled window
   , manageDocks
   ]

-- Workspaces, layout and title share @xmonadLogWidth@ columns of xmobar: the
-- title gets what is left, so it can never push the right half off screen.
fitTitle :: Int -> [String] -> [String]
fitTitle width (ws : layout : name : rest) = ws : layout : name' : rest
  where
    room  = max 3 (width - length (xmobarStrip ws) - length layout - 6)
    name' | null name = ""
          | otherwise = xmobarColor "green" "" (shorten room name)
fitTitle _ xs = xs

main = do
    xmproc <- spawnPipe "xmobar"
    xmonad . ewmhFullscreen . ewmh . docks $ def
        { manageHook = myManageHook <+> manageHook def
        , layoutHook = lessBorders OnlyScreenFloat . avoidStruts . mySpacing $ layoutHook def
        , handleEventHook = handleEventHook def -- <+> docksEventHook
        , logHook = dynamicLogWithPP xmobarPP
                        { ppOutput = hPutStrLn xmproc
                        , ppTitle  = id
                        , ppOrder  = fitTitle @xmonadLogWidth@
                        }
        , startupHook        = myStartupHook
        , modMask            = myModMask     -- Rebind Mod to the Windows key
        , borderWidth        = myBorderWidth
        , normalBorderColor  = myNormalBorderColor
        , focusedBorderColor = myFocusedBorderColor
        , terminal           = myTerminal
        } `additionalKeysP`
        -- scrot -s grabs the keyboard (any key cancels the selection) and
        -- waits only a second for xmonad to release the grab of the key just
        -- pressed: unGrab releases it at once.
        [ ("<Print>", unGrab *> spawn (screenshot "-s"))
        , ("M-<Print>", unGrab *> spawn (screenshot ""))
        , ("M-c", unGrab *> spawn "scrot -s /tmp/ocr.png && tesseract /tmp/ocr.png - | xclip -selection clipboard && rm /tmp/ocr.png")
        , ("<XF86MonBrightnessUp>", spawn "brightnessctl set 5%+")
        , ("<XF86MonBrightnessDown>", spawn "brightnessctl set 5%-")
        , ("M-y", spawn "brightnessctl set 1") -- set to minimum brightness
        , ("M-j", spawn "amixer -q sset Master 2%- && notify-send Volume \"$(amixer get Master | grep -o '[0-9]*%' | head -1)\"")
        , ("M-k", spawn "amixer -q sset Master 2%+ && notify-send Volume \"$(amixer get Master | grep -o '[0-9]*%' | head -1)\"")
        , ("M-m", spawn "amixer set Master toggle")
        , ("M-q", restart "/run/current-system/sw/bin/xmonad" True)
        ]

-- | A screenshot into ~/Pictures/Screenshots, its path then on the
-- clipboard.  With -s, drag a rectangle or click a window; a key or a
-- second mouse button cancels, and the notification says which.  scrot's
-- complaints also go to /tmp/xmonad-screenshot.log.  xclip stays behind to
-- serve the clipboard, so its output must not hold the $(...) pipe open.
screenshot :: String -> String
screenshot flags =
  "mkdir -p ~/Pictures/Screenshots; "
    ++ "if e=$(scrot " ++ flags ++ " ~/Pictures/Screenshots/%Y-%m-%d_%H-%M-%S.png"
    ++ " -e 'echo -n $f | xclip -selection clipboard >/dev/null 2>&1; notify-send Screenshot $f'"
    ++ " 2>&1 >/dev/null);"
    ++ " then :; else echo \"$(date) $e\" >> /tmp/xmonad-screenshot.log;"
    ++ " notify-send 'No screenshot' \"$e\"; fi"
