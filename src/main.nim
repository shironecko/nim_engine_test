import strutils
import sequtils
import sdl2/[sdl, sdl_syswm]
import nim_logger as log
import vulkan as vk

type
    LogCategories = enum
        LogGeneral = "G",
        LogSDL = "SDL",
        LogVulkan = "VK"

registerLogCategory(log.LogCategory(name: $LogGeneral, level: LTrace))
registerLogCategory(log.LogCategory(name: $LogSDL, level: LTrace))
registerLogCategory(log.LogCategory(name: $LogVulkan, level: LTrace))
registerLogProc(LogStandartProc.StdOut)

proc gLog(level: LogLevel, msg: string) =
    log $LogGeneral, level, msg

proc sdlLog(level: LogLevel, msg: string) =
    log $LogSDL, level, msg

proc vkLog(level: LogLevel, msg: string) =
    log $LogVulkan, level, msg

proc sdlCheck(res: cint, msg: string) =
    if res != 0:
        sdlLog LCritical, msg & "\nSDL Message: " & $sdl.getError()
        quit QuitFailure

proc vkCheck(res: VkResult) =
    if res != VkResult.success:
        vkLog LCritical, "Vulkan call failed with: " & $res
        quit QuitFailure

proc GetTime*(): float64 =
    return cast[float64](getPerformanceCounter()*1000) / cast[float64](getPerformanceFrequency())

sdlCheck sdl.init(0), "Failed to init :c"

var window: Window
window = createWindow(
    "SDL/Vulkan"
    , WINDOWPOS_UNDEFINED
    , WINDOWPOS_UNDEFINED
    , 640, 480
    , WINDOW_SHOWN or WINDOW_RESIZABLE)
if window == nil:
    sdlLog LCritical, "Failed to create window!\nSDL Message: " & $sdl.getError()
    quit(QuitFailure)

type
    WindowDimentions = object
        width, height, fullWidth, fullHeight : int32

proc getWindowDimentions(window : sdl.Window) : WindowDimentions =
    sdl.getWindowSize(window, addr result.fullWidth, addr result.fullHeight)
    sdl.vulkanGetDrawableSize(window, addr result.width, addr result.height)

var windowDimentions = getWindowDimentions(window)

type
    VulkanVersionInfo = object
        major, minor, patch: uint
proc makeVulkanVersionInfo(apiVersion: uint): VulkanVersionInfo =
    VulkanVersionInfo(
        major: apiVersion shr 22
        , minor: (apiVersion shr 12) and 0x3ff
        , patch: apiVersion and 0xfff
    )
proc `$`(vkVersion: VulkanVersionInfo): string = "$#.$#.$#".format(vkVersion.major, vkVersion.minor, vkVersion.patch)
let vkVersionInfo = makeVulkanVersionInfo(vkApiVersion10)
vkLog LInfo, "Vulkan API Version: " & $vkVersionInfo
vkLog LInfo, "Vulkan Header Version: $#" % [$vkHeaderVersion]

var
    vkLayerCount: uint32
    vkAvailableLayers: seq[VkLayerProperties]

vkCheck vkEnumerateInstanceLayerProperties(addr vkLayerCount, nil)
vkAvailableLayers.setLen(vkLayerCount)
vkCheck vkEnumerateInstanceLayerProperties(addr vkLayerCount, addr vkAvailableLayers[0])
vkLog LTrace, "[AvailableVulkanLayers]"
for layer in vkAvailableLayers:
    var layerName, layerDescription: string
    for c in layer.layerName: 
        if c == '\0': break
        layerName &= c 
    for c in layer.description: 
        if c == '\0': break
        layerDescription &= c
    let vkVersion = makeVulkanVersionInfo(layer.specVersion)
    vkLog LTrace, "$1 ($2, $3)".format(layerName, vkVersion, layer.implementationVersion)
    vkLog LTrace, layerDescription
    vkLog LTrace, ""
vkLog LTrace, "[/AvailableVulkanLayers]"

proc updateRenderResolution(winDim : WindowDimentions) =
    gLog LInfo, "Render resolution changed to: ($1, $2)".format(winDim.width, winDim.height)

updateRenderResolution(windowDimentions)

var evt: sdl.Event
block GameLoop:
    while true:
        while sdl.pollEvent(evt.addr) == 1:
            if evt.kind == sdl.Quit:
                break GameLoop
            elif evt.kind == sdl.WINDOWEVENT:
                var windowEvent = cast[WindowEventObj](evt.addr)
                let newWindowDimensions = getWindowDimentions(window)
                if windowDimentions != newWindowDimensions:
                    updateRenderResolution(newWindowDimensions)
                    windowDimentions = newWindowDimensions

destroyWindow(window)
sdl.quit()