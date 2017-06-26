import rod / [ component, node, viewport, rod_types ]
import rod / component / [ sprite ]
import rod / tools / [ serializer, debug_draw ]
import nimx / [ types, property_visitor, matrixes, portable_gl, context, image, resource,
                render_to_image, rect_packer ]

import json, tables, strutils, logging, sequtils, algorithm, math
import nimx.assets.asset_loading
import boolseq

type
    LayerRange = tuple
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

    Properties = TableRef[string, Property]

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

    BaseTileMapLayer = ref object of Component
        size: Size
        offset*: Size
        actualSize: LayerRange
        map: TileMap
        properties: Properties

    TileMapLayer* = ref object of BaseTileMapLayer
        data*: seq[int16]
        tileSize: Vector3

    ImageMapLayer* = ref object of BaseTileMapLayer
        image*: Image

    BaseTileSet = ref object of RootObj
        tileSize: Vector3
        firstGid: int
        tilesCount: int
        name: string
        properties: Properties

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

    TidAndImage = tuple[image: Image, tid: int16]


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

void main() {
    gl_FragColor = texture2D(texUnit, vTexCoord);
    float a = gl_FragColor.a;
    a = clamp(step(0.49, gl_FragColor.a) + a, 0.0, 1.0);
    gl_FragColor.a = a;
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

method canDrawTile(ts: BaseTileSet, tid: int): bool=
    result = tid >= ts.firstGid and tid < ts.firstGid + ts.tilesCount

method canDrawTile(ts: TileCollection, tid: int): bool=
    let tid = tid - ts.firstGid
    result = tid >= 0 and tid < ts.collection.len and not ts.collection[tid].image.isNil

method drawTile(ts: BaseTileSet, tid: int, r: Rect, a: float) {.base.}=
    raise newException(Exception, "Abstract method called!")

method drawTile(ts: TileSheet, tid: int, r: Rect, a: float)=
    let tilePos = tid - ts.firstGid
    let tileX = (tilePos mod ts.columns) * ts.tileSize.x.int
    let tileY = (tilePos div ts.columns) * ts.tileSize.y.int
    currentContext().drawImage(ts.sheet, r, newRect(tileX.float, tileY.float, ts.tileSize.x, ts.tileSize.y), a)

method drawTile(ts: TileCollection, tid: int, r: Rect, a: float)=
    let image = ts.collection[tid - ts.firstGid].image
    let imageSize = image.size
    var tr = r
    if imageSize.width.int != tr.width.int or imageSize.height.int != tr.height.int:
        tr.origin += newPoint(0, r.size.height - imageSize.height)
        tr.size = imageSize

    currentContext().drawImage(image, tr, alpha = a)

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

method drawLayer(layer: BaseTileMapLayer, tm: TileMap) {.base.} =
    raise newException(Exception, "Abstract method called!")

method drawLayer(layer: ImageMapLayer, tm: TileMap)=
    currentContext().drawImage(layer.image, newRect(layer.position.x, layer.position.y, layer.image.size.width, layer.image.size.height), alpha = layer.alpha)

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


proc layerIndexByName*(tm: TileMap, name: string): int =
    result = -1
    for i, l in tm.layers:
        if l.name == name:
            return i

proc insertLayer*(tm: TileMap, layerNode: Node, idx: int, layerWidth: int = 0)=
    var layer = layerNode.componentIfAvailable(TileMapLayer).BaseTileMapLayer
    if layer.isNil:
        layer = layerNode.componentIfAvailable(ImageMapLayer).BaseTileMapLayer

    if not layer.isNil:
        if layer of TileMapLayer:
            let lWidth = if layerWidth == 0: tm.mapSize.width.int else: layerWidth
            layer.actualSize.minx = 0
            layer.actualSize.miny = 0
            layer.actualSize.maxx = lWidth
            layer.actualSize.maxy = layer.TileMapLayer.data.len div lWidth
        layer.map = tm
        tm.node.addChild(layerNode)
        tm.layers.insert(layer, idx)
        if tm.drawingRows.len > 0:
            tm.rebuildAllRowsIfNeeded()

proc addLayer*(tm: TileMap, layerNode: Node, layerWidth: int = 0)=
    tm.insertLayer(layerNode, layerWidth, tm.layers.len)

proc removeLayer*(tm: TileMap, name: string)=
    for i, l in tm.layers:
        if l.name == name:
            tm.layers.del(i)
            l.node.removeFromParent()
            tm.rebuildAllRowsIfNeeded()
            return

proc layerByName*[T](tm: TileMap, name: string): T =
    for l in tm.layers:
        if l.name == name and l of T:
            return l.T

proc tileAtXY*(layer: TileMapLayer, x, y: int): int=
    if (x >= layer.actualSize.minx and x < layer.actualSize.maxx) and (y >= layer.actualSize.miny and y < layer.actualSize.maxy):

        let idx = (layer.actualSize.maxx - layer.actualSize.minx) * (y - layer.actualSize.miny) + (x - layer.actualSize.minx)
        if idx < layer.data.len:
            result = layer.data[idx]

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

proc tileAtPosition*(layer: TileMapLayer, position: Vector3): int=
    let coords = layer.tileXYAtPosition(position - layer.position)
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

proc visibleTilesAtPositionDebugInfo*(tm: TileMap, position: Vector3): seq[tuple[layerName: string, x: int, y: int, tileid: int]]=
    result = @[]
    for l in tm.layers:
        if l of TileMapLayer and l.enabled:
            let coords = l.TileMapLayer.tileXYAtPosition(position - l.position)
            let tileid = l.TileMapLayer.tileAtXY(coords.x, coords.y)
            if tileid != 0:
                result.add((layerName: l.name, x: coords.x, y: coords.y, tileid: tileid))

method drawLayer(layer: TileMapLayer, tm: TileMap) {.deprecated.}=
    var r = tm.layerRect(layer)
    var worldLayerRect = newRect(newPoint(layer.node.worldPos().x, layer.node.worldPos().y), r.size)
    let viewRect = layer.getViewportRect()

    # if worldLayerRect.intersect(viewRect):
    let (cols, cole, rows, rowe) = layer.getDrawRange(viewRect, tm.tileSize)

    let mapWidth = tm.mapSize.width.int
    var tileDrawRect = newRect(0.0, 0.0, 0.0, 0.0)
    let camera = layer.node.sceneView.camera

    for y in cols .. cole:
        let mapWidthY = mapWidth * y
        for x in rows .. rowe:
            let pos = mapWidthY + x

            let tileId = layer.tileAtXY(x, y)
            if tileId == 0: continue

            tm.tileDrawRect(tm, pos, tileDrawRect)

            for tileSet in tm.tileSets:
                if tileSet.canDrawTile(tileId):
                    tileSet.drawTile(tileId, tileDrawRect, layer.alpha)
                    break

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

    gl.uniformMatrix4fv(gl.getUniformLocation(program, "uModelViewProjectionMatrix"), false, c.transform)

    var quad: array[4, float32]
    let tex = tm.mTilesSpriteSheet.getTextureQuad(gl, quad)

    gl.bindTexture(gl.TEXTURE_2D, tex)

    gl.enableVertexAttribArray(saPosition.GLuint)
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, tm.quadIndexBuffer)

method beforeDraw*(tm: TileMap, index: int): bool =
    result = true # Prevent child nodes from drawing. We shall draw them.
    if tm.drawingRows.len == 0: return

    tm.rebuildAllRowsIfNeeded()

    let c = currentContext()
    let gl = c.gl

    var vboStateValid = false
    var iTileLayer = 0

    for layer in tm.layers:
        if layer.node.enabled:
            if layer of TileMapLayer:
                for i in 0 ..< tm.drawingRows.len:
                    assert(tm.drawingRows[i].vertexBuffer != invalidBuffer)
                    #echo "Drawing row: ", i, ", quads: ", tm.drawingRows[i].numberOfQuads

                    let quadStartIndex = tm.drawingRows[i].vboLayerBreaks[iTileLayer]
                    let quadEndIndex = tm.drawingRows[i].vboLayerBreaks[iTileLayer + 1]
                    let numQuads = quadEndIndex - quadStartIndex

                    if numQuads != 0:
                        if not vboStateValid:
                            tm.prepareVBOs()
                            vboStateValid = true

                        const floatsPerQuad = 16 # Single quad occupies 16 floats in vertex buffer

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
                    r.origin = newPoint(iml.node.position.x, iml.node.position.y)
                    c.drawImage(iml.image, r, alpha = iml.node.alpha)

method imageForTile(ts: BaseTileSet, tid: int16): Image {.base.} = discard

method imageForTile(ts: TileCollection, tid: int16): Image =
    let tid = tid - ts.firstGid
    if tid >= 0 and tid < ts.collection.len:
        return ts.collection[tid].image

proc imageForTile*(tm: TileMap, tid: int16): Image =
    for ts in tm.tileSets:
        result = ts.imageForTile(tid)
        if not result.isNil:
            return

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

method getBBox*(tm: TileMap): BBox =
    result.maxPoint = newVector3(low(int).Coord/2.0, low(int).Coord/2.0, 1.0)
    result.minPoint = newVector3(high(int).Coord/2.0, high(int).Coord/2.0, 0.0)

    for l in tm.layers:
        if l of TileMapLayer:
            let r = tm.layerRect(l.TileMapLayer)
            if r.x < result.minPoint.x:
                result.minPoint.x = r.x
            if r.y < result.minPoint.y:
                result.minPoint.y = r.y
            if r.width + r.x > result.maxPoint.x:
                result.maxPoint.x = r.width + r.x
            if r.height + r.y > result.maxPoint.y:
                result.maxPoint.y = r.height + r.y

    echo "getBBox tiledmap ", [result.minPoint, result.maxPoint]

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

proc offsetVertexData(data: var array[16, float32], xOff, yOff: float32) {.inline.} =
    data[0] += xOff
    data[1] += yOff
    data[4] += xOff
    data[5] += yOff
    data[8] += xOff
    data[9] += yOff
    data[12] += xOff
    data[13] += yOff

proc addTileToVertexData(tm: TileMap, id: int16, xOff, yOff: float32, data: var seq[float32]): bool {.inline.} =
    var quadData: array[16, float32]
    result = tm.getQuadDataForTile(id, quadData)
    if result:
        offsetVertexData(quadData, xOff, yOff)
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
                var tilesInLayerRow = layerWidth div 2
                #echo "layer: ", layer.name, ":" , tml.actualSize, ", tilesInLayerRow: ", tilesInLayerRow

                let tileYInLayer = tileY - tml.actualSize.miny

                let yOff = yOffBase + tml.offset.height

                #for i in 0 ..< tilesInLayerRow:
                var i = tml.actualSize.minx
                if layerStartOdd != odd:
                    inc i

                while i < maxx:
                    let tileX = i - tml.actualSize.minx # * 2 + odd + layerStartOdd
                    let tileIdx = tileYInLayer * layerWidth + tileX
                    #echo "tileYInLayer: ", tileYInLayer, ", tileX: ", tileX, ", idx: ", tileIdx
                    let tile = tml.data[tileIdx]

                    let xOff = Coord(tileX + tml.actualSize.minx) * tm.tileSize.x / 2 + tml.offset.width
                    #echo "xOff: ", xOff

                    if tile != 0:
                        if not tm.addTileToVertexData(tile, xOff, yOff, vertexData):
                            let n = tm.createObjectForTile(tile, xOff, yOff)
                            if not n.isNil:
                                layer.node.addChild(n)
                                if row.objects.isNil: row.objects = @[]
                                row.objects.add(n)
                            else:
                                echo "TILE NOT FOUND: ", tile

                    i += 2

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

    const maxWidth = 700
    const maxHeight = 400

    allImages.keepItIf:
        let sz = it.image.size
        sz.width < maxWidth and sz.height < maxHeight

    allImages.sort() do(i1, i2: TidAndImage) -> int:
        let sz1 = i1.image.size
        let sz2 = i2.image.size
        cmp(sz1.width * sz1.height, sz2.width * sz2.height)

    let texWidth = 2048
    let texHeight = 4096

    assert(isPowerOfTwo(texWidth) and isPowerOfTwo(texHeight))

    tm.mTilesSpriteSheet = imageWithSize(newSize(texWidth.Coord, texHeight.Coord))

    var gfs: GlFrameState
    beginDraw(tm.mTilesSpriteSheet, gfs)
    let c = currentContext()
    let gl = c.gl
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

            let p = rp.pack(sz.width.int32, sz.height.int32)
            assert(p.hasSpace)

            #echo "pos: ", p

            var r: Rect
            r.origin.x = Coord(p.x)
            r.origin.y = Coord(p.y)
            r.size = sz
            c.drawImage(img, r)

            let yOff = tm.tileSize.y - sz.height

            const dv = -1.0
            const d = 0.5

            var coords: array[16, float32]
            coords[0] = dv
            coords[1] = dv + yOff
            coords[2] = (p.x.Coord + d) / texWidth.Coord
            coords[3] = (p.y.Coord + d) / texHeight.Coord

            coords[4] = dv
            coords[5] = sz.height + yOff - dv
            coords[6] = (p.x.Coord + d) / texWidth.Coord
            coords[7] = (p.y.Coord + sz.height - d) / texHeight.Coord

            coords[8] = sz.width - dv
            coords[9] = sz.height + yOff - dv
            coords[10] = (p.x.Coord + sz.width - d) / texWidth.Coord
            coords[11] = (p.y.Coord + sz.height - d) / texHeight.Coord

            coords[12] = sz.width - dv
            coords[13] = 0 + yOff + dv
            coords[14] = (p.x.Coord + sz.width - d) / texWidth.Coord
            coords[15] = (p.y.Coord + d) / texHeight.Coord
            tm.tileVCoords[i.tid] = coords
    endDraw(tm.mTilesSpriteSheet, gfs)
    tm.mTilesSpriteSheet.generateMipmap(c.gl)

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

#todo: serialize support
# method deserialize*(c: TileMap, j: JsonNode, serealizer: Serializer) =
#     discard

# method serialize*(c: TileMap, s: Serializer): JsonNode=
#     result = newJObject()

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
        result = newTable[string, Property](node["propertytypes"].len)

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
                        for jLayer in jl["layers"]:
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
