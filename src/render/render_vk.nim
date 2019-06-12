import sequtils
import strformat
import sdl2
import vulkan_wrapper
import ../log
import ../utility

type
    RdPhysicalDeviceType* {.pure.} = enum
        other, integratedGpu, discreteGpu, virtualGpu, cpu
    RdPhysicalDeviceVendor* {.pure.} = enum
        AMD, NVidia, Intel, ARM, Qualcomm, ImgTec, Unknown
    RdPhysicalDevice* = object
        name*: string
        deviceType*: RdPhysicalDeviceType
        vendor*: RdPhysicalDeviceVendor
        vulkanData: VkwPhysicalDeviceDescription
    
    RdContextState {.pure.} = enum
        uninitialized, preInitialized, initialized
    RdContext* = object
        state: RdContextState
        instance: VkInstance
        instanceLayers: seq[string]
        instanceExtensions: seq[string]
        debugCallback: VkDebugReportCallbackEXT
        surface: VkSurfaceKHR
        physicalDevice: VkPhysicalDevice
        physicalDeviceProperties: RdPhysicalDevice
        device: VkDevice

template convert[B: RdPhysicalDeviceType](a: VkPhysicalDeviceType): B =
    case a:
        of VkPhysicalDeviceType.other:          RdPhysicalDeviceType.other
        of VkPhysicalDeviceType.integratedGpu:  RdPhysicalDeviceType.integratedGpu
        of VkPhysicalDeviceType.discreteGpu:    RdPhysicalDeviceType.discreteGpu
        of VkPhysicalDeviceType.virtualGpu:     RdPhysicalDeviceType.virtualGpu
        of VkPhysicalDeviceType.cpu:            RdPhysicalDeviceType.cpu

template convert[B: RdPhysicalDeviceVendor](a: GPUVendor): B =
    case a:
        of GPUVendor.AMD:       RdPhysicalDeviceVendor.AMD
        of GPUVendor.NVidia:    RdPhysicalDeviceVendor.NVidia
        of GPUVendor.Intel:     RdPhysicalDeviceVendor.Intel
        of GPUVendor.ARM:       RdPhysicalDeviceVendor.ARM
        of GPUVendor.Qualcomm:  RdPhysicalDeviceVendor.Qualcomm
        of GPUVendor.ImgTec:    RdPhysicalDeviceVendor.ImgTec
        of GPUVendor.Unknown:   RdPhysicalDeviceVendor.Unknown

proc rdGetRequiredSDLWindowFlags*(): uint32 = SDL_WINDOW_VULKAN

proc rdPreInitialize*(window: WindowPtr): RdContext =
    result.state = RdContextState.preInitialized

    sdlCheck vulkanLoadLibrary(nil)
    loadVulkanAPI()

    let vkVersionInfo = makeVulkanVersionInfo vkApiVersion10
    vkLog LInfo, &"Vulkan API Version: {vkVersionInfo}"
    vkLog LInfo, &"Vulkan Header Version: {vkHeaderVersion}"

    let 
        availableLayers = vkEnumerateInstanceLayerProperties()
        availableLayerNames = availableLayers.mapIt charArrayToString(it.layerName)
        desiredLayerNames = @["VK_LAYER_LUNARG_standard_validation"]
    result.instanceLayers = availableLayerNames.intersect desiredLayerNames
    vkLog LTrace, "[Layers]"
    for layer in availableLayers:
        let layerName = charArrayToString layer.layerName
        vkLog LTrace, &"\t{layerName} ({makeVulkanVersionInfo layer.specVersion}, {layer.implementationVersion})"
        vkLog LTrace, &"\t{charArrayToString layer.description}"
        vkLog LTrace, ""

    let vkNotFoundLayerNames = desiredLayerNames.filterIt(not result.instanceLayers.contains(it))
    if vkNotFoundLayerNames.len() != 0: vkLog LWarning, &"Requested layers not found: {vkNotFoundLayerNames}"
    vkLog LInfo, &"Requesting layers: {result.instanceLayers}"

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
        desiredExtensionNames = @["VK_EXT_debug_report"] & sdlVkDesiredExtensions
        availableExtensions = vkEnumerateInstanceExtensionProperties(nil)
        availableExtensionNames = availableExtensions.mapIt charArrayToString(it.extensionName)
    result.instanceExtensions = availableExtensionNames.intersect desiredExtensionNames
    vkLog LTrace, "[Extensions]"
    for extension in availableExtensions:
        let extensionName = charArrayToString(extension.extensionName)
        vkLog LTrace, &"\t{extensionName} {makeVulkanVersionInfo extension.specVersion}"

    let vkNotFoundExtensions = desiredExtensionNames.filterIt(not result.instanceExtensions.contains(it))
    if vkNotFoundExtensions.len() != 0: vkLog LWarning, &"Requested extensions not found: {vkNotFoundExtensions}"
    vkLog LInfo, &"Requesting extensions: {result.instanceExtensions}"

    let
        layersCStrings = allocCStringArray(result.instanceLayers)
        extensionsCStrings = allocCStringArray(result.instanceExtensions)
    defer:
        deallocCStringArray(layersCStrings)
        deallocCStringArray(extensionsCStrings)
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
            , enabledLayerCount: uint32 result.instanceLayers.len()
            , ppEnabledLayerNames: layersCStrings
            , enabledExtensionCount: uint32 result.instanceExtensions.len()
            , ppEnabledExtensionNames: extensionsCStrings)
    vkCheck vkCreateInstance(unsafeAddr instanceCreateInfo, nil, addr result.instance)

    loadVulkanInstanceAPI(result.instance)

    type
        VulkanDebugVerbosity {.pure.} = enum
            Light, Full
    const
        debugVerbosity = VulkanDebugVerbosity.Light
        debugMask = case debugVerbosity:
            of Light: maskCombine(VkDebugReportFlagBitsEXT.error, VkDebugReportFlagBitsEXT.warning, VkDebugReportFlagBitsEXT.performanceWarning)
            of Full: maskCombine(VkDebugReportFlagBitsEXT.error, VkDebugReportFlagBitsEXT.warning, VkDebugReportFlagBitsEXT.performanceWarning, VkDebugReportFlagBitsEXT.information, VkDebugReportFlagBitsEXT.debug)

    let debugReportCallbackProc : PFN_vkDebugReportCallbackEXT = proc (flags: VkDebugReportFlagsEXT; objectType: VkDebugReportObjectTypeEXT; cbObject: uint64; location: csize; messageCode:  int32; pLayerPrefix: cstring; pMessage: cstring; pUserData: pointer): VkBool32 {.cdecl.} =
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
            , flags: uint32 debugMask
            , pfnCallback: debugReportCallbackProc)
    vkCheck vkCreateDebugReportCallbackEXT(result.instance, unsafeAddr vkCallbackCreateInfo, nil, addr result.debugCallback)

    sdlCheck vulkanCreateSurface(window, cast[VulkanInstance](result.instance), cast[ptr VulkanSurface](addr result.surface))

proc rdGetCompatiblePhysicalDevices*(context: RdContext): seq[RdPhysicalDevice] =
    check context.state == RdContextState.preInitialized
    let physicalDevices = vkwEnumeratePhysicalDevicesWithDescriptions(context.instance, context.surface)
    physicalDevices
        .filter(proc (d: VkwPhysicalDeviceDescription): bool = d.hasPresentQueue)
        .map(proc (d: VkwPhysicalDeviceDescription): RdPhysicalDevice =
            RdPhysicalDevice(
                name: d.name
                , deviceType: convert[RdPhysicalDeviceType](d.properties.deviceType)
                , vendor: convert[RdPhysicalDeviceVendor](d.vendor)
                , vulkanData: d
            )
        )

proc rdInitialize*(context: var RdContext, selectedPhysicalDevice: RdPhysicalDevice) =
    check context.state == RdContextState.preInitialized

    let deviceVulkanData = selectedPhysicalDevice.vulkanData
    context.physicalDeviceProperties = selectedPhysicalDevice
    context.physicalDevice = deviceVulkanData.handle

    vkLog LTrace, "[Device Extensions]"
    for ex in deviceVulkanData.extensions:
        vkLog LTrace, &"\t{charArrayToString(ex.extensionName)}({makeVulkanVersionInfo(ex.specVersion)})"
    
    let
        layersCStrings = allocCStringArray(context.instanceLayers)
        deviceExtensions = ["VK_KHR_swapchain"]
        extensionsCStrings = allocCStringArray(deviceExtensions)
    defer:
        deallocCStringArray(layersCStrings)
        deallocCStringArray(extensionsCStrings)

    let
        queuePriorities = [1.0'f32]
        queueCreateInfo = VkDeviceQueueCreateInfo(
            sType: VkStructureType.deviceQueueCreateInfo
            , queueFamilyIndex: deviceVulkanData.presentQueueIdx
            , queueCount: 1
            , pQueuePriorities: addr queuePriorities[0]
        )
        deviceExtensionsCStrings = allocCStringArray(deviceExtensions)
        deviceFeatures = VkPhysicalDeviceFeatures(
            shaderClipDistance: vkTrue
        )
        deviceInfo = VkDeviceCreateInfo(
            sType: VkStructureType.deviceCreateInfo
            , queueCreateInfoCount: 1
            , pQueueCreateInfos: unsafeAddr queueCreateInfo
            , enabledLayerCount: uint32 context.instanceLayers.len()
            , ppEnabledLayerNames: layersCStrings
            , enabledExtensionCount: uint32 deviceExtensions.len()
            , ppEnabledExtensionNames: deviceExtensionsCStrings
            , pEnabledFeatures: unsafeAddr deviceFeatures
        )
    vkCheck vkCreateDevice(deviceVulkanData.handle, unsafeAddr deviceInfo, nil, addr context.device)
    deallocCStringArray(deviceExtensionsCStrings)

    let surfaceFormats = vkGetPhysicalDeviceSurfaceFormatsKHR(deviceVulkanData.handle, context.surface)
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

    var surfaceCapabilities: VkSurfaceCapabilitiesKHR
    vkCheck vkGetPhysicalDeviceSurfaceCapabilitiesKHR(deviceVulkanData.handle, context.surface, addr surfaceCapabilities)
    var desiredImageCount = 2'u32
    if desiredImageCount < surfaceCapabilities.minImageCount: 
        desiredImageCount = surfaceCapabilities.minImageCount
    elif surfaceCapabilities.maxImageCount != 0 and desiredImageCount > surfaceCapabilities.maxImageCount: 
        desiredImageCount = surfaceCapabilities.maxImageCount
    vkLog LInfo, &"Desired swapchain images: {desiredImageCount}"

    var surfaceResolution = surfaceCapabilities.currentExtent
    if surfaceResolution.width == high uint32:
        surfaceResolution.width = 640
        surfaceResolution.height = 480
    vkLog LInfo, &"Surface resolution: {surfaceResolution}"

    var preTransform = surfaceCapabilities.currentTransform
    if maskCheck(surfaceCapabilities.supportedTransforms, VkSurfaceTransformFlagBitsKHR.identity):
        preTransform = VkSurfaceTransformFlagBitsKHR.identity

    let presentModes = vkGetPhysicalDeviceSurfacePresentModesKHR(deviceVulkanData.handle, context.surface)
    vkLog LTrace, &"Present modes: {presentModes}"
    var presentMode = VkPresentModeKHR.fifo
    for pm in presentModes:
        if pm == VkPresentModeKHR.mailbox:
            presentMode = VkPresentModeKHR.mailbox
            break
    vkLog LInfo, &"Selected present mode: {presentMode}"

    let swapChainCreateInfo = VkSwapchainCreateInfoKHR(
            sType: VkStructureType.swapchainCreateInfoKHR
            , surface: context.surface
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

    vkCheck vkCreateSwapchainKHR(context.device, unsafeAddr swapChainCreateInfo, nil, addr context.swapchain)

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
    var vkImageMemory = vkwAllocateDeviceMemory(vkDevice, selectedRenderDevice.memoryProperties, vkMemoryRequirements, VkMemoryPropertyFlags VkMemoryPropertyFlagBits.deviceLocal)
    vkCheck vkBindImageMemory(vkDevice, vkDepthImage, vkImageMemory, 0)

    var vkQueue: VkQueue
    vkCheck vkGetDeviceQueue(vkDevice, selectedRenderDevice.presentQueueIdx, 0, addr vkQueue)

    let vkCommandPoolCreateInfo = VkCommandPoolCreateInfo(
        sType: VkStructureType.commandPoolCreateInfo
        , flags: uint32 VkCommandPoolCreateFlagBits.resetCommandBuffer
        , queueFamilyIndex: selectedRenderDevice.presentQueueIdx
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

    let vkFenceCreateInfo = VkFenceCreateInfo(sType: VkStructureType.fenceCreateInfo)
    var vkSubmitFence: VkFence
    vkCheck vkCreateFence(vkDevice, unsafeAddr vkFenceCreateInfo, nil, addr vkSubmitFence)

    vkwTransitionImageLayout(
        device = vkDevice
        , image = vkDepthImage
        , commandBuffer = vkSetupCmdBuffer
        , queue = vkQueue
        , fence = vkSubmitFence
        , srcAccessMask = 0
        , dstAccessMask = uint32 maskCombine(VkAccessFlagBits.depthStencilAttachmentRead, VkAccessFlagBits.depthStencilAttachmentWrite)
        , oldLayout = VkImageLayout.undefined
        , newLayout = VkImageLayout.depthStencilAttachmentOptimal
        , srcStageMask = uint32 VkPipelineStageFlagBits.topOfPipe
        , dstStageMask = uint32 VkPipelineStageFlagBits.earlyFragmentTests
        , subresourceRangeAspectMask = uint32 VkImageAspectFlagBits.depth
    )
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
    var vkDepthImageView: VkImageView
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
        Vertex {.packed.} = object
            x, y, z, w: float32
            u, v: float32
    let vkVertexBufferCreateInfo = VkBufferCreateInfo(
        sType: VkStructureType.bufferCreateInfo
        , size: uint64 sizeof(Vertex) * 6
        , usage: uint32 VkBufferUsageFlagBits.vertexBuffer
        , sharingMode: VkSharingMode.exclusive
    )
    var vkVertexInputBuffer: VkBuffer
    vkCheck vkCreateBuffer(vkDevice, unsafeAddr vkVertexBufferCreateInfo, nil, addr vkVertexInputBuffer)

    var vkVertexBufferMemoryRequirements: VkMemoryRequirements
    vkGetBufferMemoryRequirements(vkDevice, vkVertexInputBuffer, addr vkVertexBufferMemoryRequirements)
    var vkVertexBufferMemory = vkwAllocateDeviceMemory(vkDevice, selectedRenderDevice.memoryProperties, vkVertexBufferMemoryRequirements, VkMemoryPropertyFlags VkMemoryPropertyFlagBits.hostVisible)

    var vkVertexMappedMem: CArray[Vertex]
    vkCheck vkMapMemory(vkDevice, vkVertexBufferMemory, 0, 0xFFFFFFFF_FFFFFFFF'u64, 0, cast[ptr pointer](addr vkVertexMappedMem))
    vkVertexMappedMem[0] = Vertex(
        x: -0.5, y: -0.5, z: 0, w: 1.0
        , u: 0.0, v: 0.0)
    vkVertexMappedMem[1] = Vertex(
        x:  0.5, y: -0.5, z: 0, w: 1.0
        , u: 1.0, v: 0.0)
    vkVertexMappedMem[2] = Vertex(
        x: -0.5, y:  0.5, z: 0, w: 1.0
        , u: 0.0, v: 1.0)
    vkVertexMappedMem[3] = vkVertexMappedMem[1]
    vkVertexMappedMem[4] = Vertex(
        x:  0.5, y:  0.5, z: 0, w: 1.0
        , u: 1.0, v: 1.0)
    vkVertexMappedMem[5] = vkVertexMappedMem[2]
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

    let
        vkTextures = vkwLoadColorTextures(vkDevice, selectedRenderDevice.memoryProperties, vkSetupCmdBuffer, vkQueue, vkSubmitFence
                                        , @["debug_atlas.bmp"])
        vkDebugAtlasTexture = vkTextures[0]

    type
        ShaderUniform = object
            buffer: VkBuffer
            memory: VkDeviceMemory
    var vkUniforms: ShaderUniform

    let vkBufferCreateInfo = VkBufferCreateInfo(
            sType: VkStructureType.bufferCreateInfo
            , size: sizeof(float32) * 16
            , usage: uint32 VkBufferUsageFlagBits.uniformBuffer
            , sharingMode: VkSharingMode.exclusive
        )
    vkCheck vkCreateBuffer(vkDevice, unsafeAddr vkBufferCreateInfo, nil, addr vkUniforms.buffer)

    var vkBufferMemoryRequirements: VkMemoryRequirements
    vkCheck vkGetBufferMemoryRequirements(vkDevice, vkUniforms.buffer, addr vkBufferMemoryRequirements)
    vkUniforms.memory = vkwAllocateDeviceMemory(vkDevice, selectedRenderDevice.memoryProperties, vkBufferMemoryRequirements, VkMemoryPropertyFlags VkMemoryPropertyFlagBits.hostVisible)
    vkCheck vkBindBufferMemory(vkDevice, vkUniforms.buffer, vkUniforms.memory, 0)

    let
        vkBindings = @[
            VkDescriptorSetLayoutBinding(
                binding: 0
                , descriptorType: VkDescriptorType.uniformBuffer
                , descriptorCount: 1
                , stageFlags: uint32 VkShaderStageFlagBits.vertex
                , pImmutableSamplers: nil
            )
            , VkDescriptorSetLayoutBinding(
                binding: 1
                , descriptorType: VkDescriptorType.combinedImageSampler
                , descriptorCount: 1
                , stageFlags: uint32 VkShaderStageFlagBits.fragment
                , pImmutableSamplers: nil
            )
        ]
        vkSetLayoutCreateInfo = VkDescriptorSetLayoutCreateInfo(
            sType: VkStructureType.descriptorSetLayoutCreateInfo
            , bindingCount: uint32 vkBindings.len()
            , pBindings: unsafeAddr vkBindings[0]
        )
    var vkSetLayout: VkDescriptorSetLayout
    vkCheck vkCreateDescriptorSetLayout(vkDevice, unsafeAddr vkSetLayoutCreateInfo, nil, addr vkSetLayout)
    let
        vkUniformBufferPoolSizes = @[
            VkDescriptorPoolSize(
                descriptorType: VkDescriptorType.uniformBuffer
                , descriptorCount: 1
            )
            , VkDescriptorPoolSize(
                descriptorType: VkDescriptorType.combinedImageSampler
                , descriptorCount: 1
            )
        ]
        vkPoolCreateInfo = VkDescriptorPoolCreateInfo(
            sType: VkStructureType.descriptorPoolCreateInfo
            , maxSets: 1
            , poolSizeCount: uint32 vkUniformBufferPoolSizes.len()
            , pPoolSizes: unsafeAddr vkUniformBufferPoolSizes[0]
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

    let
        vkDescriptorImageInfo = VkDescriptorImageInfo(
            sampler: vkDebugAtlasTexture.sampler
            , imageView: vkDebugAtlasTexture.view
            , imageLayout: VkImageLayout.shaderReadOnlyOptimal
        )
        vkImageWriteDescriptor = VkWriteDescriptorSet(
            sType: VkStructureType.writeDescriptorSet
            , dstSet: vkDescriptorSet
            , dstBinding: 1
            , dstArrayElement: 0
            , descriptorCount: 1
            , descriptorType: VkDescriptorType.combinedImageSampler
            , pImageInfo: unsafeAddr vkDescriptorImageInfo
            , pBufferInfo: nil
            , pTexelBufferView: nil
        )
    vkCheck vkUpdateDescriptorSets(vkDevice, 1, unsafeAddr vkImageWriteDescriptor, 0, nil)

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
        vkVertexInputAttributeDescriptions = @[
            VkVertexInputAttributeDescription(
                location: 0
                , binding: 0
                , format: VkFormat.r32g32b32a32SFloat
                , offset: 0
            )
            , VkVertexInputAttributeDescription(
                location: 1
                , binding: 0
                , format: VkFormat.r32g32SFloat
                , offset: 4 * sizeof(float32)
            )
        ]
        vkPipelineVertexInputStateCreateInfo = VkPipelineVertexInputStateCreateInfo(
            sType: VkStructureType.pipelineVertexInputStateCreateInfo
            , vertexBindingDescriptionCount: 1
            , pVertexBindingDescriptions: unsafeAddr vkVertexInputBindingDescription
            , vertexAttributeDescriptionCount: uint32 vkVertexInputAttributeDescriptions.len()
            , pVertexAttributeDescriptions: unsafeAddr vkVertexInputAttributeDescriptions[0]
        )
        vkPipelineInputAssemblyStateCreateInfo = VkPipelineInputAssemblyStateCreateInfo(
            sType: VkStructureType.pipelineInputAssemblyStateCreateInfo
            , topology: VkPrimitiveTopology.triangleList
            , primitiveRestartEnable: vkFalse
        )
        viewport = VkViewport(
            x: 0, y: 0
            , width: float32 surfaceResolution.width, height: float32 surfaceResolution.height
            , minDepth: 0, maxDepth: 1
        )
        vkScisors = VkRect2D(
            offset: VkOffset2D(x: 0, y: 0)
            , extent: VkExtent2D(width: surfaceResolution.width, height: surfaceResolution.height)
        )
        viewportStateCreateInfo = VkPipelineViewportStateCreateInfo(
            sType: VkStructureType.pipelineViewportStateCreateInfo
            , viewportCount: 1
            , pViewports: unsafeAddr viewport
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
            , pViewportState: unsafeAddr viewportStateCreateInfo
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
