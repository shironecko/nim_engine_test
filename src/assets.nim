import strformat
import log
import utility
import glm
import render/render_vk
import sdl2
import sdl2/image as img

type 
    Font* = object
        id: int
    
    FontData = object
        texture: RdTexture
        textureWidth, textureHeight: uint32
        cellWidth, cellHeight: uint32
        baseCharacter: uint8
    FontRegistry* = object
        fonts: seq[FontData]

proc asLoadBitmapFont*(path: string, fontRegistry: var FontRegistry, renderContext: var RdContext): Font =
    type
        BitmapFontHeader {.packed.} = object
            signatureBytes: array[2, uint8]
            width, height: uint32
            cellWidth, cellHeight: uint32
            bitsPerPixel: uint8
            baseCharacter: uint8
            characterWidth: array[256, uint8]
    
    var
        fontContents = readBinaryFile(path)
        fontHeader = cast[ptr BitmapFontHeader](addr fontContents[0])
        fontPixelsData = cast[ptr UncheckedArray[uint8]](addr fontContents[sizeof(BitmapFontHeader)])
        pixelCount = int fontHeader.width * fontHeader.height
    
    check fontHeader.signatureBytes[0] == 0xBF'u8 and fontHeader.signatureBytes[1] == 0xF2'u8, "Debug font file header signature mismatch!"
    check fontHeader.bitsPerPixel == 32, &"Debug font file bitness per pixel mismant! Expected: 32, Got: {fontHeader.bitsPerPixel}"

    type
        FontTexturePixel {.packed.} = object
            r, g, b, a: uint8
    
    let expectedFontFileSize = sizeof(fontHeader) + pixelCount * sizeof(FontTexturePixel)
    #check fontContents.len() == expectedFontFileSize, &"Font file size mismatch! Expected: {expectedFontFileSize} Actual: {fontContents.len()}"

    var fontData = FontData(
        textureWidth: fontHeader.width
        , textureHeight: fontHeader.height
        , cellWidth: fontHeader.cellWidth
        , cellHeight: fontHeader.cellHeight
        , baseCharacter: fontHeader.baseCharacter
    )

    var rawImageData = RdRawImageData(
        width: fontHeader.width
        , height: fontHeader.height
        , format: RdRawImageFormat.RGBAFloat32
        , pixelsRGBAFloat32: newSeq[RdRawImagePixelRGBAFloat32](pixelCount)
    )
    
    let fontPixels = cast[ptr UncheckedArray[FontTexturePixel]](addr fontPixelsData[0])
    for i in 0..<pixelCount:
        let fontPixel = fontPixels[i]
        rawImageData.pixelsRGBAFloat32[i] = RdRawImagePixelRGBAFloat32(
            r: float32(fontPixel.r) / 256.0'f32
            , g: float32(fontPixel.g) / 256.0'f32
            , b: float32(fontPixel.b) / 256.0'f32
            , a: float32(fontPixel.a) / 256.0'f32
        )
    fontData.texture = rdCreateTexture(renderContext, rawImageData)
    fontRegistry.fonts.add(fontData)

    Font(id: fontRegistry.fonts.len() - 1)

# TODO: move font stuff somewhere
proc asRenderText*(text: string, x, y: float32, order: uint8, tint: RdColorF32, font: Font, fontRegistry: FontRegistry, renderList: var RdRenderList) =
    var 
        fontData = fontRegistry.fonts[font.id]
        cellsPerRow = uint32(float32(fontData.textureWidth) / float32(fontData.cellWidth))
        glyphPos = vec2f(x, y)
    for glyph in text:
        if glyph == '\n':
            glyphPos.x = x
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
        
        renderList.sprites.add(RdSpriteRenderRequest(
            x: glyphPos.x
            , y: glyphPos.y
            , w: float32 fontData.cellWidth
            , h: float32 fontData.cellHeight
            , minUV: glyphMinUV
            , maxUV: glyphMinUV + cellUV
            , texture: fontData.texture
            , order: order
            , tint: tint
        ))
        glyphPos.x += float32 fontData.cellWidth

proc asLoadColorTexture*(path: string, renderContext: var RdContext): RdTexture =
    var
        surface = img.load(path)
        rawImageData = RdRawImageData(
            width: uint32 surface.w
            , height: uint32 surface.h
            , format: RdRawImageFormat.RGBAFloat32
            , pixelsRGBAFloat32: newSeq[RdRawImagePixelRGBAFloat32](surface.w * surface.h)
        )
    
    if surface.format.format != SDL_PIXELFORMAT_RGBA8888:
        var tempPtr = convertSurfaceFormat(surface, SDL_PIXELFORMAT_RGBA8888, 0)
        freeSurface(surface)
        surface = tempPtr
    
    # TODO: implement more robust convertion using color masks?
    type
        SurfacePixel {.packed.} = object
            a: uint8
            b: uint8
            g: uint8
            r: uint8
    
    for y in 0..<surface.h:
        for x in 0..<surface.w:
            let 
                pixelOffset = x * 4 + y * surface.pitch
                pixelsAsBytesArray = cast[ptr UncheckedArray[uint8]](surface.pixels)
                surfacePixel = cast[ptr SurfacePixel](addr pixelsAsBytesArray[pixelOffset])
            rawImageData.pixelsRGBAFloat32[x + y * surface.w] = RdRawImagePixelRGBAFloat32(
                r: float32(surfacePixel.r) / 256.0'f32
                , g: float32(surfacePixel.g) / 256.0'f32
                , b: float32(surfacePixel.b) / 256.0'f32
                , a: float32(surfacePixel.a) / 256.0'f32
            )
    
    freeSurface(surface)
    rdCreateTexture(renderContext, rawImageData)