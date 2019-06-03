import strutils
import sequtils
import sugar
import macros
import sdl2/[sdl, sdl_syswm]
import logging
import vulkan as vk except vkCreateDebugReportCallbackEXT, vkDestroyDebugReportCallbackEXT

proc getVulkanProcAddrGetterProc(): PFN_vkGetInstanceProcAddr {.inline.} = cast[PFN_vkGetInstanceProcAddr](vulkanGetVkGetInstanceProcAddr())

proc loadVulkanProc[ProcType](procGetter: PFN_vkGetInstanceProcAddr, vulkanInstance: vk.VkInstance, fnName: string): ProcType {.inline.} =
    let getterProc = procGetter(vulkanInstance, fnName)
    result = cast[ProcType](getterProc)
    vkCheck result != nil, "Failed to load $# function!".format(fnName)

macro generateVulkanAPILoader(loaderName: string, usedFunctions: untyped): untyped =
    var fnDeclarations = newNimNode(nnkVarSection)
    for ident in usedFunctions:
        ident.expectKind(nnkIdent)
        let identType = "PFN_" & $ident
        let fnDecl = newIdentDefs(postfix(ident, "*"), newIdentNode(identType))
        fnDeclarations.add(fnDecl)
    
    var loadProcBody = newStmtList();
    loadProcBody.add(newLetStmt(newIdentNode("getVkProc"), newCall(newIdentNode("getVulkanProcAddrGetterProc"))))
    for ident in usedFunctions:
        loadProcBody.add(
            newAssignment(
                ident
                , newCall(
                    newNimNode(nnkBracketExpr)
                        .add(newIdentNode("loadVulkanProc"))
                        .add(newIdentNode("PFN_" & $ident))
                    , newIdentNode("getVkProc")
                    , newIdentNode("vulkanInstance")
                    , newStrLitNode($ident)
                )
            )
        )
    let vulkanInstanceParameter = newIdentDefs(newIdentNode("vulkanInstance"), newDotExpr(newIdentNode("vk"), newIdentNode("VkInstance")))
    var loadProc = newProc(postfix(newIdentNode($loaderName), "*"), [newEmptyNode(), vulkanInstanceParameter], loadProcBody)

    result = newStmtList(fnDeclarations, loadProc)

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