import rod / [ component, node, viewport, rod_types ]
import rod / component / [ sprite, camera ]
import rod / tools / [ serializer, debug_draw ]
import rod / utils / [ serialization_codegen ]
from rod.utils.property_desc import nil

import nimx / [ types, property_visitor, matrixes, portable_gl, context, image, resource,
                render_to_image, composition ]

import json, tables, strutils, logging, sequtils, algorithm, math
import nimx.assets.asset_loading
import boolseq
import rect_packer
import opengl
import times

type
    LayerRange* = tuple
        minx, miny: int32
        maxx, maxy: int32

    Properties* = TableRef[string, JsonNode]

    BaseTileMapLayer* = ref object of Component
        size*: Size
        offset*: Size
        actualSize*: LayerRange
        map*: TileMap
        properties*: Properties

    TileMapLayer* = ref object of BaseTileMapLayer
        data*: seq[int16]
        tileSize*: Vector3

    ImageMapLayer* = ref object of BaseTileMapLayer
        image*: Image

    NodeMapLayer* = ref object of BaseTileMapLayer
        bbox: BBox
        isBBoxCalculated: bool

    BaseTileSet* = ref object of RootObj
        tileSize*: Vector3
        firstGid*: int
        tilesCount*: int
        name*: string
        properties*: Properties

    TileSheet* = ref object of BaseTileSet
        sheet*: Image
        columns*: int

    Tile* = tuple[image: Image, properties: Properties, gid: int]

    TileCollection* = ref object of BaseTileSet
        collection*: seq[Tile]

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
        renderTime: float
        postEffectCalls: int

    TileMap* = ref object of Component
        mapSize*: Size
        tileSize*: Vector3
        layers*: seq[BaseTileMapLayer]
        tileSets*: seq[BaseTileSet]
        mOrientation*: TileMapOrientation
        isStaggerIndexOdd*: bool
        properties*: Properties

        # tileDrawRect: proc(tm: TileMap, pos: int, tr: var Rect)
        mQuadIndexBuffer: BufferRef
        maxQuadsInRun: int
        quadBufferLen: int
        mProgram: ProgramRef
        mTilesSpriteSheet: SelfContainedImage
        enabledLayers: BoolSeq
        tileVCoords: Table[int16, array[16, float32]]
        drawingRows: seq[DrawingRow]
        debugObjects: seq[DebugRenderData]
        debugMaxNodes: int

    TidAndImage = tuple[image: Image, tid: int16]

    RawProperties = tuple[name: string, value: string]
    RawTile = tuple[id: int32, image: Image, rawProperties:seq[RawProperties]]
    TileSetRaw = tuple
        collection: seq[RawTile] # TileCollection
        tileSize: Vector3
        firstgid: int32
        tilesCount: int32
        columns: int32  # TileSheet
        name: string
        image: Image # TileSheet
        properties: seq[RawProperties]

property_desc.properties(TileMap):
    rawProperties(phantom = seq[RawProperties])
    tileSets(phantom = seq[TileSetRaw])
    tileSize #vector3
    mapSize #size
    mOrientation #enum
    isStaggerIndexOdd #bool

property_desc.properties(TileMapLayer):
    rawProperties(phantom = seq[RawProperties])
    data #seq[int16]
    actualSize #tuple
    tileSize #vector3
    size #size
    offset #size

property_desc.properties(ImageMapLayer):
    rawProperties(phantom = seq[RawProperties])
    image #Image
    actualSize #tuple
    size #size
    offset #size

proc newNodeMapLayer*(node: Node, map: TileMap, size: Size = zeroSize, offset: Size = zeroSize, actualSize: LayerRange = (0'i32, 0'i32, 0'i32, 0'i32)): NodeMapLayer =
    NodeMapLayer(
        size: size,
        offset: offset,
        actualSize: actualSize,
        map: map,
        node: node
    )

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

proc layerChanged*(tm: TileMap)=
    tm.enabledLayers = newBoolSeq()
    tm.rebuildAllRowsIfNeeded()

method init*(tm: TileMap) =
    procCall tm.Component.init()
    tm.drawingRows = @[]
    tm.layers = @[]

proc position*(lay: BaseTileMapLayer): Vector3=
    return lay.node.position

proc alpha*(lay: BaseTileMapLayer): float=
    return lay.node.alpha

proc enabled*(lay: BaseTileMapLayer): bool=
    return lay.node.enabled

proc `enabled=`*(lay: BaseTileMapLayer, v: bool) =
    lay.node.enabled = v

proc name*(lay: BaseTileMapLayer): string =
    return lay.node.name

proc layerIndex*(tm: TileMap, sla: BaseTileMapLayer): int =
    result = -1
    for i, la in tm.layers:
        if sla == la:
            return i


proc layerIndexByName*(tm: TileMap, name: string): int =
    result = -1
    for i, lay in tm.layers:
        if lay.name == name:
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
    for lay in tm.layers:
        if lay.name == name and lay of T:
            return lay.T

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
    for lay in tm.layers:
        if lay of TileMapLayer:
            result.add(lay.TileMapLayer.tileAtPosition(position))

proc visibleTilesAtPosition*(tm: TileMap, position: Vector3): seq[int]=
    result = @[]
    for lay in tm.layers:
        if lay of TileMapLayer and lay.enabled:
            let r = lay.TileMapLayer.tileAtPosition(position)
            if r != 0:
                result.add(r)

proc visibleTilesAtPositionDebugInfo*(tm: TileMap, position: Vector3): seq[tuple[layerName: string, x: int, y: int, tileid: int, index: int]]=
    result = @[]
    for lay in tm.layers:
        if lay of TileMapLayer and lay.enabled:
            let coords = lay.TileMapLayer.tileXYAtPosition(newVector3(position.x - lay.offset.width, position.y - lay.offset.height))
            let tileid = lay.TileMapLayer.tileAtXY(coords.x, coords.y)
            let index =  lay.TileMapLayer.tileIndexAtXY(coords.x, coords.y)
            if tileid != 0:
                result.add((layerName: lay.name, x: coords.x, y: coords.y, tileid: tileid, index: index))

proc layerIntersectsAtPositionWithPropertyName*(tm: TileMap, position: Vector3, prop:string): seq[BaseTileMapLayer]=
    result = @[]
    for lay in tm.layers:
        if not lay.properties.isNil and prop in lay.properties:
            if lay of TileMapLayer:
                let coords = lay.TileMapLayer.tileXYAtPosition(newVector3(position.x - lay.offset.width, position.y - lay.offset.height))
                let tileid = lay.TileMapLayer.tileAtXY(coords.x, coords.y)
                # let index =  lay.TileMapLayer.tileIndexAtXY(coords.x, coords.y)
                if tileid != 0:
                    result.add(lay)

            # need raycast in sprite here
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
        count += 1

        for c in n.children:
            if c.alpha > 0.01 and c.enabled:
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
    let isOrtho = tm.mOrientation == TileMapOrientation.orthogonal

    for layer in tm.layers:
        if layer.node.enabled:
            if layer of TileMapLayer:
                c.withTransform(vpm * layer.node.worldTransform):
                    if vboStateValid:
                        gl.uniformMatrix4fv(gl.getUniformLocation(tm.program, "uModelViewProjectionMatrix"), false, c.transform)
                        gl.uniform1f(gl.getUniformLocation(tm.program, "uAlpha"), layer.node.alpha)

                    for i in 0 ..< tm.drawingRows.len:
                        assert(tm.drawingRows[i].vertexBuffer != invalidBuffer)
                        # echo "Drawing row: ", i #, ", quads: ", tm.drawingRows[i].numberOfQuads

                        let quadStartIndex = tm.drawingRows[i].vboLayerBreaks[iTileLayer]
                        let quadEndIndex = tm.drawingRows[i].vboLayerBreaks[iTileLayer + 1]
                        let numQuads = quadEndIndex - quadStartIndex
                        let row = tm.drawingRows[i]

                        if numQuads != 0:
                            if not vboStateValid:
                                tm.prepareVBOs()
                                vboStateValid = true

                            const floatsPerQuad = 16 # Single quad occupies 16 floats in vertex buffer

                            if isOrtho or frustum.intersectFrustum(row.bbox):
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
                var rTime = cpuTime()
                let impl = NodeMapLayer(layer)

                let bb = impl.getBBox()
                if frustum.intersectFrustum(bb):
                    impl.node.recursiveDraw()

                if not tm.debugObjects.isNil:
                    var dd: DebugRenderData
                    dd.renderTime = cpuTime() - rTime
                    dd.rect = newRect(bb.minPoint.x - tm.node.positionX, bb.minPoint.y - tm.node.positionY, bb.maxPoint.x - bb.minPoint.x, bb.maxPoint.y - bb.minPoint.y)
                    dd.text = impl.node.name
                    dd.nodeCount = impl.getNodeCount()
                    tm.debugObjects.add(dd)


    if not tm.debugObjects.isNil:
        for i, dd in tm.debugObjects:
            var p = dd.renderTime * 1000.0 / tm.debugMaxNodes.float
            if p > 1.0: p = 1.0
            let color = greenTored(p)

            if p == 0.0: p = 0.2
            glLineWidth(5.0 * p)
            DDdrawRect(dd.rect, color)
            DDdrawText(dd.text, dd.rect.origin, 38, color)
            DDdrawText(" n = " & $dd.nodeCount, dd.rect.origin + newPoint(0, 40), 38, color)
            DDdrawText(" t = " & $(dd.renderTime * 1000.0), dd.rect.origin + newPoint(0, 80), 38, color)

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

proc orientation*(tm: TileMap): TileMapOrientation=
    result = tm.mOrientation

proc `orientation=`*(tm: TileMap, val: TileMapOrientation)=
    tm.mOrientation = val

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
    let staggered = tm.orientation in [TileMapOrientation.staggeredX, TileMapOrientation.staggeredY]
    let tileY = if staggered: index div 2 else: index
    let odd = if staggered: index mod 2 else: index  # 1 if row is odd, 0 otherwise
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

    let yOffBase = if staggered: Coord(index) * tm.tileSize.y / 2 else: Coord(index) * tm.tileSize.y

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
                var layerStartOdd = if staggered:
                                        tml.actualSize.minx mod 2 # 1 if row is odd, 0 otherwise
                                    else:
                                        tml.actualSize.minx

                let tileYInLayer = tileY - tml.actualSize.miny

                let yOff = yOffBase #+ tml.offset.height

                var i = tml.actualSize.minx
                if staggered and layerStartOdd != odd:
                    inc i

                while i < maxx:
                    let tileX = i - tml.actualSize.minx # * 2 + odd + layerStartOdd
                    let tileIdx = tileYInLayer * layerWidth + tileX

                    let tile = tml.data[tileIdx]

                    let xOff =  if staggered:
                                    Coord(tileX + tml.actualSize.minx) * tm.tileSize.x / 2
                                else:
                                    Coord(i + tml.actualSize.minx) * tm.tileSize.x #+ tml.offset.width

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
                            x_min = min(x_min, vertexData[0])
                            x_max = max(x_max, xOff)
                            minOffset = min(minOffset, tml.offset.height)
                            maxOffset = max(maxOffset, tml.offset.height)

                    if not staggered:
                        inc i
                    else:
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
    let texWidth = min(2048, maxTextureSize)
    let texHeight = min(2048, maxTextureSize)

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
            let logicalSize = img.size
            let sz = img.backingSize()

            assert(sz.width > 2)
            assert(sz.height > 2)

            const margin = 4 # Hack

            let srcLogicalMarginX = margin * (logicalSize.width / sz.width)
            let srcLogicalMarginY = margin * (logicalSize.height / sz.height)

            let p = rp.pack(sz.width.int32 + margin * 2, sz.height.int32 + margin * 2)
            if p.hasSpace:
                #echo "pos: ", p

                var r: Rect
                r.origin.x = Coord(p.x) # Coord(p.x + margin)
                r.origin.y = Coord(p.y) # Coord(p.y + margin)
                r.size = sz
                r.size.width += margin * 2
                r.size.height += margin * 2
                #var tc: array[4, float32]
                #let tex = img.getTextureQuad(gl, tc)
                #gl.bindTexture(gl.TEXTURE_2D, tex)
                # gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
                # gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)

                var fromRect: Rect
                fromRect.size = logicalSize
                fromRect.size.width += srcLogicalMarginX * 2
                fromRect.size.height += srcLogicalMarginY * 2
                fromRect.origin.x = - srcLogicalMarginX
                fromRect.origin.y = - srcLogicalMarginY
                c.drawImage(img, r, fromRect)

                r.origin.x += margin
                r.origin.y += margin

                r.size.width -= margin * 2
                r.size.height -= margin * 2


                let yOff = tm.tileSize.y - logicalSize.height

                const dv = 0 #-1.0
                const d = 0.0 #1.0

                var coords: array[16, float32]
                coords[0] = dv
                coords[1] = dv + yOff
                coords[2] = (r.x.Coord + d) / texWidth.Coord
                coords[3] = (r.y.Coord + d) / texHeight.Coord

                coords[4] = dv
                coords[5] = logicalSize.height + yOff - dv
                coords[6] = (r.x.Coord + d) / texWidth.Coord
                coords[7] = (r.maxY - d) / texHeight.Coord

                coords[8] = logicalSize.width - dv
                coords[9] = logicalSize.height + yOff - dv
                coords[10] = (r.maxX - d) / texWidth.Coord
                coords[11] = (r.maxY - d) / texHeight.Coord

                coords[12] = logicalSize.width - dv
                coords[13] = 0 + yOff + dv
                coords[14] = (r.maxX - d) / texWidth.Coord
                coords[15] = (r.y + d) / texHeight.Coord
                tm.tileVCoords[i.tid] = coords

                var subimageCoords: array[4, float32]
                subimageCoords[0] = coords[2]
                subimageCoords[1] = coords[3]
                subimageCoords[2] = coords[10]
                subimageCoords[3] = coords[11]

                let sub = tm.mTilesSpriteSheet.subimageWithTexCoords(sz, subimageCoords)
                tm.setImageForTile(i.tid, sub)
            else:
                warn "pack ", i.image.filePath, " doesnt fit ", i.image.size

    endDraw(tm.mTilesSpriteSheet, gfs)
    tm.mTilesSpriteSheet.generateMipmap(c.gl)

    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

proc rebuildAllRows(tm: TileMap) =
    let numRows = tm.mapSize.height.int * (if tm.mOrientation == TileMapOrientation.orthogonal: 1 else: 2)
    # echo " num rows, ", numRows, " height ", tm.mapSize.height
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
    for i, lay in tm.layers:
        if lay.name == name:
            tm.removeLayer(i, name)
            return

proc itemsForPropertyName*[T](tm: TileMap, key: string): seq[tuple[obj: T, property: JsonNode]]=
    result = @[]
    when T is TileMapLayer | ImageMapLayer | BaseTileMapLayer:
        for lay in tm.layers:
            if lay of T and not lay.properties.isNil and key in lay.properties:
                result.add((obj:lay.T, property: lay.properties[key]))

    elif T is TileSheet | TileCollection:
        for ts in tm.tileSets:
            if ts of T and not ts.properties.isNil and key in ts.properties:
                result.add((obj:ts.T, property: ts.properties[key]))

    elif T is Tile:
        for ts in tm.tileSets:
            if ts of TileCollection:
                let tc = ts.TileCollection
                for tile in tc.collection:
                    if not tile.properties.isNil and key in tile.properties:
                        result.add((obj:tile.T, property: tile.properties[key]))

proc itemsForPropertyValue*[T, V](tm: TileMap, key: string, value: V): seq[tuple[obj: T, property: JsonNode]]=
    result = @[]
    for item in itemsForPropertyName[T](tm, key):
        when V is string:
            if item.property.kind == JString and item.property.str == value:
                result.add(item)
        elif V is int:
            if item.property.kind == JInt and item.property.num.int == value:
                result.add(item)
        elif V is float:
            if item.property.kind == JFloat and item.property.getFNum() == value:
                result.add(item)
        elif V is bool:
            if item.property.kind == JBool and item.property.getBVal() == value:
                result.add(item)

method visitProperties*(tm: BaseTileMapLayer, p: var PropertyVisitor) =
    if not tm.properties.isNil:
        for k, v in tm.properties:
            var val = $v
            p.visitProperty(k, val)

method componentNodeWasAddedToSceneView*(tm: TileMap)=
    tm.layers = @[]
    for n in tm.node.children:
        let lc = n.componentIfAvailable(BaseTileMapLayer)
        if not lc.isNil:
            lc.map = tm
            if lc of TileMapLayer:
                lc.TileMapLayer.tileSize = tm.tileSize
            tm.layers.add(lc)

    tm.packAllTilesToSheet()
    tm.rebuildAllRowsIfNeeded()

method componentNodeWillBeRemovedFromSceneView*(tm: TileMap) =
    let c = currentContext()
    if tm.mQuadIndexBuffer != invalidBuffer:
        c.gl.deleteBuffer(tm.mQuadIndexBuffer)
        tm.mQuadIndexBuffer = invalidBuffer

    for row in tm.drawingRows:
        if row.vertexBuffer != invalidBuffer:
            c.gl.deleteBuffer(row.vertexBuffer)

#[

    SERIALIZATION / DESERIALIZATION

]#

proc toProperties(rps: seq[RawProperties]): Properties=
    result = newTable[string, JsonNode]()
    for rp in rps:
        result[rp.name] = parseJson(rp.value)

proc toRawProperties(ps: Properties): seq[RawProperties]=
    result = @[]
    for name, value in ps:
        result.add((name: name, value: $value))

proc toPhantom(c: TileMap, p: var object) {.used.} =
    var rawTileSets = newSeq[TileSetRaw]()
    for ts in c.tileSets:
        var rts: TileSetRaw
        rts.firstgid = ts.firstGid.int32
        if ts of TileSheet:
            rts.image = ts.TileSheet.sheet
            rts.columns = ts.TileSheet.columns.int32
        else:
            rts.collection = @[]
            let tc = ts.TileCollection
            for i, t in tc.collection:
                if not t.image.isNil:
                    var rt: RawTile
                    rt.image = t.image
                    rt.id = i.int32
                    if not t.properties.isNil:
                        rt.rawProperties = t.properties.toRawProperties()
                    rts.collection.add(rt)

        rts.tileSize = ts.tileSize
        rts.name = ts.name
        rawTileSets.add(rts)

    p.tileSets = rawTileSets

    if not c.properties.isNil:
        p.rawProperties = c.properties.toRawProperties()

proc fromPhantom(c: TileMap, p: object) =
    c.tileSets = @[]
    for rts in p.tileSets:
        var ts: BaseTileSet
        if not rts.image.isNil:
            var sts = new(TileSheet)
            sts.sheet = rts.image
            sts.columns = rts.columns
            ts = sts
        else:
            var cts = new(TileCollection)
            cts.collection = @[]
            for t in rts.collection:
                if t.id >= cts.collection.len:
                    cts.collection.setLen(t.id + 1)
                cts.collection[t.id] = (image: t.image, properties: (if not t.rawProperties.isNil: t.rawProperties.toProperties() else: nil), gid: t.id.int + rts.firstGid.int)
            ts = cts

        ts.name = rts.name
        ts.firstgid = rts.firstGid
        ts.tileSize = rts.tileSize
        c.tileSets.add(ts)

    if not p.rawProperties.isNil:
        c.properties = p.rawProperties.toProperties()

proc toPhantom(c: TileMapLayer, p: var object) {.used.} =
    if not c.properties.isNil:
        p.rawProperties = c.properties.toRawProperties()

proc fromPhantom(c: TileMapLayer, p: object) =
    if not p.rawProperties.isNil:
        c.properties = p.rawProperties.toProperties()

proc toPhantom(c: ImageMapLayer, p: var object) {.used.} =
    if not c.properties.isNil:
        p.rawProperties = c.properties.toRawProperties()

proc fromPhantom(c: ImageMapLayer, p: object) =
    if not p.rawProperties.isNil:
        c.properties = p.rawProperties.toProperties()

genSerializationCodeForComponent(TileMap)
genSerializationCodeForComponent(TileMapLayer)
genSerializationCodeForComponent(ImageMapLayer)

registerComponent(TileMap, "TileMap")
registerComponent(ImageMapLayer, "TileMap")
registerComponent(TileMapLayer, "TileMap")
