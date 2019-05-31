import strutils
import sequtils
import sugar
import macros
import sdl2/[sdl, sdl_syswm]
import logging
import vulkan as vk except vkCreateDebugReportCallbackEXT, vkDestroyDebugReportCallbackEXT

proc getVulkanProcAddrGetterProc(): PFN_vkGetInstanceProcAddr {.inline.} = cast[PFN_vkGetInstanceProcAddr](vulkanGetVkGetInstanceProcAddr())

proc loadVulkanProc[ProcType](procGetter: PFN_vkGetInstanceProcAddr, fnName: string): ProcType {.inline.} =
    let getterProc = procGetter(cast[vk.VkInstance](nil), fnName)
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
                    , newStrLitNode($ident)
                )
            )
        )

    var loadProc = newProc(postfix(newIdentNode($loaderName), "*"), [newEmptyNode()], loadProcBody)

    result = newStmtList(fnDeclarations, loadProc)

generateVulkanAPILoader "loadVulkanAPI":
    vkCreateInstance
    vkDestroyInstance
    vkEnumeratePhysicalDevices
    vkGetPhysicalDeviceFeatures
    vkGetPhysicalDeviceFormatProperties
    vkGetPhysicalDeviceImageFormatProperties
    vkGetPhysicalDeviceProperties
    vkGetPhysicalDeviceQueueFamilyProperties
    vkGetPhysicalDeviceMemoryProperties
    vkGetInstanceProcAddr
    vkGetDeviceProcAddr
    vkCreateDevice
    vkDestroyDevice
    vkEnumerateInstanceExtensionProperties
    vkEnumerateDeviceExtensionProperties
    vkEnumerateInstanceLayerProperties
    vkEnumerateDeviceLayerProperties
    vkGetDeviceQueue
    vkQueueSubmit
    vkQueueWaitIdle
    vkDeviceWaitIdle
    vkAllocateMemory
    vkFreeMemory
    vkMapMemory
    vkUnmapMemory
    vkFlushMappedMemoryRanges
    vkInvalidateMappedMemoryRanges
    vkGetDeviceMemoryCommitment
    vkBindBufferMemory
    vkBindImageMemory
    vkGetBufferMemoryRequirements
    vkGetImageMemoryRequirements
    vkGetImageSparseMemoryRequirements
    vkGetPhysicalDeviceSparseImageFormatProperties
    vkQueueBindSparse
    vkCreateFence
    vkDestroyFence
    vkResetFences
    vkGetFenceStatus
    vkWaitForFences
    vkCreateSemaphore
    vkDestroySemaphore
    vkCreateEvent
    vkDestroyEvent
    vkGetEventStatus
    vkSetEvent
    vkResetEvent
    vkCreateQueryPool
    vkDestroyQueryPool
    vkGetQueryPoolResults
    vkCreateBuffer
    vkDestroyBuffer
    vkCreateBufferView
    vkDestroyBufferView
    vkCreateImage
    vkDestroyImage
    vkGetImageSubresourceLayout
    vkCreateImageView
    vkDestroyImageView
    vkCreateShaderModule
    vkDestroyShaderModule
    vkCreatePipelineCache
    vkDestroyPipelineCache
    vkGetPipelineCacheData
    vkMergePipelineCaches
    vkCreateGraphicsPipelines
    vkCreateComputePipelines
    vkDestroyPipeline
    vkCreatePipelineLayout
    vkDestroyPipelineLayout
    vkCreateSampler
    vkDestroySampler
    vkCreateDescriptorSetLayout
    vkDestroyDescriptorSetLayout
    vkCreateDescriptorPool
    vkDestroyDescriptorPool
    vkResetDescriptorPool
    vkAllocateDescriptorSets
    vkFreeDescriptorSets
    vkUpdateDescriptorSets
    vkCreateFramebuffer
    vkDestroyFramebuffer
    vkCreateRenderPass
    vkDestroyRenderPass
    vkGetRenderAreaGranularity
    vkCreateCommandPool
    vkDestroyCommandPool
    vkResetCommandPool
    vkAllocateCommandBuffers
    vkFreeCommandBuffers
    vkBeginCommandBuffer
    vkEndCommandBuffer
    vkResetCommandBuffer
    vkCmdBindPipeline
    vkCmdSetViewport
    vkCmdSetScissor
    vkCmdSetLineWidth
    vkCmdSetDepthBias
    vkCmdSetBlendConstants
    vkCmdSetDepthBounds
    vkCmdSetStencilCompareMask
    vkCmdSetStencilWriteMask
    vkCmdSetStencilReference
    vkCmdBindDescriptorSets
    vkCmdBindIndexBuffer
    vkCmdBindVertexBuffers
    vkCmdDraw
    vkCmdDrawIndexed
    vkCmdDrawIndirect
    vkCmdDrawIndexedIndirect
    vkCmdDispatch
    vkCmdDispatchIndirect
    vkCmdCopyBuffer
    vkCmdCopyImage
    vkCmdBlitImage
    vkCmdCopyBufferToImage
    vkCmdCopyImageToBuffer
    vkCmdUpdateBuffer
    vkCmdFillBuffer
    vkCmdClearColorImage
    vkCmdClearDepthStencilImage
    vkCmdClearAttachments
    vkCmdResolveImage
    vkCmdSetEvent
    vkCmdResetEvent
    vkCmdWaitEvents
    vkCmdPipelineBarrier
    vkCmdBeginQuery
    vkCmdEndQuery
    vkCmdResetQueryPool
    vkCmdWriteTimestamp
    vkCmdCopyQueryPoolResults
    vkCmdPushConstants
    vkCmdBeginRenderPass
    vkCmdNextSubpass
    vkCmdEndRenderPass
    vkCmdExecuteCommands