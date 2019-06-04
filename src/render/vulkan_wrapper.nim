import strutils
import sequtils
import sugar
import macros
import sdl2/sdl except VkInstance
import ../log
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
        doAssert(fn.kind() == nnkIdent or fn.kind() == nnkCall)

        let
            fnHasCustomName = fn.kind() == nnkCall
            fnIdent = if fnHasCustomName: fn[1][0] else: fn
            fnCName = if fnHasCustomName: toStrLit(fn[0]) else: toStrLit(fnIdent)
            fnName = toStrLit(fnIdent)
            fnType = ident("PFN_$#".format($fnCName))
        
        fnDeclarations.add quote do:
            var `fnIdent`*: `fnType`
        
        fnLoadingCode.add quote do:
            `fnIdent` = loadVulkanProc[`fnType`](`fnLoaderIdent`, `vkInstanceParamIdent`, `fnCName`)
            vkCheck `fnIdent` != nil, "Failed to load $# function!".format(`fnCName`)
    
    var loaderFnDecl = quote do:
        proc `apiLoaderFnIdent`*(`vkInstanceParamIdent`: vk.VkInstance) = `fnLoadingCode`

    newStmtList fnDeclarations, loaderFnDecl

generateVulkanAPILoader "loadVulkanAPI":
    vkCreateInstance
    vkEnumerateInstanceLayerProperties: vkEnumerateInstanceLayerPropertiesRaw
    vkEnumerateInstanceExtensionProperties: vkEnumerateInstanceExtensionPropertiesRaw

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

# proc vkEnumerateInstanceLayerPropertiesWrapper(): seq[VkLayerProperties] =
#     var vkLayerCount: uint32
#     vkCheck vkEnumerateInstanceLayerProperties(addr vkLayerCount, nil)
#     result.setLen(vkLayerCount)
#     vkCheck vkEnumerateInstanceLayerProperties(addr vkLayerCount, addr result[0])

# proc vkEnumerateInstanceExtensionPropertiesWrapper(layerName: cstring): seq[VkExtensionProperties] =
#     var vkExtensionCount: uint32
#     vkCheck vkEnumerateInstanceExtensionProperties(layerName, addr vkExtensionCount, nil)
#     result.setLen(vkExtensionCount)
#     vkCheck vkEnumerateInstanceExtensionProperties(layerName, addr vkExtensionCount, addr result[0])

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
    echo treeRepr(fnDecl)
    fnDecl

generateVulkanArrayGetterWrapper vkEnumerateInstanceLayerPropertiesRaw, vkEnumerateInstanceLayerProperties, VkLayerProperties
generateVulkanArrayGetterWrapper vkEnumerateInstanceExtensionPropertiesRaw, vkEnumerateInstanceExtensionProperties, VkExtensionProperties:
    pLayerName: cstring
