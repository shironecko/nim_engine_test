import strutils
import sequtils
import sugar
import strformat
import sdl2/[sdl, sdl_syswm]
import log
import vulkan as vk except vkCreateDebugReportCallbackEXT, vkDestroyDebugReportCallbackEXT
import render/vulkan_wrapper
import utility

proc GetTime*(): float64 =
    return cast[float64](getPerformanceCounter()*1000) / cast[float64](getPerformanceFrequency())

sdlCheck sdl.init(INIT_EVERYTHING), "Failed to init :c"
sdlCheck vulkanLoadLibrary(nil)
loadVulkanAPI()

var window: Window
window = createWindow(
    "SDL/Vulkan"
    , WINDOWPOS_UNDEFINED
    , WINDOWPOS_UNDEFINED
    , 640, 480
    , WINDOW_VULKAN or WINDOW_SHOWN or WINDOW_RESIZABLE)
sdlCheck window != nil, "Failed to create window!"

type
    WindowDimentions = object
        width, height, fullWidth, fullHeight : int32

proc getWindowDimentions(window : sdl.Window) : WindowDimentions =
    sdl.getWindowSize(window, addr result.fullWidth, addr result.fullHeight)
    sdl.vulkanGetDrawableSize(window, addr result.width, addr result.height)

var windowDimentions = getWindowDimentions(window)

let vkVersionInfo = makeVulkanVersionInfo vkApiVersion10
vkLog LInfo, &"Vulkan API Version: {vkVersionInfo}"
vkLog LInfo, &"Vulkan Header Version: {vkHeaderVersion}"

let 
    vkAvailableLayers = vkEnumerateInstanceLayerProperties()
    vkAvailableLayerNames = vkAvailableLayers.mapIt charArrayToString(it.layerName)
    vkDesiredLayerNames = @["VK_LAYER_LUNARG_standard_validation"]
    vkLayerNamesToRequest = vkAvailableLayerNames.intersect vkDesiredLayerNames
vkLog LTrace, "[Layers]"
for layer in vkAvailableLayers:
    let layerName = charArrayToString layer.layerName
    vkLog LTrace, &"\t{layerName} ({makeVulkanVersionInfo layer.specVersion}, {layer.implementationVersion})"
    vkLog LTrace, &"\t{charArrayToString layer.description}"
    vkLog LTrace, ""

let vkNotFoundLayerNames = vkDesiredLayerNames.filterIt(not vkLayerNamesToRequest.contains(it))
if vkNotFoundLayerNames.len() != 0: vkLog LWarning, &"Requested layers not found: {vkNotFoundLayerNames}"
vkLog LInfo, &"Requesting layers: {vkLayerNamesToRequest}"

var 
    sdlVkExtensionCount: cuint
    sdlVkExtensionsCStrings: seq[cstring]
sdlCheck vulkanGetInstanceExtensions(window, addr sdlVkExtensionCount, nil)
sdlVkExtensionsCStrings.setLen(sdlVkExtensionCount)
sdlCheck vulkanGetInstanceExtensions(window, addr sdlVkExtensionCount, cast[cstringArray](addr sdlVkExtensionsCStrings[0]))
let sdlVkDesiredExtensions = sdlVkExtensionsCStrings.mapIt($it)
sdlLog LInfo, &"SDL VK required extensions: {sdlVkDesiredExtensions}"

# TODO: move to debug utils
let 
    vkDesiredExtensionNames = @["VK_EXT_debug_report"] & sdlVkDesiredExtensions
    vkAvailableExtensions = vkEnumerateInstanceExtensionProperties(nil)
    vkAvailableExtensionNames = vkAvailableExtensions.mapIt charArrayToString(it.extensionName)
    vkExtensionNamesToRequest = vkAvailableExtensionNames.intersect vkDesiredExtensionNames
vkLog LTrace, "[Extensions]"
for extension in vkAvailableExtensions:
    let extensionName = charArrayToString(extension.extensionName)
    vkLog LTrace, &"\t{extensionName} {makeVulkanVersionInfo extension.specVersion}"

let vkNotFoundExtensions = vkDesiredExtensionNames.filterIt(not vkExtensionNamesToRequest.contains(it))
if vkNotFoundExtensions.len() != 0: vkLog LWarning, &"Requested extensions not found: {vkNotFoundExtensions}"
vkLog LInfo, &"Requesting extensions: {vkExtensionNamesToRequest}"

var vkInstance: vk.VkInstance
let vkLayersCStrings = allocCStringArray(vkLayerNamesToRequest)
block CreateVulkanInstance:
    let vkExtensionsCStrings = allocCStringArray(vkExtensionNamesToRequest)
    # TODO: deallocate cstring arrays? Or who cares?
    #defer: deallocCStringArray(vkExtensionsCStrings)
    
    let 
        appInfo = VkApplicationInfo(
            sType: VkStructureType.applicationInfo
            , pNext: nil
            , pApplicationName: "Nim Vulkan"
            , applicationVersion: 1
            , pEngineName: "Dunno"
            , engineVersion: 1
            , apiVersion: vkVersion10)
        instanceCreateInfo = VkInstanceCreateInfo(
            sType: VkStructureType.instanceCreateInfo
            , pNext: nil
            , flags: 0
            , pApplicationInfo: unsafeAddr appInfo
            , enabledLayerCount: uint32 vkLayerNamesToRequest.len()
            , ppEnabledLayerNames: vkLayersCStrings
            , enabledExtensionCount: uint32 vkExtensionNamesToRequest.len()
            , ppEnabledExtensionNames: vkExtensionsCStrings)
    vkCheck vkCreateInstance(unsafeAddr instanceCreateInfo, nil, addr vkInstance)

loadVulkanInstanceAPI(vkInstance)

type
    VulkanDebugVerbosity {.pure.} = enum
        Light, Full
const
    vkDebugVerbosity = VulkanDebugVerbosity.Light
    vkDebugMask = case vkDebugVerbosity:
        of Light: maskCombine(VkDebugReportFlagBitsEXT.error, VkDebugReportFlagBitsEXT.warning, VkDebugReportFlagBitsEXT.performanceWarning)
        of Full: maskCombine(VkDebugReportFlagBitsEXT.error, VkDebugReportFlagBitsEXT.warning, VkDebugReportFlagBitsEXT.performanceWarning, VkDebugReportFlagBitsEXT.information, VkDebugReportFlagBitsEXT.debug)

var vkDebugCallback: VkDebugReportCallbackEXT
block SetupVulkanDebugCallback:
    let vkDebugReportCallback : PFN_vkDebugReportCallbackEXT = proc (flags: VkDebugReportFlagsEXT; objectType: VkDebugReportObjectTypeEXT; cbObject: uint64; location: csize; messageCode:  int32; pLayerPrefix: cstring; pMessage: cstring; pUserData: pointer): VkBool32 {.cdecl.} =
        var logLevel = LTrace
        if   maskCheck(flags, VkDebugReportFlagBitsEXT.error):              logLevel = LError
        elif maskCheck(flags, VkDebugReportFlagBitsEXT.warning):            logLevel = LWarning
        elif maskCheck(flags, VkDebugReportFlagBitsEXT.performanceWarning): logLevel = LWarning
        elif maskCheck(flags, VkDebugReportFlagBitsEXT.information):        logLevel = LInfo
        elif maskCheck(flags, VkDebugReportFlagBitsEXT.debug):              logLevel = LTrace
        vkLog logLevel, &"{pLayerPrefix} {objectType} {messageCode} {pMessage}"
        vkFalse

    let 
        vkCallbackCreateInfo = VkDebugReportCallbackCreateInfoEXT(
            sType: VkStructureType.debugReportCallbackCreateInfoExt
            , flags: uint32 vkDebugMask
            , pfnCallback: vkDebugReportCallback)
    vkCheck vkCreateDebugReportCallbackEXT(vkInstance, unsafeAddr vkCallbackCreateInfo, nil, addr vkDebugCallback)

var vkSurface: vk.VkSurfaceKHR
sdlCheck vulkanCreateSurface(window, cast[sdl.VkInstance](vkInstance), addr vkSurface)

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

let vkDevices = vkEnumeratePhysicalDevices(vkInstance)
vkCheck vkDevices.len() != 0, "Failed to find any compatible devices!"

let vkDevicesWithProperties = vkDevices.map(proc (device: VkPhysicalDevice): tuple[
        id: VkPhysicalDevice
        , props: VkPhysicalDeviceProperties
        , queues: seq[VkQueueFamilyProperties]
        , presentQueueIdx: uint32
    ] =
    result.id = device
    vkGetPhysicalDeviceProperties(device, addr result.props)

    result.queues = vkGetPhysicalDeviceQueueFamilyProperties(device)
    result.presentQueueIdx = 0xFFFFFFFF'u32
    for i, q in result.queues:
        var surfaceSupported: VkBool32
        vkCheck vkGetPhysicalDeviceSurfaceSupportKHR(device, uint32 i, vkSurface, addr surfaceSupported)
        if surfaceSupported == vkTrue and maskCheck(q.queueFlags, VkQueueFlagBits.graphics):
            result.presentQueueIdx = uint32 i
            break
)

vkLog LTrace, "[Devices]"
for d in vkDevicesWithProperties:
    vkLog LTrace, &"\t{charArrayToString d[1].deviceName}"
    vkLog LTrace, &"\t\tType {d.props.deviceType} API {makeVulkanVersionInfo d.props.apiVersion} Driver {d.props.driverVersion} Vendor {vkVendorIDToGPUVendor d.props.vendorID}"
let vkCompatibleDevices = vkDevicesWithProperties.filter((d) => d.presentQueueIdx != 0xFFFFFFFF'u32)
vkLog LInfo, "[Compatible Devices]"
vkCheck vkCompatibleDevices.len != 0, "No compatible devices found!"
for d in vkCompatibleDevices:
    vkLog LInfo, &"\t{charArrayToString d.props.deviceName}"
let vkSelectedPhysicalDevice = vkCompatibleDevices[0]
vkLog LInfo, &"Selected physical device: {charArrayToString vkSelectedPhysicalDevice.props.deviceName}"

let vkDeviceExtensions = vkEnumerateDeviceExtensionProperties(vkSelectedPhysicalDevice.id, nil)
vkLog LTrace, "[Device Extensions]"
for ex in vkDeviceExtensions:
    vkLog LTrace, &"\t{charArrayToString(ex.extensionName)}({makeVulkanVersionInfo(ex.specVersion)})"

var
    queuePriorities = [1.0'f32]
    queueCreateInfo = VkDeviceQueueCreateInfo(
        sType: VkStructureType.deviceQueueCreateInfo
        , queueFamilyIndex: vkSelectedPhysicalDevice.presentQueueIdx
        , queueCount: 1
        , pQueuePriorities: addr queuePriorities[0]
    )
    deviceExtensions = ["VK_KHR_swapchain"]
    deviceExtensionsCStrings = allocCStringArray(deviceExtensions)
    deviceFeatures = VkPhysicalDeviceFeatures(
        shaderClipDistance: vkTrue
    )
    deviceInfo = VkDeviceCreateInfo(
        sType: VkStructureType.deviceCreateInfo
        , queueCreateInfoCount: 1
        , pQueueCreateInfos: addr queueCreateInfo
        , enabledLayerCount: uint32 vkLayerNamesToRequest.len()
        , ppEnabledLayerNames: vkLayersCStrings
        , enabledExtensionCount: uint32 deviceExtensions.len()
        , ppEnabledExtensionNames: deviceExtensionsCStrings
        , pEnabledFeatures: addr deviceFeatures
    )
    vkDevice: VkDevice
vkCheck vkCreateDevice(vkSelectedPhysicalDevice.id, addr deviceInfo, nil, addr vkDevice)
deallocCStringArray(deviceExtensionsCStrings)

let surfaceFormats = vkGetPhysicalDeviceSurfaceFormatsKHR(vkSelectedPhysicalDevice.id, vkSurface)
vkLog LTrace, "[Surface Formats]"
for fmt in surfaceFormats:
    vkLog LTrace, &"\t{fmt.format}"
vkCheck surfaceFormats.len > 0, "No surface formats returned!"

var colorFormat: VkFormat
if surfaceFormats.len() == 1 and surfaceFormats[0].format == VkFormat.undefined:
    colorFormat = VkFormat.b8g8r8a8Unorm
else:
    colorFormat = surfaceFormats[0].format
let colorSpace = surfaceFormats[0].colorSpace
vkLog LInfo, &"Selected surface format: {colorFormat}, colorspace: {colorSpace}"

var vkSurfaceCapabilities: VkSurfaceCapabilitiesKHR
vkCheck vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vkSelectedPhysicalDevice.id, vkSurface, addr vkSurfaceCapabilities)
var desiredImageCount = 2'u32
if desiredImageCount < vkSurfaceCapabilities.minImageCount: 
    desiredImageCount = vkSurfaceCapabilities.minImageCount
elif vkSurfaceCapabilities.maxImageCount != 0 and desiredImageCount > vkSurfaceCapabilities.maxImageCount: 
    desiredImageCount = vkSurfaceCapabilities.maxImageCount
vkLog LInfo, &"Desired swapchain images: {desiredImageCount}"

var surfaceResolution = vkSurfaceCapabilities.currentExtent
if surfaceResolution.width == 0xFFFFFFFF'u32:
    surfaceResolution.width = 640
    surfaceResolution.height = 480
vkLog LInfo, &"Surface resolution: {surfaceResolution}"

var preTransform = vkSurfaceCapabilities.currentTransform
if maskCheck(vkSurfaceCapabilities.supportedTransforms, VkSurfaceTransformFlagBitsKHR.identity):
    preTransform = VkSurfaceTransformFlagBitsKHR.identity

let presentModes = vkGetPhysicalDeviceSurfacePresentModesKHR(vkSelectedPhysicalDevice.id, vkSurface)
vkLog LTrace, &"Present modes: {presentModes}"
var presentMode = VkPresentModeKHR.fifo
for pm in presentModes:
    if pm == VkPresentModeKHR.mailbox:
        presentMode = VkPresentModeKHR.mailbox
        break
vkLog LInfo, &"Selected present mode: {presentMode}"

let swapChainCreateInfo = VkSwapchainCreateInfoKHR(
        sType: VkStructureType.swapchainCreateInfoKHR
        , surface: vkSurface
        , minImageCount: desiredImageCount
        , imageFormat: colorFormat
        , imageColorSpace: colorSpace
        , imageExtent: surfaceResolution
        , imageArrayLayers: 1
        , imageUsage: VkFlags(VkImageUsageFlagBits.colorAttachment)
        , imageSharingMode: VkSharingMode.exclusive
        , preTransform: preTransform
        , compositeAlpha: VkCompositeAlphaFlagBitsKHR.opaque
        , presentMode: presentMode
        , clipped: vkTrue
        , oldSwapchain: nil
    )
var vkSwapchain: VkSwapchainKHR
doAssert(vkCreateSwapchainKHR != nil)
echo vkCreateSwapchainKHR == nil
vkCheck vkCreateSwapchainKHR(vkDevice, unsafeAddr swapChainCreateInfo, nil, addr vkSwapchain)

var vkQueue: VkQueue
vkCheck vkGetDeviceQueue(vkDevice, vkSelectedPhysicalDevice.presentQueueIdx, 0, addr vkQueue)

let vkCommandPoolCreateInfo = VkCommandPoolCreateInfo(
    sType: VkStructureType.commandPoolCreateInfo
    , flags: uint32 VkCommandPoolCreateFlagBits.resetCommandBuffer
    , queueFamilyIndex: vkSelectedPhysicalDevice.presentQueueIdx
)
var vkCommandPool: VkCommandPool
vkCheck vkCreateCommandPool(vkDevice, unsafeAddr vkCommandPoolCreateInfo, nil, addr vkCommandPool)

let vkCommandBufferAllocateInfo = VkCommandBufferAllocateInfo(
    sType: VkStructureType.commandBufferAllocateInfo
    , commandPool: vkCommandPool
    , level: VkCommandBufferLevel.primary
    , commandBufferCount: 1
)
var vkSetupCmdBuffer, vkRenderCmdBuffer: VkCommandBuffer
vkCheck vkAllocateCommandBuffers(vkDevice, unsafeAddr vkCommandBufferAllocateInfo, addr vkSetupCmdBuffer)
vkCheck vkAllocateCommandBuffers(vkDevice, unsafeAddr vkCommandBufferAllocateInfo, addr vkRenderCmdBuffer)

let vkSwapchainImages = vkGetSwapchainImagesKHR(vkDevice, vkSwapchain)
var vkPresentImagesViewCreateInfo = VkImageViewCreateInfo(
    sType: VkStructureType.imageViewCreateInfo
    , viewType: VkImageViewType.twoDee
    , format: colorFormat
    , components: VkComponentMapping(r: VkComponentSwizzle.r, g: VkComponentSwizzle.g, b: VkComponentSwizzle.b, a: VkComponentSwizzle.a)
    , subresourceRange: VkImageSubresourceRange(
        aspectMask: uint32 VkImageAspectFlagBits.color
        , baseMipLevel: 0
        , levelCount: 1
        , baseArrayLayer: 0
        , layerCount: 1
    )
)

let
    vkCommandBufferBeginInfo = VkCommandBufferBeginInfo(
        sType: VkStructureType.commandBufferBeginInfo
        , flags: uint32 VkCommandBufferUsageFlagBits.oneTimeSubmit
    )
    vkFenceCreateInfo = VkFenceCreateInfo(sType: VkStructureType.fenceCreateInfo)
var vkSubmitFence: VkFence
vkCheck vkCreateFence(vkDevice, unsafeAddr vkFenceCreateInfo, nil, addr vkSubmitFence)

var vkImageViews: seq[VkImageView]
for img in vkSwapchainImages:
    vkPresentImagesViewCreateInfo.image = img
    vkCheck vkBeginCommandBuffer(vkSetupCmdBuffer, unsafeAddr vkCommandBufferBeginInfo)

    let vkLayoutTransitionBarrier = VkImageMemoryBarrier(
        sType: VkStructureType.imageMemoryBarrier
        , srcAccessMask: 0
        , dstAccessMask: uint32 VkAccessFlagBits.memoryRead
        , oldLayout: VkImageLayout.undefined
        , newLayout: VkImageLayout.presentSrcKHR
        , srcQueueFamilyIndex: 0xFFFFFFFF'u32
        , dstQueueFamilyIndex: 0xFFFFFFFF'u32
        , image: img
        , subresourceRange: VkImageSubresourceRange(
            aspectMask: uint32 VkImageAspectFlagBits.color
            , baseMipLevel: 0
            , levelCount: 1
            , baseArrayLayer: 0
            , layerCount: 1
        )
    )
    vkCheck vkCmdPipelineBarrier(
        vkSetupCmdBuffer
        , uint32 VkPipelineStageFlagBits.topOfPipe
        , uint32 VkPipelineStageFlagBits.topOfPipe
        , 0
        , 0, nil
        , 0, nil
        , 1, unsafeAddr vkLayoutTransitionBarrier
    )

    vkCheck vkEndCommandBuffer(vkSetupCmdBuffer)

    let
        vkWaitStageMask: VkPipelineStageFlags = uint32 VkPipelineStageFlagBits.colorAttachmentOutput
        vkSubmitInfo = VkSubmitInfo(
            sType: VkStructureType.submitInfo
            , waitSemaphoreCount: 0
            , pWaitSemaphores: nil
            , pWaitDstStageMask: unsafeAddr vkWaitStageMask
            , commandBufferCount: 1
            , pCommandBuffers: addr vkSetupCmdBuffer
            , signalSemaphoreCount: 0
            , pSignalSemaphores: nil
        )
    vkCheck vkQueueSubmit(vkQueue, 1, unsafeAddr vkSubmitInfo, vkSubmitFence)
    vkCheck vkWaitForFences(vkDevice, 1, addr vkSubmitFence, vkTrue, 0xFFFFFFFF_FFFFFFFF'u64)
    vkCheck vkResetFences(vkDevice, 1, addr vkSubmitFence)

    vkCheck vkResetCommandBuffer(vkSetupCmdBuffer, 0)

    var vkImageView: VkImageView
    vkCheck vkCreateImageView(vkDevice, unsafeAddr vkPresentImagesViewCreateInfo, nil, addr vkImageView)
    vkImageViews.add vkImageView

let render = proc() =
    var nextImageIdx: uint32
    vkCheck vkAcquireNextImageKHR(vkDevice, vkSwapchain, 0xFFFFFFFF_FFFFFFFF'u64, vkNullHandle, vkNullHandle, addr nextImageIdx)
    let presentInfo = VkPresentInfoKHR(
        sType: VkStructureType.presentInfoKHR
        , pNext: nil
        , waitSemaphoreCount: 0
        , pWaitSemaphores: nil
        , swapchainCount: 1
        , pSwapchains: addr vkSwapchain
        , pImageIndices: addr nextImageIdx
        , pResults: nil
    )
    vkCheck vkQueuePresentKHR(vkQueue, unsafeAddr presentInfo)

proc updateRenderResolution(winDim : WindowDimentions) =
    gLog LInfo, &"Render resolution changed to: ({winDim.width}, {winDim.height})"

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
    
        render()

for imgView in vkImageViews:
    vkDestroyImageView(vkDevice, imgView, nil)
vkDestroyFence(vkDevice, vkSubmitFence, nil)
vkFreeCommandBuffers(vkDevice, vkCommandPool, 1, addr vkRenderCmdBuffer)
vkFreeCommandBuffers(vkDevice, vkCommandPool, 1, addr vkSetupCmdBuffer)
vkDestroyCommandPool(vkDevice, vkCommandPool, nil)
vkDestroySwapchainKHR(vkDevice, vkSwapchain, nil)
vkDestroyDevice(vkDevice, nil)
vkDestroyDebugReportCallbackEXT(vkInstance, vkDebugCallback, nil)
vkDestroyInstance(vkInstance, nil)
destroyWindow(window)
sdl.quit()