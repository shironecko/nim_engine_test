import algorithm
import math
import sequtils
import strformat
import sugar
import glm
import sdl2
import vulkan_wrapper
import ../log
import ../utility

const
    MAX_SPRITES_PER_FRAME = 10000
    VERTEX_BUFFER_SIZE = MAX_SPRITES_PER_FRAME * 6
    INVALID_RESOURCE_ID = -1
    MAX_TEXTURES_LOADED = 512
    DEBUG_FONT_TEXTURE_ID = 0

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
    
    RdColorF32* {.packed.} = object
        r*, g*, b*, a*: float32
    
    RdRawImageFormat* {.pure.} = enum
        RGBAFloat32 # only one format for now, maybe ever?
    RdRawImagePixelRGBAFloat32* = RdColorF32
    RdRawImageData* = object
        width*, height*: uint32
        case format*: RdRawImageFormat
        of RdRawImageFormat.RGBAFloat32:
            pixelsRGBAFloat32*: seq[RdRawImagePixelRGBAFloat32]
    
    RdTextureData = object
        image: VkImage
        memory: VkDeviceMemory
        view: VkImageView
        sampler: VkSampler
        descriptorSet: VkDescriptorSet
    
    RdTexture* = object # a texture is actually just an index into descriptor sets array
        id: int
    RdBitmapFont* = object
        id: int
    RdSpriteRenderRequest* = object
        x*, y*: float32
        w*, h*: float32
        minUV*, maxUV*: Vec2f
        texture*: RdTexture
        tint*: RdColorF32
        order*: uint8
    RdBitmapFontRenderRequest* = object
        x*, y*: float32
        text*: string
        font*: RdBitmapFont
    RdRenderList* = object
        sprites*: seq[RdSpriteRenderRequest]
        text*: seq[RdBitmapFontRenderRequest]
    
    RdContextState {.pure.} = enum
        uninitialized, preInitialized, initialized
    RdDescriptorSetAllocateData = object
        pool: VkDescriptorPool
        layout: VkDescriptorSetLayout
    
    RdBitmapFontHeader {.packed.} = object
        signatureBytes: array[2, uint8]
        width, height: uint32
        cellWidth, cellHeight: uint32
        bitsPerPixel: uint8
        baseCharacter: uint8
        characterWidth: array[256, uint8]
    RdBitmapFontTexturePixel* {.packed.} = object
        r, g, b, a: float32
    RdBitmapFontData = object
        cellWidth, cellHeight: uint32
        textureWidth, textureHeight: uint32
        baseCharacter: uint8
        pixels: seq[RdBitmapFontTexturePixel]
        texture: RdTexture

    RdContext* = object
        state: RdContextState
        instance: VkInstance
        instanceLayers: seq[string]
        instanceExtensions: seq[string]
        debugCallback: VkDebugReportCallbackEXT
        surface: VkSurfaceKHR
        physicalDevice: VkPhysicalDevice
        physicalDeviceMemoryProperties: VkPhysicalDeviceMemoryProperties
        physicalDeviceProperties: RdPhysicalDevice
        device: VkDevice
        swapchain: VkSwapchainKHR
        swapchainTextures: seq[RdTextureData]
        framebuffers: seq[VkFramebuffer]
        depthImage: RdTextureData
        queue: VkQueue
        commandPool: VkCommandPool
        commandBuffer: VkCommandBuffer
        submitFence: VkFence
        renderPass: VkRenderPass
        vertexBuffer: VkwBuffer
        uniforms: VkwBuffer
        descriptorPool: VkDescriptorPool
        descriptorSet: VkDescriptorSet
        pipelineLayout: VkPipelineLayout
        pipeline: VkPipeline
        textureDescriptorSetAllocationData: RdDescriptorSetAllocateData
        textureDescriptorSets: seq[VkDescriptorSet]
        bitmapFonts: seq[RdBitmapFontData]
        textures: seq[RdTextureData]
        colorTextureSampler: VkSampler

const
    WHITE*          = RdColorF32(r: 1.0, g: 1.0, b: 1.0, a: 1.0)
    BLACK*          = RdColorF32(r: 0.0, g: 0.0, b: 0.0, a: 1.0)
    RED*            = RdColorF32(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
    GREEN*          = RdColorF32(r: 0.0, g: 1.0, b: 0.0, a: 1.0)
    BLUE*           = RdColorF32(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
    OPAQUE*         = RdColorF32(r: 1.0, g: 1.0, b: 1.0, a: 1.0)
    TRANSPARENT*    = RdColorF32(r: 1.0, g: 1.0, b: 1.0, a: 0.0)

proc rdBlend*(a, b: RdColorF32): RdColorF32 =
    RdColorF32(r: a.r * b.r, g: a.g * b.g, b: a.b * b.b, a: a.a * b.a)

proc `*`*(a, b: RdColorF32): RdColorF32 = rdBlend(a, b)

proc rdCreateTexture*(context: var RdContext, imageData: RdRawImageData): RdTexture =
    check context.state == RdContextState.initialized

    var
        texture: RdTextureData
        pixels = case imageData.format:
            of RdRawImageFormat.RGBAFloat32:
                imageData.pixelsRGBAFloat32
    
    (texture.image, texture.memory) = vkwCreateImage(context.device, context.physicalDeviceMemoryProperties, imageData.width, imageData.height, VkFormat.r32g32b32a32SFloat)
    vkwWithMemory context.device, texture.memory:
        copyMem(memoryPtr, addr pixels[0], sizeof(pixels[0]) * pixels.len())

    vkwTransitionImageLayout(context.device, texture.image, context.commandBuffer, context.queue, context.submitFence, VkwImageLayoutTransitionType.ColorTextureInitialization)
    texture.view = vkwCreateImageView(context.device, texture.image, VkFormat.r32g32b32a32SFloat)
    texture.descriptorSet = vkwCreateImageDescriptorSet(context.device, context.textureDescriptorSetAllocationData.pool, context.textureDescriptorSetAllocationData.layout, context.colorTextureSampler, texture.view)

    context.textures.add(texture)
    RdTexture(id: context.textures.len() - 1)


proc rdLoadBitmapFontData(path: string): RdBitmapFontData =
    var
        fontContents = readBinaryFile(path)
        fontHeader = cast[ptr RdBitmapFontHeader](addr fontContents[0])
        fontPixels = cast[ptr UncheckedArray[uint8]](addr fontContents[sizeof(RdBitmapFontHeader)])
        pixelCount = fontHeader.width * fontHeader.height
    check fontHeader.signatureBytes[0] == 0xBF'u8 and fontHeader.signatureBytes[1] == 0xF2'u8, "Debug font file header signature mismatch!"
    check fontHeader.bitsPerPixel == 8, &"Debug font file bitness per pixel mismant! Expected: 8, Got: {fontHeader.bitsPerPixel}"
    result.textureWidth = fontHeader.width
    result.textureHeight = fontHeader.height
    result.cellWidth = fontHeader.cellWidth
    result.cellHeight = fontHeader.cellHeight
    result.baseCharacter = fontHeader.baseCharacter
    vkLog LTrace, $result
    result.pixels.setLen(pixelCount)
    for i in 0..<pixelCount:
        let pixel =
            if fontPixels[i] >= 1'u8: RdBitmapFontTexturePixel(r:0.0'f32, g:1.0'f32, b:1.0'f32, a:1.0'f32)
            else: RdBitmapFontTexturePixel(r:0.0'f32, g:1.0'f32, b:0.0'f32, a:1.0'f32)
        result.pixels.add pixel

type
    Vertex {.packed.} = object
        x, y, z, w: float32
        u, v: float32
        tint: RdColorF32

proc newVertex(position: Vec4f, u, v: float32, tint: RdColorF32): Vertex = Vertex(x: position.x, y: position.y, z: position.z, w: position.w, u: u, v: v, tint: tint)

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
        deviceExtensionsCStrings = allocCStringArray(result.instanceExtensions)
    defer:
        deallocCStringArray(layersCStrings)
        deallocCStringArray(deviceExtensionsCStrings)
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
            , ppEnabledExtensionNames: deviceExtensionsCStrings)
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
    context.state = RdContextState.initialized

    let deviceVulkanData = selectedPhysicalDevice.vulkanData
    context.physicalDeviceProperties = selectedPhysicalDevice
    context.physicalDeviceMemoryProperties = deviceVulkanData.memoryProperties
    context.physicalDevice = deviceVulkanData.handle

    vkLog LTrace, "[Device Extensions]"
    for ex in deviceVulkanData.extensions:
        vkLog LTrace, &"\t{charArrayToString(ex.extensionName)}({makeVulkanVersionInfo(ex.specVersion)})"
    
    let
        layersCStrings = allocCStringArray(context.instanceLayers)
        deviceExtensions = ["VK_KHR_swapchain"]
        deviceExtensionsCStrings = allocCStringArray(deviceExtensions)
    defer:
        deallocCStringArray(layersCStrings)
        deallocCStringArray(deviceExtensionsCStrings)

    let
        queuePriorities = [1.0'f32]
        queueCreateInfo = VkDeviceQueueCreateInfo(
            sType: VkStructureType.deviceQueueCreateInfo
            , queueFamilyIndex: deviceVulkanData.presentQueueIdx
            , queueCount: 1
            , pQueuePriorities: unsafeAddr queuePriorities[0]
        )
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

    let depthImageCreateInfo = VkImageCreateInfo(
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
    vkCheck vkCreateImage(context.device, unsafeAddr depthImageCreateInfo, nil, addr context.depthImage.image)

    var depthImageMemoryRequirements: VkMemoryRequirements
    vkCheck vkGetImageMemoryRequirements(context.device, context.depthImage.image, addr depthImageMemoryRequirements)
    context.depthImage.memory = vkwAllocateDeviceMemory(context.device, context.physicalDeviceMemoryProperties, depthImageMemoryRequirements, VkMemoryPropertyFlags VkMemoryPropertyFlagBits.deviceLocal)
    vkCheck vkBindImageMemory(context.device, context.depthImage.image, context.depthImage.memory, 0)
    
    let presentQueueIndex = context.physicalDeviceProperties.vulkanData.presentQueueIdx
    vkCheck vkGetDeviceQueue(context.device, presentQueueIndex, 0, addr context.queue)

    let vkCommandPoolCreateInfo = VkCommandPoolCreateInfo(
        sType: VkStructureType.commandPoolCreateInfo
        , flags: uint32 VkCommandPoolCreateFlagBits.resetCommandBuffer
        , queueFamilyIndex: presentQueueIndex
    )
    vkCheck vkCreateCommandPool(context.device, unsafeAddr vkCommandPoolCreateInfo, nil, addr context.commandPool)

    let commandBufferAllocateInfo = VkCommandBufferAllocateInfo(
        sType: VkStructureType.commandBufferAllocateInfo
        , commandPool: context.commandPool
        , level: VkCommandBufferLevel.primary
        , commandBufferCount: 1
    )
    vkCheck vkAllocateCommandBuffers(context.device, unsafeAddr commandBufferAllocateInfo, addr context.commandBuffer)

    context.swapchainTextures = vkGetSwapchainImagesKHR(context.device, context.swapchain).mapIt RdTextureData(image: it, memory: vkNullHandle)
    var swapchainTextureTransitionFlags = repeat(false, context.swapchainTextures.len())
    while swapchainTextureTransitionFlags.anyIt(not it):
        var presentBeginData = vkwPresentBegin(context.device, context.swapchain, context.commandBuffer)

        if not swapchainTextureTransitionFlags[int presentBeginData.imageIndex]:
            swapchainTextureTransitionFlags[int presentBeginData.imageIndex] = true

            let layoutTransitionBarrier = VkImageMemoryBarrier(
                sType: VkStructureType.imageMemoryBarrier
                , srcAccessMask: 0
                , dstAccessMask: uint32 VkAccessFlagBits.memoryRead
                , oldLayout: VkImageLayout.undefined
                , newLayout: VkImageLayout.presentSrcKHR
                , srcQueueFamilyIndex: high uint32
                , dstQueueFamilyIndex: high uint32
                , image: context.swapchainTextures[int presentBeginData.imageIndex].image
                , subresourceRange: VkImageSubresourceRange(
                    aspectMask: uint32 VkImageAspectFlagBits.color
                    , baseMipLevel: 0
                    , levelCount: 1
                    , baseArrayLayer: 0
                    , layerCount: 1
                )
            )
            vkCheck vkCmdPipelineBarrier(
                context.commandBuffer
                , uint32 VkPipelineStageFlagBits.topOfPipe
                , uint32 VkPipelineStageFlagBits.topOfPipe
                , 0
                , 0, nil
                , 0, nil
                , 1, unsafeAddr layoutTransitionBarrier
            )
        
        vkwPresentEnd(context.device, context.swapchain, context.commandBuffer, context.queue, presentBeginData)

    var
        presentImageViewCreateInfo = VkImageViewCreateInfo(
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
    context.swapchainTextures.applyIt:
        var texture = it
        presentImageViewCreateInfo.image = texture.image
        vkCheck vkCreateImageView(context.device, unsafeAddr presentImageViewCreateInfo, nil, addr texture.view)
        texture

    let submitFenceCreateInfo = VkFenceCreateInfo(sType: VkStructureType.fenceCreateInfo)
    vkCheck vkCreateFence(context.device, unsafeAddr submitFenceCreateInfo, nil, addr context.submitFence)

    vkwTransitionImageLayout(
        device = context.device
        , image = context.depthImage.image
        , commandBuffer = context.commandBuffer
        , queue = context.queue
        , fence = context.submitFence
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
            , image: context.depthImage.image
            , viewType: VkImageViewType.twoDee
            , format: depthImageCreateInfo.format
            , components: VkComponentMapping(r: VkComponentSwizzle.identity, g: VkComponentSwizzle.identity, b: VkComponentSwizzle.identity, a: VkComponentSwizzle.identity)
            , subresourceRange: VkImageSubresourceRange(
                aspectMask: uint32 VkImageAspectFlagBits.depth
                , baseMipLevel: 0
                , levelCount: 1
                , baseArrayLayer: 0
                , layerCount: 1
            )
        )
    vkCheck vkCreateImageView(context.device, unsafeAddr imageViewCreateInfo, nil, addr context.depthImage.view)

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
    vkCheck vkCreateRenderPass(context.device, unsafeAddr renderPassCreateInfo, nil, addr context.renderPass)

    var frameBufferAttachments: seq[VkImageView]
    frameBufferAttachments.setLen(2)
    frameBufferAttachments[1] = context.depthImage.view

    let framebufferCreateInfo = VkFramebufferCreateInfo(
        sType: VkStructureType.framebufferCreateInfo
        , renderPass: context.renderPass
        , attachmentCount: 2
        , pAttachments: addr frameBufferAttachments[0]
        , width: surfaceResolution.width
        , height: surfaceResolution.height
        , layers: 1
    )

    context.framebuffers.setLen(context.swapchainTextures.len())
    for i, swt in context.swapchainTextures:
        frameBufferAttachments[0] = swt.view
        vkCheck vkCreateFramebuffer(context.device, unsafeAddr framebufferCreateInfo, nil, addr context.framebuffers[i])
    
    context.vertexBuffer = vkwAllocateBuffer(
        context.device
        , context.physicalDeviceMemoryProperties
        , uint64 sizeof(Vertex) * VERTEX_BUFFER_SIZE
        , uint32 VkBufferUsageFlagBits.vertexBuffer
    )
    
    let
        vertexShaderBytecode = readBinaryFile("./vert.spv")
        fragmentShaderBytecode = readBinaryFile("./frag.spv")
        vertexShaderCreateInfo = VkShaderModuleCreateInfo(
            sType: VkStructureType.shaderModuleCreateInfo
            , codeSize: vertexShaderBytecode.len()
            , pCode: cast[ptr uint32](unsafeAddr vertexShaderBytecode[0])
        )
        fragmentShaderCreateInfo = VkShaderModuleCreateInfo(
            sType: VkStructureType.shaderModuleCreateInfo
            , codeSize: fragmentShaderBytecode.len()
            , pCode: cast[ptr uint32](unsafeAddr fragmentShaderBytecode[0])
        )
    var 
        vertexShaderModule, fragmentShaderModule: VkShaderModule
    vkCheck vkCreateShaderModule(context.device, unsafeAddr vertexShaderCreateInfo, nil, addr vertexShaderModule)
    vkCheck vkCreateShaderModule(context.device, unsafeAddr fragmentShaderCreateInfo, nil, addr fragmentShaderModule)
    defer:
        vkDestroyShaderModule(context.device, vertexShaderModule, nil)
        vkDestroyShaderModule(context.device, fragmentShaderModule, nil)
    
    context.colorTextureSampler = vkwCreateImageSampler(context.device)

    block TextureDescriptorSetAllocationDataSetup:
        let
            binding = VkDescriptorSetLayoutBinding(
                binding: 0
                , descriptorType: VkDescriptorType.combinedImageSampler
                , descriptorCount: 1
                , stageFlags: uint32 VkShaderStageFlagBits.fragment
                , pImmutableSamplers: nil
            )
            descriptorSetLayoutCreateInfo = VkDescriptorSetLayoutCreateInfo(
                sType: VkStructureType.descriptorSetLayoutCreateInfo
                , bindingCount: 1
                , pBindings: unsafeAddr binding
            )
        vkCheck vkCreateDescriptorSetLayout(context.device, unsafeAddr descriptorSetLayoutCreateInfo, nil, addr context.textureDescriptorSetAllocationData.layout)
        
        let
            textureDescriptorPoolSizes = @[
                VkDescriptorPoolSize(
                    descriptorType: VkDescriptorType.combinedImageSampler
                    , descriptorCount: MAX_TEXTURES_LOADED
                )
            ]
            descriptorPoolCreateInfo = VkDescriptorPoolCreateInfo(
                sType: VkStructureType.descriptorPoolCreateInfo
                , maxSets: MAX_TEXTURES_LOADED
                , poolSizeCount: uint32 textureDescriptorPoolSizes.len()
                , pPoolSizes: unsafeAddr textureDescriptorPoolSizes[0]
            )
        vkCheck vkCreateDescriptorPool(context.device, unsafeAddr descriptorPoolCreateInfo, nil, addr context.textureDescriptorSetAllocationData.pool)

    context.uniforms = vkwAllocateBuffer(
        context.device
        , context.physicalDeviceMemoryProperties
        , sizeof(float32) * 16
        , uint32 VkBufferUsageFlagBits.uniformBuffer)

    let
        bindings = @[
            VkDescriptorSetLayoutBinding(
                binding: 0
                , descriptorType: VkDescriptorType.uniformBuffer
                , descriptorCount: 1
                , stageFlags: uint32 VkShaderStageFlagBits.vertex
                , pImmutableSamplers: nil
            )
        ]
        descriptorSetLayoutCreateInfo = VkDescriptorSetLayoutCreateInfo(
            sType: VkStructureType.descriptorSetLayoutCreateInfo
            , bindingCount: uint32 bindings.len()
            , pBindings: unsafeAddr bindings[0]
        )
    var descriptorSetLayout: VkDescriptorSetLayout
    vkCheck vkCreateDescriptorSetLayout(context.device, unsafeAddr descriptorSetLayoutCreateInfo, nil, addr descriptorSetLayout)
    defer: vkDestroyDescriptorSetLayout(context.device, descriptorSetLayout, nil)
    
    let
        uniformBufferPoolSizes = @[
            VkDescriptorPoolSize(
                descriptorType: VkDescriptorType.uniformBuffer
                , descriptorCount: 1
            )
        ]
        descriptorPoolCreateInfo = VkDescriptorPoolCreateInfo(
            sType: VkStructureType.descriptorPoolCreateInfo
            , maxSets: 1
            , poolSizeCount: uint32 uniformBufferPoolSizes.len()
            , pPoolSizes: unsafeAddr uniformBufferPoolSizes[0]
        )
    vkCheck vkCreateDescriptorPool(context.device, unsafeAddr descriptorPoolCreateInfo, nil, addr context.descriptorPool)

    let descriptorAllocateInfo = VkDescriptorSetAllocateInfo(
        sType: VkStructureType.descriptorSetAllocateInfo
        , descriptorPool: context.descriptorPool
        , descriptorSetCount: 1
        , pSetLayouts: addr descriptorSetLayout
    )
    vkCheck vkAllocateDescriptorSets(context.device, unsafeAddr descriptorAllocateInfo, addr context.descriptorSet)

    let
        descriptorBufferInfo = VkDescriptorBufferInfo(
            buffer: context.uniforms.buffer
            , offset: 0
            , range: high uint64
        )
        writeDescriptorSet = VkWriteDescriptorSet(
            sType: VkStructureType.writeDescriptorSet
            , dstSet: context.descriptorSet
            , dstBinding: 0
            , dstArrayElement: 0
            , descriptorCount: 1
            , descriptorType: VkDescriptorType.uniformBuffer
            , pImageInfo: nil
            , pBufferInfo: unsafeAddr descriptorBufferInfo
            , pTexelBufferView: nil
        )
    vkCheck vkUpdateDescriptorSets(context.device, 1, unsafeAddr writeDescriptorSet, 0, nil)
    

    let
        descriptorSetLayouts = @[descriptorSetLayout, context.textureDescriptorSetAllocationData.layout]
        pipelineLayoutCreateInfo = VkPipelineLayoutCreateInfo(
            sType: VkStructureType.pipelineLayoutCreateInfo
            , setLayoutCount: 2
            , pSetLayouts: unsafeAddr descriptorSetLayouts[0]
            , pushConstantRangeCount: 0
            , pPushConstantRanges: nil
        )
    vkCheck vkCreatePipelineLayout(context.device, unsafeAddr pipelineLayoutCreateInfo, nil, addr context.pipelineLayout)

    let pipelineShaderStageCreateInfos = @[
        VkPipelineShaderStageCreateInfo(
            sType: VkStructureType.pipelineShaderStageCreateInfo
            , stage: VkShaderStageFlagBits.vertex
            , module: vertexShaderModule
            , pName: "main"
            , pSpecializationInfo: nil
        )
        , VkPipelineShaderStageCreateInfo(
            sType: VkStructureType.pipelineShaderStageCreateInfo
            , stage: VkShaderStageFlagBits.fragment
            , module: fragmentShaderModule
            , pName: "main"
            , pSpecializationInfo: nil
        )
    ]

    let
        vertexInputBindingDescription = VkVertexInputBindingDescription(
            binding: 0
            , stride: uint32 sizeof Vertex
            , inputRate: VkVertexInputRate.vertex
        )
        vertexInputAttributeDescriptions = @[
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
            , VkVertexInputAttributeDescription(
                location: 2
                , binding: 0
                , format: VkFormat.r32g32b32a32SFloat
                , offset: 4 * sizeof(float32) + 2 * sizeof(float32)
            )
        ]
        pipelineVertexInputStateCreateInfo = VkPipelineVertexInputStateCreateInfo(
            sType: VkStructureType.pipelineVertexInputStateCreateInfo
            , vertexBindingDescriptionCount: 1
            , pVertexBindingDescriptions: unsafeAddr vertexInputBindingDescription
            , vertexAttributeDescriptionCount: uint32 vertexInputAttributeDescriptions.len()
            , pVertexAttributeDescriptions: unsafeAddr vertexInputAttributeDescriptions[0]
        )
        pipelineInputAssemblyStateCreateInfo = VkPipelineInputAssemblyStateCreateInfo(
            sType: VkStructureType.pipelineInputAssemblyStateCreateInfo
            , topology: VkPrimitiveTopology.triangleList
            , primitiveRestartEnable: vkFalse
        )
        viewport = VkViewport(
            x: 0, y: 0
            , width: float32 surfaceResolution.width, height: float32 surfaceResolution.height
            , minDepth: 0, maxDepth: 1
        )
        scissor = VkRect2D(
            offset: VkOffset2D(x: 0, y: 0)
            , extent: VkExtent2D(width: surfaceResolution.width, height: surfaceResolution.height)
        )
        viewportStateCreateInfo = VkPipelineViewportStateCreateInfo(
            sType: VkStructureType.pipelineViewportStateCreateInfo
            , viewportCount: 1
            , pViewports: unsafeAddr viewport
            , scissorCount: 1
            , pScissors: unsafeAddr scissor
        )
        pipelineRasterizationStateCreateInfo = VkPipelineRasterizationStateCreateInfo(
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
        pipelineMultisampleStateCreateInfo = VkPipelineMultisampleStateCreateInfo(
            sType: VkStructureType.pipelineMultisampleStateCreateInfo
            , rasterizationSamples: VkSampleCountFlagBits.one
            , sampleShadingEnable: vkFalse
            , minSampleShading: 0
            , pSampleMask: nil
            , alphaToCoverageEnable: vkFalse
            , alphaToOneEnable: vkFalse
        )
        noopStencilOpState = VkStencilOpState(
            failOp: VkStencilOp.keep
            , passOp: VkStencilOp.keep
            , depthFailOp: VkStencilOp.keep
            , compareOp: VkCompareOp.always
            , compareMask: 0
            , writeMask: 0
            , reference: 0
        )
        depthState = VkPipelineDepthStencilStateCreateInfo(
            sType: pipelineDepthStencilStateCreateInfo
            , depthTestEnable: vkTrue
            , depthWriteEnable: vkTrue
            , depthCompareOp: VkCompareOp.lessOrEqual
            , depthBoundsTestEnable: vkFalse
            , stencilTestEnable: vkFalse
            , front: noopStencilOpState
            , back: noopStencilOpState
            , minDepthBounds: 0
            , maxDepthBounds: 0
        )
        colorBlendAttachmentState = VkPipelineColorBlendAttachmentState(
            blendEnable: vkTrue
            , srcColorBlendFactor: VkBlendFactor.srcAlpha
            , dstColorBlendFactor: VkBlendFactor.oneMinusSrcAlpha
            , colorBlendOp: VkBlendOp.opAdd
            , srcAlphaBlendFactor: VkBlendFactor.one
            , dstAlphaBlendFactor: VkBlendFactor.zero
            , alphaBlendOp: VkBlendOp.opAdd
            , colorWriteMask: uint32 maskCombine(VkColorComponentFlagBits.r, VkColorComponentFlagBits.g, VkColorComponentFlagBits.b, VkColorComponentFlagBits.a)
        )
        colorBlendState = VkPipelineColorBlendStateCreateInfo(
            sType: VkStructureType.pipelineColorBlendStateCreateInfo
            , logicOpEnable: vkFalse
            , logicOp: VkLogicOp.opClear
            , attachmentCount: 1
            , pAttachments: unsafeAddr colorBlendAttachmentState
            , blendConstants: [0'f32, 0, 0, 0]
        )
        pipelineDynamicState = @[VkDynamicState.viewport, VkDynamicState.scissor]
        pipelineDynamicStateCreateInfo = VkPipelineDynamicStateCreateInfo(
            sType: VkStructureType.pipelineDynamicStateCreateInfo
            , dynamicStateCount: 2
            , pDynamicStates: unsafeAddr pipelineDynamicState[0]
        )
        pipelineCreateInfo = VkGraphicsPipelineCreateInfo(
            sType: VkStructureType.graphicsPipelineCreateInfo
            , stageCount: 2
            , pStages: unsafeAddr pipelineShaderStageCreateInfos[0]
            , pVertexInputState: unsafeAddr pipelineVertexInputStateCreateInfo
            , pInputAssemblyState: unsafeAddr pipelineInputAssemblyStateCreateInfo
            , pTessellationState: nil
            , pViewportState: unsafeAddr viewportStateCreateInfo
            , pRasterizationState: unsafeAddr pipelineRasterizationStateCreateInfo
            , pMultisampleState: unsafeAddr pipelineMultisampleStateCreateInfo
            , pDepthStencilState: unsafeAddr depthState
            , pColorBlendState: unsafeAddr colorBlendState
            , pDynamicState: unsafeAddr pipelineDynamicStateCreateInfo
            , layout: context.pipelineLayout
            , renderPass: context.renderPass
            , subpass: 0
            , basePipelineHandle: 0
            , basePipelineIndex: 0
        )
    vkCheck vkCreateGraphicsPipelines(context.device, vkNullHandle, 1, unsafeAddr pipelineCreateInfo, nil, addr context.pipeline)

proc rdRenderAndPresent*(context: var RdContext, cameraPosition: Vec3f, renderList: RdRenderList) =
    check context.state == RdContextState.initialized

    # TODO: move projection stuff outside?
    let
        view = lookAt(
            eye = vec3(0.0'f32, 0.0'f32, -1.0'f32)
            , center = vec3(0.0'f32)
            , up = vec3(0.0'f32, -1.0'f32, 0.0'f32)
        ).translate(-vec3f(round(cameraPosition.x), round(cameraPosition.y), round(cameraPosition.z)))
        projection = ortho(
            float32(640) * -0.5'f32
            , float32(640) * 0.5'f32
            , float32(480) * -0.5'f32
            , float32(480) * 0.5'f32
            , 0.0'f32, 1.0'f32)
        clip = mat4(
            vec4(1.0'f32, 0.0'f32, 0.0'f32, 0.0'f32),
            vec4(0.0'f32,-1.0'f32, 0.0'f32, 0.0'f32),
            vec4(0.0'f32, 0.0'f32, 0.5'f32, 0.0'f32),
            vec4(0.0'f32, 0.0'f32, 0.5'f32, 1.0'f32),
        )
    var shaderMVP = (clip * projection * view).transpose()
    vkwWithMemory context.device, context.uniforms.memory:
        copyMem(memoryPtr, shaderMVP.caddr, sizeof(float32) * 16)
    
    type
        RenderBatch = object
            offset, primitiveCount: uint32
            texture: RdTexture
    var spriteDrawRequests = renderList.sprites
    for text in renderList.text:
        var 
            fontData = context.bitmapFonts[text.font.id]
            cellsPerRow = uint32(float32(fontData.textureWidth) / float32(fontData.cellWidth))
            glyphPos = vec2f(text.x, text.y)
        for glyph in text.text:
            if glyph == '\n':
                glyphPos.x = text.x
                glyphPos.y += float32 fontData.cellHeight
                continue
            let
                glyphIndex = uint32(glyph) - fontData.baseCharacter
                glyphRow = uint32(float32(glyphIndex) / float32(cellsPerRow))
                glyphCol = glyphIndex - glyphRow * cellsPerRow
                cellU = float32(fontData.cellWidth) / float32(fontData.textureWidth)
                cellV = float32(fontData.cellHeight) / float32(fontData.textureHeight)
                cellUV = vec2f(cellU, cellV)
                glyphMinUV = vec2f(cellU * float32 glyphCol, cellV * float32 glyphRow)
            
            spriteDrawRequests.add(RdSpriteRenderRequest(
                x: glyphPos.x
                , y: glyphPos.y
                , w: float32 fontData.cellWidth
                , h: float32 fontData.cellHeight
                , minUV: glyphMinUV
                , maxUV: glyphMinUV + cellUV
                , texture: fontData.texture
            ))
            glyphPos.x += float32 fontData.cellWidth

    spriteDrawRequests.sort(proc (a, b: RdSpriteRenderRequest): int =
        if a.order == b.order: a.texture.id - b.texture.id
        else: int(a.order) - int(b.order)
    )
    var renderBatches: seq[RenderBatch]
    vkwWithMemory context.device, context.vertexBuffer.memory:
        var vertices = cast[ptr UncheckedArray[Vertex]](memoryPtr)
        var currentBatch = RenderBatch(offset: 0, primitiveCount: 0, texture: spriteDrawRequests[0].texture)
        for i, sprite in spriteDrawRequests:
            let offset = i * 6
            if currentBatch.texture != sprite.texture:
                renderBatches.add(currentBatch)
                currentBatch = RenderBatch(offset: uint32 offset, primitiveCount: 0, texture: sprite.texture)
            
            var model = mat4f(1.0).translate(sprite.x, sprite.y, 0.0).scale(sprite.w, sprite.h, 1.0).transpose()
            let plane = @[
                newVertex(vec4f(x = -0.5, y = -0.5, z = 0, w = 1.0) * model, sprite.minUV.x, sprite.minUV.y, sprite.tint),
                newVertex(vec4f(x =  0.5, y = -0.5, z = 0, w = 1.0) * model, sprite.maxUV.x, sprite.minUV.y, sprite.tint),
                newVertex(vec4f(x = -0.5, y =  0.5, z = 0, w = 1.0) * model, sprite.minUV.x, sprite.maxUV.y, sprite.tint),
                newVertex(vec4f(x =  0.5, y =  0.5, z = 0, w = 1.0) * model, sprite.maxUV.x, sprite.maxUV.y, sprite.tint),
            ]
            vertices[offset + 0] = plane[0]
            vertices[offset + 1] = plane[1]
            vertices[offset + 2] = plane[2]
            vertices[offset + 3] = plane[1]
            vertices[offset + 4] = plane[3]
            vertices[offset + 5] = plane[2]

            currentBatch.primitiveCount += 6
        
        renderBatches.add(currentBatch)

    var presentBeginData = vkwPresentBegin(context.device, context.swapchain, context.commandBuffer)

    let vertexMemoryBarrier = VkMemoryBarrier(
        sType: VkStructureType.memoryBarrier
        , srcAccessMask: uint32 VkAccessFlagBits.hostWrite
        , dstAccessMask: uint32 VkAccessFlagBits.vertexAttributeRead
    )
    vkCheck vkCmdPipelineBarrier(
        context.commandBuffer
        , uint32 VkPipelineStageFlagBits.host
        , uint32 VkPipelineStageFlagBits.vertexInput
        , 0
        , 1, unsafeAddr vertexMemoryBarrier
        , 0, nil
        , 0, nil
    )
    
    let uniformMemoryBarrier = VkMemoryBarrier(
        sType: VkStructureType.memoryBarrier
        , srcAccessMask: uint32 VkAccessFlagBits.hostWrite
        , dstAccessMask: uint32 VkAccessFlagBits.uniformRead
    )
    vkCheck vkCmdPipelineBarrier(
        context.commandBuffer
        , uint32 VkPipelineStageFlagBits.host
        , uint32 VkPipelineStageFlagBits.vertexShader
        , 0
        , 1, unsafeAddr uniformMemoryBarrier
        , 0, nil
        , 0, nil
    )

    let vkLayoutTransitionBarrier = VkImageMemoryBarrier(
        sType: VkStructureType.imageMemoryBarrier
        , srcAccessMask: uint32 VkAccessFlagBits.memoryRead
        , dstAccessMask: uint32 maskCombine(VkAccessFlagBits.colorAttachmentRead, VkAccessFlagBits.colorAttachmentWrite)
        , oldLayout: VkImageLayout.presentSrcKHR
        , newLayout: VkImageLayout.colorAttachmentOptimal
        , srcQueueFamilyIndex: high uint32
        , dstQueueFamilyIndex: high uint32
        , image: context.swapchainTextures[int presentBeginData.imageIndex].image
        , subresourceRange: VkImageSubresourceRange(
            aspectMask: uint32 VkImageAspectFlagBits.color
            , baseMipLevel: 0
            , levelCount: 1
            , baseArrayLayer: 0
            , layerCount: 1
        )
    )
    vkCheck vkCmdPipelineBarrier(
        context.commandBuffer
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
            # TODO: get rid of constants
            , extent: VkExtent2D(width: 640, height: 480)
        )
        renderPassBeginInfo = VkRenderPassBeginInfo(
            sType: VkStructureType.renderPassBeginInfo
            , renderPass: context.renderPass
            , framebuffer: context.framebuffers[int presentBeginData.imageIndex]
            , renderArea: renderArea
            , clearValueCount: 2
            , pClearValues: unsafeAddr clearValues[0]
        )
    vkCheck vkCmdBeginRenderPass(context.commandBuffer, unsafeAddr renderPassBeginInfo, VkSubpassContents.inline)
    vkCheck vkCmdBindPipeline(context.commandBuffer, VkPipelineBindPoint.graphics, context.pipeline)
    
    let
        # TODO: get rid of constants
        viewport = VkViewport(x: 0, y: 0, width: float32 640, height: float32 480, minDepth: 0, maxDepth: 1)
        scissor = renderArea
    vkCheck vkCmdSetViewport(context.commandBuffer, 0, 1, unsafeAddr viewport)
    vkCheck vkCmdSetScissor(context.commandBuffer, 0, 1, unsafeAddr scissor)

    var offsets: VkDeviceSize
    vkCheck vkCmdBindVertexBuffers(context.commandBuffer, 0, 1, addr context.vertexBuffer.buffer, addr offsets)

    vkCheck vkCmdBindDescriptorSets(context.commandBuffer, VkPipelineBindPoint.graphics, context.pipelineLayout, 0, 1, addr context.descriptorSet, 0, nil)
    for renderBatch in renderBatches:
        vkCheck vkCmdBindDescriptorSets(context.commandBuffer, VkPipelineBindPoint.graphics, context.pipelineLayout, 1, 1, addr context.textures[renderBatch.texture.id].descriptorSet, 0, nil)
        vkCheck vkCmdDraw(context.commandBuffer, renderBatch.primitiveCount, 1, renderBatch.offset, 0)


    vkCheck vkCmdEndRenderPass(context.commandBuffer)

    let prePresentBarrier = VkImageMemoryBarrier(
        sType: VkStructureType.imageMemoryBarrier
        , srcAccessMask: uint32 VkAccessFlagBits.colorAttachmentWrite
        , dstAccessMask: uint32 VkAccessFlagBits.memoryRead
        , oldLayout: VkImageLayout.colorAttachmentOptimal
        , newLayout: VkImageLayout.presentSrcKHR
        , srcQueueFamilyIndex: high uint32
        , dstQueueFamilyIndex: high uint32
        , image: context.swapchainTextures[int presentBeginData.imageIndex].image
        , subresourceRange: VkImageSubresourceRange(
            aspectMask: uint32 VkImageAspectFlagBits.color
            , baseMipLevel: 0
            , levelCount: 1
            , baseArrayLayer: 0
            , layerCount: 1
        )
    )
    
    vkCheck vkCmdPipelineBarrier(
        context.commandBuffer
        , uint32 VkPipelineStageFlagBits.allCommands
        , uint32 VkPipelineStageFlagBits.bottomOfPipe
        , 0
        , 0, nil
        , 0, nil
        , 1, unsafeAddr prePresentBarrier
    )
    
    vkwPresentEnd(context.device, context.swapchain, context.commandBuffer, context.queue, presentBeginData)