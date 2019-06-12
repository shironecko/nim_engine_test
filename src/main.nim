import strutils
import sequtils
import sugar
import strformat
import glm
import log
import sdl2
import vulkan as vk except vkCreateDebugReportCallbackEXT, vkDestroyDebugReportCallbackEXT
import render/vulkan_wrapper
import render/render_vk
import utility

proc GetTime*(): float64 =
    return cast[float64](getPerformanceCounter()*1000) / cast[float64](getPerformanceFrequency())

sdlCheck sdl2.init(INIT_EVERYTHING), "Failed to init :c"

const
    prefferedWidth = 512
    prefferedHeight = 512

var window: WindowPtr
window = createWindow(
    "SDL/Vulkan"
    , SDL_WINDOWPOS_UNDEFINED
    , SDL_WINDOWPOS_UNDEFINED
    , prefferedWidth, prefferedHeight
    , uint32 maskCombine(SDL_WINDOW_SHOWN, rdGetRequiredSDLWindowFlags())
)
sdlCheck window != nil, "Failed to create window!"

type
    WindowDimentions = object
        width, height, fullWidth, fullHeight : int32

proc getWindowDimentions(window : WindowPtr) : WindowDimentions =
    sdl2.getSize(window, result.fullWidth, result.fullHeight)
    sdl2.vulkanGetDrawableSize(window, addr result.width, addr result.height)

var windowDimentions = getWindowDimentions(window)

var renderContext = rdPreInitialize(window)

let renderDevices = rdGetCompatiblePhysicalDevices(renderContext)
check renderDevices.len() != 0, "Failed to find any render compatible devices!"

gLog LTrace, "[Compatible Devices]"
for d in renderDevices: gLog LTrace, &"\t{d.name}({d.deviceType}, {d.vendor})"
let selectedRenderDevice = renderDevices[0]
gLog LInfo, &"Selected render device: {selectedRenderDevice.name}"

vkLog LTrace, "[Device Extensions]"
for ex in selectedRenderDevice.extensions:
    vkLog LTrace, &"\t{charArrayToString(ex.extensionName)}({makeVulkanVersionInfo(ex.specVersion)})"

var
    queuePriorities = [1.0'f32]
    queueCreateInfo = VkDeviceQueueCreateInfo(
        sType: VkStructureType.deviceQueueCreateInfo
        , queueFamilyIndex: selectedRenderDevice.presentQueueIdx
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
vkCheck vkCreateDevice(selectedRenderDevice.handle, addr deviceInfo, nil, addr vkDevice)
deallocCStringArray(deviceExtensionsCStrings)

let surfaceFormats = vkGetPhysicalDeviceSurfaceFormatsKHR(selectedRenderDevice.handle, vkSurface)
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
vkCheck vkGetPhysicalDeviceSurfaceCapabilitiesKHR(selectedRenderDevice.handle, vkSurface, addr vkSurfaceCapabilities)
var desiredImageCount = 2'u32
if desiredImageCount < vkSurfaceCapabilities.minImageCount: 
    desiredImageCount = vkSurfaceCapabilities.minImageCount
elif vkSurfaceCapabilities.maxImageCount != 0 and desiredImageCount > vkSurfaceCapabilities.maxImageCount: 
    desiredImageCount = vkSurfaceCapabilities.maxImageCount
vkLog LInfo, &"Desired swapchain images: {desiredImageCount}"

var surfaceResolution = vkSurfaceCapabilities.currentExtent
if surfaceResolution.width == 0xFFFFFFFF'u32:
    surfaceResolution.width = prefferedWidth
    surfaceResolution.height = prefferedHeight
vkLog LInfo, &"Surface resolution: {surfaceResolution}"

var preTransform = vkSurfaceCapabilities.currentTransform
if maskCheck(vkSurfaceCapabilities.supportedTransforms, VkSurfaceTransformFlagBitsKHR.identity):
    preTransform = VkSurfaceTransformFlagBitsKHR.identity

let presentModes = vkGetPhysicalDeviceSurfacePresentModesKHR(selectedRenderDevice.handle, vkSurface)
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

let render = proc(cameraPosition: Vec3f) =
    block CameraSetup:
        var
            unitPixelScale = 512'f32
            model = mat4(1.0'f32).scale(unitPixelScale, unitPixelScale, 1.0'f32)
            view = lookAt(
                eye = vec3(0.0'f32, 0.0'f32, -1.0'f32)
                , center = vec3(0.0'f32)
                , up = vec3(0.0'f32, -1.0'f32, 0.0'f32)
            ).translate(-cameraPosition)
            projection = ortho(
                float32(surfaceResolution.width) * -0.5'f32
                , float32(surfaceResolution.width) * 0.5'f32
                , float32(surfaceResolution.height) * -0.5'f32
                , float32(surfaceResolution.height) * 0.5'f32
                , 0.0'f32, 1.0'f32)
            clip = mat4(
                vec4(1.0'f32, 0.0'f32, 0.0'f32, 0.0'f32),
                vec4(0.0'f32,-1.0'f32, 0.0'f32, 0.0'f32),
                vec4(0.0'f32, 0.0'f32, 0.5'f32, 0.0'f32),
                vec4(0.0'f32, 0.0'f32, 0.5'f32, 1.0'f32),
            )
            mvp = (clip * projection * view * model).transpose()
            mvpMappedMem: pointer
        vkCheck vkMapMemory(vkDevice, vkUniforms.memory, 0, high uint64, 0, addr mvpMappedMem)
        copyMem(mvpMappedMem, mvp.caddr, sizeof(float32) * 16)
        let memoryRange = VkMappedMemoryRange(
            sType: VkStructureType.mappedMemoryRange
            , memory: vkUniforms.memory
            , offset: 0
            , size: high uint64
        )
        vkCheck vkFlushMappedMemoryRanges(vkDevice, 1, unsafeAddr memoryRange)
        vkCheck vkUnmapMemory(vkDevice, vkUniforms.memory)

    var presentBeginData = vkwPresentBegin(vkDevice, vkSwapchain, vkRenderCmdBuffer)
    
    let uniformMemoryBarrier = VkMemoryBarrier(
        sType: VkStructureType.memoryBarrier
        , srcAccessMask: uint32 VkAccessFlagBits.hostWrite
        , dstAccessMask: uint32 VkAccessFlagBits.uniformRead
    )
    vkCheck vkCmdPipelineBarrier(
        vkRenderCmdBuffer
        , uint32 VkPipelineStageFlagBits.host
        , uint32 VkPipelineStageFlagBits.vertexShader
        , 0
        , 1, unsafeAddr uniformMemoryBarrier
        , 0, nil
        , 0, nil)

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
    vkCheck vkCmdDraw(vkRenderCmdBuffer, 6, 1, 0, 0)

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

var
    evt: sdl2.Event
    cameraPosition = vec3(0.0'f32)
    lastPC = getPerformanceCounter()
block GameLoop:
    while true:
        while sdl2.pollEvent(evt) == True32:
            case evt.kind:
                of QuitEvent:
                    break GameLoop
                of WindowEvent:
                    var windowEvent = cast[WindowEventObj](addr evt)
                    let newWindowDimensions = getWindowDimentions(window)
                    if windowDimentions != newWindowDimensions:
                        updateRenderResolution(newWindowDimensions)
                        windowDimentions = newWindowDimensions
                else: discard
        
        let 
            keys = getKeyboardState(nil)
            cameraSpeed = 100.0'f32
            pc = getPerformanceCounter()
            dt = float32(float64(pc - lastPC) / float64(getPerformanceFrequency()))
        lastPC = pc

        if keys[int SDL_SCANCODE_ESCAPE] == 1:
            break GameLoop

        if keys[int SDL_SCANCODE_A] == 1:
            cameraPosition.x -= cameraSpeed * dt
        if keys[int SDL_SCANCODE_D] == 1:
            cameraPosition.x += cameraSpeed * dt
        if keys[int SDL_SCANCODE_W] == 1:
            cameraPosition.y -= cameraSpeed * dt
        if keys[int SDL_SCANCODE_S] == 1:
            cameraPosition.y += cameraSpeed * dt

        render(cameraPosition)

for texture in vkTextures:
    vkwFreeColorTexture(vkDevice, texture)
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
sdl2.quit()