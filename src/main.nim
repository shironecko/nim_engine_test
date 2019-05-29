import strutils
import sequtils
import sugar
import sdl2/[sdl, sdl_syswm]
import nim_logger as log
import vulkan as vk except vkCreateDebugReportCallbackEXT, vkDestroyDebugReportCallbackEXT

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

proc check(condition: bool, msg = "") =
    if not condition:
        if msg != "": gLog LCritical, msg
        gLog LCritical, "Check failed!"
        quit QuitFailure

proc sdlCheck(res: cint, msg = "") =
    if res != 0:
        if msg != "": sdlLog LCritical, msg
        sdlLog LCritical, "SDL Call Failed: " & $sdl.getError()
        quit QuitFailure

proc sdlCheck(res: bool, msg = "") =
    if not res:
        if msg != "": sdlLog LCritical, msg
        sdlLog LCritical, "SDL Call Failed: " & $sdl.getError()
        quit QuitFailure

proc vkCheck(res: VkResult, msg = "") =
    if res != VkResult.success:
        if msg != "": vkLog LCritical, msg
        vkLog LCritical, "Call failed: " & $res
        quit QuitFailure

proc vkCheck(res: bool, msg = "") =
    if not res:
        if msg != "": vkLog LCritical, msg
        vkLog LCritical, "Call failed: " & $res
        quit QuitFailure

proc GetTime*(): float64 =
    return cast[float64](getPerformanceCounter()*1000) / cast[float64](getPerformanceFrequency())

sdlCheck sdl.init(INIT_EVERYTHING), "Failed to init :c"

var window: Window
window = createWindow(
    "SDL/Vulkan"
    , WINDOWPOS_UNDEFINED
    , WINDOWPOS_UNDEFINED
    , 640, 480
    , WINDOW_VULKAN or WINDOW_SHOWN or WINDOW_RESIZABLE)
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
vkLog LTrace, "[Layers]"
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

var sdlVkExtensionCount: cuint
sdlCheck vulkanGetInstanceExtensions(window, addr sdlVkExtensionCount, nil)
var sdlVkExtensionsCStrings = cast[cstringArray](malloc(sizeof(cstring) * csize(sdlVkExtensionCount)))
sdlCheck vulkanGetInstanceExtensions(window, addr sdlVkExtensionCount, sdlVkExtensionsCStrings)
let sdlVkDesiredExtensions = cstringArrayToSeq(sdlVkExtensionsCStrings)
free(sdlVkExtensionsCStrings)
sdlLog LInfo, "SDL VK desired extensions: " & $sdlVkDesiredExtensions

let vkDesiredExtensions = @["VK_EXT_debug_report"] & sdlVkDesiredExtensions
var vkExtensionsToRequest: seq[string]
vkLog LTrace, "[Extensions]"
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
    , apiVersion: vkVersion10)

let vkLayersCStrings = allocCStringArray(vkLayersToRequest)
let vkExtensionsCStrings = allocCStringArray(vkExtensionsToRequest)
var instanceCreateInfo = VkInstanceCreateInfo(
    sType: VkStructureType.instanceCreateInfo
    , pNext: nil
    , flags: 0
    , pApplicationInfo: addr appInfo
    , enabledLayerCount: uint32 vkLayersToRequest.len()
    , ppEnabledLayerNames: vkLayersCStrings
    , enabledExtensionCount: uint32 vkExtensionsToRequest.len()
    , ppEnabledExtensionNames: vkExtensionsCStrings)

var instance: vk.VkInstance
vkCheck vkCreateInstance(addr instanceCreateInfo, nil, addr instance)
deallocCStringArray(vkLayersCStrings)
deallocCStringArray(vkExtensionsCStrings)

let vkDebugReportCallback : PFN_vkDebugReportCallbackEXT = proc (flags: VkDebugReportFlagsEXT; objectType: VkDebugReportObjectTypeEXT; cbObject: uint64; location: csize; messageCode:  int32; pLayerPrefix: cstring; pMessage: cstring; pUserData: pointer): VkBool32 {.cdecl.} =
    var logLevel = LTrace
    if   (flags and uint32(VkDebugReportFlagBitsEXT.error)) != 0:               logLevel = LError
    elif (flags and uint32(VkDebugReportFlagBitsEXT.warning)) != 0:             logLevel = LWarning
    elif (flags and uint32(VkDebugReportFlagBitsEXT.performanceWarning)) != 0:  logLevel = LWarning
    elif (flags and uint32(VkDebugReportFlagBitsEXT.information)) != 0:         logLevel = LInfo
    elif (flags and uint32(VkDebugReportFlagBitsEXT.debug)) != 0:               logLevel = LTrace
    vkLog logLevel, "$# $# $# $#".format(pLayerPrefix, objectType, messageCode, pMessage)
    vkFalse

let
    vkCreateDebugReportCallbackEXT = cast[PFN_vkCreateDebugReportCallbackEXT](vkGetInstanceProcAddr(instance, "vkCreateDebugReportCallbackEXT"))
    vkDestroyDebugReportCallbackEXT = cast[PFN_vkDestroyDebugReportCallbackEXT](vkGetInstanceProcAddr(instance, "vkDestroyDebugReportCallbackEXT"))
vkCheck vkCreateDebugReportCallbackEXT != nil, "Failed to load vkCreateDebugReportCallbackEXT proc!"
vkCheck vkDestroyDebugReportCallbackEXT != nil, "Failed to load vkDestroyDebugReportCallbackEXT proc!"

var 
    vkCallbackCreateInfo = VkDebugReportCallbackCreateInfoEXT(
        sType: VkStructureType.debugReportCallbackCreateInfoExt
        , flags: uint32(VkDebugReportFlagBitsEXT.error) or uint32(VkDebugReportFlagBitsEXT.warning) or uint32(VkDebugReportFlagBitsEXT.performanceWarning)
        , pfnCallback: vkDebugReportCallback)
    vkDebugCallback: VkDebugReportCallbackEXT
vkCheck vkCreateDebugReportCallbackEXT(instance, addr vkCallbackCreateInfo, nil, addr vkDebugCallback)

var vkSurface: vk.VkSurfaceKHR
sdlCheck vulkanCreateSurface(window, cast[sdl.VkInstance](instance), addr vkSurface)

type
    GPUVendor {.pure.} = enum
        AMD, NVidia, Intel, ARM, Qualcomm, ImgTec, Unknown
proc vkVendorIDToGPUVendor(vendorID: uint32): GPUVendor =
    case vendorID:
        of 0x1002: GPUVendor.AMD
        of 0x10DE: GPUVendor.NVidia
        of 0x8086: GPUVendor.Intel
        of 0x13B5: GPUVendor.ARM
        of 0x5143: GPUVendor.Qualcomm
        of 0x1010: GPUVendor.ImgTec
        else: GPUVendor.Unknown

var 
    vkDeviceCount: uint32
    vkDevices: seq[VkPhysicalDevice]
vkCheck vkEnumeratePhysicalDevices(instance, addr vkDeviceCount, nil)
check vkDeviceCount != 0, "VK: failed to find any devices!"
vkDevices.setLen(vkDeviceCount)
vkCheck vkEnumeratePhysicalDevices(instance, addr vkDeviceCount, addr vkDevices[0])

let vkDevicesWithProperties = vkDevices.map(proc (device: VkPhysicalDevice): tuple[
        id: VkPhysicalDevice
        , props: VkPhysicalDeviceProperties
        , queues: seq[VkQueueFamilyProperties]
        , presentQueueIdx: uint32
    ] =
    result.id = device
    vkGetPhysicalDeviceProperties(device, addr result.props)

    var queueFamiliesCount: uint32
    vkGetPhysicalDeviceQueueFamilyProperties(device, addr queueFamiliesCount, nil)
    result.queues.setLen(queueFamiliesCount)
    vkGetPhysicalDeviceQueueFamilyProperties(device, addr queueFamiliesCount, addr result.queues[0])
    result.presentQueueIdx = 0xFFFFFFFF'u32
    for i, q in result.queues:
        var surfaceSupported: VkBool32
        vkCheck vkGetPhysicalDeviceSurfaceSupportKHR(device, uint32 i, vkSurface, addr surfaceSupported)
        if (surfaceSupported == vkTrue) and ((q.queueFlags and VkFlags(VkQueueFlagBits.graphics)) == VkFlags(VkQueueFlagBits.graphics)):
            result.presentQueueIdx = uint32 i
            break
)

vkLog LTrace, "[Devices]"
for device in vkDevicesWithProperties:
    vkLog LTrace, "\t" & charArrayToString(device[1].deviceName)
    vkLog LTrace, "\t\tType $# API $# Driver $# Vendor $#".format(device.props.deviceType, makeVulkanVersionInfo(device.props.apiVersion), device.props.driverVersion, vkVendorIDToGPUVendor device.props.vendorID)
let vkCompatibleDevices = vkDevicesWithProperties.filter((d) => d.presentQueueIdx != 0xFFFFFFFF'u32)
vkLog LInfo, "[Compatible Devices]"
for device in vkCompatibleDevices:
    vkLog LInfo, "\t" & charArrayToString(device.props.deviceName)
if (vkCompatibleDevices.len == 0):
    vkLog LCritical, "No compatible devices found!"
    quit QuitFailure
let vkSelectedPhysicalDevice = vkCompatibleDevices[0]
vkLog LInfo, "Selected physical device: " & charArrayToString(vkSelectedPhysicalDevice.props.deviceName)

var
    queuePriorities = [1.0'f32]
    queueCreateInfo = VkDeviceQueueCreateInfo(
        sType: VkStructureType.deviceQueueCreateInfo
        , queueFamilyIndex: vkSelectedPhysicalDevice.presentQueueIdx
        , queueCount: 1
        , pQueuePriorities: addr queuePriorities[0]
    )
    deviceExtensions = allocCStringArray(["VK_KHR_swapchain"])
    deviceFeatures = VkPhysicalDeviceFeatures(
        shaderClipDistance: vkTrue
    )
    deviceInfo = VkDeviceCreateInfo(
        sType: VkStructureType.deviceCreateInfo
        , queueCreateInfoCount: 1
        , pQueueCreateInfos: addr queueCreateInfo
        , enabledExtensionCount: 1
        , ppEnabledExtensionNames: deviceExtensions
        , pEnabledFeatures: addr deviceFeatures
    )
    vkDevice: VkDevice
vkCheck vkCreateDevice(vkSelectedPhysicalDevice.id, addr deviceInfo, nil, addr vkDevice)

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

vkDestroyDevice(vkDevice, nil)
vkDestroyDebugReportCallbackEXT(instance, vkDebugCallback, nil)
vkDestroyInstance(instance, nil)
destroyWindow(window)
sdl.quit()