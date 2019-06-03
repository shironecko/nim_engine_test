import strutils
import sequtils
import sugar
import macros
import sdl2/sdl
import logging
import vulkan as vk

proc getVulkanProcAddrGetterProc(): PFN_vkGetInstanceProcAddr {.inline.} = cast[PFN_vkGetInstanceProcAddr](vulkanGetVkGetInstanceProcAddr())

proc loadVulkanProc[ProcType](procGetter: PFN_vkGetInstanceProcAddr, vulkanInstance: vk.VkInstance, fnName: string): ProcType {.inline.} =
    let getterProc = procGetter(vulkanInstance, fnName)
    result = cast[ProcType](getterProc)
    vkCheck result != nil, "Failed to load $# function!".format(fnName)

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
        fn.expectKind(nnkIdent)

        let
            fnName = toStrLit(fn)
            fnType = ident("PFN_$#".format($fn))
        fnDeclarations.add quote do:
            var `fn`*: `fnType`
        
        fnLoadingCode.add quote do:
            `fn` = loadVulkanProc[`fnType`](`fnLoaderIdent`, `vkInstanceParamIdent`, `fnName`)
            vkCheck `fn` != nil, "Failed to load $# function!".format(`fnName`)
    
    var loaderFnDecl = quote do:
            proc `apiLoaderFnIdent`*(`vkInstanceParamIdent`: vk.VkInstance) = `fnLoadingCode`
    
    newStmtList fnDeclarations, loaderFnDecl

generateVulkanAPILoader "loadVulkanAPI":
    vkCreateInstance
    vkEnumerateInstanceLayerProperties
    vkEnumerateInstanceExtensionProperties

generateVulkanAPILoader "loadVulkanInstanceAPI":
    vkDestroyInstance
    vkEnumeratePhysicalDevices
    vkGetPhysicalDeviceProperties
    vkGetPhysicalDeviceQueueFamilyProperties
    vkCreateDevice
    vkDestroyDevice
    vkGetPhysicalDeviceSurfaceSupportKHR
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR
    vkGetPhysicalDeviceSurfaceFormatsKHR
    vkGetPhysicalDeviceSurfacePresentModesKHR
    vkCreateSwapchainKHR
    vkDestroySwapchainKHR
    vkCreateDebugReportCallbackEXT
    vkDestroyDebugReportCallbackEXT