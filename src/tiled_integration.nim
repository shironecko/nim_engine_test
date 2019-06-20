import os
import utility
import strformat
import ecs
import glm
import nimPNG
import nim_tiled
import render/render_vk
import assets

proc tileRegionToUV(region: TiledRegion, textureWidth, textureHeight: int): (Vec2f, Vec2f) =
    let
        minUV = vec2f(
            mapToRange32(region.x, 0, textureWidth)
            , mapToRange32(region.y, 0, textureHeight)
        )
        maxUV = vec2f(
            mapToRange32(region.x + region.width, 0, textureWidth)
            , mapToRange32(region.y + region.height, 0, textureHeight)
        )
    (minUV, maxUV)

proc loadMapIntoWorld*(path: string, world: var World, renderContext: var RdContext) =
    let
        map = loadTiledMap(path)
        tileset = map.tilesets[0]
        tilesetTexture = asLoadColorTexture(
            splitFile(path).dir / tileset.imagePath
            , renderContext
        )
    
    for i, layer in map.layers:
        for y in 0..<layer.height:
            for x in 0..<layer.width:
                let
                    tileDimensions = vec2f(float32 map.tileWidth, float32 map.tileHeight)
                    tileWorldPosition = vec2f(
                        float32(x) * tileDimensions.x
                        , float32(y) * tileDimensions.y
                    )
                    tileIndex = x + y * layer.width
                    tilesetIndex = layer.tiles[tileIndex]
                
                if tilesetIndex != 0:
                    let
                        tileRegion = tileset.regions[tilesetIndex - 1]
                        (minUV, maxUV) = tileRegionToUV(tileRegion, tileset.width, tileset.height)
                    
                    discard addEntity(
                        world
                        , TransformComponent(position: tileWorldPosition)
                        , SpriteComponent(
                            dimensions: tileDimensions
                            , minUV: minUV
                            , maxUV: maxUV
                            , texture: tilesetTexture
                            , tint: WHITE
                            , order: uint8 i
                        )
                    )
