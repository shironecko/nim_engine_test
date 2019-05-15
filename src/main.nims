--parallel_build:1
--cpu:amd64
--app:console
--debugger:native
when defined(windows):
    --d:SDL_VIDEO_DRIVER_WINDOWS
when defined(macosx):
    --d:SDL_VIDEO_DRIVER_COCOA

when defined(windows):
    switch("passL", r"C:\VulkanSDK\1.1.106.0\Lib\vulkan-1.lib")
elif defined(linux):
    switch("passL", r"/usr/lib/libvulkan.so.1")