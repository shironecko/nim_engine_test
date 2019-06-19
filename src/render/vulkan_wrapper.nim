import strutils
import sequtils
import sugar
import strformat
import macros
import sdl2 except VkInstance, VkSurfaceKHR
import ../log
import ../utility
import vulkan
export vulkan

type
    VulkanVersionInfo* = object
        major*, minor*, patch*: uint

proc makeVulkanVersionInfo*(apiVersion: uint): VulkanVersionInfo =
    VulkanVersionInfo(
        major: apiVersion shr 22
        , minor: (apiVersion shr 12) and 0x3ff
        , patch: apiVersion and 0xfff)

proc `$`*(vkVersion: VulkanVersionInfo): string = &"{vkVersion.major}.{vkVersion.minor}.{vkVersion.patch}"

proc getVulkanProcAddrGetterProc(): PFN_vkGetInstanceProcAddr {.inline.} = cast[PFN_vkGetInstanceProcAddr](vulkanGetVkGetInstanceProcAddr())

proc loadVulkanProc[ProcType](procGetter: PFN_vkGetInstanceProcAddr, vulkanInstance: VkInstance, fnName: string): ProcType {.inline.} =
    let getterProc = procGetter(vulkanInstance, fnName)
    result = cast[ProcType](getterProc)
    vkCheck result != nil, &"Failed to load {fnName} function!"

macro generateVulkanAPILoader(loaderName: string, usedFunctions: untyped): untyped =
    var
        fnDeclarations = newStmtList()
        fnLoadingCode = newStmtList()
    let
        fnLoaderIdent = ident "fnLoader"
        vkInstanceParamIdent = ident "vulkanInstance"
        apiLoaderFnIdent = ident $loaderName

    fnLoadingCode.add quote do:
        var `fnLoaderIdent`: PFN_vkGetInstanceProcAddr
        `fnLoaderIdent` = getVulkanProcAddrGetterProc()
    
    for fn in usedFunctions:
        doAssert(fn.kind() == nnkIdent or fn.kind() == nnkCall)

        let
            fnHasCustomName = fn.kind() == nnkCall
            fnIdent = if fnHasCustomName: fn[1][0] else: fn
            fnCName = if fnHasCustomName: toStrLit(fn[0]) else: toStrLit(fnIdent)
            fnType = ident(&"PFN_{fnCName}")
        
        fnDeclarations.add quote do:
            var `fnIdent`*: `fnType`
        
        fnLoadingCode.add quote do:
            `fnIdent` = loadVulkanProc[`fnType`](`fnLoaderIdent`, `vkInstanceParamIdent`, `fnCName`)
            vkCheck `fnIdent` != nil, "Failed to load $# function!".format(`fnCName`)
    
    var loaderFnDecl = quote do:
        proc `apiLoaderFnIdent`*(`vkInstanceParamIdent`: VkInstance = cast[VkInstance](nil)) = `fnLoadingCode`

    newStmtList fnDeclarations, loaderFnDecl

generateVulkanAPILoader "loadVulkanAPI":
    vkCreateInstance
    vkEnumerateInstanceLayerProperties: vkEnumerateInstanceLayerPropertiesRaw
    vkEnumerateInstanceExtensionProperties: vkEnumerateInstanceExtensionPropertiesRaw

generateVulkanAPILoader "loadVulkanInstanceAPI":
    vkDestroyInstance
    vkEnumeratePhysicalDevices: vkEnumeratePhysicalDevicesRaw
    vkGetPhysicalDeviceProperties
    vkGetPhysicalDeviceQueueFamilyProperties: vkGetPhysicalDeviceQueueFamilyPropertiesRaw
    vkCreateDevice
    vkDestroyDevice
    vkGetPhysicalDeviceSurfaceSupportKHR
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR
    vkGetPhysicalDeviceSurfaceFormatsKHR: vkGetPhysicalDeviceSurfaceFormatsKHRRaw
    vkGetPhysicalDeviceSurfacePresentModesKHR: vkGetPhysicalDeviceSurfacePresentModesKHRRaw
    vkGetPhysicalDeviceMemoryProperties
    vkEnumerateDeviceExtensionProperties: vkEnumerateDeviceExtensionPropertiesRaw
    vkCreateSwapchainKHR
    vkDestroySwapchainKHR
    vkGetSwapchainImagesKHR: vkGetSwapchainImagesKHRRaw
    vkCreateImage
    vkDestroyImage
    vkAllocateMemory
    vkFreeMemory
    vkMapMemory
    vkUnmapMemory
    vkBindBufferMemory
    vkBindImageMemory
    vkGetImageMemoryRequirements
    vkCreateImageView
    vkDestroyImageView
    vkAcquireNextImageKHR
    vkCreateDebugReportCallbackEXT
    vkDestroyDebugReportCallbackEXT
    vkGetDeviceQueue
    vkCreateCommandPool
    vkDestroyCommandPool
    vkAllocateCommandBuffers
    vkFreeCommandBuffers
    vkBeginCommandBuffer
    vkEndCommandBuffer
    vkResetCommandBuffer
    vkCmdPipelineBarrier
    vkCmdBindPipeline
    vkCmdBeginRenderPass
    vkCmdEndRenderPass
    vkCmdSetViewport
    vkCmdSetScissor
    vkCmdBindVertexBuffers
    vkCmdDraw
    vkQueueSubmit
    vkQueuePresentKHR
    vkCreateFence
    vkDestroyFence
    vkWaitForFences
    vkResetFences
    vkCreateRenderPass
    vkDestroyRenderPass
    vkCreateFramebuffer
    vkDestroyFramebuffer
    vkCreateBuffer
    vkDestroyBuffer
    vkGetBufferMemoryRequirements
    vkCreateBufferView
    vkDestroyBufferView
    vkCreateShaderModule
    vkDestroyShaderModule
    vkCreatePipelineLayout
    vkDestroyPipelineLayout
    vkCreateGraphicsPipelines
    vkDestroyPipeline
    vkCreateSemaphore
    vkDestroySemaphore
    vkCreateDescriptorSetLayout
    vkDestroyDescriptorSetLayout
    vkCreateDescriptorPool
    vkDestroyDescriptorPool
    vkAllocateDescriptorSets
    vkFreeDescriptorSets
    vkUpdateDescriptorSets
    vkCmdBindDescriptorSets
    vkFlushMappedMemoryRanges
    vkCreateSampler
    vkDestroySampler

macro generateVulkanArrayGetterWrapper(fnToWrap: typed, wrapperFnName: untyped, arrayElemType: typed): untyped =
    fnToWrap.expectKind nnkSym
    wrapperFnName.expectKind nnkIdent
    arrayElemType.expectKind nnkSym

    quote do:
        proc `wrapperFnName`*(): seq[`arrayElemType`] =
            var 
                elementsCount: uint32
                elements: seq[`arrayElemType`]
            vkCheck `fnToWrap`(addr elementsCount, nil)
            elements.setLen(elementsCount)
            vkCheck `fnToWrap`(addr elementsCount, addr elements[0])
            elements

macro generateVulkanArrayGetterWrapper(fnToWrap: typed, wrapperFnName: untyped, arrayElemType: typed, additionalArgs: untyped): untyped =
    fnToWrap.expectKind nnkSym
    wrapperFnName.expectKind nnkIdent
    arrayElemType.expectKind nnkSym

    let
        elementsCountIdent = ident "elementsCount"
        elementCountAddrCommand = newNimNode(nnkCommand).add(ident "addr").add(elementsCountIdent)
        elementsIdent = ident "elements"
        returnType = quote do:
            seq[`arrayElemType`]
        fnArgs = additionalArgs.foldl(a & newIdentDefs(b[0], b[1][0]), @[returnType])
        wrappedFnDryCall = additionalArgs.foldl(a.add(b[0]), newNimNode(nnkCall).add(fnToWrap)).add(elementCountAddrCommand).add(newNilLit())
    
    var wrappedFnCall = copyNimTree(wrappedFnDryCall)
    wrappedFnCall[^1] = quote do:
        addr `elementsIdent`[0]

    let 
        fnBody = quote do:
            var 
                `elementsCountIdent`: uint32
                `elementsIdent`: `returnType`
            vkCheck `wrappedFnDryCall`
            elements.setLen(elementsCount)
            vkCheck `wrappedFnCall`
            elements
        fnDecl = newProc(postfix(wrapperFnName, "*"), fnArgs, fnBody)
    fnDecl

generateVulkanArrayGetterWrapper vkEnumerateInstanceLayerPropertiesRaw, vkEnumerateInstanceLayerProperties, VkLayerProperties
generateVulkanArrayGetterWrapper vkEnumerateInstanceExtensionPropertiesRaw, vkEnumerateInstanceExtensionProperties, VkExtensionProperties:
    pLayerName: cstring
generateVulkanArrayGetterWrapper vkEnumeratePhysicalDevicesRaw, vkEnumeratePhysicalDevices, VkPhysicalDevice:
    instance: VkInstance
generateVulkanArrayGetterWrapper vkGetPhysicalDeviceQueueFamilyPropertiesRaw, vkGetPhysicalDeviceQueueFamilyProperties, VkQueueFamilyProperties:
    device: VkPhysicalDevice
generateVulkanArrayGetterWrapper vkGetPhysicalDeviceSurfaceFormatsKHRRaw, vkGetPhysicalDeviceSurfaceFormatsKHR, VkSurfaceFormatKHR:
    device: VkPhysicalDevice
    surface: VkSurfaceKHR
generateVulkanArrayGetterWrapper vkGetPhysicalDeviceSurfacePresentModesKHRRaw, vkGetPhysicalDeviceSurfacePresentModesKHR, VkPresentModeKHR:
    device: VkPhysicalDevice
    surface: VkSurfaceKHR
generateVulkanArrayGetterWrapper vkEnumerateDeviceExtensionPropertiesRaw, vkEnumerateDeviceExtensionProperties, VkExtensionProperties:
    device: VkPhysicalDevice
    pLayerName: cstring
generateVulkanArrayGetterWrapper vkGetSwapchainImagesKHRRaw, vkGetSwapchainImagesKHR, VkImage:
    device: VkDevice
    swapChain: VkSwapchainKHR

type
    GPUVendor* {.pure.} = enum
        AMD, NVidia, Intel, ARM, Qualcomm, ImgTec, Unknown

proc vkVendorIDToGPUVendor*(vendorID: uint32): GPUVendor =
    case vendorID:
        of 0x1002: GPUVendor.AMD
        of 0x10DE: GPUVendor.NVidia
        of 0x8086: GPUVendor.Intel
        of 0x13B5: GPUVendor.ARM
        of 0x5143: GPUVendor.Qualcomm
        of 0x1010: GPUVendor.ImgTec
        else: GPUVendor.Unknown

type
    VkwPhysicalDeviceDescription* = object
        handle*: VkPhysicalDevice
        name*: string
        vendor*: GPUVendor
        properties*: VkPhysicalDeviceProperties
        memoryProperties*: VkPhysicalDeviceMemoryProperties
        extensions*: seq[VkExtensionProperties]
        queueFamilies*: seq[VkQueueFamilyProperties]
        hasPresentQueue*: bool
        presentQueueIdx*: uint32

proc vkwEnumeratePhysicalDevicesWithDescriptions*(instance: VkInstance, surface: VkSurfaceKHR): seq[VkwPhysicalDeviceDescription] =
    let devices = vkEnumeratePhysicalDevices(instance)
    vkCheck devices.len() != 0, "Failed to find any compatible devices!"

    devices.map(proc (device: VkPhysicalDevice): VkwPhysicalDeviceDescription =
        result.handle = device
        vkGetPhysicalDeviceProperties(device, addr result.properties)
        vkGetPhysicalDeviceMemoryProperties(device, addr result.memoryProperties)
        result.name = charArrayToString(result.properties.deviceName)
        result.vendor = vkVendorIDToGPUVendor(result.properties.vendorID)
        result.extensions = vkEnumerateDeviceExtensionProperties(device, nil)
        result.queueFamilies = vkGetPhysicalDeviceQueueFamilyProperties(device)
        result.hasPresentQueue = false
        result.presentQueueIdx = high(uint32)
        for i, q in result.queueFamilies:
            var surfaceSupported: VkBool32
            vkCheck vkGetPhysicalDeviceSurfaceSupportKHR(device, uint32 i, surface, addr surfaceSupported)
            if surfaceSupported == vkTrue and maskCheck(q.queueFlags, VkQueueFlagBits.graphics):
                result.hasPresentQueue = true
                result.presentQueueIdx = uint32 i
                break
    )

proc vkwAllocateDeviceMemory*(device: VkDevice, deviceMemoryProperties: VkPhysicalDeviceMemoryProperties, requirements: VkMemoryRequirements, desiredMemoryFlags: VkMemoryPropertyFlags): VkDeviceMemory =
    var 
        allocateInfo = VkMemoryAllocateInfo(
            sType: VkStructureType.memoryAllocateInfo
            , allocationSize: requirements.size
        )
        memoryTypeBits = requirements.memoryTypeBits
    
    for i in 0..<32:
        let memoryType = deviceMemoryProperties.memoryTypes[i]
        if maskCheck(memoryTypeBits, 1):
            if maskCheck(memoryType.propertyFlags, desiredMemoryFlags):
                allocateInfo.memoryTypeIndex = uint32 i
                break
        
        memoryTypeBits = memoryTypeBits shr 1
    
    vkCheck vkAllocateMemory(device ,addr allocateInfo, nil, addr result)

type
    VkwPresentBeginData* = object
        presentCompleteSemaphore*, renderingCompleteSemaphore*: VkSemaphore
        imageIndex*: uint32

proc vkwPresentBegin*(device: VkDevice, swapchain: VkSwapchainKHR, commandBuffer: VkCommandBuffer): VkwPresentBeginData =
    let semaphoreCreateInfo = VkSemaphoreCreateInfo(
        sType: VkStructureType.semaphoreCreateInfo
        , pNext: nil
        , flags: 0
    )
    vkCheck vkCreateSemaphore(device, unsafeAddr semaphoreCreateInfo, nil, addr result.presentCompleteSemaphore )
    vkCheck vkCreateSemaphore(device, unsafeAddr semaphoreCreateInfo, nil, addr result.renderingCompleteSemaphore)

    vkCheck vkAcquireNextImageKHR(device, swapchain, high uint64, result.presentCompleteSemaphore, vkNullHandle, addr result.imageIndex)

    let commandBufferBeginInfo = VkCommandBufferBeginInfo(
        sType: VkStructureType.commandBufferBeginInfo
        , flags: uint32 VkCommandBufferUsageFlagBits.oneTimeSubmit
    )
    vkCheck vkBeginCommandBuffer(commandBuffer, unsafeAddr commandBufferBeginInfo)

proc vkwPresentEnd*(device: VkDevice, swapchain: var VkSwapchainKHR, commandBuffer: var VkCommandBuffer, queue: VkQueue, presentBeginData: var VkwPresentBeginData) =
    vkCheck vkEndCommandBuffer(commandBuffer)

    var
        renderFence: VkFence
        fenceCreateInfo = VkFenceCreateInfo(sType: VkStructureType.fenceCreateInfo)
    vkCheck vkCreateFence(device, addr fenceCreateInfo, nil, addr renderFence)

    let
        waitStageMask: VkPipelineStageFlags = uint32 VkPipelineStageFlagBits.bottomOfPipe
        submitInfo = VkSubmitInfo(
            sType: VkStructureType.submitInfo
            , waitSemaphoreCount: 1
            , pWaitSemaphores: addr presentBeginData.presentCompleteSemaphore
            , pWaitDstStageMask: unsafeAddr waitStageMask
            , commandBufferCount: 1
            , pCommandBuffers: addr commandBuffer
            , signalSemaphoreCount: 1
            , pSignalSemaphores: addr presentBeginData.renderingCompleteSemaphore
        )
    vkCheck vkQueueSubmit(queue, 1, unsafeAddr submitInfo, renderFence)
    vkCheck vkWaitForFences(device, 1, addr renderFence, vkTrue, high uint64)
    vkDestroyFence(device, renderFence, nil)
    vkCheck vkResetCommandBuffer(commandBuffer, 0)

    let presentInfo = VkPresentInfoKHR(
        sType: VkStructureType.presentInfoKHR
        , waitSemaphoreCount: 1
        , pWaitSemaphores: addr presentBeginData.renderingCompleteSemaphore
        , swapchainCount: 1
        , pSwapchains: addr swapchain
        , pImageIndices: addr presentBeginData.imageIndex
        , pResults: nil
    )
    vkCheck vkQueuePresentKHR(queue, unsafeAddr presentInfo)

    vkDestroySemaphore(device, presentBeginData.presentCompleteSemaphore, nil)
    vkDestroySemaphore(device, presentBeginData.renderingCompleteSemaphore, nil)

    presentBeginData = VkwPresentBeginData(
        presentCompleteSemaphore: vkNullHandle
        , renderingCompleteSemaphore: vkNullHandle
        , imageIndex: high uint32
    )

proc vkwTransitionImageLayout*(
        device: VkDevice
        , image: VkImage
        , commandBuffer: var VkCommandBuffer
        , queue: VkQueue
        , fence: var VkFence
        , srcAccessMask, dstAccessMask: VkAccessFlags
        , oldLayout, newLayout: VkImageLayout
        , srcStageMask, dstStageMask: VkPipelineStageFlags
        , subresourceRangeAspectMask: VkImageAspectFlags
    ) =

    let beginInfo = VkCommandBufferBeginInfo(
        sType: VkStructureType.commandBufferBeginInfo
        , flags: uint32 VkCommandBufferUsageFlagBits.oneTimeSubmit
    )
    vkCheck vkBeginCommandBuffer(commandBuffer, unsafeAddr beginInfo)
    let layoutTransitionBarrier = VkImageMemoryBarrier(
        sType: VkStructureType.imageMemoryBarrier
        , srcAccessMask: srcAccessMask
        , dstAccessMask: dstAccessMask
        , oldLayout: oldLayout
        , newLayout: newLayout
        , srcQueueFamilyIndex: high uint32
        , dstQueueFamilyIndex: high uint32
        , image: image
        , subresourceRange: VkImageSubresourceRange(
            aspectMask: subresourceRangeAspectMask
            , baseMipLevel: 0
            , levelCount: 1
            , baseArrayLayer: 0
            , layerCount: 1
        )
    )
    vkCheck vkCmdPipelineBarrier(
        commandBuffer
        , srcStageMask
        , dstStageMask
        , 0
        , 0, nil
        , 0, nil
        , 1, unsafeAddr layoutTransitionBarrier
    )
    vkCheck vkEndCommandBuffer(commandBuffer)

    let
        waitStageMask: VkPipelineStageFlags = uint32 VkPipelineStageFlagBits.colorAttachmentOutput
        submitInfo = VkSubmitInfo(
            sType: VkStructureType.submitInfo
            , waitSemaphoreCount: 0
            , pWaitSemaphores: nil
            , pWaitDstStageMask: unsafeAddr waitStageMask
            , commandBufferCount: 1
            , pCommandBuffers: addr commandBuffer
            , signalSemaphoreCount: 0
            , pSignalSemaphores: nil
        )
    vkCheck vkQueueSubmit(queue, 1, unsafeAddr submitInfo, fence)

    vkCheck vkWaitForFences(device, 1, addr fence, vkTrue, high uint64)
    vkCheck vkResetFences(device, 1, addr fence)
    vkCheck vkResetCommandBuffer(commandBuffer, 0)

type
    VkwImageLayoutTransitionType* {.pure.} = enum
        ColorTextureInitialization

proc vkwTransitionImageLayout*(
    device: VkDevice
    , image: VkImage
    , commandBuffer: var VkCommandBuffer
    , queue: VkQueue
    , fence: var VkFence
    , transitionType: VkwImageLayoutTransitionType
    ) =
    case transitionType:
        of ColorTextureInitialization:
            vkwTransitionImageLayout(
                device = device
                , image = image
                , commandBuffer = commandBuffer
                , queue = queue
                , fence = fence
                , srcAccessMask = uint32 VkAccessFlagBits.hostWrite
                , dstAccessMask = uint32 VkAccessFlagBits.shaderRead
                , oldLayout = VkImageLayout.preinitialized
                , newLayout = VkImageLayout.shaderReadOnlyOptimal
                , srcStageMask = uint32 VkPipelineStageFlagBits.host
                , dstStageMask = uint32 VkPipelineStageFlagBits.fragmentShader
                , subresourceRangeAspectMask = uint32 VkImageAspectFlagBits.color
            )

type
    VkwTexturePixelRGBAFloat32* {.packed.} = object
        r, g, b, a: float32

proc vkwCreateImage*(device: VkDevice, deviceMemoryProperties: VkPhysicalDeviceMemoryProperties, width: uint32, height: uint32
        , format = VkFormat.r32g32b32a32SFloat
    ): tuple[image: VkImage, memory: VkDeviceMemory] =
    let textureCreateInfo = VkImageCreateInfo(
        sType: VkStructureType.imageCreateInfo
        , imageType: VkImageType.twoDee
        , format: format
        , extent: VkExtent3D(width: width, height: height, depth: 1)
        , mipLevels: 1
        , arrayLayers: 1
        , samples: VkSampleCountFlagBits.one
        , tiling: VkImageTiling.linear
        , usage: uint32 VkImageUsageFlagBits.sampled
        , sharingMode: VkSharingMode.exclusive
        , initialLayout: VkImageLayout.preinitialized
    )
    
    vkCheck vkCreateImage(device, unsafeAddr textureCreateInfo, nil, addr result.image)
    var imageMemoryRequirements: VkMemoryRequirements
    vkCheck vkGetImageMemoryRequirements(device, result.image, addr imageMemoryRequirements)
    result.memory = vkwAllocateDeviceMemory(device, deviceMemoryProperties, imageMemoryRequirements, VkMemoryPropertyFlags VkMemoryPropertyFlagBits.hostVisible)
    vkCheck vkBindImageMemory(device, result.image, result.memory, 0)

proc vkwCreateImageView*(device: VkDevice, image: VkImage
        , format = VkFormat.r32g32b32a32SFloat
    ): VkImageView =
    let vkTextureImageViewCreateInfo = VkImageViewCreateInfo(
            sType: VkStructureType.imageViewCreateInfo
            , image: image
            , viewType: VkImageViewType.twoDee
            , format: VkFormat.r32g32b32a32SFloat
            , components: VkComponentMapping(r: VkComponentSwizzle.r, g: VkComponentSwizzle.g, b: VkComponentSwizzle.b, a: VkComponentSwizzle.a)
            , subresourceRange: VkImageSubresourceRange(
                aspectMask: uint32 VkImageAspectFlagBits.color
                , baseMipLevel: 0
                , levelCount: 1
                , baseArrayLayer: 0
                , layerCount: 1
            )
        )
    vkCheck vkCreateImageView(device, unsafeAddr vkTextureImageViewCreateInfo, nil, addr result)

proc vkwCreateImageSampler*(device: VkDevice): VkSampler =
    let samplerCreateInfo = VkSamplerCreateInfo(
            sType: VkStructureType.samplerCreateInfo
            , magFilter: VkFilter.linear
            , minFilter: VkFilter.linear
            , mipmapMode: VkSamplerMipmapMode.linear
            , addressModeU: VkSamplerAddressMode.clampToEdge
            , addressModeV: VkSamplerAddressMode.clampToEdge
            , addressModeW: VkSamplerAddressMode.clampToEdge
            , mipLodBias: 0
            , anisotropyEnable: vkFalse
            , minLod: 0
            , maxLod: 5
            , borderColor: VkBorderColor.floatTransparentBlack
            , unnormalizedCoordinates: vkFalse
        )
    vkCheck vkCreateSampler(device, unsafeAddr samplerCreateInfo, nil, addr result)

proc vkwCreateImageDescriptorSet*(
        device: VkDevice
        , descriptorPool: VkDescriptorPool
        , descriptorLayout: var VkDescriptorSetLayout
        , sampler: VkSampler
        , imageView: VkImageView
    ): VkDescriptorSet =
    let 
        descriptorAllocateInfo = VkDescriptorSetAllocateInfo(
            sType: VkStructureType.descriptorSetAllocateInfo
            , descriptorPool: descriptorPool
            , descriptorSetCount: 1
            , pSetLayouts: addr descriptorLayout
        )
    vkCheck vkAllocateDescriptorSets(device, unsafeAddr descriptorAllocateInfo, addr result)

    let 
        imageInfo = VkDescriptorImageInfo(
            sampler: sampler
            , imageView: imageView
            , imageLayout: VkImageLayout.shaderReadOnlyOptimal
        )
        writeDescriptor = VkWriteDescriptorSet(
            sType: VkStructureType.writeDescriptorSet
            , dstSet: result
            , dstBinding: 0
            , dstArrayElement: 0
            , descriptorCount: 1
            , descriptorType: VkDescriptorType.combinedImageSampler
            , pImageInfo: unsafeAddr imageInfo
            , pBufferInfo: nil
            , pTexelBufferView: nil
        )

    vkCheck vkUpdateDescriptorSets(device, 1, unsafeAddr writeDescriptor, 0, nil)

type
    VkwBuffer* = object
        buffer*: VkBuffer
        view*: VkBufferView
        memory*: VkDeviceMemory

proc vkwAllocateBuffer*(
        device: VkDevice
        , memoryProperties: VkPhysicalDeviceMemoryProperties
        , size: uint64
        , usageFlags: VkBufferUsageFlags
    ): VkwBuffer =
    let bufferCreateInfo = VkBufferCreateInfo(
        sType: VkStructureType.bufferCreateInfo
        , size: size
        , usage: usageFlags
        , sharingMode: VkSharingMode.exclusive
    )
    vkCheck vkCreateBuffer(device, unsafeAddr bufferCreateInfo, nil, addr result.buffer)

    var bufferMemoryRequirements: VkMemoryRequirements
    vkGetBufferMemoryRequirements(device, result.buffer, addr bufferMemoryRequirements)
    result.memory = vkwAllocateDeviceMemory(device, memoryProperties, bufferMemoryRequirements, VkMemoryPropertyFlags VkMemoryPropertyFlagBits.hostVisible)
    vkCheck vkBindBufferMemory(device, result.buffer, result.memory, 0)

proc vkwFreeBuffer*(
        device: VkDevice
        , buffer: VkwBuffer
    ) =
    vkCheck vkDestroyBuffer(device, buffer.buffer, nil)
    vkCheck vkFreeMemory(device, buffer.memory, nil)

proc vkwWithMemoryBegin(device: VkDevice, memory: VkDeviceMemory): pointer =
    vkCheck vkMapMemory(device, memory, 0, high uint64, 0, addr result)

proc vkwWithMemoryEnd(device: VkDevice, memory: VkDeviceMemory) =
    let memoryRange = VkMappedMemoryRange(
        sType: VkStructureType.mappedMemoryRange
        , memory: memory
        , offset: 0
        , size: high uint64
    )
    vkCheck vkFlushMappedMemoryRanges(device, 1, unsafeAddr memoryRange)
    vkCheck vkUnmapMemory(device, memory)

template vkwWithMemory*(device: VkDevice, memory: VkDeviceMemory, operations: untyped): untyped =
    block:
        var memoryPtr {.inject.} = vkwWithMemoryBegin(device, memory)
        operations
        vkwWithMemoryEnd(device, memory)
