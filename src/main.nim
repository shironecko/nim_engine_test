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

proc sdlCheck(res: cint, msg = "") =
    if res != 0:
        if msg != "": sdlLog LCritical, msg
        sdlLog LCritical, "SDL Call Failed: " & $sdl.getError()
        quit QuitFailure

proc vkCheck(res: VkResult, msg = "") =
    if res != VkResult.success:
        if msg != "": vkLog LCritical, msg
        vkLog LCritical, "Call failed: " & $res
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
    sdlLog LCritical, "Failed to create window!"
    sdlLog LCritical, "Call Failed: " & $sdl.getError()
    quit QuitFailure

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
        , patch: apiVersion and 0xfff)
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

proc charArrayToString[LEN](charArr: array[LEN, char]): string =
    for c in charArr:
        if c == '\0': break
        result &= c

let vkDesiredLayers = ["VK_LAYER_LUNARG_standard_validation"]
var vkLayersToRequest: seq[string]
vkLog LTrace, "[AvailableLayers]"
for layer in vkAvailableLayers:
    let layerName = charArrayToString(layer.layerName)
    vkLog LTrace, "\t$# ($#, $#)".format(layerName, makeVulkanVersionInfo(layer.specVersion), layer.implementationVersion)
    vkLog LTrace, "\t" & charArrayToString(layer.description)
    vkLog LTrace, ""

    if vkDesiredLayers.contains(layerName): vkLayersToRequest.add(layerName)
let vkNotFoundLayers = vkDesiredLayers.filterIt(not vkLayersToRequest.contains(it))
if vkNotFoundLayers.len() != 0: vkLog LWarning, "Requested layers not found: " & $vkNotFoundLayers
vkLog LInfo, "Requesting layers: " & $vkLayersToRequest

var 
    vkExtensionCount: uint32
    vkExtensions: seq[VkExtensionProperties]
vkCheck vkEnumerateInstanceExtensionProperties(nil, addr vkExtensionCount, nil)
vkExtensions.setLen(vkExtensionCount)
vkCheck vkEnumerateInstanceExtensionProperties(nil, addr vkExtensionCount, addr vkExtensions[0])

let vkDesiredExtensions = ["VK_EXT_debug_report"]
var vkExtensionsToRequest: seq[string]
vkLog LTrace, "[AvailableExtensions]"
for extension in vkExtensions:
    let extensionName = charArrayToString(extension.extensionName)
    vkLog LTrace, "\t$# $#".format(extensionName, makeVulkanVersionInfo(extension.specVersion))

    if vkDesiredExtensions.contains(extensionName): vkExtensionsToRequest.add(extensionName)
let vkNotFoundExtensions = vkDesiredExtensions.filterIt(not vkExtensionsToRequest.contains(it))
if vkNotFoundExtensions.len() != 0: vkLog LWarning, "Requested extensions not found: " & $vkNotFoundExtensions
vkLog LInfo, "Requesting extensions: " & $vkExtensionsToRequest

var appInfo = VkApplicationInfo(
    sType: VkStructureType.applicationInfo
    , pNext: nil
    , pApplicationName: "Nim Vulkan"
    , applicationVersion: 1
    , pEngineName: "Dunno"
    , engineVersion: 1
    , apiVersion: vkMakeVersion(1, 0, 2))

var instanceCreateInfo = VkInstanceCreateInfo(
    sType: VkStructureType.instanceCreateInfo
    , pNext: nil
    , flags: 0
    , pApplicationInfo: addr appInfo
    , enabledLayerCount: 0
    , ppEnabledLayerNames: nil
    , enabledExtensionCount: 0
    , ppEnabledExtensionNames: nil)

var instance: vk.VkInstance
vkCheck vkCreateInstance(addr instanceCreateInfo, nil, addr instance)

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

vkDestroyInstance(instance, nil)
destroyWindow(window)
sdl.quit()