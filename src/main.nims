--app:console
--debugger:native
when defined(windows):
    --d:SDL_VIDEO_DRIVER_WINDOWS
when defined(macosx):
    --d:SDL_VIDEO_DRIVER_COCOA