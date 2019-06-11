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

let vkDevices = vkwEnumeratePhysicalDevicesWithDescriptions(vkInstance, vkSurface)
vkCheck vkDevices.len() != 0, "Failed to find any Vulkan compatible devices!"

vkLog LTrace, "[Devices]"
for d in vkDevices:
    vkLog LTrace, &"\t{d.name}"
    vkLog LTrace, &"\t\tType {d.properties.deviceType} API {makeVulkanVersionInfo d.properties.apiVersion} Driver {d.properties.driverVersion} Vendor {d.vendor}"

let vkCompatibleDevices = vkDevices.filter((d) => d.hasPresentQueue)
vkCheck vkCompatibleDevices.len != 0, "No devices with a present queue found!"

vkLog LInfo, "[Compatible Devices]"
for d in vkCompatibleDevices:
    vkLog LInfo, &"\t{d.name}"

let vkSelectedPhysicalDevice = vkCompatibleDevices[0]
vkLog LInfo, &"Selected physical device: {charArrayToString vkSelectedPhysicalDevice.name}"

vkLog LTrace, "[Device Extensions]"
for ex in vkSelectedPhysicalDevice.extensions:
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
vkCheck vkCreateDevice(vkSelectedPhysicalDevice.handle, addr deviceInfo, nil, addr vkDevice)
deallocCStringArray(deviceExtensionsCStrings)

let surfaceFormats = vkGetPhysicalDeviceSurfaceFormatsKHR(vkSelectedPhysicalDevice.handle, vkSurface)
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
vkCheck vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vkSelectedPhysicalDevice.handle, vkSurface, addr vkSurfaceCapabilities)
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

let presentModes = vkGetPhysicalDeviceSurfacePresentModesKHR(vkSelectedPhysicalDevice.handle, vkSurface)
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
vkCheck vkCreateSwapchainKHR(vkDevice, unsafeAddr swapChainCreateInfo, nil, addr vkSwapchain)

let vkImageCreateInfo = VkImageCreateInfo(
    sType: VkStructureType.imageCreateInfo
    , imageType: VkImageType.twoDee
    , format: VkFormat.d16Unorm
    , extent: VkExtent3D(width: surfaceResolution.width, height: surfaceResolution.height, depth: 1)
    , mipLevels: 1
    , arrayLayers: 1
    , samples: VkSampleCountFlagBits.one
    , tiling: VkImageTiling.optimal
    , usage: uint32 VkImageUsageFlagBits.depthStencilAttachment
    , sharingMode: VkSharingMode.exclusive
    , queueFamilyIndexCount: 0
    , pQueueFamilyIndices: nil
    , initialLayout: VkImageLayout.undefined
)
var vkDepthImage: VkImage
vkCheck vkCreateImage(vkDevice, unsafeAddr vkImageCreateInfo, nil, addr vkDepthImage)

var vkMemoryRequirements: VkMemoryRequirements
vkCheck vkGetImageMemoryRequirements(vkDevice, vkDepthImage, addr vkMemoryRequirements)
var vkImageMemory = vkwAllocateDeviceMemory(vkDevice, vkSelectedPhysicalDevice.memoryProperties, vkMemoryRequirements, VkMemoryPropertyFlags VkMemoryPropertyFlagBits.deviceLocal)
vkCheck vkBindImageMemory(vkDevice, vkDepthImage, vkImageMemory, 0)

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
var vkImageTransitionStatus = repeat(false, vkSwapchainImages.len())
while vkImageTransitionStatus.any(proc (x: bool): bool = not x):
    var presentBeginData = vkwPresentBegin(vkDevice, vkSwapchain, vkSetupCmdBuffer)

    if not vkImageTransitionStatus[int presentBeginData.imageIndex]:
        vkImageTransitionStatus[int presentBeginData.imageIndex] = true

        let vkLayoutTransitionBarrier = VkImageMemoryBarrier(
            sType: VkStructureType.imageMemoryBarrier
            , srcAccessMask: 0
            , dstAccessMask: uint32 VkAccessFlagBits.memoryRead
            , oldLayout: VkImageLayout.undefined
            , newLayout: VkImageLayout.presentSrcKHR
            , srcQueueFamilyIndex: high uint32
            , dstQueueFamilyIndex: high uint32
            , image: vkSwapchainImages[int presentBeginData.imageIndex]
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
    
    vkwPresentEnd(vkDevice, vkSwapchain, vkSetupCmdBuffer, vkQueue, presentBeginData)

var
    vkPresentImagesViewCreateInfo = VkImageViewCreateInfo(
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
    vkImageViews: seq[VkImageView]

for img in vkSwapchainImages:
    vkPresentImagesViewCreateInfo.image = img
    var vkImageView: VkImageView
    vkCheck vkCreateImageView(vkDevice, unsafeAddr vkPresentImagesViewCreateInfo, nil, addr vkImageView)
    vkImageViews.add vkImageView

let
    vkCommandBufferBeginInfo = VkCommandBufferBeginInfo(
        sType: VkStructureType.commandBufferBeginInfo
        , flags: uint32 VkCommandBufferUsageFlagBits.oneTimeSubmit
    )
    vkFenceCreateInfo = VkFenceCreateInfo(sType: VkStructureType.fenceCreateInfo)
var vkSubmitFence: VkFence
vkCheck vkCreateFence(vkDevice, unsafeAddr vkFenceCreateInfo, nil, addr vkSubmitFence)

var vkDepthImageView: VkImageView
block DepthStensilSetup:
    let beginInfo = VkCommandBufferBeginInfo(
        sType: VkStructureType.commandBufferBeginInfo
        , flags: uint32 VkCommandBufferUsageFlagBits.oneTimeSubmit
    )
    vkCheck vkBeginCommandBuffer(vkSetupCmdBuffer, unsafeAddr beginInfo)
    let layoutTransitionBarrier = VkImageMemoryBarrier(
        sType: VkStructureType.imageMemoryBarrier
        , srcAccessMask: 0
        , dstAccessMask: uint32 maskCombine(VkAccessFlagBits.depthStencilAttachmentRead, VkAccessFlagBits.depthStencilAttachmentWrite)
        , oldLayout: VkImageLayout.undefined
        , newLayout: VkImageLayout.depthStencilAttachmentOptimal
        , srcQueueFamilyIndex: 0xFFFFFFFF'u32
        , dstQueueFamilyIndex: 0xFFFFFFFF'u32
        , image: vkDepthImage
        , subresourceRange: VkImageSubresourceRange(
            aspectMask: uint32 VkImageAspectFlagBits.depth
            , baseMipLevel: 0
            , levelCount: 1
            , baseArrayLayer: 0
            , layerCount: 1
        )
    )
    vkCheck vkCmdPipelineBarrier(
        vkSetupCmdBuffer
        , uint32 VkPipelineStageFlagBits.topOfPipe
        , uint32 VkPipelineStageFlagBits.earlyFragmentTests
        , 0
        , 0, nil
        , 0, nil
        , 1, unsafeAddr layoutTransitionBarrier
    )
    vkCheck vkEndCommandBuffer(vkSetupCmdBuffer)

    let
        waitStageMask: VkPipelineStageFlags = uint32 VkPipelineStageFlagBits.colorAttachmentOutput
        submitInfo = VkSubmitInfo(
            sType: VkStructureType.submitInfo
            , waitSemaphoreCount: 0
            , pWaitSemaphores: nil
            , pWaitDstStageMask: unsafeAddr waitStageMask
            , commandBufferCount: 1
            , pCommandBuffers: addr vkSetupCmdBuffer
            , signalSemaphoreCount: 0
            , pSignalSemaphores: nil
        )
    vkCheck vkQueueSubmit(vkQueue, 1, unsafeAddr submitInfo, vkSubmitFence)

    vkCheck vkWaitForFences(vkDevice, 1, addr vkSubmitFence, vkTrue, 0xFFFFFFFF_FFFFFFFF'u64)
    vkCheck vkResetFences(vkDevice, 1, addr vkSubmitFence)
    vkCheck vkResetCommandBuffer(vkSetupCmdBuffer, 0)

    let
        imageViewCreateInfo = VkImageViewCreateInfo(
            sType: VkStructureType.imageViewCreateInfo
            , image: vkDepthImage
            , viewType: VkImageViewType.twoDee
            , format: vkImageCreateInfo.format
            , components: VkComponentMapping(r: VkComponentSwizzle.identity, g: VkComponentSwizzle.identity, b: VkComponentSwizzle.identity, a: VkComponentSwizzle.identity)
            , subresourceRange: VkImageSubresourceRange(
                aspectMask: uint32 VkImageAspectFlagBits.depth
                , baseMipLevel: 0
                , levelCount: 1
                , baseArrayLayer: 0
                , layerCount: 1
            )
        )
    vkCheck vkCreateImageView(vkDevice, unsafeAddr imageViewCreateInfo, nil, addr vkDepthImageView)

let
    passAttachments = @[
        VkAttachmentDescription(
            format: colorFormat
            , samples: VkSampleCountFlagBits.one
            , loadOp: VkAttachmentLoadOp.opClear
            , storeOp: VkAttachmentStoreOp.opStore
            , stencilLoadOp: VkAttachmentLoadOp.opDontCare
            , stencilStoreOp: VkAttachmentStoreOp.opDontCare
            , initialLayout: VkImageLayout.colorAttachmentOptimal
            , finalLayout: VkImageLayout.colorAttachmentOptimal
        )
        , VkAttachmentDescription(
            format: VkFormat.d16Unorm
            , samples: VkSampleCountFlagBits.one
            , loadOp: VkAttachmentLoadOp.opClear
            , storeOp: VkAttachmentStoreOp.opDontCare
            , stencilLoadOp: VkAttachmentLoadOp.opDontCare
            , stencilStoreOp: VkAttachmentStoreOp.opDontCare
            , initialLayout: VkImageLayout.depthStencilAttachmentOptimal
            , finalLayout: VkImageLayout.depthStencilAttachmentOptimal
        )
    ]
    colorAttachmentReference = VkAttachmentReference(
        attachment: 0
        , layout: VkImageLayout.colorAttachmentOptimal
    )
    depthAttachmentReference = VkAttachmentReference(
        attachment: 1
        , layout: VkImageLayout.depthStencilAttachmentOptimal
    )
    subpass = VkSubpassDescription(
        pipelineBindPoint: VkPipelineBindPoint.graphics
        , colorAttachmentCount: 1
        , pColorAttachments: unsafeAddr colorAttachmentReference
        , pDepthStencilAttachment: unsafeAddr depthAttachmentReference
    )
    renderPassCreateInfo = VkRenderPassCreateInfo(
        sType: VkStructureType.renderPassCreateInfo
        , attachmentCount: 2
        , pAttachments: unsafeAddr passAttachments[0]
        , subpassCount: 1
        , pSubpasses: unsafeAddr subpass
    )
var vkRenderPass: VkRenderPass
vkCheck vkCreateRenderPass(vkDevice, unsafeAddr renderPassCreateInfo, nil, addr vkRenderPass)

var frameBufferAttachments: seq[VkImageView]
frameBufferAttachments.setLen(2)
frameBufferAttachments[1] = vkDepthImageView

let framebufferCreateInfo = VkFramebufferCreateInfo(
    sType: VkStructureType.framebufferCreateInfo
    , renderPass: vkRenderPass
    , attachmentCount: 2
    , pAttachments: addr frameBufferAttachments[0]
    , width: surfaceResolution.width
    , height: surfaceResolution.height
    , layers: 1
)

var vkFramebuffers: seq[VkFramebuffer]
vkFramebuffers.setLen(vkImageViews.len())
for i, piv in vkImageViews:
    frameBufferAttachments[0] = piv
    vkCheck vkCreateFramebuffer(vkDevice, unsafeAddr framebufferCreateInfo, nil, addr vkFramebuffers[i])

type
    Vertex = object
        x, y, z, w: float32
let vkVertexBufferCreateInfo = VkBufferCreateInfo(
    sType: VkStructureType.bufferCreateInfo
    , size: uint64 sizeof(Vertex) * 3
    , usage: uint32 VkBufferUsageFlagBits.vertexBuffer
    , sharingMode: VkSharingMode.exclusive
)
var vkVertexInputBuffer: VkBuffer
vkCheck vkCreateBuffer(vkDevice, unsafeAddr vkVertexBufferCreateInfo, nil, addr vkVertexInputBuffer)

var vkVertexBufferMemoryRequirements: VkMemoryRequirements
vkGetBufferMemoryRequirements(vkDevice, vkVertexInputBuffer, addr vkVertexBufferMemoryRequirements)
var vkVertexBufferMemory = vkwAllocateDeviceMemory(vkDevice, vkSelectedPhysicalDevice.memoryProperties, vkVertexBufferMemoryRequirements, VkMemoryPropertyFlags VkMemoryPropertyFlagBits.hostVisible)

var vkVertexMappedMem: CArray[Vertex]
vkCheck vkMapMemory(vkDevice, vkVertexBufferMemory, 0, 0xFFFFFFFF_FFFFFFFF'u64, 0, cast[ptr pointer](addr vkVertexMappedMem))
vkVertexMappedMem[0] = Vertex(x: -0.9, y: -0.9, z: 0, w: 1.0)
vkVertexMappedMem[1] = Vertex(x:  0.9, y: -0.9, z: 0, w: 1.0)
vkVertexMappedMem[2] = Vertex(x:  0.0, y:  0.9, z: 0, w: 1.0)
vkCheck vkUnmapMemory(vkDevice, vkVertexBufferMemory)
vkCheck vkBindBufferMemory(vkDevice, vkVertexInputBuffer, vkVertexBufferMemory, 0)

let
    vkVertexShaderBytecode = readBinaryFile("./vert.spv")
    vkFragmentShaderBytecode = readBinaryFile("./frag.spv")
    vkVertexShaderCreateInfo = VkShaderModuleCreateInfo(
        sType: VkStructureType.shaderModuleCreateInfo
        , codeSize: vkVertexShaderBytecode.len()
        , pCode: cast[ptr uint32](unsafeAddr vkVertexShaderBytecode[0])
    )
    vkFragmentShaderCreateInfo = VkShaderModuleCreateInfo(
        sType: VkStructureType.shaderModuleCreateInfo
        , codeSize: vkFragmentShaderBytecode.len()
        , pCode: cast[ptr uint32](unsafeAddr vkFragmentShaderBytecode[0])
    )
var 
    vkVertexShaderModule, vkFragmentShaderModule: VkShaderModule
vkCheck vkCreateShaderModule(vkDevice, unsafeAddr vkVertexShaderCreateInfo, nil, addr vkVertexShaderModule)
vkCheck vkCreateShaderModule(vkDevice, unsafeAddr vkFragmentShaderCreateInfo, nil, addr vkFragmentShaderModule)

type
    ShaderUniform = object
        buffer: VkBuffer
        memory: VkDeviceMemory
var vkUniforms: ShaderUniform

let 
    vkIdentityMatrix = @[
        1'f32, 0, 0, 0
          , 0, 1, 0, 0
          , 0, 0, 1, 0
          , 0, 0, 0, 1
    ]
    vkBufferCreateInfo = VkBufferCreateInfo(
        sType: VkStructureType.bufferCreateInfo
        , size: sizeof(float32) * 16
        , usage: uint32 VkBufferUsageFlagBits.uniformBuffer
        , sharingMode: VkSharingMode.exclusive
    )
vkCheck vkCreateBuffer(vkDevice, unsafeAddr vkBufferCreateInfo, nil, addr vkUniforms.buffer)

var vkBufferMemoryRequirements: VkMemoryRequirements
vkCheck vkGetBufferMemoryRequirements(vkDevice, vkUniforms.buffer, addr vkBufferMemoryRequirements)
vkUniforms.memory = vkwAllocateDeviceMemory(vkDevice, vkSelectedPhysicalDevice.memoryProperties, vkBufferMemoryRequirements, VkMemoryPropertyFlags VkMemoryPropertyFlagBits.hostVisible)
vkCheck vkBindBufferMemory(vkDevice, vkUniforms.buffer, vkUniforms.memory, 0)

var vkMatrixMappedMem: pointer
vkCheck vkMapMemory(vkDevice, vkUniforms.memory, 0, high uint64, 0, addr vkMatrixMappedMem)
copyMem(vkMatrixMappedMem, unsafeAddr vkIdentityMatrix[0], sizeof(float32) * 16)
vkCheck vkUnmapMemory(vkDevice, vkUniforms.memory)

let
    vkBindings = VkDescriptorSetLayoutBinding(
        binding: 0
        , descriptorType: VkDescriptorType.uniformBuffer
        , descriptorCount: 1
        , stageFlags: uint32 VkShaderStageFlagBits.vertex
        , pImmutableSamplers: nil
    )
    vkSetLayoutCreateInfo = VkDescriptorSetLayoutCreateInfo(
        sType: VkStructureType.descriptorSetLayoutCreateInfo
        , bindingCount: 1
        , pBindings: unsafeAddr vkBindings
    )
var vkSetLayout: VkDescriptorSetLayout
vkCheck vkCreateDescriptorSetLayout(vkDevice, unsafeAddr vkSetLayoutCreateInfo, nil, addr vkSetLayout)
let
    vkUniformBufferPoolSize = VkDescriptorPoolSize(
        descriptorType: VkDescriptorType.uniformBuffer
        , descriptorCount: 1
    )
    vkPoolCreateInfo = VkDescriptorPoolCreateInfo(
        sType: VkStructureType.descriptorPoolCreateInfo
        , maxSets: 1
        , poolSizeCount: 1
        , pPoolSizes: unsafeAddr vkUniformBufferPoolSize
    )
var vkDescriptorPool: VkDescriptorPool
vkCheck vkCreateDescriptorPool(vkDevice, unsafeAddr vkPoolCreateInfo, nil, addr vkDescriptorPool)

let vkDescriptorAllocateInfo = VkDescriptorSetAllocateInfo(
    sType: VkStructureType.descriptorSetAllocateInfo
    , descriptorPool: vkDescriptorPool
    , descriptorSetCount: 1
    , pSetLayouts: addr vkSetLayout
)
var vkDescriptorSet: VkDescriptorSet
vkCheck vkAllocateDescriptorSets(vkDevice, unsafeAddr vkDescriptorAllocateInfo, addr vkDescriptorSet)

let
    vkDescriptorBufferInfo = VkDescriptorBufferInfo(
        buffer: vkUniforms.buffer
        , offset: 0
        , range: high uint64
    )
    vkWriteDescriptor = VkWriteDescriptorSet(
        sType: VkStructureType.writeDescriptorSet
        , dstSet: vkDescriptorSet
        , dstBinding: 0
        , dstArrayElement: 0
        , descriptorCount: 1
        , descriptorType: VkDescriptorType.uniformBuffer
        , pImageInfo: nil
        , pBufferInfo: unsafeAddr vkDescriptorBufferInfo
        , pTexelBufferView: nil
    )
vkCheck vkUpdateDescriptorSets(vkDevice, 1, unsafeAddr vkWriteDescriptor, 0, nil)

let vkPipelineLayoutCreateInfo = VkPipelineLayoutCreateInfo(
    sType: VkStructureType.pipelineLayoutCreateInfo
    , setLayoutCount: 1
    , pSetLayouts: addr vkSetLayout
    , pushConstantRangeCount: 0
    , pPushConstantRanges: nil
)
var vkPipelineLayout: VkPipelineLayout
vkCheck vkCreatePipelineLayout(vkDevice, unsafeAddr vkPipelineLayoutCreateInfo, nil, addr vkPipelineLayout)

let vkPipelineShaderStageCreateInfos = @[
    VkPipelineShaderStageCreateInfo(
        sType: VkStructureType.pipelineShaderStageCreateInfo
        , stage: VkShaderStageFlagBits.vertex
        , module: vkVertexShaderModule
        , pName: "main"
        , pSpecializationInfo: nil
    )
    , VkPipelineShaderStageCreateInfo(
        sType: VkStructureType.pipelineShaderStageCreateInfo
        , stage: VkShaderStageFlagBits.fragment
        , module: vkFragmentShaderModule
        , pName: "main"
        , pSpecializationInfo: nil
    )
]

let
    vkVertexInputBindingDescription = VkVertexInputBindingDescription(
        binding: 0
        , stride: uint32 sizeof Vertex
        , inputRate: VkVertexInputRate.vertex
    )
    vkVertexInputAttributeDescription = VkVertexInputAttributeDescription(
        location: 0
        , binding: 0
        , format: VkFormat.r32g32b32a32SFloat
        , offset: 0
    )
    vkPipelineVertexInputStateCreateInfo = VkPipelineVertexInputStateCreateInfo(
        sType: VkStructureType.pipelineVertexInputStateCreateInfo
        , vertexBindingDescriptionCount: 1
        , pVertexBindingDescriptions: unsafeAddr vkVertexInputBindingDescription
        , vertexAttributeDescriptionCount: 1
        , pVertexAttributeDescriptions: unsafeAddr vkVertexInputAttributeDescription
    )
    vkPipelineInputAssemblyStateCreateInfo = VkPipelineInputAssemblyStateCreateInfo(
        sType: VkStructureType.pipelineInputAssemblyStateCreateInfo
        , topology: VkPrimitiveTopology.triangleList
        , primitiveRestartEnable: vkFalse
    )
    vkViewport = VkViewport(
        x: 0, y: 0
        , width: float32 surfaceResolution.width, height: float32 surfaceResolution.height
        , minDepth: 0, maxDepth: 1
    )
    vkScisors = VkRect2D(
        offset: VkOffset2D(x: 0, y: 0)
        , extent: VkExtent2D(width: surfaceResolution.width, height: surfaceResolution.height)
    )
    vkViewportStateCreateInfo = VkPipelineViewportStateCreateInfo(
        sType: VkStructureType.pipelineViewportStateCreateInfo
        , viewportCount: 1
        , pViewports: unsafeAddr vkViewport
        , scissorCount: 1
        , pScissors: unsafeAddr vkScisors
    )
    vkPipelineRasterizationStateCreateInfo = VkPipelineRasterizationStateCreateInfo(
        sType: VkStructureType.pipelineRasterizationStateCreateInfo
        , depthClampEnable: vkFalse
        , rasterizerDiscardEnable: vkFalse
        , polygonMode: VkPolygonMode.fill
        , cullMode: VkCullModeFlags VkCullModeFlagBits.none
        , frontFace: VkFrontFace.counterClockwise
        , depthBiasEnable: vkFalse
        , depthBiasConstantFactor: 0
        , depthBiasClamp: 0
        , depthBiasSlopeFactor: 0
        , lineWidth: 1
    )
    vkPipelineMultisampleStateCreateInfo = VkPipelineMultisampleStateCreateInfo(
        sType: VkStructureType.pipelineMultisampleStateCreateInfo
        , rasterizationSamples: VkSampleCountFlagBits.one
        , sampleShadingEnable: vkFalse
        , minSampleShading: 0
        , pSampleMask: nil
        , alphaToCoverageEnable: vkFalse
        , alphaToOneEnable: vkFalse
    )
    vkNoopStencilOpState = VkStencilOpState(
        failOp: VkStencilOp.keep
        , passOp: VkStencilOp.keep
        , depthFailOp: VkStencilOp.keep
        , compareOp: VkCompareOp.always
        , compareMask: 0
        , writeMask: 0
        , reference: 0
    )
    vkDepthState = VkPipelineDepthStencilStateCreateInfo(
        sType: pipelineDepthStencilStateCreateInfo
        , depthTestEnable: vkTrue
        , depthWriteEnable: vkTrue
        , depthCompareOp: VkCompareOp.lessOrEqual
        , depthBoundsTestEnable: vkFalse
        , stencilTestEnable: vkFalse
        , front: vkNoopStencilOpState
        , back: vkNoopStencilOpState
        , minDepthBounds: 0
        , maxDepthBounds: 0
    )
    vkColorBlendAttachmentState = VkPipelineColorBlendAttachmentState(
        blendEnable: vkFalse
        , srcColorBlendFactor: VkBlendFactor.srcColor
        , dstColorBlendFactor: VkBlendFactor.oneMinusDstColor
        , colorBlendOp: VkBlendOp.opAdd
        , srcAlphaBlendFactor: VkBlendFactor.zero
        , dstAlphaBlendFactor: VkBlendFactor.zero
        , alphaBlendOp: VkBlendOp.opAdd
        , colorWriteMask: 0xf
    )
    vkColorBlendState = VkPipelineColorBlendStateCreateInfo(
        sType: VkStructureType.pipelineColorBlendStateCreateInfo
        , logicOpEnable: vkFalse
        , logicOp: VkLogicOp.opClear
        , attachmentCount: 1
        , pAttachments: unsafeAddr vkColorBlendAttachmentState
        , blendConstants: [0'f32, 0, 0, 0]
    )
    vkDynamicState = @[VkDynamicState.viewport, VkDynamicState.scissor]
    vkDynamicStateCreateInfo = VkPipelineDynamicStateCreateInfo(
        sType: VkStructureType.pipelineDynamicStateCreateInfo
        , dynamicStateCount: 2
        , pDynamicStates: unsafeAddr vkDynamicState[0]
    )
    vkPipelineCreateInfo = VkGraphicsPipelineCreateInfo(
        sType: VkStructureType.graphicsPipelineCreateInfo
        , stageCount: 2
        , pStages: unsafeAddr vkPipelineShaderStageCreateInfos[0]
        , pVertexInputState: unsafeAddr vkPipelineVertexInputStateCreateInfo
        , pInputAssemblyState: unsafeAddr vkPipelineInputAssemblyStateCreateInfo
        , pTessellationState: nil
        , pViewportState: unsafeAddr vkViewportStateCreateInfo
        , pRasterizationState: unsafeAddr vkPipelineRasterizationStateCreateInfo
        , pMultisampleState: unsafeAddr vkPipelineMultisampleStateCreateInfo
        , pDepthStencilState: unsafeAddr vkDepthState
        , pColorBlendState: unsafeAddr vkColorBlendState
        , pDynamicState: unsafeAddr vkDynamicStateCreateInfo
        , layout: vkPipelineLayout
        , renderPass: vkRenderPass
        , subpass: 0
        , basePipelineHandle: 0
        , basePipelineIndex: 0
    )
var vkPipeline: VkPipeline
vkCheck vkCreateGraphicsPipelines(vkDevice, vkNullHandle, 1, unsafeAddr vkPipelineCreateInfo, nil, addr vkPipeline)

let render = proc() =
    var presentBeginData = vkwPresentBegin(vkDevice, vkSwapchain, vkRenderCmdBuffer)

    let vkLayoutTransitionBarrier = VkImageMemoryBarrier(
        sType: VkStructureType.imageMemoryBarrier
        , srcAccessMask: uint32 VkAccessFlagBits.memoryRead
        , dstAccessMask: uint32 maskCombine(VkAccessFlagBits.colorAttachmentRead, VkAccessFlagBits.colorAttachmentWrite)
        , oldLayout: VkImageLayout.presentSrcKHR
        , newLayout: VkImageLayout.colorAttachmentOptimal
        , srcQueueFamilyIndex: high uint32
        , dstQueueFamilyIndex: high uint32
        , image: vkSwapchainImages[int presentBeginData.imageIndex]
        , subresourceRange: VkImageSubresourceRange(
            aspectMask: uint32 VkImageAspectFlagBits.color
            , baseMipLevel: 0
            , levelCount: 1
            , baseArrayLayer: 0
            , layerCount: 1
        )
    )
    vkCheck vkCmdPipelineBarrier(
        vkRenderCmdBuffer
        , uint32 VkPipelineStageFlagBits.topOfPipe
        , uint32 VkPipelineStageFlagBits.colorAttachmentOutput
        , 0
        , 0, nil
        , 0, nil
        , 1, unsafeAddr vkLayoutTransitionBarrier
    )
    let
        clearValues = @[
            VkClearValue(
                color: VkClearColorValue(float32: [0.8'f32, 0.8, 0.8, 1.0])
            )
            , VkClearValue(
                depthStencil: VkClearDepthStencilValue(depth: 1.0, stencil: 0)
            )
        ]
        renderArea = VkRect2D(
            offset: VkOffset2D(x: 0, y: 0)
            , extent: VkExtent2D(width: surfaceResolution.width, height: surfaceResolution.height)
        )
        renderPassBeginInfo = VkRenderPassBeginInfo(
            sType: VkStructureType.renderPassBeginInfo
            , renderPass: vkRenderPass
            , framebuffer: vkFrameBuffers[int presentBeginData.imageIndex]
            , renderArea: renderArea
            , clearValueCount: 2
            , pClearValues: unsafeAddr clearValues[0]
        )
    vkCheck vkCmdBeginRenderPass(vkRenderCmdBuffer, unsafeAddr renderPassBeginInfo, VkSubpassContents.inline)
    vkCheck vkCmdBindPipeline(vkRenderCmdBuffer, VkPipelineBindPoint.graphics, vkPipeline)
    
    let
        viewport = VkViewport(x: 0, y: 0, width: float32 surfaceResolution.width, height: float32 surfaceResolution.height, minDepth: 0, maxDepth: 1)
        scissor = renderArea
    vkCheck vkCmdSetViewport(vkRenderCmdBuffer, 0, 1, unsafeAddr viewport)
    vkCheck vkCmdSetScissor(vkRenderCmdBuffer, 0, 1, unsafeAddr scissor)
    vkCheck vkCmdBindDescriptorSets(vkRenderCmdBuffer, VkPipelineBindPoint.graphics, vkPipelineLayout, 0, 1, addr vkDescriptorSet, 0, nil)

    var offsets: VkDeviceSize
    vkCheck vkCmdBindVertexBuffers(vkRenderCmdBuffer, 0, 1, addr vkVertexInputBuffer, addr offsets)
    vkCheck vkCmdDraw(vkRenderCmdBuffer, 3, 1, 0, 0)

    vkCheck vkCmdEndRenderPass(vkRenderCmdBuffer)

    let prePresentBarrier = VkImageMemoryBarrier(
        sType: VkStructureType.imageMemoryBarrier
        , srcAccessMask: uint32 VkAccessFlagBits.colorAttachmentWrite
        , dstAccessMask: uint32 VkAccessFlagBits.memoryRead
        , oldLayout: VkImageLayout.colorAttachmentOptimal
        , newLayout: VkImageLayout.presentSrcKHR
        , srcQueueFamilyIndex: high uint32
        , dstQueueFamilyIndex: high uint32
        , image: vkSwapchainImages[int presentBeginData.imageIndex]
        , subresourceRange: VkImageSubresourceRange(
            aspectMask: uint32 VkImageAspectFlagBits.color
            , baseMipLevel: 0
            , levelCount: 1
            , baseArrayLayer: 0
            , layerCount: 1
        )
    )
    
    vkCheck vkCmdPipelineBarrier(
        vkRenderCmdBuffer
        , uint32 VkPipelineStageFlagBits.allCommands
        , uint32 VkPipelineStageFlagBits.bottomOfPipe
        , 0
        , 0, nil
        , 0, nil
        , 1, unsafeAddr prePresentBarrier
    )
    
    vkwPresentEnd(vkDevice, vkSwapchain, vkRenderCmdBuffer, vkQueue, presentBeginData)

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

vkDestroyPipeline(vkDevice, vkPipeline, nil)
vkDestroyPipelineLayout(vkDevice, vkPipelineLayout, nil)
vkDestroyDescriptorPool(vkDevice, vkDescriptorPool, nil)
vkDestroyDescriptorSetLayout(vkDevice, vkSetlayout, nil)
vkDestroyBuffer(vkDevice, vkUniforms.buffer, nil)
vkFreeMemory(vkDevice, vkUniforms.memory, nil)
vkDestroyShaderModule(vkDevice, vkFragmentShaderModule, nil)
vkDestroyShaderModule(vkDevice, vkVertexShaderModule, nil)
vkDestroyBuffer(vkDevice, vkVertexInputBuffer, nil)
vkFreeMemory(vkDevice, vkVertexBufferMemory, nil)
for fb in vkFramebuffers:
    vkDestroyFramebuffer(vkDevice, fb, nil)
vkDestroyRenderPass(vkDevice, vkRenderPass, nil)
for imgView in vkImageViews:
    vkDestroyImageView(vkDevice, imgView, nil)
vkDestroyImageView(vkDevice, vkDepthImageView, nil)
vkDestroyImage(vkDevice, vkDepthImage, nil)
vkFreeMemory(vkDevice, vkImageMemory, nil)
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