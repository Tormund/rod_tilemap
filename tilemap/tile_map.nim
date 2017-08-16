import rod / [ component, node, viewport, rod_types ]
import rod / component / [ sprite, camera ]
import rod / tools / [ serializer, debug_draw ]
import nimx / [ types, property_visitor, matrixes, portable_gl, context, image, resource,
                render_to_image ]

import json, tables, strutils, logging, sequtils, algorithm, math
import nimx.assets.asset_loading
import boolseq
import rect_packer
import opengl

type
    LayerRange* = tuple
        minx, maxx: int
        miny, maxy: int

    PropertyType* = enum
        lptString = "string"
        lptFloat = "float"
        lptInt = "int"
        lptBool = "bool"
        lptColor = "color"
        lptFile = "file"

    Property* = ref object
        case kind*: PropertyType:
            of lptString:
                strVal*: string
            of lptFloat:
                floatVal*: float
            of lptInt:
                intVal*: int
            of lptBool:
                boolVal*: bool
            of lptColor:
                colorVal*: Color
            of lptFile:
                fileVal*: string

    Properties* = TableRef[string, Property]

    TileMapPropertyType* = enum
        tmlptLayer
        tmlptTileset
        tmlptTile

    TileMapProperty* = object
        property*: Property
        case kind*: TileMapPropertyType:
            of tmlptLayer:
                layer*: BaseTileMapLayer
            of tmlptTileset:
                tileset*: BaseTileSet
            of tmlptTile:
                tid*: int16

    TileMapPropertyCollection = object
        collection: seq[TileMapProperty]

    BaseTileMapLayer* = ref object of Component
        size: Size
        offset*: Size
        actualSize*: LayerRange
        map*: TileMap
        properties*: Properties

    TileMapLayer* = ref object of BaseTileMapLayer
        data*: seq[int16]
        tileSize: Vector3

    ImageMapLayer* = ref object of BaseTileMapLayer
        image*: Image

    NodeMapLayer* = ref object of BaseTileMapLayer
        bbox: BBox
        isBBoxCalculated: bool

    BaseTileSet = ref object of RootObj
        tileSize: Vector3
        firstGid: int
        tilesCount: int
        name: string
        properties*: Properties

    TileSheet = ref object of BaseTileSet
        sheet: Image
        columns: int

    TileCollection = ref object of BaseTileSet
        collection: seq[tuple[image: Image, properties: Properties]]

    TileMapOrientation* {.pure.}= enum
        orthogonal
        isometric
        staggeredX
        staggeredY
        hexagonal

    DrawingRow = object
        vertexBuffer: BufferRef
        vboLayerBreaks: seq[int]

        objects: seq[Node]
        objectLayerBreaks: seq[int]
        bbox: BBox

    DebugRenderData = object
        rect: Rect
        text: string
        nodeCount: int

    TileMap* = ref object of Component
        mapSize*: Size
        tileSize*: Vector3
        layers: seq[BaseTileMapLayer]
        tileSets: seq[BaseTileSet]
        tileDrawRect: proc(tm: TileMap, pos: int, tr: var Rect)
        mQuadIndexBuffer: BufferRef
        maxQuadsInRun: int
        quadBufferLen: int
        mProgram: ProgramRef
        mTilesSpriteSheet: SelfContainedImage
        enabledLayers: BoolSeq

        tileVCoords: Table[int16, array[16, float32]]
        properties: Table[string, TileMapPropertyCollection]

        drawingRows: seq[DrawingRow]

        case mOrientation: TileMapOrientation
        of TileMapOrientation.staggeredX, TileMapOrientation.staggeredY:
            isStaggerIndexOdd: bool
        else: discard

        debugObjects: seq[DebugRenderData]
        debugMaxNodes: int

    TidAndImage = tuple[image: Image, tid: int16]


proc newNodeMapLayer*(node: Node, map: TileMap, size: Size = zeroSize, offset: Size = zeroSize, actualSize: LayerRange = (0, 0, 0, 0)): NodeMapLayer =
    NodeMapLayer(
        size: size,
        offset: offset,
        actualSize: actualSize,
        map: map,
        node: node
    )

proc newProperty(kind: PropertyType, value: JsonNode): Property =
    case kind:
        of lptString:
            result = Property(kind: lptString, strVal: value.getStr())
        of lptFloat:
            result = Property(kind: lptFloat, floatVal: value.getFNum())
        of lptInt:
            result = Property(kind: lptInt, intVal: value.getNum().int)
        of lptBool:
            result = Property(kind: lptBool, boolVal: value.getBVal())
        of lptColor:
            let color = value.getStr()
            let a = color[1..2].parseHexInt().float / 255.0
            let r = color[3..4].parseHexInt().float
            let g = color[5..6].parseHexInt().float
            let b = color[7..8].parseHexInt().float
            result = Property(kind: lptColor, colorVal: newColor(r, g, b, a))
        of lptFile:
            result = Property(kind: lptFile, fileVal: value.getStr())


const vertexShader = """
attribute vec4 aPosition;
uniform mat4 uModelViewProjectionMatrix;
varying vec2 vTexCoord;

void main() {
    vTexCoord = aPosition.zw;
    gl_Position = uModelViewProjectionMatrix * vec4(aPosition.xy, 0, 1);
}
"""

const fragmentShader = """
#ifdef GL_ES
#extension GL_OES_standard_derivatives : enable
precision mediump float;
#endif

varying vec2 vTexCoord;
uniform sampler2D texUnit;
uniform float uAlpha;

void main() {
    gl_FragColor = texture2D(texUnit, vTexCoord);
    float a = gl_FragColor.a;
    a = clamp(step(0.49, gl_FragColor.a) + a, 0.0, 1.0);
    gl_FragColor.a = a * uAlpha;
}
"""

proc rebuildAllRowsIfNeeded(tm: TileMap)

method init*(tm: TileMap) =
    procCall tm.Component.init()
    tm.drawingRows = @[]
    tm.properties = initTable[string, TileMapPropertyCollection]()

proc position*(l: BaseTileMapLayer): Vector3=
    return l.node.position

proc alpha*(l: BaseTileMapLayer): float=
    return l.node.alpha

proc enabled*(l: BaseTileMapLayer): bool=
    return l.node.enabled

proc `enabled=`*(l: BaseTileMapLayer, v: bool) =
    l.node.enabled = v

proc name*(l: BaseTileMapLayer): string =
    return l.node.name

proc layerSize(l: TileMapLayer): Size=
    return newSize((l.actualSize.maxx - l.actualSize.minx).float, (l.actualSize.maxy - l.actualSize.miny).float)

proc layerRect(tm: TileMap, l: TileMapLayer): Rect =
    let layerSize = l.layerSize
    case tm.mOrientation:
    of TileMapOrientation.orthogonal:
        result = newRect(l.position.x, l.position.y, layerSize.width * l.tileSize.x, layerSize.height * l.tileSize.y)

    of TileMapOrientation.isometric:
        let
            width = (layerSize.width + layerSize.height) * l.tileSize.x * 0.5
            height = (layerSize.width + layerSize.height) * l.tileSize.y * 0.5
        result = newRect(l.position.x, l.position.y, width, height)

    of TileMapOrientation.staggeredX:
        result.origin = newPoint(l.position.x, l.position.y)
        result.size = newSize(l.tileSize.x * (layerSize.width / 2.0 + 0.5), l.tileSize.y * (layerSize.height + 0.5))

    of TileMapOrientation.staggeredY:
        result.origin = newPoint(l.position.x, l.position.y)
        result.size = newSize(l.tileSize.x * (layerSize.width + 0.5), l.tileSize.y * (layerSize.height / 2.0 + 0.5))

    else:
        discard

proc getViewportRect(l: TileMapLayer): Rect=
    if not l.node.sceneView.isNil:
        let camera = l.node.sceneView.camera
        result.size = camera.viewportSize * camera.node.scale.x
        result.origin = newPoint(camera.node.worldPos().x, camera.node.worldPos().y)
        result.origin.x = result.origin.x - camera.viewportSize.width  * 0.5 * camera.node.scale.x
        result.origin.y = result.origin.y - camera.viewportSize.height * 0.5 * camera.node.scale.y

proc getDrawRange(layer: TileMapLayer, r: Rect, ts: Vector3): LayerRange =
    let layerLen = layer.data.len
    result.miny = (r.x / ts.x).int
    result.maxy = ((r.x + r.width) / (ts.x * 0.5)).int

    result.minx = (r.y / ts.y).int
    result.maxx = ((r.y + r.height) / ts.y).int


proc layerIndex*(tm: TileMap, sla: BaseTileMapLayer): int =
    result = -1
    for i, la in tm.layers:
        if sla == la:
            return i


proc layerIndexByName*(tm: TileMap, name: string): int =
    result = -1
    for i, l in tm.layers:
        if l.name == name:
            return i

proc insertLayer*(tm: TileMap, layerNode: Node, idx: int) =
    var layer = layerNode.componentIfAvailable(TileMapLayer).BaseTileMapLayer
    if layer.isNil:
        layer = layerNode.componentIfAvailable(ImageMapLayer).BaseTileMapLayer
    if layer.isNil:
        layer = layerNode.componentIfAvailable(NodeMapLayer).BaseTileMapLayer
    if layer.isNil:
        layer = newNodeMapLayer(layerNode, tm)

    if not layer.isNil:
        layer.map = tm
        if layer of TileMapLayer:
            layer.TileMapLayer.tileSize = tm.tileSize

        tm.node.insertChild(layerNode, idx)
        tm.layers.insert(layer, idx)
        if tm.drawingRows.len > 0:
            tm.rebuildAllRowsIfNeeded()

proc addLayer*(tm: TileMap, layerNode: Node, )=
    tm.insertLayer(layerNode, tm.layers.len)

proc layerByName*[T](tm: TileMap, name: string): T =
    for l in tm.layers:
        if l.name == name and l of T:
            return l.T

proc tileXYAtIndex*(layer: TileMapLayer, idx: int): tuple[x:int, y:int]=
    let width = layer.actualSize.maxx - layer.actualSize.minx
    result.x = idx mod width + layer.actualSize.minx
    result.y = idx div width + layer.actualSize.miny

proc tileIndexAtXY*(layer: TileMapLayer, x, y: int): int=
    result = -1
    if (x >= layer.actualSize.minx and x < layer.actualSize.maxx) and (y >= layer.actualSize.miny and y < layer.actualSize.maxy):

        let idx = (layer.actualSize.maxx - layer.actualSize.minx) * (y - layer.actualSize.miny) + (x - layer.actualSize.minx)
        if idx < layer.data.len:
            result = idx

proc tileAtXY*(layer: TileMapLayer, x, y: int): int=
    let idx = layer.tileIndexAtXY(x, y)
    if idx != -1:
        result = layer.data[idx]

proc positionAtTileXY*(tm: TileMap, col, row: int): Vector3 =
    newVector3(col.float * tm.tileSize.x / 2.0, ((col mod 2).float / 2.0 + row.float + 0.5) * tm.tileSize.y, 0.0)

proc tileXYAtPosition*(layer: TileMapLayer, position: Vector3): tuple[x:int, y:int]=
    var tileWidth = layer.tileSize.x
    var tileHeight = layer.tileSize.y

    let tm = layer.map
    case tm.mOrientation:
    of TileMapOrientation.staggeredX:
        let offset = if tm.isStaggerIndexOdd: 0.0 else: 0.5

        var x = position.x / tileWidth
        var y = position.y / tileHeight
        var cx = x - x.int.float + offset
        var cy = y - y.int.float

        let tileCoof = tileHeight / tileWidth
        let topleft  = cx + cy >= tileCoof
        let topright = cx - cy <= tileCoof
        let botleft  = cy - cx <= tileCoof
        let botright = cx + cy <= 1.0 + tileCoof

        x = (x.int * 2).float

        if not topleft:
            y -= 1.0
            x -= 1.0

        if not botleft:
            x -= 1.0

        if not topright:
            y -= 1.0
            x += 1.0

        if not botright:
            x += 1.0

        result.x = x.int
        result.y = y.int

    else:
        result.x = (position.x / tileWidth).int
        result.y = (position.y / tileHeight).int


proc tileIndexAtPosition*(layer: TileMapLayer, position: Vector3): int=
    let coords = layer.tileXYAtPosition(position)
    result = layer.tileIndexAtXY(coords.x, coords.y)

proc tileAtPosition*(layer: TileMapLayer, position: Vector3): int=
    let coords = layer.tileXYAtPosition(position)
    result = layer.tileAtXY(coords.x, coords.y)

proc tilesAtPosition*(tm: TileMap, position: Vector3): seq[int]=
    result = @[]
    for l in tm.layers:
        if l of TileMapLayer:
            result.add(l.TileMapLayer.tileAtPosition(position))

proc visibleTilesAtPosition*(tm: TileMap, position: Vector3): seq[int]=
    result = @[]
    for l in tm.layers:
        if l of TileMapLayer and l.enabled:
            let r = l.TileMapLayer.tileAtPosition(position)
            if r != 0:
                result.add(r)

proc visibleTilesAtPositionDebugInfo*(tm: TileMap, position: Vector3): seq[tuple[layerName: string, x: int, y: int, tileid: int, index: int]]=
    result = @[]
    for l in tm.layers:
        if l of TileMapLayer and l.enabled:
            let coords = l.TileMapLayer.tileXYAtPosition(newVector3(position.x - l.offset.width, position.y - l.offset.height))
            let tileid = l.TileMapLayer.tileAtXY(coords.x, coords.y)
            let index =  l.TileMapLayer.tileIndexAtXY(coords.x, coords.y)
            if tileid != 0:
                result.add((layerName: l.name, x: coords.x, y: coords.y, tileid: tileid, index: index))

proc layerIntersectsAtPositionWithPropertyName*(tm: TileMap, position: Vector3, prop:string): seq[BaseTileMapLayer]=
    result = @[]
    for l in tm.layers:
        if not l.properties.isNil and prop in l.properties:
            if l of TileMapLayer:
                let coords = l.TileMapLayer.tileXYAtPosition(newVector3(position.x - l.offset.width, position.y - l.offset.height))
                let tileid = l.TileMapLayer.tileAtXY(coords.x, coords.y)
                let index =  l.TileMapLayer.tileIndexAtXY(coords.x, coords.y)
                if tileid != 0:
                    result.add(l)

            # elif l of ImageMapLayer: # todo: implement raycasting for images by alpha
            #     let img = l.ImageMapLayer.image
            #     let pos = l.node.position
            #     let r = newRect(pos.x, pos.y, img.size.width, img.size.height)
            #     if r.contains(newPoint(position.x, position.y)):
            #         result.add(l)

proc quadIndexBuffer(tm: TileMap): BufferRef =
    if tm.maxQuadsInRun > tm.quadBufferLen:
        let c = currentContext()
        if tm.mQuadIndexBuffer != invalidBuffer:
            c.gl.deleteBuffer(tm.mQuadIndexBuffer)
        tm.mQuadIndexBuffer = c.createQuadIndexBuffer(tm.maxQuadsInRun)
        tm.quadBufferLen = tm.maxQuadsInRun
    result = tm.mQuadIndexBuffer

proc program(tm: TileMap): ProgramRef =
    if tm.mProgram == invalidProgram:
        let c = currentContext()
        tm.mProgram = c.gl.newShaderProgram(vertexShader, fragmentShader, { 0.GLuint: "aPosition"} )
    result = tm.mProgram

proc prepareVBOs(tm: TileMap) =
    let c = currentContext()
    let gl = c.gl
    let program = tm.program
    gl.useProgram(program)

    gl.activeTexture(gl.TEXTURE0)
    gl.uniform1i(gl.getUniformLocation(program, "texUnit"), 0)
    gl.uniform1f(gl.getUniformLocation(tm.program, "uAlpha"), 1.0)
    gl.uniformMatrix4fv(gl.getUniformLocation(tm.program, "uModelViewProjectionMatrix"), false, c.transform)

    var quad: array[4, float32]
    let tex = tm.mTilesSpriteSheet.getTextureQuad(gl, quad)

    gl.bindTexture(gl.TEXTURE_2D, tex)

    gl.enableVertexAttribArray(saPosition.GLuint)
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, tm.quadIndexBuffer)

# =================== BBox logic ==================
proc hasDimension*(bb: BBox): bool =
    let diff = bb.maxPoint - bb.minPoint
    if abs(diff.x) > 0 or abs(diff.y) > 0:
        return true

proc minVector(a,b: Vector3):Vector3=
    result = newVector3(min(a.x, b.x), min(a.y, b.y), min(a.z, b.z))

proc maxVector(a,b:Vector3):Vector3=
    result = newVector3(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z))

proc getBBox(n: Node): BBox =
    var index = 0
    # get start point
    for i, comp in n.components:
        let bb = comp.getBBox()

        if bb.hasDimension():
            result.minPoint = bb.minPoint
            result.maxPoint = bb.maxPoint
            index = i + 1
            break

    while index < n.components.len:
        let comp = n.components[index]
        index.inc()

        let bb = comp.getBBox()
        if bb.hasDimension():
            result.minPoint = minVector(result.minPoint, bb.minPoint)
            result.maxPoint = maxVector(result.maxPoint, bb.maxPoint)

proc nodeBounds2d(n: Node, minP: var Vector3, maxP: var Vector3) =
    let wrldMat = n.worldTransform()
    var wp0, wp1, wp2, wp3: Vector3

    let bb = n.getBBox()
    if bb.hasDimension:
        wp0 = wrldMat * bb.minPoint
        wp1 = wrldMat * newVector3(bb.minPoint.x, bb.maxPoint.y, 0.0)
        wp2 = wrldMat * bb.maxPoint
        wp3 = wrldMat * newVector3(bb.maxPoint.x, bb.minPoint.y, 0.0)

        minP = minVector(minP, wp0)
        minP = minVector(minP, wp1)
        minP = minVector(minP, wp2)
        minP = minVector(minP, wp3)

        maxP = maxVector(maxP, wp0)
        maxP = maxVector(maxP, wp1)
        maxP = maxVector(maxP, wp2)
        maxP = maxVector(maxP, wp3)

    for ch in n.children:
        ch.nodeBounds2d(minP, maxP)

const absMinPoint = newVector3(high(int).Coord, high(int).Coord, high(int).Coord)
const absMaxPoint = newVector3(low(int).Coord, low(int).Coord, low(int).Coord)

proc nodeBounds(n: Node): BBox=
    var minP = absMinPoint
    var maxP = absMaxPoint
    n.nodeBounds2d(minP, maxP)
    if minP != absMinPoint and maxP != absMaxPoint:
        result.minPoint = minP
        result.maxPoint = maxP

proc getBBox(ml: NodeMapLayer): BBox =
    if not ml.isBBoxCalculated:
        ml.bbox = ml.node.nodeBounds()
        ml.isBBoxCalculated = true

    result = ml.bbox

proc getNodeCount(ml: NodeMapLayer): int =
    proc recursiveChildrenCount(n: Node, count: var int) =
        if not n.children.isNil:
            count += n.children.len()

            for c in n.children:
                c.recursiveChildrenCount(count)

    result = 1
    ml.node.recursiveChildrenCount(result)

proc getBBox(dr: DrawingRow): BBox =
    for n in dr.objects:
        result.minPoint = minVector(result.minPoint, n.nodeBounds().minPoint)
        result.maxPoint = maxVector(result.maxPoint, n.nodeBounds().maxPoint)

#================   BBox     ======================

proc greenTored(p: float32): Color =
    var v = p
    result.a = 1.0
    if v < 0.5:
        result.r = v * 2.0
        result.g = 1.0
    else:
        result.r = 1.0
        result.g = 1.0 - (v - 0.5) * 2.0

proc setDebugMaxNodes*(tm: TileMap, count: int) =
    tm.debugMaxNodes = count
    if count > 0:
        tm.debugObjects = newSeq[DebugRenderData]()
    else:
        tm.debugObjects = nil

proc intersectFrustum*(f: Frustum, bbox: BBox): bool =
    if f.min.x < bbox.maxPoint.x and bbox.minPoint.x < f.max.x and f.min.y < bbox.maxPoint.y and bbox.minPoint.y < f.max.y:
        return true

method beforeDraw*(tm: TileMap, index: int): bool =
    result = true # Prevent child nodes from drawing. We shall draw them.
    if tm.drawingRows.len == 0: return

    tm.rebuildAllRowsIfNeeded()

    let c = currentContext()
    let gl = c.gl

    var vboStateValid = false
    var iTileLayer = 0
    let vpm = tm.node.sceneView.viewProjMatrix
    let frustum = tm.node.sceneView.camera.getFrustum()

    for layer in tm.layers:
        if layer.node.enabled:
            if layer of TileMapLayer:
                c.withTransform(vpm * layer.node.worldTransform):
                    if vboStateValid:
                        gl.uniformMatrix4fv(gl.getUniformLocation(tm.program, "uModelViewProjectionMatrix"), false, c.transform)
                        gl.uniform1f(gl.getUniformLocation(tm.program, "uAlpha"), layer.node.alpha)

                    for i in 0 ..< tm.drawingRows.len:
                        assert(tm.drawingRows[i].vertexBuffer != invalidBuffer)
                        #echo "Drawing row: ", i, ", quads: ", tm.drawingRows[i].numberOfQuads

                        let quadStartIndex = tm.drawingRows[i].vboLayerBreaks[iTileLayer]
                        let quadEndIndex = tm.drawingRows[i].vboLayerBreaks[iTileLayer + 1]
                        let numQuads = quadEndIndex - quadStartIndex
                        let row = tm.drawingRows[i]

                        if numQuads != 0:
                            if not vboStateValid:
                                tm.prepareVBOs()
                                vboStateValid = true

                            const floatsPerQuad = 16 # Single quad occupies 16 floats in vertex buffer

                            if frustum.intersectFrustum(row.bbox):
                                gl.bindBuffer(gl.ARRAY_BUFFER, tm.drawingRows[i].vertexBuffer)
                                gl.vertexAttribPointer(saPosition.GLuint, 4, gl.FLOAT, false, 0, quadStartIndex * floatsPerQuad * sizeof(float32))

                                gl.drawElements(gl.TRIANGLES, GLsizei(numQuads * 6), gl.UNSIGNED_SHORT)

                        let objectStartIndex = tm.drawingRows[i].objectLayerBreaks[iTileLayer]
                        let objectEndIndex = tm.drawingRows[i].objectLayerBreaks[iTileLayer + 1]
                        let numObjects = objectEndIndex - objectStartIndex

                        if numObjects != 0:
                            vboStateValid = false
                            for iObj in objectStartIndex ..< objectEndIndex:
                                tm.drawingRows[i].objects[iObj].recursiveDraw()
                    inc iTileLayer

            elif layer of ImageMapLayer:
                let iml = ImageMapLayer(layer)
                if not iml.image.isNil:
                    vboStateValid = false
                    var r: Rect
                    r.size = iml.image.size
                    c.withTransform(vpm * layer.node.worldTransform):
                        c.drawImage(iml.image, r, alpha = iml.node.alpha)

            elif layer of NodeMapLayer:
                vboStateValid = false
                let impl = NodeMapLayer(layer)

                let bb = impl.getBBox()
                if frustum.intersectFrustum(bb):
                    impl.node.recursiveDraw()

                if not tm.debugObjects.isNil:
                    var dd: DebugRenderData
                    dd.rect = newRect(bb.minPoint.x - tm.node.positionX, bb.minPoint.y - tm.node.positionY, bb.maxPoint.x - bb.minPoint.x, bb.maxPoint.y - bb.minPoint.y)
                    dd.text = impl.node.name & " n= " & $impl.getNodeCount()
                    dd.nodeCount = impl.getNodeCount()
                    tm.debugObjects.add(dd)


    if not tm.debugObjects.isNil:
        for i, dd in tm.debugObjects:
            var p = dd.nodeCount.float / tm.debugMaxNodes.float
            if p > 1.0: p = 1.0
            let color = greenTored(p)

            glLineWidth(5.0 * p)
            DDdrawRect(dd.rect, color)
            DDdrawText(dd.text, dd.rect.origin, 38, color)

        tm.debugObjects.setLen(0)
        glLineWidth(1.0)

method imageForTile(ts: BaseTileSet, tid: int16): Image {.base.} = discard

method propertiesForTile*(ts: BaseTileSet, tid: int16): Properties {.base.} = discard

method imageForTile(ts: TileCollection, tid: int16): Image =
    let tid = tid - ts.firstGid
    if tid >= 0 and tid < ts.collection.len:
        return ts.collection[tid].image

proc imageForTile*(tm: TileMap, tid: int16): Image =
    for ts in tm.tileSets:
        result = ts.imageForTile(tid)
        if not result.isNil:
            return

method propertiesForTile*(ts: TileCollection, tid: int16): Properties=
    let tid = tid - ts.firstGid
    if tid >= 0 and tid < ts.collection.len:
        return ts.collection[tid].properties

proc propertiesForTile*(tm: TileMap, tid: int16): Properties =
    for ts in tm.tileSets:
        result = ts.propertiesForTile(tid)
        if not result.isNil:
            return


method setImageForTile(ts: BaseTileSet, tid: int16, i: Image) {.base.} = discard

method setImageForTile(ts: TileCollection, tid: int16, i: Image) =
    let tid = tid - ts.firstGid
    if tid >= 0 and tid < ts.collection.len:
        ts.collection[tid].image = i

proc setImageForTile*(tm: TileMap, tid: int16, i: Image) =
    for ts in tm.tileSets:
        ts.setImageForTile(tid, i)

proc itemsForPropertyName*(tm: TileMap, key: string): seq[TileMapProperty] =
    if key in tm.properties:
        result = tm.properties[key].collection
    else:
        result = @[]

proc itemsForPropertyValue*[T](tm: TileMap, key: string, value: T): seq[TileMapProperty] =
    result = @[]
    for item in tm.itemsForPropertyName(key):
        case item.property.kind:
            of lptString:
                when T is string:
                    if item.property.strVal == value:
                        result.add(item)
            of lptInt:
                when T is int:
                    if item.property.intVal == value:
                        result.add(item)
            of lptFloat:
                when T is float:
                    if item.property.floatVal == value:
                        result.add(item)
            of lptBool:
                when T is bool:
                    if item.property.boolVal == value:
                        result.add(item)
            of lptColor:
                when T is Color:
                    if item.property.colorVal == value:
                        result.add(item)
            of lptFile:
                when T is string:
                    if item.property.fileVal == value:
                        result.add(item)


proc staggeredYTileRect(tm: TileMap, pos: int, tr: var Rect)=
    var row = (pos div tm.mapSize.width.int).float
    var col = (pos mod tm.mapSize.width.int).float

    let offIndex = if tm.isStaggerIndexOdd: 0 else: 1
    let axisP = (row.int + offIndex) mod 2

    tr.origin.x = col * tm.tileSize.x + axisP.float * tm.tileSize.x * 0.5
    tr.origin.y = row * tm.tileSize.y * 0.5

    tr.size = newSize(tm.tileSize.x, tm.tileSize.y)

proc staggeredXTileRect(tm: TileMap, pos: int, tr: var Rect)=
    var row = (pos div tm.mapSize.width.int).float
    var col = (pos mod tm.mapSize.width.int).float

    let offIndex = if tm.isStaggerIndexOdd: 0 else: 1
    let axisP = (col.int + offIndex) mod 2

    tr.origin.x = col * tm.tileSize.x * 0.5
    tr.origin.y = row * tm.tileSize.y + axisP.float * 0.5 * tm.tileSize.y

    tr.size = newSize(tm.tileSize.x, tm.tileSize.y)

proc isometricTileRect(tm: TileMap, pos: int, tr: var Rect)=
    var row = (pos div tm.mapSize.width.int).float
    var col = (pos mod tm.mapSize.width.int).float

    let halfTileWidth  = tm.tileSize.x * 0.5
    let halfTileHeigth = tm.tileSize.y * 0.5

    tr.origin.x = (col * halfTileWidth) - (row * tm.tileSize.x * 0.5) + (tm.mapSize.width - 1.0) * halfTileWidth
    tr.origin.y = (row * halfTileHeigth) + (col * halfTileHeigth)

    tr.size = newSize(tm.tileSize.x, tm.tileSize.y)

proc orthogonalTileRect(tm: TileMap, pos: int, tr: var Rect)=
    var row = (pos div tm.mapSize.width.int).float
    var col = (pos mod tm.mapSize.width.int).float

    tr.origin.x = col * tm.tileSize.x
    tr.origin.y = row * tm.tileSize.y

    tr.size = newSize(tm.tileSize.x, tm.tileSize.y)

proc orientation*(tm: TileMap): TileMapOrientation=
    result = tm.mOrientation

proc `orientation=`*(tm: TileMap, val: TileMapOrientation)=
    tm.mOrientation = val

    case val:
    of TileMapOrientation.orthogonal:
        tm.tileDrawRect = orthogonalTileRect
    of TileMapOrientation.isometric:
        tm.tileDrawRect = isometricTileRect
    of TileMapOrientation.staggeredX:
        tm.tileDrawRect = staggeredXTileRect
    of TileMapOrientation.staggeredY:
        tm.tileDrawRect = staggeredYTileRect
    else:
        tm.tileDrawRect = orthogonalTileRect

proc containsRow(layer: BaseTileMapLayer, row: int): bool {.inline.} =
    row >= layer.actualSize.miny and row < layer.actualSize.maxy

method getAllImages(ts: BaseTileSet, result: var seq[TidAndImage]) {.base.} =
    discard

method getAllImages(ts: TileCollection, result: var seq[TidAndImage]) =
    for tid, tile in ts.collection:
        if not tile.image.isNil:
            result.add((tile.image, int16(ts.firstGid + tid)))

proc getQuadDataForTile(tm: TileMap, id: int16, quadData: var array[16, float32]): bool {.inline.} =
    if id in tm.tileVCoords:
        quadData = tm.tileVCoords[id]
        result = true

proc offsetVertexData(data: var array[16, float32], xOff, yOff: float32, minY, maxY: var float32) {.inline.} =
    data[0] += xOff
    data[1] += yOff
    data[4] += xOff
    data[5] += yOff
    data[8] += xOff
    data[9] += yOff
    data[12] += xOff
    data[13] += yOff

    minY = min(minY, data[1])
    maxY = max(maxY, data[5])

proc addTileToVertexData(tm: TileMap, id: int16, xOff, yOff: float32, data: var seq[float32], minY, maxY: var float32): bool {.inline.} =
    var quadData: array[16, float32]
    result = tm.getQuadDataForTile(id, quadData)
    if result:
        offsetVertexData(quadData, xOff, yOff, minY, maxY)
        data.add(quadData)

proc createObjectForTile(tm: TileMap, id: int16, xOff, yOff: float32): Node =
    let i = tm.imageForTile(id)
    if not i.isNil:
        result = newNode()
        let s = result.component(Sprite)
        s.image = i
        let yOff = tm.tileSize.y - i.size.height + yOff
        result.position = newVector3(xOff, yOff)

proc updateWithVertexData(row: var DrawingRow, vertexData: openarray[float32]) {.inline.} =
    let gl = currentContext().gl
    if row.vertexBuffer == invalidBuffer:
        row.vertexBuffer = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, row.vertexBuffer)
    gl.bufferData(gl.ARRAY_BUFFER, vertexData, gl.STATIC_DRAW)

proc rebuildRow(tm: TileMap, row: var DrawingRow, index: int) =
    let tileY = index div 2
    let odd = index mod 2 # 1 if row is odd, 0 otherwise
    var x_min = Inf
    var x_max = -Inf
    var y_min: float32 = Inf
    var y_max: float32 = -Inf
    var minOffset = Inf
    var maxOffset = -Inf

    if row.vboLayerBreaks.isNil:
        row.vboLayerBreaks = @[]
    else:
        row.vboLayerBreaks.setLen(0)

    if row.objectLayerBreaks.isNil:
        row.objectLayerBreaks = @[]
    else:
        row.objectLayerBreaks.setLen(0)

    var vertexData = newSeq[float32]()

    #echo "rebuildRow: ", index, ", tileY: ", tileY

    let yOffBase = Coord(index) * tm.tileSize.y / 2

    template addLayerBreak() =
        let quadsInRowSoFar = vertexData.len div 16
        row.vboLayerBreaks.add(quadsInRowSoFar)
        if quadsInRowSoFar > 0:
            let quadsInRun = row.vboLayerBreaks[^1] - row.vboLayerBreaks[^2]
            if quadsInRun > tm.maxQuadsInRun:
                tm.maxQuadsInRun = quadsInRun

        let objectsInRowSoFar = row.objects.len
        row.objectLayerBreaks.add(objectsInRowSoFar)

    for layerIndex, layer in tm.layers:
        if layer.enabled and layer of TileMapLayer:
            addLayerBreak()
            if layer.containsRow(tileY):
                let tml = TileMapLayer(layer)
                let maxx = tml.actualSize.maxx
                let layerWidth = maxx - tml.actualSize.minx
                let layerStartOdd = tml.actualSize.minx mod 2 # 1 if row is odd, 0 otherwise
                # var tilesInLayerRow = layerWidth div 2
                #echo "layer: ", layer.name, ":" , tml.actualSize, ", tilesInLayerRow: ", tilesInLayerRow

                let tileYInLayer = tileY - tml.actualSize.miny

                let yOff = yOffBase #+ tml.offset.height

                #for i in 0 ..< tilesInLayerRow:
                var i = tml.actualSize.minx
                if layerStartOdd != odd:
                    inc i

                while i < maxx:
                    let tileX = i - tml.actualSize.minx # * 2 + odd + layerStartOdd
                    let tileIdx = tileYInLayer * layerWidth + tileX
                    #echo "tileYInLayer: ", tileYInLayer, ", tileX: ", tileX, ", idx: ", tileIdx
                    let tile = tml.data[tileIdx]

                    let xOff = Coord(tileX + tml.actualSize.minx) * tm.tileSize.x / 2 #+ tml.offset.width
                    #echo "xOff: ", xOff
                    # let yOff = Coord(tileY + tml.actualSize.miny) * tm.tileSize.x / 2
                    # if tile == 197:
                    if tile != 0:
                        if not tm.addTileToVertexData(tile, xOff, yOff, vertexData, y_min, y_max):
                            let n = tm.createObjectForTile(tile, xOff, yOff)
                            if not n.isNil:
                                layer.node.addChild(n)
                                if row.objects.isNil: row.objects = @[]
                                row.objects.add(n)
                                let bb = n.nodeBounds()
                                x_min = min(x_min, bb.minPoint.x)
                                x_max = max(x_max, bb.maxPoint.x)
                                y_min = min(y_min, bb.minPoint.y)
                                y_max = max(y_max, bb.maxPoint.y)
                            else:
                                echo "TILE NOT FOUND: ", tile

                        else:
                            x_min = min(x_min, vertexData[0])
                            x_max = max(x_max, xOff)
                            minOffset = min(minOffset, tml.offset.height)
                            maxOffset = max(maxOffset, tml.offset.height)

                    i += 2

    row.bbox.minPoint = newVector3(x_min, y_min + minOffset, 0.0)
    row.bbox.maxPoint = newVector3(x_max, y_max + maxOffset, 0.0)

    addLayerBreak()
    row.updateWithVertexData(vertexData)

proc rebuildRow(tm: TileMap, row: int) =
    if tm.drawingRows.len <= row:
        tm.drawingRows.setLen(row + 1)
    tm.rebuildRow(tm.drawingRows[row], row)

proc packAllTilesToSheet(tm: TileMap) =
    tm.tileVCoords = initTable[int16, array[16, float32]]()
    var allImages = newSeq[TidAndImage]()
    for ts in tm.tileSets:
        ts.getAllImages(allImages)

    const maxWidth = 800
    const maxHeight = 500

    allImages.keepItIf:
        let sz = it.image.size
        sz.width < maxWidth and sz.height < maxHeight

    allImages.sort() do(i1, i2: TidAndImage) -> int:
        let sz2 = i1.image.size
        let sz1 = i2.image.size
        cmp(sz1.width * sz1.height, sz2.width * sz2.height)

    let c = currentContext()
    let gl = c.gl

    var maxTextureSize = gl.getParami(gl.MAX_TEXTURE_SIZE)
    let texWidth = min(4096, maxTextureSize)
    let texHeight = min(4096, maxTextureSize)

    info "[TileMap::packAllTilesToSheet] maxTextureSize ", maxTextureSize

    assert(isPowerOfTwo(texWidth) and isPowerOfTwo(texHeight))

    tm.mTilesSpriteSheet = imageWithSize(newSize(texWidth.Coord, texHeight.Coord))

    var gfs: GlFrameState
    beginDraw(tm.mTilesSpriteSheet, gfs)

    gl.blendFunc(gl.ONE, gl.ZERO)
    c.withTransform ortho(0, texWidth.Coord, 0, texHeight.Coord, -1, 1):
        var rp = newPacker(texWidth.int32, texHeight.int32)
        for i in allImages:
            #echo "Packing image: ", i.image.filePath
            let img = i.image
            let sz = img.size
            #echo "size: ", sz
            assert(sz.width > 2)
            assert(sz.height > 2)

            const margin = 4 # Hack

            let p = rp.pack(sz.width.int32 + margin * 2, sz.height.int32 + margin * 2)
            if p.hasSpace:
                #echo "pos: ", p

                var r: Rect
                r.origin.x = Coord(p.x) # Coord(p.x + margin)
                r.origin.y = Coord(p.y) # Coord(p.y + margin)
                r.size = sz
                r.size.width += margin * 2
                r.size.height += margin * 2
#                var tc: array[4, float32]
#                let tex = img.getTextureQuad(gl, tc)
#                gl.bindTexture(gl.TEXTURE_2D, tex)
                # gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
                # gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)

                var fromRect = r
                fromRect.origin.x = - margin
                fromRect.origin.y = - margin
                c.drawImage(img, r, fromRect)

                r.origin.x += margin
                r.origin.y += margin

                r.size.width -= margin * 2
                r.size.height -= margin * 2


                let yOff = tm.tileSize.y - sz.height

                const dv = 0 #-1.0
                const d = 0.0 #1.0

                var coords: array[16, float32]
                coords[0] = dv
                coords[1] = dv + yOff
                coords[2] = (r.x.Coord + d) / texWidth.Coord
                coords[3] = (r.y.Coord + d) / texHeight.Coord

                coords[4] = dv
                coords[5] = sz.height + yOff - dv
                coords[6] = (r.x.Coord + d) / texWidth.Coord
                coords[7] = (r.maxY - d) / texHeight.Coord

                coords[8] = sz.width - dv
                coords[9] = sz.height + yOff - dv
                coords[10] = (r.maxX - d) / texWidth.Coord
                coords[11] = (r.maxY - d) / texHeight.Coord

                coords[12] = sz.width - dv
                coords[13] = 0 + yOff + dv
                coords[14] = (r.maxX - d) / texWidth.Coord
                coords[15] = (r.y + d) / texHeight.Coord
                tm.tileVCoords[i.tid] = coords

                var subimageCoords: array[4, float32]
                subimageCoords[0] = coords[2]
                subimageCoords[1] = coords[3]
                subimageCoords[2] = coords[10]
                subimageCoords[3] = coords[7]

                let sub = tm.mTilesSpriteSheet.subimageWithTexCoords(sz, subimageCoords)
                tm.setImageForTile(i.tid, sub)
            else:
                warn "pack ", i.image.filePath, " doesnt fit ", i.image.size

    endDraw(tm.mTilesSpriteSheet, gfs)
    tm.mTilesSpriteSheet.generateMipmap(c.gl)
    # tm.mTilesSpriteSheet.writeToPNGFile("/Users/rrenderr/Documents/im.png")

    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

proc rebuildAllRows(tm: TileMap) =
    let numRows = tm.mapSize.height.int * 2
    for i in 0 ..< numRows:
        tm.rebuildRow(i)

proc rebuildAllRowsIfNeeded(tm: TileMap) =
    var enabledLayers = newBoolSeq()
    enabledLayers.setLen(tm.layers.len)
    for i, layer in tm.layers:
        enabledLayers[i] = layer of TileMapLayer and layer.node.enabled

    if enabledLayers != tm.enabledLayers:
        swap(enabledLayers, tm.enabledLayers)
        tm.rebuildAllRows()

proc removeLayer(tm: TileMap, idx: int, name: string) =
    if idx < tm.layers.len:
        let layer = tm.layers[idx]
        tm.layers.delete(idx)
        layer.node.removeFromParent()

        if tm.drawingRows.len > 0:
            tm.rebuildAllRows()

proc removeLayer*(tm: TileMap, name: string)=
    for i, l in tm.layers:
        if l.name == name:
            tm.removeLayer(i, name)
            return

#todo: serialize support
# method deserialize*(c: TileMap, j: JsonNode, serealizer: Serializer) =
#     discard

# method serialize*(c: TileMap, s: Serializer): JsonNode=
#     result = newJObject()


method visitProperties*(tm: BaseTileMapLayer, p: var PropertyVisitor) =
    if not tm.properties.isNil:
        for k, v in tm.properties:
            case v.kind:
            of lptString:
                p.visitProperty(k, v.strVal)
            of lptBool:
                p.visitProperty(k, v.boolVal)
            of lptColor:
                p.visitProperty(k, v.colorVal)
            of lptFloat:
                p.visitProperty(k, v.floatVal)
            of lptInt:
                p.visitProperty(k, v.intVal)
            else:
                discard

method visitProperties*(tm: TileMap, p: var PropertyVisitor) =
    p.visitProperty("mapSize", tm.mapSize)
    p.visitProperty("tileSize", tm.tileSize)
    p.visitProperty("orientation", tm.orientation)

registerComponent(TileMap, "TileMap")
registerComponent(ImageMapLayer, "TileMap")
registerComponent(TileMapLayer, "TileMap")

#[
    Tiled support http://www.mapeditor.org/
 ]#

var tiledLayerCreators = initTable[string, proc(tm: TileMap, jl: JsonNode, s: Serializer): BaseTileMapLayer]()

tiledLayerCreators["imagelayer"] = proc(tm: TileMap, jl: JsonNode, s: Serializer): BaseTileMapLayer =
    let layer = new(ImageMapLayer)
    if "image" in jl and jl["image"].str.len > 0:
        deserializeImage(jl["image"], s) do(img: Image, err: string):
            layer.image = img

    result = layer

tiledLayerCreators["tilelayer"] = proc(tm: TileMap, jl: JsonNode, s: Serializer): BaseTileMapLayer =
    let layer = new(TileMapLayer)

    var dataSize = (tm.mapSize.width * tm.mapSize.height).int
    if "actualSize" in jl:
        let acts = jl["actualSize"]
        layer.actualSize.minx = acts["minX"].getNum().int
        layer.actualSize.maxx = acts["maxX"].getNum().int
        layer.actualSize.miny = acts["minY"].getNum().int
        layer.actualSize.maxy = acts["maxY"].getNum().int

        dataSize = (layer.actualSize.maxx - layer.actualSize.minx) * (layer.actualSize.maxy - layer.actualSize.miny)

    else:
        layer.actualSize.minx = 0
        layer.actualSize.maxx = tm.mapSize.width.int
        layer.actualSize.miny = 0
        layer.actualSize.maxy = tm.mapSize.height.int

    layer.tileSize = tm.tileSize
    layer.data = newSeq[int16](dataSize)

    var i = 0
    for jld in jl["data"]:
        layer.data[i] = jld.getNum().int16
        inc i

    result = layer

proc checkLoadingErr(err: string) {.raises: Exception.}=
    if not err.isNil:
        raise newException(Exception, err)


proc getProperties[T](tm: TileMap, node: JsonNode, item: T): Properties =
    if "propertytypes" in node and "properties" in node:
        var len = 4
        while node["propertytypes"].len > len:
            len *= 2
        result = newTable[string, Property](len)

        for key, value in node["propertytypes"]:
            if key in node["properties"]:
                let kind = parseEnum[PropertyType](value.getStr())
                let property = newProperty(kind, node["properties"][key])
                result[key] = property

                var mapProperty: TileMapProperty
                when T is BaseTileMapLayer:
                    mapProperty = TileMapProperty(kind: tmlptLayer, layer: item, property: property)
                elif T is BaseTileSet:
                    mapProperty = TileMapProperty(kind: tmlptTileset, tileset: item, property: property)
                elif T is int16:
                    mapProperty = TileMapProperty(kind: tmlptTile, tid: item, property: property)
                if not (key in tm.properties):
                    tm.properties[key] = TileMapPropertyCollection(collection: @[])
                tm.properties[key].collection.add(mapProperty)


proc loadTileSet(jTileSet: JsonNode, serializer: Serializer, tm: TileMap): BaseTileSet =
    var firstgid = 0
    if "firstgid" in jTileSet:
        firstgid = jTileSet["firstgid"].getNum().int

    if "tiles" in jTileSet:
        let tileCollection = new(TileCollection)

        tileCollection.tilesCount = jTileSet["tilecount"].getNum().int
        tileCollection.collection = @[]
        tileCollection.firstGid = firstgid

        for k, v in jTileSet["tiles"]:
            closureScope:
                let i = parseInt(k)

                deserializeImage(v["image"], serializer) do(img: Image, err: string):
                    checkLoadingErr(err)

                    if i >= tileCollection.collection.len:
                        tileCollection.collection.setLen(i + 1)

                    tileCollection.collection[i] = (img, getProperties(tm, v, int16(firstgid + i)))

        result = tileCollection

    elif "image" in jTileSet:
        let tileSheet = new(TileSheet)
        deserializeImage(jTileSet["image"], serializer) do(img: Image, err: string):
            checkLoadingErr(err)
            tileSheet.sheet = img

        tileSheet.columns = jTileSet["columns"].getNum().int
        result = tileSheet

    else:
        raise newException(Exception, "Incorrect tileSet format")

    result.name = jTileSet["name"].getStr()
    result.tileSize = newVector3(jTileSet["tilewidth"].getFNum(), jTileSet["tileheight"].getFNum())
    result.tilesCount = jTileSet["tilecount"].getNum().int

    result.firstGid = firstgid

    result.properties = getProperties(tm, jTileSet, result)

    echo "TileSet ", result.name, " loaded!"

proc loadTiledWithUrl*(tm: TileMap, url: string, onComplete: proc() = nil) =
    loadAsset(url) do(jtm: JsonNode, err: string):
        checkLoadingErr(err)

        let serializer = new(Serializer)
        serializer.url = url
        serializer.onComplete = proc () =
            tm.packAllTilesToSheet()
            tm.rebuildAllRowsIfNeeded()
            if not onComplete.isNil: onComplete()

        if "orientation" in jtm:
            try:
                tm.orientation = parseEnum[TileMapOrientation](jtm["orientation"].getStr())
            except:
                if jtm["orientation"].getStr() == "staggered":
                    let isStaggerAxisX = jtm["staggeraxis"].getStr() == "x"
                    if isStaggerAxisX:
                        tm.orientation = TileMapOrientation.staggeredX
                    else:
                        tm.orientation = TileMapOrientation.staggeredY
                    tm.isStaggerIndexOdd = jtm["staggerindex"].getStr() == "odd"

        if "width" in jtm and "height" in jtm:
            tm.mapSize = newSize(jtm["width"].getFNum(), jtm["height"].getFNum())

        if "tileheight" in jtm and "tilewidth" in jtm:
            let tWidth = jtm["tilewidth"].getNum().float
            let tHeigth = jtm["tileheight"].getNum().float
            tm.tileSize = newVector3(tWidth, tHeigth)

        if "layers" in jtm:
            tm.layers = @[]

            proc parseLayer(tm: TileMap, jl: JsonNode, pos: Vector3 = newVector3(), visible = true)=
                let layerType = jl["type"].getStr()
                let layerCreator = tiledLayerCreators.getOrDefault(layerType)

                var position = newVector3()
                if "offsetx" in jl:
                    position.x = jl["offsetx"].getFNum()
                if "offsety" in jl:
                    position.y = jl["offsety"].getFNum()

                position += pos

                let enabled = if visible: jl["visible"].getBVal() else: false

                if layerCreator.isNil:
                    if layerType == "group":
                        var grps: JsonNode
                        var grpt: JsonNode
                        if "propertytypes" in jl and "properties" in jl:
                            grps = jl["properties"]
                            grpt = jl["propertytypes"]

                        let inheritProperties = not grps.isNil and not grpt.isNil

                        for jLayer in jl["layers"]:
                            ## properties inheritance
                            if inheritProperties:
                                var chps: JsonNode
                                var chpt: JsonNode
                                if "propertytypes" in jLayer and "properties" in jLayer:
                                    chpt = jLayer["propertytypes"]
                                    chps = jLayer["properties"]

                                if chps.isNil:
                                    chps = newJObject()
                                if chpt.isNil:
                                    chpt = newJObject()

                                for pk, pv in grps:
                                    if pk notin chps:
                                        chps[pk] = pv

                                for pk, pv in grpt:
                                    if pk notin chpt:
                                        chpt[pk] = pv

                                jLayer["properties"] = chps
                                jLayer["propertytypes"] = chpt

                            tm.parseLayer(jLayer, position, enabled)
                    else:
                        warn "TileMap loadTiled: ", layerType, " doesn't supported!"
                    return

                var layer = tm.layerCreator(jl, serializer)
                layer.map = tm
                let name = jl["name"].getStr()

                let alpha = jl["opacity"].getFNum()

                if "width" notin jl or "height" notin jl:
                    layer.size = zeroSize
                else:
                    layer.size = newSize(jl["width"].getFNum(), jl["height"].getFNum())

                layer.offset = newSize(position.x, position.y)

                var layerNode = newNode(name)
                layerNode.position = position
                layerNode.alpha = alpha
                layerNode.enabled = enabled

                if layerType == "imagelayer":
                    layerNode.setComponent("ImageMapLayer", layer)
                elif layerType == "tilelayer":
                    layerNode.setComponent("TileMapLayer", layer)

                layer.node = layerNode
                tm.node.addChild(layerNode)
                tm.layers.add(layer)

                layer.properties = getProperties(tm, jl, layer)

            for jl in jtm["layers"]:
                tm.parseLayer(jl)

        if "tilesets" in jtm:
            tm.tileSets = @[]

            for jts in jtm["tilesets"]:
                if "source" in jts:
                    closureScope:
                        let url = serializer.toAbsoluteUrl(jts["source"].getStr())
                        serializer.startAsyncOp()
                        let fg = jts["firstgid"]

                        loadAsset(url) do(j: JsonNode, err: string):
                            checkLoadingErr(err)

                            let s = new(Serializer)
                            s.url = url
                            j["firstgid"] = fg
                            s.onComplete = proc() =
                                serializer.endAsyncOp()

                            let ts = loadTileSet(j, s, tm)
                            s.finish()
                            tm.tileSets.add(ts)
                else:
                    let ts = loadTileSet(jts, serializer, tm)
                    if not ts.isNil:
                        tm.tileSets.add(ts)

        serializer.finish()

proc loadTiledWithResource*(tm: TileMap, path: string) =
    var done = false
    tm.loadTiledWithUrl("res://" & path) do():
        done = true

        echo "done loadTiledWithResource"
    if not done:
        echo "failed loadTiledWithResource"
    #     raise newException(Exception, "Load could not complete synchronously. Possible reason: asset bundle not preloaded")
