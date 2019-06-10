import strutils
import sequtils
import sugar
import strformat
import macros
import sdl2/sdl except VkInstance, VkSurfaceKHR
import ../log
import ../utility
import vulkan as vk

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

proc loadVulkanProc[ProcType](procGetter: PFN_vkGetInstanceProcAddr, vulkanInstance: vk.VkInstance, fnName: string): ProcType {.inline.} =
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
            fnName = toStrLit(fnIdent)
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
        additionalArgsIdents = additionalArgs.mapIt(it[0])
        additionalArgsDefs = additionalArgs.mapIt(newIdentDefs(it[0], it[1][0]))
    
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