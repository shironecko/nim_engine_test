--parallel_build:1
--cpu:amd64
--app:console
--debugger:native
--d:VK_NO_PROTOTYPES
--d:TILED_NO_ZLIB

when defined(windows):
    --d:SDL_VIDEO_DRIVER_WINDOWS
when defined(macosx):
    --d:SDL_VIDEO_DRIVER_COCOA