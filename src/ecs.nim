import strformat
import glm
import utility
import log
import render/render_vk

const
    MAX_ENTITIES = 5000
    NO_COMPONENTS_MASK          = 0
    TRANSFORM_COMPONENT_ID      = 1 shl 0
    SPRITE_COMPONENT_ID         = 1 shl 1

type
    Entity* = int
    ComponentMask* = uint64
    TransformComponent* = object
        position*: Vec2f
    SpriteComponent* = object
        dimensions*: Vec2f
        minUV*, maxUV*: Vec2f
        texture*: RdTexture
        tint*: RdColorF32
        order*: uint8
    ComponentArray*[T] = array[MAX_ENTITIES, T]
    World* = object
        entityMasks: ComponentArray[ComponentMask]
        transformComponents: ComponentArray[TransformComponent]
        spriteComponents: ComponentArray[SpriteComponent]

proc addEntity*(world: var World, componentMask: ComponentMask): Entity =
    for i, entityMask in world.entityMasks:
        if entityMask == NO_COMPONENTS_MASK:
            world.entityMasks[i] = componentMask
            return i
    
    check false, &"Max number of {MAX_ENTITIES} is exceded!"

proc setEntityComponentData*(world: var World, entity: Entity, transform: TransformComponent) =
    check maskCheck(world.entityMasks[entity], TRANSFORM_COMPONENT_ID)
    world.transformComponents[entity] = transform

proc setEntityComponentData*(world: var World, entity: Entity, sprite: SpriteComponent) =
    check maskCheck(world.entityMasks[entity], SPRITE_COMPONENT_ID)
    world.spriteComponents[entity] = sprite

proc addEntity*(world: var World, transform: TransformComponent, sprite: SpriteComponent): Entity =
    let entity = addEntity(world, maskCombine(TRANSFORM_COMPONENT_ID, SPRITE_COMPONENT_ID))
    setEntityComponentData(world, entity, transform)
    setEntityComponentData(world, entity, sprite)

proc spriteRenderSystem*(world: World): seq[RdSpriteRenderRequest] =
    let queryMask = maskCombine(TRANSFORM_COMPONENT_ID, SPRITE_COMPONENT_ID)
    for i, entityMask in world.entityMasks:
        if maskCheck(entityMask, queryMask):
            let
                transform = world.transformComponents[i]
                sprite = world.spriteComponents[i]
            result.add RdSpriteRenderRequest(
                x: transform.position.x, y: transform.position.y
                , w: sprite.dimensions.x, h: sprite.dimensions.y
                , minUV: sprite.minUV, maxUV: sprite.maxUV
                , texture: sprite.texture
                , tint: sprite.tint
                , order: sprite.order
            )
